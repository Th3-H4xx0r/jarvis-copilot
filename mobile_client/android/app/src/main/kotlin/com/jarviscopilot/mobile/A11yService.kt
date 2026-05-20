package com.jarviscopilot.mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/// Backs the `type_text` and `tap_at` skills.
///
/// We hold a static `instance` ref so the SkillChannels can talk to
/// the service from outside its lifecycle. Tap is a GestureDescription
/// shooting a single down-up sequence; type_text uses the focused
/// editable node's setText extra (the standard pattern for
/// AccessibilityService text insertion).
class A11yService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        active = this
    }

    override fun onDestroy() {
        if (active === this) active = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    companion object {
        @Volatile var active: A11yService? = null

        fun typeText(text: String): Boolean {
            val svc = active ?: return false
            val root = svc.rootInActiveWindow ?: return false
            val focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            return focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        }

        fun tapAt(x: Float, y: Float): Boolean {
            val svc = active ?: return false
            val path = Path().apply { moveTo(x, y); lineTo(x, y) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 60))
                .build()
            return svc.dispatchGesture(gesture, null, null)
        }
    }
}
