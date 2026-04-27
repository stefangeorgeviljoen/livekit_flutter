import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'app/mode_picker_screen.dart';
import 'app/settings_screen.dart';
import 'controller/controller_screen.dart';
import 'host/host_screen.dart';

/// Process-wide hook so any open RoomSession can be torn down when the
/// OS asks us to detach (window close, app swiped away, etc.). The
/// HostScreen / ControllerScreen register themselves here on init and
/// unregister on dispose; on AppLifecycleState.detached we drain the
/// list with a hard 1s timeout so a slow LiveKit teardown doesn't keep
/// the process alive (the symptom users see is a "frozen" window).
class AppShutdown {
  AppShutdown._();
  static final List<Future<void> Function()> _hooks = [];
  static void register(Future<void> Function() hook) => _hooks.add(hook);
  static void unregister(Future<void> Function() hook) => _hooks.remove(hook);

  static Future<void> drain() async {
    final pending = List<Future<void> Function()>.from(_hooks);
    _hooks.clear();
    for (final h in pending) {
      try {
        await h().timeout(const Duration(seconds: 1));
      } catch (_) {
        // Best-effort.
      }
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Verbose LiveKit / WebRTC logs in debug builds. Helpful for diagnosing
  // ICE / PeerConnection timeouts. Stripped from release builds.
  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((r) {
      // ignore: avoid_print
      print('[${r.level.name}] ${r.loggerName}: ${r.message}');
      if (r.error != null) {
        // ignore: avoid_print
        print('  error: ${r.error}');
      }
      if (r.stackTrace != null) {
        // ignore: avoid_print
        print(r.stackTrace);
      }
    });
  }
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const RemoteDeskApp());
}

class RemoteDeskApp extends StatefulWidget {
  const RemoteDeskApp({super.key});

  @override
  State<RemoteDeskApp> createState() => _RemoteDeskAppState();
}

class _RemoteDeskAppState extends State<RemoteDeskApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // Window-close on desktop / swipe-away on mobile. Drain LiveKit
      // sessions before the engine yanks the isolate.
      AppShutdown.drain();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiveKit Remote Desk',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const ModePickerScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/host': (_) => const HostScreen(),
        '/controller': (_) => const ControllerScreen(),
      },
    );
  }
}
