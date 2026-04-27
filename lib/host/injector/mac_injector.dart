import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';

/// macOS host injector using CoreGraphics event APIs via dart:ffi.
///
/// REQUIREMENTS for this to actually inject events:
///   1. Bundle is signed (ad-hoc OK during dev).
///   2. The user has granted "Accessibility" permission in
///      System Settings → Privacy & Security → Accessibility.
///   3. The user has granted "Screen Recording" so the screen-share
///      track actually contains pixels.
class MacInjector implements InputInjector {
  MacInjector() {
    if (Platform.isMacOS) {
      _cg = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      );
      _appServices = DynamicLibrary.open(
        '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices',
      );
      _bindAll();
    }
  }

  late final DynamicLibrary _cg;
  late final DynamicLibrary _appServices;

  /// When non-null, mouse events are posted onto this display (using its
  /// CGDirectDisplayID and global-coord origin) instead of the main display.
  DisplayInfo? _target;

  @override
  void setTargetDisplay(DisplayInfo? display) {
    _target = display;
  }

  // --- bindings ---
  late final int Function() _cgMainDisplayId = _cg
      .lookupFunction<Uint32 Function(), int Function()>('CGMainDisplayID');
  late final int Function(int) _cgDisplayPixelsWide = _cg
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'CGDisplayPixelsWide',
      );
  late final int Function(int) _cgDisplayPixelsHigh = _cg
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'CGDisplayPixelsHigh',
      );

  late final Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int)
  _cgEventCreateMouseEvent;
  late final Pointer<Void> Function(Pointer<Void>, int, bool)
  _cgEventCreateKeyboardEvent;
  late final void Function(int, Pointer<Void>) _cgEventPost;
  late final void Function(Pointer<Void>) _cfRelease;
  late final void Function(Pointer<Void>, int, int, Pointer<Uint16>)
  _cgEventKeyboardSetUnicodeString;
  late final bool Function(Pointer<Void> options)
  _axIsProcessTrustedWithOptions;

  void _bindAll() {
    _cgEventCreateMouseEvent = _cg
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Uint32, _CGPoint, Uint32),
          Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int)
        >('CGEventCreateMouseEvent');
    _cgEventCreateKeyboardEvent = _cg
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
          Pointer<Void> Function(Pointer<Void>, int, bool)
        >('CGEventCreateKeyboardEvent');
    _cgEventPost = _cg
        .lookupFunction<
          Void Function(Uint32, Pointer<Void>),
          void Function(int, Pointer<Void>)
        >('CGEventPost');
    _cfRelease = _cg
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('CFRelease');
    _cgEventKeyboardSetUnicodeString = _cg
        .lookupFunction<
          Void Function(Pointer<Void>, UintPtr, UintPtr, Pointer<Uint16>),
          void Function(Pointer<Void>, int, int, Pointer<Uint16>)
        >('CGEventKeyboardSetUnicodeString');
    _axIsProcessTrustedWithOptions = _appServices
        .lookupFunction<
          Bool Function(Pointer<Void>),
          bool Function(Pointer<Void>)
        >('AXIsProcessTrustedWithOptions');
  }

  @override
  Future<bool> isReady() async {
    if (!Platform.isMacOS) return false;
    return _axIsProcessTrustedWithOptions(nullptr);
  }

  @override
  Future<void> requestPermissions() async {
    // Calling AXIsProcessTrustedWithOptions with the prompt option will
    // surface the OS dialog. For a richer experience, prefer launching the
    // System Settings pane directly:
    //   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    await Process.run('open', [
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
    ]);
  }

  @override
  Future<ScreenInfoEvent> screenInfo() async {
    if (!Platform.isMacOS) {
      return ScreenInfoEvent(width: 0, height: 0, scale: 1.0);
    }
    final t = _target;
    if (t != null) {
      return ScreenInfoEvent(width: t.width, height: t.height, scale: t.scale);
    }
    final id = _cgMainDisplayId();
    final w = _cgDisplayPixelsWide(id);
    final h = _cgDisplayPixelsHigh(id);
    return ScreenInfoEvent(width: w, height: h, scale: 1.0);
  }

  @override
  Future<void> handle(InputEvent event) async {
    if (!Platform.isMacOS) return;
    if (event is MouseMoveEvent) {
      _postMouse(event.x, event.y, _kCGEventMouseMoved, _kCGMouseButtonLeft);
    } else if (event is MouseButtonEvent) {
      final cgBtn = switch (event.button) {
        MouseButton.left => _kCGMouseButtonLeft,
        MouseButton.right => _kCGMouseButtonRight,
        MouseButton.middle => _kCGMouseButtonCenter,
      };
      final type = switch ((event.button, event.down)) {
        (MouseButton.left, true) => _kCGEventLeftMouseDown,
        (MouseButton.left, false) => _kCGEventLeftMouseUp,
        (MouseButton.right, true) => _kCGEventRightMouseDown,
        (MouseButton.right, false) => _kCGEventRightMouseUp,
        (MouseButton.middle, true) => _kCGEventOtherMouseDown,
        (MouseButton.middle, false) => _kCGEventOtherMouseUp,
      };
      _postMouse(event.x, event.y, type, cgBtn);
    } else if (event is KeyInputEvent) {
      // TODO: (developer) Map Flutter physical key -> macOS virtual keycode.
      // This minimal implementation posts whatever low byte we get; for full
      // coverage, ship a HID-usage -> kVK_* lookup table.
      final vk = event.physicalKey & 0xFF;
      final ev = _cgEventCreateKeyboardEvent(nullptr, vk, event.down);
      if (ev != nullptr) {
        _cgEventPost(_kCGHIDEventTap, ev);
        _cfRelease(ev);
      }
    } else if (event is TextEvent) {
      final units = event.text.codeUnits;
      final buf = calloc<Uint16>(units.length);
      for (var i = 0; i < units.length; i++) {
        buf[i] = units[i];
      }
      try {
        final ev = _cgEventCreateKeyboardEvent(nullptr, 0, true);
        if (ev != nullptr) {
          _cgEventKeyboardSetUnicodeString(ev, units.length, units.length, buf);
          _cgEventPost(_kCGHIDEventTap, ev);
          _cfRelease(ev);
        }
      } finally {
        calloc.free(buf);
      }
    }
  }

  void _postMouse(double nx, double ny, int type, int button) {
    // Inject in CG global *points* (Quartz coords, not pixels). When a
    // target display is set we use its origin + size so the event lands on
    // that monitor; otherwise fall back to the main display.
    final t = _target;
    final double ox;
    final double oy;
    final double w;
    final double h;
    if (t != null) {
      ox = t.x.toDouble();
      oy = t.y.toDouble();
      w = t.width.toDouble();
      h = t.height.toDouble();
    } else {
      final id = _cgMainDisplayId();
      ox = 0;
      oy = 0;
      w = _cgDisplayPixelsWide(id).toDouble();
      h = _cgDisplayPixelsHigh(id).toDouble();
    }
    final pt = calloc<_CGPoint>()
      ..ref.x = ox + nx.clamp(0.0, 1.0) * w
      ..ref.y = oy + ny.clamp(0.0, 1.0) * h;
    try {
      final ev = _cgEventCreateMouseEvent(nullptr, type, pt.ref, button);
      if (ev != nullptr) {
        _cgEventPost(_kCGHIDEventTap, ev);
        _cfRelease(ev);
      }
    } finally {
      calloc.free(pt);
    }
  }

  // CGEventTapLocation
  static const int _kCGHIDEventTap = 0;
  // CGEventType
  static const int _kCGEventLeftMouseDown = 1;
  static const int _kCGEventLeftMouseUp = 2;
  static const int _kCGEventRightMouseDown = 3;
  static const int _kCGEventRightMouseUp = 4;
  static const int _kCGEventMouseMoved = 5;
  static const int _kCGEventOtherMouseDown = 25;
  static const int _kCGEventOtherMouseUp = 26;
  // CGMouseButton
  static const int _kCGMouseButtonLeft = 0;
  static const int _kCGMouseButtonRight = 1;
  static const int _kCGMouseButtonCenter = 2;
}

final class _CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}
