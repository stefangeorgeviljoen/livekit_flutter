import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';

/// Android host injector — bridges to a Kotlin AccessibilityService
/// via a MethodChannel (registered by [MainActivity]).
///
/// Android does NOT allow non-system apps to inject raw key events, so:
///   • mouse moves/clicks are mapped to single-finger gestures via
///     AccessibilityService.dispatchGesture
///   • text input is sent through ACTION_SET_TEXT on the focused node
///   • dedicated keys (Back/Home/Recents) use performGlobalAction
class AndroidInjector implements InputInjector {
  static const _channel = MethodChannel('remote_desk/android_input');

  @override
  Future<bool> isReady() async {
    if (!Platform.isAndroid) return false;
    final res = await _channel.invokeMethod<bool>('isAccessibilityEnabled');
    return res ?? false;
  }

  @override
  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  @override
  void setTargetDisplay(DisplayInfo? display) {
    // Android injects through AccessibilityService gestures which target the
    // single foreground display only. Multi-display targeting is N/A.
  }

  @override
  Future<ScreenInfoEvent> screenInfo() async {
    if (!Platform.isAndroid) {
      return ScreenInfoEvent(width: 0, height: 0, scale: 1.0);
    }
    final m = await _channel.invokeMapMethod<String, dynamic>('screenInfo');
    return ScreenInfoEvent(
      width: (m?['w'] as num?)?.toInt() ?? 0,
      height: (m?['h'] as num?)?.toInt() ?? 0,
      scale: (m?['s'] as num?)?.toDouble() ?? 1.0,
    );
  }

  @override
  Future<void> handle(InputEvent event) async {
    if (!Platform.isAndroid) return;
    try {
      if (event is MouseMoveEvent) {
        // No-op: Android cursor is meaningless without a click. The Controller
        // should mostly send taps/swipes derived from pointer-down/up pairs.
        return;
      }
      if (event is MouseButtonEvent) {
        if (event.down) {
          await _channel.invokeMethod('tap', {'x': event.x, 'y': event.y});
        }
        return;
      }
      if (event is TextEvent) {
        await _channel.invokeMethod('setText', {'s': event.text});
        return;
      }
      if (event is KeyInputEvent && event.down) {
        // Map well-known Flutter logical keys to global actions.
        final action = _globalActionFor(event.logicalKey);
        if (action != null) {
          await _channel.invokeMethod('globalAction', {'a': action});
        }
      }
    } catch (e, st) {
      // Never let an injection failure (missing service, denied permission,
      // unsupported gesture) crash the host. Log and drop the event.
      // ignore: avoid_print
      print('AndroidInjector.handle failed: $e\n$st');
    }
  }

  int? _globalActionFor(int logicalKey) {
    // Flutter LogicalKeyboardKey IDs (subset).
    const goBack = 0x100070029; // Escape -> back
    const home = 0x10007004A; // Home key
    if (logicalKey == goBack) return 1; // GLOBAL_ACTION_BACK
    if (logicalKey == home) return 2; // GLOBAL_ACTION_HOME
    return null;
  }
}
