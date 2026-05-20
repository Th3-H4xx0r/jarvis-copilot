package com.jarviscopilot.mobile

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/// Backs the `read_notifications` skill. Keeps a tiny in-memory cache
/// of currently-active notifications so the Dart MethodChannel can
/// snapshot it cheaply. Doesn't persist or forward — privacy-by-default.
class NotifListenerService : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        synchronized(cache) {
            cache[sbn.key] = mapOf(
                "package" to sbn.packageName,
                "title" to (sbn.notification.extras.getCharSequence("android.title")?.toString() ?: ""),
                "text" to (sbn.notification.extras.getCharSequence("android.text")?.toString() ?: ""),
                "ts" to sbn.postTime,
            )
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn ?: return
        synchronized(cache) { cache.remove(sbn.key) }
    }

    companion object {
        private val cache = mutableMapOf<String, Map<String, Any>>()
        fun snapshot(): List<Map<String, Any>> {
            synchronized(cache) { return cache.values.toList() }
        }
    }
}
