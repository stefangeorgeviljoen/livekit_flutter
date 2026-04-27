import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';

/// Used on platforms where being a Host is not supported (Linux, iOS, Web).
class NoopInjector implements InputInjector {
  @override
  Future<bool> isReady() async => false;

  @override
  Future<void> requestPermissions() async {}

  @override
  void setTargetDisplay(DisplayInfo? display) {}

  @override
  Future<ScreenInfoEvent> screenInfo() async =>
      ScreenInfoEvent(width: 0, height: 0, scale: 1.0);

  @override
  Future<void> handle(InputEvent event) async {
    // Intentionally no-op.
  }
}
