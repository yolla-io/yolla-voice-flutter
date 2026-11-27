//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import com.yollacalls.android.voice.Call
import com.yollacalls.android.voice.CallStats
import com.yollacalls.android.voice.VoiceError
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A snapshot of the client's call as the plugin reports it. */
internal data class CallView(
    val call: Call,
    /** The system asked for a hold the SDK refused; the plugin keeps the microphone closed instead. */
    val heldByMute: Boolean = false,
) {
    val isOnHold: Boolean get() = call.isOnHold || heldByMute
}

internal data class AudioRoutesView(val routes: List<AudioRoute> = emptyList(), val current: AudioRoute? = null)

/**
 * The call of the process and everything the system needs around it: Telecom, the foreground service with the call
 * notification, the audio routes, the proximity lock. It outlives the Flutter engine and the Activity, so a call goes
 * on when the app's screen is closed; the plugin instances only look at it and send it commands.
 *
 * Main-thread confined; [scope] is a main scope.
 */
internal class VoiceRuntime(
    private val voice: () -> VoiceConnecting,
    private val telecom: TelecomStarting,
    private val service: CallServiceControlling,
    private val directRouting: DirectAudioRouting,
    proximity: ProximityLocking,
    private val scope: CoroutineScope,
    private val log: (String) -> Unit,
    /** The grants as they are, when there is no screen to ask from. */
    private val currentPermissions: () -> CallPermissions,
    private val destination: (callToken: String) -> String? = ::destinationOf,
) {
    /** Set by the plugin while it has an Activity. */
    var permissions: PermissionRequesting? = null

    private val mutableCall = MutableStateFlow<CallView?>(null)

    /** Null until the first call; an ended call stays until the next one starts. */
    val call: StateFlow<CallView?> = mutableCall

    private val routing = MutableStateFlow<AudioRouting?>(null)
    private val mutableRoutes = MutableStateFlow(AudioRoutesView())

    /** The routes of the call in progress; empty without one. */
    val routes: StateFlow<AudioRoutesView> = mutableRoutes

    /** Created at the first call and kept: creating it starts nothing, the first call starts WebRTC. */
    private var client: VoiceConnecting? = null
    private var session: Session? = null

    /** The call being set up, from the moment it is asked for until the SDK has it or it failed. */
    private var attempt: Session? = null
    private var placing = false

    init {
        @OptIn(ExperimentalCoroutinesApi::class)
        routing.flatMapLatest { routing ->
            if (routing == null) flowOf(AudioRoutesView()) else combine(routing.routes, routing.current, ::AudioRoutesView)
        }.combine(mutableCall) { routes, call ->
            mutableRoutes.value = routes
            proximity.update(callActive = call?.call?.state?.let { it != Call.State.Disconnected } == true, route = routes.current)
        }.launchIn(scope)
    }

    /**
     * Places a call. Returns once the SDK has it (the first snapshot is in [call]); throws [VoiceError] when no call
     * started: `call_in_progress`, `invalid_token`, `microphone_denied`, `cancelled` (a hang-up arrived meanwhile).
     */
    suspend fun connect(callToken: String) {
        if (placing || session?.isActive == true) throw VoiceError.callInProgress
        placing = true
        try {
            start(callToken)
        } finally {
            placing = false
            attempt = null
        }
    }

    private suspend fun start(callToken: String) {
        val number = destination(callToken) ?: throw VoiceError("invalid_token", "The call token cannot be read")
        val session = Session(number)
        attempt = session
        val granted = permissions?.requestCallPermissions() ?: currentPermissions()
        if (!granted.microphone) throw VoiceError.microphoneDenied
        if (!granted.notifications) log("notifications are off: the call notification will not be shown")
        // The previous call may still be playing its end tone and reporting its end.
        this.session?.finished?.join()
        // Hung up while the user was asked for the microphone: nothing is started at all.
        if (session.hangupRequested) throw VoiceError.cancelled
        this.session = session
        try {
            service.start(number, granted.microphone, telecom = true)
            session.telecom = try {
                telecom.startCall(number, session)
            } catch (e: TelecomStartException) {
                // A device without Telecom, or one that refuses: the call goes on without the system's call screen.
                log("[telecom] not used for this call: ${e.message}")
                null
            }
            routing.value = session.telecom ?: directRouting
            // Hung up while the service or Telecom was starting: nothing is dialed at all.
            if (session.hangupRequested) throw VoiceError.cancelled
            session.connect(client ?: voice().also { client = it }, callToken)
        } catch (e: Throwable) {
            // No call started. Throwable, not Exception: a LinkageError must not skip the cleanup.
            log("connect failed: ${describe(e)}")
            session.abandon(if (session.hangupRequested) TelecomEndCause.Local else TelecomEndCause.Error)
            throw e
        }
    }

    /** Ends the call at any moment, also while it is being set up; does nothing without one. */
    fun hangup() {
        (attempt ?: session?.takeIf { it.isActive })?.requestHangup(fromTelecom = false)
    }

    suspend fun setMuted(muted: Boolean) = active().setMuted(muted)
    suspend fun setOnHold(hold: Boolean) = active().setOnHold(hold)
    suspend fun sendDigits(digits: String) = active().voice().sendDigits(digits)
    suspend fun stats(): CallStats? = client?.stats()

    suspend fun selectRoute(id: String) {
        val routing = routing.value ?: throw VoiceError.invalidCallState
        val route = routing.routes.value.firstOrNull { it.id == id } ?: return
        routing.select(route)
    }

    private fun active(): Session = session?.takeIf { it.isActive && it.connected } ?: throw VoiceError.invalidCallState

    private fun describe(e: Throwable) = if (e is VoiceError) "${e.code}: ${e.message}" else e.toString()

    /** One call: follows its snapshots, keeps Telecom in step and cleans up after it. */
    private inner class Session(val number: String) : TelecomCallEvents {
        var telecom: TelecomSession? = null
        var hangupRequested = false
            private set

        /** False once the call has ended (or never started). */
        var isActive = true
            private set

        /** True once the SDK has the call. */
        var connected = false
            private set

        /** Completes when the end was reported to Telecom and the service released. */
        var finished: Job? = null
            private set

        private var voice: VoiceConnecting? = null
        private var last: Call? = null
        private var reportedConnected = false
        private var endedViaTelecom = false
        private var heldByMute = false
        private var mutedBeforeHold = false

        fun voice(): VoiceConnecting = voice ?: throw VoiceError.invalidCallState

        /**
         * Places the call on [voice] and follows it to its end. `connect` puts the new call's first snapshot into
         * `voice.call` before it returns, so the value read right after it is this call, never the ended previous one.
         * A StateFlow may skip snapshots, never the latest: the `Disconnected` one is the call's last and stays until
         * the next `connect`, so the end is always seen.
         */
        fun connect(voice: VoiceConnecting, callToken: String) {
            voice.connect(callToken)
            this.voice = voice
            connected = true
            val callID = voice.call.value?.callID ?: throw VoiceError.invalidCallState
            scope.launch {
                voice.call
                    .transformWhile { call ->
                        if (call?.callID != callID) return@transformWhile false
                        emit(call)
                        call.state != Call.State.Disconnected
                    }
                    .collect(::apply)
            }
            if (hangupRequested) voice.hangup()
        }

        /** The call never started: the system's side of it is taken down. */
        suspend fun abandon(cause: TelecomEndCause) = withContext(NonCancellable) {
            isActive = false
            release(cause)
        }

        fun requestHangup(fromTelecom: Boolean) {
            hangupRequested = true
            log("hangup" + if (fromTelecom) " (from Telecom)" else "")
            voice?.hangup()
        }

        suspend fun setMuted(muted: Boolean) = voice().setMuted(muted)

        /** Telecom has a say in a hold: it is asked first, and told again when the SDK refuses. */
        suspend fun setOnHold(hold: Boolean) {
            val telecom = telecom
            if (telecom != null && !telecom.setHeld(hold)) {
                throw VoiceError(SYSTEM_CALL_FAILED, "Telecom did not allow the hold change")
            }
            if (!hold && heldByMute) {
                endHoldByMute()
                return
            }
            try {
                voice().setOnHold(hold)
            } catch (e: VoiceError) {
                telecom?.setHeld(!hold)
                throw e
            }
        }

        // region Requests of the system; they must not throw

        override suspend fun hangupFromTelecom() {
            endedViaTelecom = true
            requestHangup(fromTelecom = true)
        }

        override suspend fun holdFromTelecom(hold: Boolean) {
            val call = last
            if (hold) {
                if (call?.state != Call.State.Connected) {
                    // The system wants the line (another call came in) and this call cannot be held yet: it ends.
                    log("hold requested by the system while not connected")
                    requestHangup(fromTelecom = false)
                    return
                }
                if (call.isOnHold || heldByMute) return
                quietly("hold") { voice().setOnHold(true) } ?: run {
                    // The SDK refused: keep the system's view of the call and close the microphone instead.
                    heldByMute = true
                    mutedBeforeHold = call.isMuted
                    quietly("mute") { voice().setMuted(true) }
                    publish()
                }
            } else if (heldByMute) {
                endHoldByMute()
            } else {
                quietly("resume") { voice().setOnHold(false) }
            }
        }

        override suspend fun muteFromTelecom(muted: Boolean) {
            // Telecom tells its mute state as soon as it has the call, before the SDK does: there is nothing to mute yet.
            val call = last ?: return
            if (muted != call.isMuted) quietly("mute") { voice().setMuted(muted) }
        }

        // endregion

        private suspend fun endHoldByMute() {
            heldByMute = false
            if (!mutedBeforeHold) quietly("unmute") { voice().setMuted(false) }
            publish()
        }

        /** Null when [block] failed; the failure is logged. */
        private suspend fun quietly(what: String, block: suspend () -> Unit): Unit? =
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("$what failed: ${describe(e)}")
                null
            }

        private fun publish() {
            val call = last ?: return
            mutableCall.value = CallView(call, heldByMute)
        }

        /** Publishes a snapshot and acts on what changed since the last one. States are read, not transitions. */
        private fun apply(call: Call) {
            last = call
            publish()
            when (call.state) {
                Call.State.Connected, Call.State.Reconnecting ->
                    if (!reportedConnected) {
                        reportedConnected = true
                        telecom?.let { scope.launch { it.reportConnected() } }
                    }
                Call.State.Disconnected -> didDisconnect(call.endReason ?: Call.EndReason.Failed)
                else -> Unit
            }
        }

        private fun didDisconnect(reason: Call.EndReason) {
            isActive = false
            log("ended: $reason")
            val cause = telecomEndCause(reason, endedViaTelecom)
            finished = scope.launch {
                // Held back so that the SDK's end or busy tone is heard before Telecom takes the audio away.
                delay(END_TONE_DELAY)
                withContext(NonCancellable) { release(cause) }
            }
        }

        private suspend fun release(cause: TelecomEndCause?) {
            if (routing.value === (telecom ?: directRouting)) routing.value = null
            if (telecom == null) directRouting.reset()
            if (cause != null) telecom?.reportEnded(cause)
            service.stop()
        }
    }

    companion object {
        /** The plugin's own error code: Telecom did not take a command. */
        const val SYSTEM_CALL_FAILED = "system_call_failed"

        /**
         * How long the end report to Telecom is held so that the SDK's end tone is heard. The SDK itself turns the
         * call audio off once the tone has played.
         */
        val END_TONE_DELAY: Duration = 600.milliseconds

        /**
         * What to report to Telecom; null when the end came from Telecom itself (it already knows). A local end that
         * bypassed Telecom is still reported so that no stale system call remains.
         */
        fun telecomEndCause(reason: Call.EndReason, endedViaTelecom: Boolean): TelecomEndCause? = when (reason) {
            Call.EndReason.RemoteHangup, Call.EndReason.NoAnswer -> TelecomEndCause.Remote
            Call.EndReason.Busy, Call.EndReason.Rejected -> TelecomEndCause.Rejected
            Call.EndReason.LocalHangup, Call.EndReason.Cancelled -> if (endedViaTelecom) null else TelecomEndCause.Local
            else -> TelecomEndCause.Error
        }
    }
}

/**
 * The destination a call token was issued for (its `to` claim), which Telecom and the call notification show before
 * the call exists. The token is not checked here: the SDK does that. Null when the token cannot be read.
 */
internal fun destinationOf(callToken: String): String? {
    val segments = callToken.split('.')
    if (segments.size != 3) return null
    return try {
        val payload = String(java.util.Base64.getUrlDecoder().decode(segments[1].trimEnd('=')), Charsets.UTF_8)
        val to = (Json.parseToJsonElement(payload) as? JsonObject)?.get("to") as? JsonPrimitive
        to?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() }
    } catch (_: IllegalArgumentException) {
        // Not base64, or not JSON (SerializationException is an IllegalArgumentException).
        null
    }
}
