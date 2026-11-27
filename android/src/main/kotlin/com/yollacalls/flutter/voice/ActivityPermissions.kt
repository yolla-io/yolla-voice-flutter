//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

package com.yollacalls.flutter.voice

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred

/** The call's grants as they are now. */
internal fun currentCallPermissions(context: Context): CallPermissions {
    fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    return CallPermissions(
        microphone = granted(Manifest.permission.RECORD_AUDIO),
        notifications = NotificationManagerCompat.from(context).areNotificationsEnabled(),
        bluetooth = Build.VERSION.SDK_INT < 31 || granted(Manifest.permission.BLUETOOTH_CONNECT),
    )
}

/**
 * Asks for the call's runtime permissions from the Activity the plugin is attached to, all missing ones in one
 * request: the microphone, and where the system has them the notifications (the call notification, API 33+) and
 * Bluetooth (headsets among the audio routes, API 31+). Never throws: with a request already in flight, or when the
 * Activity goes away mid-request, it returns the current grants. Main thread.
 */
internal class ActivityPermissions(private val activity: Activity) :
    PermissionRequesting, PluginRegistry.RequestPermissionsResultListener {
    private var pending: CompletableDeferred<Unit>? = null

    override suspend fun requestCallPermissions(): CallPermissions {
        val missing = wanted().filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty() || pending != null) return currentCallPermissions(activity)
        val request = CompletableDeferred<Unit>()
        pending = request
        try {
            ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CODE)
        } catch (e: Exception) {
            Log.w(TAG, "permission request failed: $e")
            finish()
        }
        request.await()
        return currentCallPermissions(activity)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        finish()
        return true
    }

    /** The Activity is gone: a request in flight gets no answer any more. */
    fun finish() {
        pending?.complete(Unit)
        pending = null
    }

    private companion object {
        const val TAG = "YollaVoice"
        const val REQUEST_CODE = 0x596f

        fun wanted(): List<String> = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
        }
    }
}
