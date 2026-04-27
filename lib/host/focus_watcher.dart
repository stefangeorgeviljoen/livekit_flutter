import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Streams a single boolean — "is the OS reporting that an editable text
/// field currently has focus on this host?" — so the host can tell remote
/// controllers when to surface the soft keyboard.
///
/// Per-platform implementation:
///   • Android   — EventChannel `remote_desk/android_focus`, fed by our
///                 AccessibilityService (RemoteInputService.kt).
///   • Windows   — TODO. Likely AttachThreadInput + GetFocus polling, or
///                 SetWinEventHook(EVENT_OBJECT_FOCUS).
///   • macOS     — TODO. AXObserver watching kAXFocusedUIElementChanged.
///   • Linux/web — unsupported (controller-only platforms anyway).
abstract class FocusWatcher {
  static FocusWatcher forCurrentPlatform() {
    if (Platform.isAndroid) return _AndroidFocusWatcher();
    return _NoopFocusWatcher();
  }

  /// Distinct stream of focus state changes. Emits the current value on
  /// subscribe so callers can sync their state without waiting.
  Stream<bool> get editableFocused;

  Future<void> dispose();
}

class _NoopFocusWatcher extends FocusWatcher {
  final _ctl = StreamController<bool>.broadcast();
  bool _seeded = false;

  @override
  Stream<bool> get editableFocused {
    // Replay an initial false so subscribers know the ground truth.
    if (!_seeded) {
      _seeded = true;
      Future.microtask(() {
        if (!_ctl.isClosed) _ctl.add(false);
      });
    }
    return _ctl.stream;
  }

  @override
  Future<void> dispose() async {
    await _ctl.close();
  }
}

class _AndroidFocusWatcher extends FocusWatcher {
  static const _channel = EventChannel('remote_desk/android_focus');

  StreamSubscription<dynamic>? _sub;
  final _ctl = StreamController<bool>.broadcast();
  bool? _last;

  _AndroidFocusWatcher() {
    _sub = _channel.receiveBroadcastStream().listen(
      (event) {
        final v = event == true;
        if (_last == v) return;
        _last = v;
        if (!_ctl.isClosed) _ctl.add(v);
      },
      onError: (_) {
        // Keep the stream alive; the AccessibilityService might not be
        // bound yet. We'll just stop seeing updates until it is.
      },
      cancelOnError: false,
    );
  }

  @override
  Stream<bool> get editableFocused => _ctl.stream;

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _ctl.close();
  }
}
