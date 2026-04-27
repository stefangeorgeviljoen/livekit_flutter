package com.example.livekit_flutter

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.os.Bundle
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Bridges Flutter input events into Android via the AccessibilityService API.
 *
 * Limitations (OS-imposed for non-system apps):
 *   - Cannot inject arbitrary key codes.
 *   - Cannot interact with screens marked FLAG_SECURE.
 *   - The user must enable this service manually.
 */
class RemoteInputService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: RemoteInputService? = null
            private set

        /** Most recent "is editable input focused?" value, broadcast on change. */
        @Volatile
        var editableFocused: Boolean = false
            private set

        private val focusListeners = mutableListOf<(Boolean) -> Unit>()

        @Synchronized
        fun addFocusListener(l: (Boolean) -> Unit) {
            focusListeners.add(l)
            // Replay current state so subscribers don't have to wait for
            // the next focus change.
            l(editableFocused)
        }

        @Synchronized
        fun removeFocusListener(l: (Boolean) -> Unit) {
            focusListeners.remove(l)
        }

        @Synchronized
        private fun notifyFocus(value: Boolean) {
            if (editableFocused == value) return
            editableFocused = value
            for (l in focusListeners.toList()) {
                try { l(value) } catch (_: Throwable) {}
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        notifyFocus(false)
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // Find current input focus across all windows; fall back to
                // event.source when no input-focused node exists.
                val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                val isEditable = (focused?.isEditable == true) ||
                    (event.source?.isEditable == true)
                notifyFocus(isEditable)
            }
        }
    }
    override fun onInterrupt() { /* unused */ }

    fun tapNormalized(nx: Double, ny: Double): Boolean {
        val (w, h) = realMetrics()
        val x = (nx.coerceIn(0.0, 1.0) * w).toFloat()
        val y = (ny.coerceIn(0.0, 1.0) * h).toFloat()
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, 60L))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    fun setFocusedText(text: String): Boolean {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text
            )
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    fun globalAction(action: Int): Boolean = performGlobalAction(action)

    private fun realMetrics(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(m)
        return m.widthPixels to m.heightPixels
    }
}
