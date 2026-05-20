package com.jarviscopilot.mobile

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/// We override only token refresh + onMessageReceived so we can log
/// them; the actual work happens on the Dart side via the
/// firebase_messaging plugin, which intercepts the same callbacks.
class FcmService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        Log.d(TAG, "FCM data: ${message.data}")
        super.onMessageReceived(message)
    }

    override fun onNewToken(token: String) {
        Log.d(TAG, "FCM token: $token")
        super.onNewToken(token)
    }

    companion object {
        private const val TAG = "JcFcm"
    }
}
