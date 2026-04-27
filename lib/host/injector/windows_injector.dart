import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';

// Win32 mouse-wheel notch value.
const int _kWheelDelta = 120;

/// Windows host injector using the Win32 SendInput API via the `win32`
/// package (no hand-rolled FFI needed).
class WindowsInjector implements InputInjector {
  DisplayInfo? _target;

  @override
  Future<bool> isReady() async => Platform.isWindows;

  @override
  Future<void> requestPermissions() async {
    // Nothing to request; SendInput works for any user-level process.
    // NOTE: To control elevated windows, the host process itself must be
    // running elevated (UAC isolation).
  }

  @override
  void setTargetDisplay(DisplayInfo? display) {
    _target = display;
  }

  @override
  Future<ScreenInfoEvent> screenInfo() async {
    final t = _target;
    if (t != null) {
      return ScreenInfoEvent(width: t.width, height: t.height, scale: t.scale);
    }
    final w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    final h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    return ScreenInfoEvent(width: w, height: h, scale: 1.0);
  }

  @override
  Future<void> handle(InputEvent event) async {
    if (event is MouseMoveEvent) {
      _sendMouseAbsolute(event.x, event.y, MOUSEEVENTF_MOVE);
    } else if (event is MouseButtonEvent) {
      final flag = _mouseButtonFlag(event.button, event.down);
      _sendMouseAbsolute(event.x, event.y, MOUSEEVENTF_MOVE | flag);
    } else if (event is MouseWheelEvent) {
      if (event.dy != 0) {
        _sendWheel(event.dy.round(), horizontal: false);
      }
      if (event.dx != 0) {
        _sendWheel(event.dx.round(), horizontal: true);
      }
    } else if (event is KeyInputEvent) {
      _sendKey(event);
    } else if (event is TextEvent) {
      _sendText(event.text);
    }
  }

  // ---- helpers ----

  void _sendMouseAbsolute(double nx, double ny, int flags) {
    // Map normalized (0..1) into the virtual screen using
    // MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_ABSOLUTE which expects
    // coordinates 0..65535 spanning the *entire* virtual desktop.
    //
    // When a target monitor is set we first translate the normalized point
    // to that monitor's pixel rect, then express it as a fraction of the
    // virtual-desktop extents — so clicks land on the captured monitor
    // only and never bleed into other displays.
    final vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
    final vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    final vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    final vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    final t = _target;
    final double px;
    final double py;
    if (t != null) {
      px = t.x + nx.clamp(0.0, 1.0) * t.width;
      py = t.y + ny.clamp(0.0, 1.0) * t.height;
    } else {
      px = vx + nx.clamp(0.0, 1.0) * vw;
      py = vy + ny.clamp(0.0, 1.0) * vh;
    }
    final x = (((px - vx) / (vw == 0 ? 1 : vw)) * 65535).round();
    final y = (((py - vy) / (vh == 0 ? 1 : vh)) * 65535).round();
    final pInput = calloc<INPUT>();
    try {
      pInput.ref.type = INPUT_MOUSE;
      pInput.ref.mi
        ..dx = x
        ..dy = y
        ..mouseData = 0
        ..dwFlags = flags | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK
        ..time = 0
        ..dwExtraInfo = 0;
      SendInput(1, pInput, sizeOf<INPUT>());
    } finally {
      calloc.free(pInput);
    }
  }

  int _mouseButtonFlag(MouseButton b, bool down) {
    switch (b) {
      case MouseButton.left:
        return down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
      case MouseButton.right:
        return down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
      case MouseButton.middle:
        return down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
    }
  }

  void _sendWheel(int delta, {required bool horizontal}) {
    final pInput = calloc<INPUT>();
    try {
      pInput.ref.type = INPUT_MOUSE;
      pInput.ref.mi
        ..dx = 0
        ..dy = 0
        ..mouseData = delta * _kWheelDelta
        ..dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL
        ..time = 0
        ..dwExtraInfo = 0;
      SendInput(1, pInput, sizeOf<INPUT>());
    } finally {
      calloc.free(pInput);
    }
  }

  void _sendKey(KeyInputEvent e) {
    // Convert Flutter physical key (USB HID usage) to Windows scancode.
    // The low byte of HID usage matches the PS/2 set 1 scancode for the
    // common keys; for full coverage, supply a HID->scancode table.
    // TODO: (developer) Expand the HID -> scancode/VK mapping for full
    // international keyboard coverage; current mapping handles ASCII.
    final scan = e.physicalKey & 0xFF;
    final pInput = calloc<INPUT>();
    try {
      pInput.ref.type = INPUT_KEYBOARD;
      pInput.ref.ki
        ..wVk = 0
        ..wScan = scan
        ..dwFlags = KEYEVENTF_SCANCODE | (e.down ? 0 : KEYEVENTF_KEYUP)
        ..time = 0
        ..dwExtraInfo = 0;
      SendInput(1, pInput, sizeOf<INPUT>());
    } finally {
      calloc.free(pInput);
    }
  }

  void _sendText(String s) {
    for (final code in s.codeUnits) {
      for (final down in [true, false]) {
        final pInput = calloc<INPUT>();
        try {
          pInput.ref.type = INPUT_KEYBOARD;
          pInput.ref.ki
            ..wVk = 0
            ..wScan = code
            ..dwFlags = KEYEVENTF_UNICODE | (down ? 0 : KEYEVENTF_KEYUP)
            ..time = 0
            ..dwExtraInfo = 0;
          SendInput(1, pInput, sizeOf<INPUT>());
        } finally {
          calloc.free(pInput);
        }
      }
    }
  }
}
