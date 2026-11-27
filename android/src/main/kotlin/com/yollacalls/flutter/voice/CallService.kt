//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process in the foreground while a call is up and shows the call notification. It does not own the call:
 * its "Hang up" action goes to [CallServiceController]'s `onHangup`, and so does the end of the call when the service
 * cannot enter the foreground.
 */
internal class CallService : Service() {
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANG_UP) {
            onHangup?.invoke()
            // A tap on a stale notification must not leave a service behind.
            if (!inForeground) stopSelf(startId)
            return START_NOT_STICKY
        }
        val number = intent?.getStringExtra(EXTRA_NUMBER).orEmpty()
        val microphone = intent?.getBooleanExtra(EXTRA_MICROPHONE, false) ?: false
        val telecom = intent?.getBooleanExtra(EXTRA_TELECOM, true) ?: true
        if (pendingStarts > 0) pendingStarts--
        // Every startForegroundService must reach startForeground, even when the call is already over: stopping the
        // service before that crashes the app.
        if (!enterForeground(number, foregroundServiceTypes(Build.VERSION.SDK_INT, telecom, microphone))) {
            // No foreground, no call: the microphone would record silence and the process could be killed. Only the
            // call this start belongs to is ended: none when the call is already over, a newer start tries itself.
            val ending = wanted && pendingStarts == 0
            log?.invoke("call service: could not start in the foreground" + if (ending) ", ending the call" else "")
            stopSelf(startId)
            if (ending) onHangup?.invoke()
            return START_NOT_STICKY
        }
        inForeground = true
        if (!wanted && pendingStarts == 0) stopSelf()
        return START_NOT_STICKY
    }

    /**
     * `startForeground` with [types]; when the system refuses them with a [SecurityException] (on API 34+ `microphone`
     * while the app is not in the foreground, `phoneCall` without the permission it needs) it retries with the
     * fallback. False when it could not start at all; never throws (a throw here kills the process).
     */
    private fun enterForeground(number: String, types: Int): Boolean {
        val notification = notification(number)
        try {
            startForeground(this, notification, types)
            return true
        } catch (e: SecurityException) {
            val fallback = foregroundServiceFallback(Build.VERSION.SDK_INT, types)
            log?.invoke("call service: foreground type $types refused (${e.message})" + if (fallback != null) ", retrying with $fallback" else "")
            if (fallback == null) return false
            return try {
                startForeground(this, notification, fallback)
                true
            } catch (e: Exception) {
                log?.invoke("call service: foreground type $fallback refused too (${e.message})")
                false
            }
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (API 31+) and the like.
            log?.invoke("call service: startForeground failed: $e")
            return false
        }
    }

    override fun onDestroy() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun notification(number: String): Notification {
        // Low importance: the call notification makes no sound.
        NotificationManagerCompat.from(this).createNotificationChannel(
            NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                .setName(getString(R.string.yolla_voice_notification_channel))
                .build(),
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.yolla_voice_ic_call)
            .setContentTitle(number)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
        // A tap opens the app, as its launcher icon does.
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(
                PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        }
        val hangUp = PendingIntent.getService(
            this, 1,
            Intent(this, CallService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val caller = Person.Builder().setName(number).setImportant(true).build()
        return builder.setStyle(NotificationCompat.CallStyle.forOngoingCall(caller, hangUp)).build()
    }

    internal companion object {
        const val CHANNEL_ID = "yolla_voice_ongoing_calls"
        const val NOTIFICATION_ID = 0x596f6c
        const val ACTION_HANG_UP = "com.yollacalls.flutter.voice.action.HANG_UP"
        const val EXTRA_NUMBER = "number"
        const val EXTRA_MICROPHONE = "microphone"
        const val EXTRA_TELECOM = "telecom"

        /**
         * Set by [CallServiceController]; the service only forwards the tap, and ends the call through it when it
         * cannot run in the foreground. Main thread.
         */
        var onHangup: (() -> Unit)? = null

        /** The plugin's log; set by [CallServiceController]. Main thread. */
        var log: ((String) -> Unit)? = null

        /** `ServiceCompat.startForeground`; a test puts a failing one in its place. Main thread. */
        var startForeground: (Service, Notification, Int) -> Unit = { service, notification, types ->
            ServiceCompat.startForeground(service, NOTIFICATION_ID, notification, types)
        }

        /** Whether a call wants the service; [CallServiceController] sets it, the service reads it. Main thread. */
        var wanted = false

        /** `startForegroundService` calls whose `onStartCommand` has not run yet. Main thread. */
        var pendingStarts = 0
    }
}

/**
 * The call service's foreground types: API 26–28 none; 29 `phoneCall`; 30+ with Telecom `phoneCall`, plus `microphone`
 * when it is granted; 30+ without Telecom `microphone` when it is granted, else `phoneCall` (the call then fails with
 * `microphone_denied` anyway; `microphone` without the permission would throw on API 34+). `phoneCall` on API 34+ needs
 * `MANAGE_OWN_CALLS`, which the plugin's manifest asks for.
 */
internal fun foregroundServiceTypes(sdk: Int, telecom: Boolean, microphoneGranted: Boolean): Int = when {
    sdk < 29 -> 0
    sdk < 30 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
    telecom && microphoneGranted ->
        ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    microphoneGranted -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
}

/** What to retry with after the system refused [types] with a `SecurityException`: `phoneCall` alone, or null. */
internal fun foregroundServiceFallback(sdk: Int, types: Int): Int? =
    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL.takeIf { sdk >= 29 && types != it && types != 0 }

/** Starts and stops [CallService]; [onHangup] runs on the main thread when the notification's "Hang up" is tapped. */
internal class CallServiceController(
    context: Context,
    private val log: (String) -> Unit = {},
    private val onHangup: () -> Unit,
) : CallServiceControlling {
    private val context = context.applicationContext

    override fun start(number: String, microphoneGranted: Boolean, telecom: Boolean) {
        CallService.onHangup = onHangup
        CallService.log = log
        CallService.wanted = true
        val intent = Intent(context, CallService::class.java)
            .putExtra(CallService.EXTRA_NUMBER, number)
            .putExtra(CallService.EXTRA_MICROPHONE, microphoneGranted)
            .putExtra(CallService.EXTRA_TELECOM, telecom)
        ContextCompat.startForegroundService(context, intent)
        // Counted only once the start went out; onStartCommand runs in a later main-thread message.
        CallService.pendingStarts++
    }

    /** A start that has not reached `startForeground` yet is stopped by the service itself once it has. */
    override fun stop() {
        CallService.wanted = false
        if (CallService.pendingStarts == 0) context.stopService(Intent(context, CallService::class.java))
    }
}
