//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import android.content.Context
import android.net.Uri
import android.telecom.DisconnectCause
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallException
import androidx.core.telecom.CallsManager
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Telecom did not add the call: it is missing, refused, hung or the attempt was torn down. Never a [CancellationException]. */
internal class TelecomStartException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Waits for [started] at most [timeout]. A timeout, a refusal or a cancelled [started] becomes a
 * [TelecomStartException] with a readable message, and so does any other failure of [started]; only the caller's own
 * cancellation stays a [CancellationException].
 */
internal suspend fun <T : Any> awaitTelecomStart(started: Deferred<T>, timeout: Duration): T {
    val result = try {
        withTimeoutOrNull(timeout) { started.await() }
    } catch (e: CancellationException) {
        currentCoroutineContext().ensureActive()
        throw TelecomStartException("Telecom cancelled the call", e)
    } catch (e: CallException) {
        throw TelecomStartException("Telecom refused the call (code ${e.code})", e)
    } catch (e: Exception) {
        throw TelecomStartException("Telecom is not available ($e)", e)
    }
    return result ?: throw TelecomStartException("Telecom did not answer in time")
}

/**
 * Runs one request to Telecom for at most [timeout]; no answer in time is [CallException.ERROR_OPERATION_TIMED_OUT].
 * Exceptions, the caller's cancellation among them, are passed on.
 */
internal suspend fun boundedTelecomRequest(timeout: Duration, block: suspend () -> CallControlResult): CallControlResult =
    withTimeoutOrNull(timeout) { block() } ?: CallControlResult.Error(CallException.ERROR_OPERATION_TIMED_OUT)

/** What [TelecomCallManager] uses of [CallsManager]; the JVM tests put a fake in its place. */
internal interface TelecomCalls {
    /** Registers the app with Telecom (once). */
    fun register()

    /**
     * [CallsManager.addCall] for an outgoing audio call to [number]; suspends until the call ends. [onDisconnect] gets
     * Telecom's disconnect cause as text.
     */
    suspend fun addCall(
        number: String,
        onDisconnect: suspend (cause: String) -> Unit,
        onSetActive: suspend () -> Unit,
        onSetInactive: suspend () -> Unit,
        block: CallControlScope.() -> Unit,
    )

    /** Asks Telecom to end the call of [control] for [cause]. */
    suspend fun disconnect(control: CallControlScope, cause: TelecomEndCause): CallControlResult
}

private class CoreTelecomCalls(context: Context) : TelecomCalls {
    private val manager = CallsManager(context.applicationContext)
    private var registered = false

    override fun register() {
        if (registered) return
        manager.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE)
        registered = true
    }

    override suspend fun addCall(
        number: String,
        onDisconnect: suspend (cause: String) -> Unit,
        onSetActive: suspend () -> Unit,
        onSetInactive: suspend () -> Unit,
        block: CallControlScope.() -> Unit,
    ) {
        val attributes = CallAttributesCompat(
            displayName = number,
            address = Uri.fromParts("tel", number, null),
            direction = CallAttributesCompat.DIRECTION_OUTGOING,
            callType = CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
            callCapabilities = CallAttributesCompat.SUPPORTS_SET_INACTIVE,
        )
        manager.addCall(
            attributes,
            onAnswer = {},
            onDisconnect = { cause -> onDisconnect(describe(cause)) },
            onSetActive = onSetActive,
            onSetInactive = onSetInactive,
            block = block,
        )
    }

    override suspend fun disconnect(control: CallControlScope, cause: TelecomEndCause): CallControlResult {
        // core-telecom takes only LOCAL, REMOTE, MISSED and REJECTED: anything else it refuses with an exception, and
        // the call would stay in Telecom. A call that failed is reported as ended by the other side.
        val code = when (cause) {
            TelecomEndCause.Local -> DisconnectCause.LOCAL
            TelecomEndCause.Remote, TelecomEndCause.Error -> DisconnectCause.REMOTE
            TelecomEndCause.Rejected -> DisconnectCause.REJECTED
        }
        return control.disconnect(DisconnectCause(code))
    }

    private fun describe(cause: DisconnectCause): String {
        val reason = cause.reason?.takeIf { it.isNotBlank() }?.let { ", $it" } ?: ""
        return "code ${cause.code}$reason"
    }
}

/**
 * Self-managed calls through `androidx.core.telecom`. [CallsManager.addCall] suspends until the call ends, so it runs
 * in [scope] (the main scope); [startCall] returns once its [CallControlScope] block is entered. Telecom's callbacks
 * are handed to [TelecomCallEvents] and never throw: a throw would tear the call down.
 */
