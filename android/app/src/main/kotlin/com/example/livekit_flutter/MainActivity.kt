package com.example.livekit_flutter

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "remote_desk/android_input"
    private val focusChannelName = "remote_desk/android_focus"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge: lets MediaQuery.systemGestureInsets in Flutter
        // report the real swipe-back / swipe-up reserved zones, so the
        // controller view can shrink its hit-target away from them.
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Stream of "is editable text field focused?" pushed from the
        // accessibility service. The host uses this to tell controllers
        // when to pop up the soft keyboard.
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            focusChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            private var listener: ((Boolean) -> Unit)? = null
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val l: (Boolean) -> Unit = { value ->
                    runOnUiThread { events.success(value) }
                }
                listener = l
                RemoteInputService.addFocusListener(l)
            }
            override fun onCancel(arguments: Any?) {
                listener?.let { RemoteInputService.removeFocusListener(it) }
                listener = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isAccessibilityEnabled" -> {
                        result.success(isAccessibilityServiceEnabled())
                    }
                    "openAccessibilitySettings" -> {
                        val i = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(null)
                    }
                    "screenInfo" -> {
                        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                        val m = DisplayMetrics()
                        @Suppress("DEPRECATION")
                        wm.defaultDisplay.getRealMetrics(m)
                        result.success(
                            mapOf(
                                "w" to m.widthPixels,
                                "h" to m.heightPixels,
                                "s" to m.density.toDouble()
                            )
                        )
                    }
                    "tap" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.error(
                                "NO_SERVICE",
                                "RemoteInputService not connected; enable it in Accessibility settings.",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        val x = (call.argument<Double>("x") ?: 0.0)
                        val y = (call.argument<Double>("y") ?: 0.0)
                        result.success(svc.tapNormalized(x, y))
                    }
                    "setText" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val s = call.argument<String>("s") ?: ""
                        result.success(svc.setFocusedText(s))
                    }
                    "globalAction" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val a = call.argument<Int>("a") ?: -1
                        result.success(svc.globalAction(a))
                    }
                    "startScreenCaptureService" -> {
                        val i = Intent(this, ScreenCaptureService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(i)
                        } else {
                            startService(i)
                        }
                        result.success(null)
                    }
                    "stopScreenCaptureService" -> {
                        stopService(Intent(this, ScreenCaptureService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("EXCEPTION", t.message, null)
            }
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        // The most reliable check: look up the comma-separated list of
        // enabled services in Settings.Secure. AccessibilityManager-based
        // checks can miss services that the user enabled but that haven't
        // been bound yet by the system.
        val expected = "$packageName/${RemoteInputService::class.java.name}"
        val flat = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return flat.split(':').any { it.equals(expected, ignoreCase = true) }
    }
}
