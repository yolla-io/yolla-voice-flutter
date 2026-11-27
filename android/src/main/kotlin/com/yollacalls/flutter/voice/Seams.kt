//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import com.yollacalls.android.voice.Call
import com.yollacalls.android.voice.CallStats
import kotlinx.coroutines.flow.StateFlow

/** A place the call's audio can go. */
internal data class AudioRoute(val id: String, val kind: Kind, val name: String) {
    enum class Kind { Earpiece, Speaker, Bluetooth, Wired, Other }
}

/** The audio outputs of the current call and the one in use. */
internal interface AudioRouting {
    val routes: StateFlow<List<AudioRoute>>
    val current: StateFlow<AudioRoute?>
    suspend fun select(route: AudioRoute)
}

/** The audio routes without Telecom; [reset] puts the output back to the default once such a call is over. */
internal interface DirectAudioRouting : AudioRouting {
    fun reset()
}

/** The SDK client as the plugin uses it; the JVM tests put a fake in its place. */
internal interface VoiceConnecting {
    val call: StateFlow<Call?>

    /** Throws [com.yollacalls.android.voice.VoiceError] when the call cannot start at all. */
    fun connect(callToken: String)

    /** Returns at once; the end comes in [call]. */
    fun hangup()
    suspend fun setMuted(muted: Boolean)
    suspend fun setOnHold(hold: Boolean)
    suspend fun sendDigits(digits: String)
    suspend fun stats(): CallStats?
}

internal enum class TelecomEndCause { Local, Remote, Rejected, Error }

/** One call's handle to Telecom. */
internal interface TelecomControlling {
    /** Asks Telecom to put the call on hold (`setInactive`) or resume it (`setActive`); false means it refused. */
    suspend fun setHeld(held: Boolean): Boolean
    suspend fun reportConnected()

    /** A no-op once Telecom has ended the call itself. */
    suspend fun reportEnded(cause: TelecomEndCause)
}

/** Requests that come from the system. */
internal interface TelecomCallEvents {
    suspend fun hangupFromTelecom()

    /** Never throws. */
    suspend fun holdFromTelecom(hold: Boolean)
    suspend fun muteFromTelecom(muted: Boolean)
}

/** One call's Telecom handle that also exposes the audio routes Telecom manages. */
internal interface TelecomSession : TelecomControlling, AudioRouting

internal interface TelecomStarting {
    /**
     * Returns once Telecom accepted the call; throws [TelecomStartException] when it refuses or does not answer in
     * time, and a [kotlinx.coroutines.CancellationException] only for the caller's own cancellation.
     */
    suspend fun startCall(number: String, events: TelecomCallEvents): TelecomSession
}

internal interface CallServiceControlling {
    /** [telecom]: the call goes through Telecom; it decides the foreground-service type with [microphoneGranted]. */
    fun start(number: String, microphoneGranted: Boolean, telecom: Boolean)
    fun stop()
}

internal data class CallPermissions(val microphone: Boolean, val notifications: Boolean, val bluetooth: Boolean)

internal fun interface PermissionRequesting {
    /**
     * Asks the user for what is missing and returns the grants as they are afterwards; without a screen to ask from
     * it returns the current grants. Never throws.
     */
    suspend fun requestCallPermissions(): CallPermissions
}

internal fun interface ProximityLocking {
    fun update(callActive: Boolean, route: AudioRoute?)
}

/** The one SDK client of the process. */
internal class SdkVoice(context: android.content.Context) : VoiceConnecting {
    private val client = com.yollacalls.android.voice.VoiceClient(context.applicationContext)

    override val call: StateFlow<Call?> get() = client.call

    override fun connect(callToken: String) = client.connect(callToken)
    override fun hangup() = client.hangup()
    override suspend fun setMuted(muted: Boolean) = client.setMuted(muted)
    override suspend fun setOnHold(hold: Boolean) = client.setOnHold(hold)
    override suspend fun sendDigits(digits: String) = client.sendDigits(digits)
    override suspend fun stats(): CallStats? = client.stats()
}
