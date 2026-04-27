import 'dart:convert';
import 'dart:typed_data';

/// Versioned wire protocol for input events sent from Controller -> Host
/// and capability/screen info sent Host -> Controller.
///
/// Uses compact JSON for portability. All coordinates are normalized to
/// [0.0, 1.0] of the host's primary capture surface; the host scales
/// them to physical pixels using its own [ScreenInfo].
const int kProtocolVersion = 1;

enum EventType {
  mouseMove,
  mouseButton,
  mouseWheel,
  keyEvent,
  text,
  screenInfo,
  ping,
  imeState,
}

enum MouseButton { left, right, middle }

abstract class InputEvent {
  EventType get type;
  Map<String, dynamic> toJson();

  Uint8List encode() {
    final m = {'v': kProtocolVersion, 't': type.name, 'd': toJson()};
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  static InputEvent? decode(List<int> bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['v'] != kProtocolVersion) return null;
      final t = EventType.values.firstWhere((e) => e.name == m['t']);
      final d = (m['d'] as Map).cast<String, dynamic>();
      switch (t) {
        case EventType.mouseMove:
          return MouseMoveEvent(
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
          );
        case EventType.mouseButton:
          return MouseButtonEvent(
            button: MouseButton.values.firstWhere((b) => b.name == d['b']),
            down: d['down'] as bool,
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
          );
        case EventType.mouseWheel:
          return MouseWheelEvent(
            dx: (d['dx'] as num).toDouble(),
            dy: (d['dy'] as num).toDouble(),
          );
        case EventType.keyEvent:
          return KeyInputEvent(
            logicalKey: (d['lk'] as num).toInt(),
            physicalKey: (d['pk'] as num).toInt(),
            down: d['down'] as bool,
            modifiers: (d['mods'] as num).toInt(),
          );
        case EventType.text:
          return TextEvent(text: d['s'] as String);
        case EventType.screenInfo:
          return ScreenInfoEvent(
            width: (d['w'] as num).toInt(),
            height: (d['h'] as num).toInt(),
            scale: (d['s'] as num).toDouble(),
          );
        case EventType.ping:
          return PingEvent(stamp: (d['ts'] as num).toInt());
        case EventType.imeState:
          return ImeStateEvent(open: d['o'] as bool);
      }
    } catch (_) {
      return null;
    }
  }
}

class MouseMoveEvent extends InputEvent {
  MouseMoveEvent({required this.x, required this.y});
  final double x; // 0..1
  final double y; // 0..1
  @override
  EventType get type => EventType.mouseMove;
  @override
  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

class MouseButtonEvent extends InputEvent {
  MouseButtonEvent({
    required this.button,
    required this.down,
    required this.x,
    required this.y,
  });
  final MouseButton button;
  final bool down;
  final double x;
  final double y;
  @override
  EventType get type => EventType.mouseButton;
  @override
  Map<String, dynamic> toJson() => {
    'b': button.name,
    'down': down,
    'x': x,
    'y': y,
  };
}

class MouseWheelEvent extends InputEvent {
  MouseWheelEvent({required this.dx, required this.dy});
  final double dx;
  final double dy;
  @override
  EventType get type => EventType.mouseWheel;
  @override
  Map<String, dynamic> toJson() => {'dx': dx, 'dy': dy};
}

/// Modifier bits.
class KeyMods {
  static const int shift = 1 << 0;
  static const int ctrl = 1 << 1;
  static const int alt = 1 << 2;
  static const int meta = 1 << 3; // Win/Cmd
}

class KeyInputEvent extends InputEvent {
  KeyInputEvent({
    required this.logicalKey,
    required this.physicalKey,
    required this.down,
    required this.modifiers,
  });
  final int logicalKey; // Flutter LogicalKeyboardKey.keyId
  final int physicalKey; // Flutter PhysicalKeyboardKey.usbHidUsage
  final bool down;
  final int modifiers;
  @override
  EventType get type => EventType.keyEvent;
  @override
  Map<String, dynamic> toJson() => {
    'lk': logicalKey,
    'pk': physicalKey,
    'down': down,
    'mods': modifiers,
  };
}

class TextEvent extends InputEvent {
  TextEvent({required this.text});
  final String text;
  @override
  EventType get type => EventType.text;
  @override
  Map<String, dynamic> toJson() => {'s': text};
}

class ScreenInfoEvent extends InputEvent {
  ScreenInfoEvent({
    required this.width,
    required this.height,
    required this.scale,
  });
  final int width;
  final int height;
  final double scale;
  @override
  EventType get type => EventType.screenInfo;
  @override
  Map<String, dynamic> toJson() => {'w': width, 'h': height, 's': scale};
}

class PingEvent extends InputEvent {
  PingEvent({required this.stamp});
  final int stamp;
  @override
  EventType get type => EventType.ping;
  @override
  Map<String, dynamic> toJson() => {'ts': stamp};
}

/// Host -> Controller hint that the focus on the host is currently on (or
/// has just left) an editable text field. Touch-only controllers use this
/// to pop up / dismiss the OS soft keyboard automatically.
class ImeStateEvent extends InputEvent {
  ImeStateEvent({required this.open});
  final bool open;
  @override
  EventType get type => EventType.imeState;
  @override
  Map<String, dynamic> toJson() => {'o': open};
}
