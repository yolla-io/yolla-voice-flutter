//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import android.content.Context
import android.util.Log
import com.yollacalls.android.voice.Call
import com.yollacalls.android.voice.CallStats
import com.yollacalls.android.voice.CallerID
import com.yollacalls.android.voice.VoiceError
import com.yollacalls.android.voice.VoiceSDK
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The Android side of the Yolla Voice plugin: hands the Dart side's commands to the process's [VoiceRuntime] and
 * sends it the call's snapshots and audio routes. The call is not this object's: it lives in the runtime, and goes on
 * when the engine or the Activity is gone.
 */
class YollaVoicePlugin : FlutterPlugin, ActivityAware, VoiceHostApi {
    private lateinit var runtime: VoiceRuntime
    private var reports: Job? = null
    private var activity: ActivityPluginBinding? = null
    private var permissions: ActivityPermissions? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runtime = runtime(binding.applicationContext)
        VoiceHostApi.setUp(binding.binaryMessenger, this)
        val events = VoiceFlutterApi(binding.binaryMessenger)
        reports = scope.launch {
            launch { runtime.call.collect { call -> deliver { events.onCallChanged(call?.toMessage()) } } }
            launch { runtime.routes.collect { routes -> deliver { events.onAudioRoutesChanged(routes.toMessage()) } } }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VoiceHostApi.setUp(binding.binaryMessenger, null)
        reports?.cancel()
        reports = null
    }

    /** A Dart side that is not listening (yet, or any more) is not an error. */
    private suspend fun deliver(send: suspend () -> Unit) {
        try {
            send()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
    }

    // region ActivityAware: the Activity is only where the permissions are asked from

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        val permissions = ActivityPermissions(binding.activity)
        binding.addRequestPermissionsResultListener(permissions)
        activity = binding
        this.permissions = permissions
        runtime.permissions = permissions
    }

    override fun onDetachedFromActivity() {
        val permissions = permissions ?: return
        activity?.removeRequestPermissionsResultListener(permissions)
        permissions.finish()
        if (runtime.permissions === permissions) runtime.permissions = null
        activity = null
        this.permissions = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // endregion

    // region VoiceHostApi

    override fun sdkVersion(): String = VoiceSDK.version
    override fun currentCall(): CallMessage? = runtime.call.value?.toMessage()
    override fun audioRoutes(): AudioRoutesMessage = runtime.routes.value.toMessage()
    override suspend fun connect(callToken: String) = refusing { runtime.connect(callToken) }
    override fun hangup() = runtime.hangup()
    override suspend fun setMuted(muted: Boolean) = refusing { runtime.setMuted(muted) }
    override suspend fun setOnHold(hold: Boolean) = refusing { runtime.setOnHold(hold) }
    override suspend fun sendDigits(digits: String) = refusing { runtime.sendDigits(digits) }
    override suspend fun stats(): CallStatsMessage? = refusing { runtime.stats()?.toMessage() }
    override suspend fun selectAudioRoute(id: String) = refusing { runtime.selectRoute(id) }

    /** The SDK's refusal as the Dart side reads it: the code, the message and the SIP status. */
    private suspend fun <T> refusing(command: suspend () -> T): T =
        try {
            command()
        } catch (e: VoiceError) {
            throw FlutterError(e.code, e.message, e.sipStatus)
        }

    // endregion

    internal companion object {
        private const val TAG = "YollaVoice"
        private var shared: VoiceRuntime? = null

        /** Main-thread scope of the process: a call outlives every screen and engine. */
        private val scope = CoroutineScope(
            SupervisorJob() + Dispatchers.Main.immediate +
                CoroutineExceptionHandler { _, e -> Log.e(TAG, "uncaught in the plugin's scope", e) },
        )

        /** The one runtime of the process. Main thread. */
        private fun runtime(context: Context): VoiceRuntime = shared ?: run {
            val app = context.applicationContext
            val log: (String) -> Unit = { Log.i(TAG, it) }
            VoiceRuntime(
                voice = { SdkVoice(app) },
                telecom = TelecomCallManager(app, scope, log),
                service = CallServiceController(app, log) { shared?.hangup() },
                directRouting = DirectAudioRouter(app),
                proximity = ProximityLock(app),
                scope = scope,
                log = log,
                currentPermissions = { currentCallPermissions(app) },
            ).also { shared = it }
        }
    }
}

internal fun CallView.toMessage() = CallMessage(
    callId = call.callID,
    to = call.to,
    from = (call.from as? CallerID.Verified)?.number,
    state = when (call.state) {
        Call.State.Connecting -> CallStateMessage.CONNECTING
        Call.State.Ringing -> CallStateMessage.RINGING
        Call.State.Connected -> CallStateMessage.CONNECTED
        Call.State.Reconnecting -> CallStateMessage.RECONNECTING
        Call.State.Disconnected -> CallStateMessage.DISCONNECTED
    },
    endReason = when (call.endReason) {
        null -> null
        Call.EndReason.LocalHangup -> EndReasonMessage.LOCAL_HANGUP
        Call.EndReason.RemoteHangup -> EndReasonMessage.REMOTE_HANGUP
        Call.EndReason.Busy -> EndReasonMessage.BUSY
        Call.EndReason.NoAnswer -> EndReasonMessage.NO_ANSWER
        Call.EndReason.Rejected -> EndReasonMessage.REJECTED
        Call.EndReason.Failed -> EndReasonMessage.FAILED
        Call.EndReason.Cancelled -> EndReasonMessage.CANCELLED
    },
    error = call.error?.let { VoiceErrorMessage(it.code, it.message, it.sipStatus?.toLong()) },
    wasConnected = call.wasConnected,
    isMuted = call.isMuted,
    isOnHold = isOnHold,
    hasEarlyMedia = call.hasEarlyMedia,
    qualityWarnings = call.qualityWarnings.map { it.rawValue },
)

internal fun CallStats.toMessage() = CallStatsMessage(
    rttMs = media.rttMs,
    jitterMs = media.jitterMs,
    packetsSent = media.packetsSent.toLong(),
    packetsReceived = media.packetsReceived.toLong(),
    packetsLost = media.packetsLost.toLong(),
    bytesReceived = media.bytesReceived.toLong(),
    audioLevelIn = media.audioLevelIn,
    codec = media.codec,
    candidateType = media.candidateType,
    sampleRttMs = sample.rttMs,
    sampleJitterMs = sample.jitterMs,
    sampleLossPercent = sample.lossPercent,
    sampleMos = sample.mos,
    warnings = warnings.map { it.rawValue },
)

internal fun AudioRoutesView.toMessage() = AudioRoutesMessage(
    routes = routes.map { route ->
        AudioRouteMessage(
            id = route.id,
            kind = when (route.kind) {
                AudioRoute.Kind.Earpiece -> AudioRouteKindMessage.EARPIECE
                AudioRoute.Kind.Speaker -> AudioRouteKindMessage.SPEAKER
                AudioRoute.Kind.Bluetooth -> AudioRouteKindMessage.BLUETOOTH
                AudioRoute.Kind.Wired -> AudioRouteKindMessage.WIRED
                AudioRoute.Kind.Other -> AudioRouteKindMessage.OTHER
            },
            name = route.name,
        )
    },
    currentId = current?.id,
)
