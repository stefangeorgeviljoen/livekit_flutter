import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_flutter/protocol/input_event.dart';

void main() {
  group('input event codec round-trip', () {
    test('mouseMove', () {
      final e = MouseMoveEvent(x: 0.25, y: 0.75);
      final d = InputEvent.decode(e.encode()) as MouseMoveEvent;
      expect(d.x, 0.25);
      expect(d.y, 0.75);
    });

    test('mouseButton', () {
      final e = MouseButtonEvent(
        button: MouseButton.right,
        down: true,
        x: 0.1,
        y: 0.2,
      );
      final d = InputEvent.decode(e.encode()) as MouseButtonEvent;
      expect(d.button, MouseButton.right);
      expect(d.down, true);
      expect(d.x, 0.1);
      expect(d.y, 0.2);
    });

    test('mouseWheel', () {
      final e = MouseWheelEvent(dx: 0, dy: -3.5);
      final d = InputEvent.decode(e.encode()) as MouseWheelEvent;
      expect(d.dy, -3.5);
    });

    test('keyEvent', () {
      final e = KeyInputEvent(
        logicalKey: 0x100000041,
        physicalKey: 0x07001E,
        down: true,
        modifiers: KeyMods.shift | KeyMods.ctrl,
      );
      final d = InputEvent.decode(e.encode()) as KeyInputEvent;
      expect(d.logicalKey, 0x100000041);
      expect(d.physicalKey, 0x07001E);
      expect(d.down, true);
      expect(d.modifiers, KeyMods.shift | KeyMods.ctrl);
    });

    test('text', () {
      final e = TextEvent(text: 'hellö 世界');
      final d = InputEvent.decode(e.encode()) as TextEvent;
      expect(d.text, 'hellö 世界');
    });

    test('screenInfo', () {
      final e = ScreenInfoEvent(width: 2560, height: 1440, scale: 2.0);
      final d = InputEvent.decode(e.encode()) as ScreenInfoEvent;
      expect(d.width, 2560);
      expect(d.height, 1440);
      expect(d.scale, 2.0);
    });

    test('garbage', () {
      expect(InputEvent.decode([1, 2, 3]), isNull);
    });
  });
}
