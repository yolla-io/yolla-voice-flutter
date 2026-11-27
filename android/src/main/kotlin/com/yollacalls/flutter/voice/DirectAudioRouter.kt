//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The audio routes without Telecom, straight through [AudioManager]: on API 31+ the communication devices, below only
 * the earpiece and the speaker (`isSpeakerphoneOn`). [reset] undoes the choice once the call is over. Main thread.
 */
internal class DirectAudioRouter(context: Context) : DirectAudioRouting {
    private val audio = context.applicationContext.getSystemService(AudioManager::class.java)
    private val mutableRoutes = MutableStateFlow<List<AudioRoute>>(emptyList())
    private val mutableCurrent = MutableStateFlow<AudioRoute?>(null)

    override val routes: StateFlow<List<AudioRoute>> = mutableRoutes
    override val current: StateFlow<AudioRoute?> = mutableCurrent

    init {
        if (Build.VERSION.SDK_INT >= 31) {
            val main = Handler(Looper.getMainLooper())
            audio.registerAudioDeviceCallback(object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refresh()
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refresh()
            }, main)
            audio.addOnCommunicationDeviceChangedListener(ContextCompat.getMainExecutor(context)) { refresh() }
        }
        refresh()
    }

    override suspend fun select(route: AudioRoute) {
        if (Build.VERSION.SDK_INT >= 31) {
            audio.availableCommunicationDevices.firstOrNull { it.id.toString() == route.id }
                ?.let { audio.setCommunicationDevice(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = route.kind == AudioRoute.Kind.Speaker
        }
        refresh()
    }

    /** Back to the default output (the earpiece) after a call, so the next call does not start on the speaker. */
    override fun reset() {
        if (Build.VERSION.SDK_INT >= 31) {
            audio.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = false
        }
        refresh()
    }

    private fun refresh() {
        if (Build.VERSION.SDK_INT >= 31) {
            refreshCommunicationDevices()
        } else {
            mutableRoutes.value = legacyRoutes
            @Suppress("DEPRECATION")
            mutableCurrent.value = if (audio.isSpeakerphoneOn) SPEAKER else EARPIECE
        }
    }

    @RequiresApi(31)
    private fun refreshCommunicationDevices() {
        mutableRoutes.value = audio.availableCommunicationDevices.mapNotNull(::route)
        mutableCurrent.value = audio.communicationDevice?.let(::route)
    }

    private companion object {
        val EARPIECE = AudioRoute("earpiece", AudioRoute.Kind.Earpiece, "Phone")
        val SPEAKER = AudioRoute("speaker", AudioRoute.Kind.Speaker, "Speaker")
        val legacyRoutes = listOf(EARPIECE, SPEAKER)

        /** Null for devices that are not a place to hear a call (telephony, remote submix, …). */
        fun route(device: AudioDeviceInfo): AudioRoute? {
            val (kind, name) = when (device.type) {
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> AudioRoute.Kind.Earpiece to "Phone"
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> AudioRoute.Kind.Speaker to "Speaker"
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER,
                AudioDeviceInfo.TYPE_HEARING_AID ->
                    AudioRoute.Kind.Bluetooth to device.productName.toString().ifBlank { "Bluetooth" }
                AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET -> AudioRoute.Kind.Wired to "Headset"
                else -> return null
            }
            return AudioRoute(device.id.toString(), kind, name)
        }
    }
}

/**
 * Turns the screen off at the ear: holds `PROXIMITY_SCREEN_OFF_WAKE_LOCK` only while a call is active and the audio
 * goes to the earpiece (or the route is not known yet). Main thread.
 */
internal class ProximityLock(context: Context) : ProximityLocking {
    private val lock: PowerManager.WakeLock? = context.applicationContext.getSystemService(PowerManager::class.java)
        .takeIf { it.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK) }
        ?.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "YollaVoice:proximity")
        ?.apply { setReferenceCounted(false) }

    override fun update(callActive: Boolean, route: AudioRoute?) {
        val lock = lock ?: return
        val wanted = callActive && (route == null || route.kind == AudioRoute.Kind.Earpiece)
        if (wanted && !lock.isHeld) {
            lock.acquire()
        } else if (!wanted && lock.isHeld) {
            lock.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
        }
    }
}