internal class TelecomCallManager internal constructor(
    private val scope: CoroutineScope,
    private val logs: (String) -> Unit,
    private val calls: TelecomCalls,
) : TelecomStarting {
    constructor(context: Context, scope: CoroutineScope, logs: (String) -> Unit) : this(scope, logs, CoreTelecomCalls(context))

    override suspend fun startCall(number: String, events: TelecomCallEvents): TelecomSession {
        try {
            calls.register()
        } catch (e: Exception) {
            // No Telecom on this device (a tablet without telephony features), or it refuses self-managed calls.
            throw TelecomStartException("Telecom is not available ($e)", e)
        }
        val session = Session(events)
        val started = CompletableDeferred<CallControlScope>()
        session.addCall = scope.launch {
            try {
                calls.addCall(
                    number,
                    onDisconnect = { session.disconnectedByTelecom(it) },
                    onSetActive = { session.fromSystem("resume") { events.holdFromTelecom(false) } },
                    onSetInactive = { session.fromSystem("hold") { events.holdFromTelecom(true) } },
                ) {
                    session.begin(this)
                    started.complete(this)
                }
            } catch (e: CancellationException) {
                started.cancel(e)
                throw e
            } catch (e: Exception) {
                started.completeExceptionally(e)
            } finally {
                session.finish()
            }
        }
        try {
            awaitTelecomStart(started, START_TIMEOUT)
        } catch (e: Throwable) {
            if (e !is CancellationException) log("start failed: ${e.message ?: e}")
            // The caller gave up or Telecom did not answer in time: no stale system call may stay behind.
            session.abandon()
            throw e
        }
        log("call accepted")
        return session
    }

    private fun log(message: String) = logs("[telecom] $message")

    /** One call's handle; main-thread confined like the scope it runs in. */
    private inner class Session(private val events: TelecomCallEvents) : TelecomSession {
        /** The coroutine running `addCall`; cancelled when Telecom does not take our end report. */
        var addCall: Job? = null
        private var control: CallControlScope? = null
        private var ended = false
        private var collectors: Job? = null
        private var abandoned = false
        private val endpoints = mutableMapOf<String, CallEndpointCompat>()

        override val routes = MutableStateFlow<List<AudioRoute>>(emptyList())
        override val current = MutableStateFlow<AudioRoute?>(null)

        fun begin(control: CallControlScope) {
            this.control = control
            collectors = scope.launch {
                launch {
                    control.availableEndpoints.collect { list ->
                        endpoints.clear()
                        list.forEach { endpoints[it.identifier.toString()] = it }
                        routes.value = list.map(::route)
                    }
                }
                launch { control.currentCallEndpoint.collect { current.value = route(it) } }
                launch { control.isMuted.collect { muted -> fromSystem("mute $muted") { events.muteFromTelecom(muted) } } }
            }
            if (abandoned) scope.launch { reportEnded(TelecomEndCause.Error) }
        }

        fun finish() {
            // The system side ended without onDisconnect and without our report: the SDK call must end too.
            if (control != null && !ended && !abandoned) {
                log("the system ended the call without a disconnect")
                scope.launch { deliver("hangup") { events.hangupFromTelecom() } }
            }
            ended = true
            collectors?.cancel()
            control = null
        }

        /** Nobody holds this session: end the call, now or when Telecom adds it after all. */
        fun abandon() {
            abandoned = true
            if (control != null) scope.launch { reportEnded(TelecomEndCause.Error) }
        }

        suspend fun disconnectedByTelecom(cause: String) {
            log("disconnect requested by the system ($cause)")
            ended = true
            deliver("hangup") { events.hangupFromTelecom() }
        }

        /** A request of the system: logged, then handed on. */
        suspend fun fromSystem(what: String, block: suspend () -> Unit) {
            log("$what requested by the system")
            deliver(what, block)
        }

        /** A Telecom callback must not throw: that would end the call instead of declining one request. */
        private suspend fun deliver(what: String, block: suspend () -> Unit) {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("$what failed: $e")
            }
        }

        override suspend fun setHeld(held: Boolean): Boolean {
            val control = control ?: return false
            if (ended) return false
            return request(if (held) "setInactive" else "setActive") {
                if (held) control.setInactive() else control.setActive()
            }
        }

        override suspend fun reportConnected() {
            val control = control ?: return
            if (ended) return
            request("setActive") { control.setActive() }
        }

        override suspend fun reportEnded(cause: TelecomEndCause) {
            val control = control ?: return
            if (ended) return
            ended = true // also when Telecom does not answer the disconnect in time
            if (!request("disconnect") { calls.disconnect(control, cause) }) {
                // Telecom did not take the end: stop waiting for it, so that addCall and its collectors do not stay.
                addCall?.cancel()
            }
        }

        override suspend fun select(route: AudioRoute) {
            val control = control ?: return
            val endpoint = endpoints[route.id] ?: return
            request("requestEndpointChange") { control.requestEndpointChange(endpoint) }
        }

        /** False when Telecom refuses, throws or does not answer within [REQUEST_TIMEOUT]; each of these is logged. */
        private suspend fun request(what: String, block: suspend () -> CallControlResult): Boolean {
            val result = try {
                boundedTelecomRequest(REQUEST_TIMEOUT, block)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("$what failed: $e")
                return false
            }
            if (result is CallControlResult.Error) {
                log(if (result.errorCode == CallException.ERROR_OPERATION_TIMED_OUT) "$what timed out" else "$what refused (code ${result.errorCode})")
            }
            return result is CallControlResult.Success
        }
    }

    private companion object {
        /** core-telecom gives up after 5 s itself; this only guards against it never answering. */
        val START_TIMEOUT = 10.seconds

        /** A hold, an end report or a route change that Telecom never answers must not hang the cleanup. */
        val REQUEST_TIMEOUT = 5.seconds

        fun route(endpoint: CallEndpointCompat) = AudioRoute(
            id = endpoint.identifier.toString(),
            kind = when (endpoint.type) {
                CallEndpointCompat.TYPE_EARPIECE -> AudioRoute.Kind.Earpiece
                CallEndpointCompat.TYPE_SPEAKER -> AudioRoute.Kind.Speaker
                CallEndpointCompat.TYPE_BLUETOOTH -> AudioRoute.Kind.Bluetooth
                CallEndpointCompat.TYPE_WIRED_HEADSET -> AudioRoute.Kind.Wired
                else -> AudioRoute.Kind.Other
            },
            name = endpoint.name.toString(),
        )
    }
}
