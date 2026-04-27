import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/settings_store.dart';
import '../livekit/room_session.dart';
import '../livekit/token_client.dart';
import '../main.dart' show AppShutdown;
import '../protocol/input_event.dart';
import 'display_info.dart';
import 'focus_watcher.dart';
import 'injector/input_injector.dart';
import 'screen_enumerator.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> with WidgetsBindingObserver {
  static const _androidChannel = MethodChannel('remote_desk/android_input');

  final _session = RoomSession();
  final _injector = InputInjector.forCurrentPlatform();
  late final String _pairingCode;

  bool _connecting = false;
  bool _connected = false;
  bool _injectorReady = false;
  bool _switching = false;
  String? _error;
  EventsListener<RoomEvent>? _listener;

  /// Captured screens enumerated from the OS at Start time.
  List<DisplayInfo> _displays = const [];

  /// The display we're currently capturing & controlling.
  DisplayInfo? _activeDisplay;

  /// Watches the host OS for "is an editable text field focused" so we
  /// can tell touch-only controllers when to pop up their soft keyboard.
  final _focusWatcher = FocusWatcher.forCurrentPlatform();
  StreamSubscription<bool>? _focusSub;
  bool _lastFocusBroadcast = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pairingCode = _generateCode();
    AppShutdown.register(_shutdownHook);
    _refreshInjectorStatus();
  }

  /// Called from [AppShutdown.drain] when the OS is closing the window /
  /// detaching the engine. Best-effort and time-bounded.
  Future<void> _shutdownHook() async {
    await _focusSub?.cancel();
    _focusSub = null;
    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod('stopScreenCaptureService');
      } catch (_) {}
    }
    await _session.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user returns from Accessibility settings, re-check status
    // so the badge flips to green automatically.
    if (state == AppLifecycleState.resumed) {
      _refreshInjectorStatus();
    }
  }

  String _generateCode() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  Future<void> _refreshInjectorStatus() async {
    final ready = await _injector.isReady();
    if (mounted) setState(() => _injectorReady = ready);
  }

  /// Resolve the picked [DesktopCapturerSource] to one of [_displays] by
  /// looking up its position in the Screen-only source list. Both
  /// libwebrtc's screen capturer and `EnumDisplayMonitors` walk the OS in
  /// the same order, so index alignment is reliable; matching by `source.id`
  /// is not (Windows libwebrtc returns an opaque numeric id).
  Future<DisplayInfo?> _resolveDisplay(rtc.DesktopCapturerSource picked) async {
    if (_displays.isEmpty) return null;
    try {
      final sources = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen],
      );
      // libwebrtc enumerates monitors in OS order, the same order
      // EnumDisplayMonitors / CGGetActiveDisplayList walks. Index alignment
      // is the reliable mapping (the source.id is opaque on Windows).
      final idx = sources.indexWhere((s) => s.id == picked.id);
      // ignore: avoid_print
      print(
        '[host] picked source id=${picked.id} name="${picked.name}" '
        'index=$idx of ${sources.length}; displays=${_displays.length}',
      );
      if (idx >= 0) return ScreenEnumerator.matchByIndex(idx, _displays);
    } catch (e) {
      // ignore: avoid_print
      print('[host] _resolveDisplay enumeration failed: $e');
    }
    return ScreenEnumerator.match(
      picked.id,
      _displays,
      sourceName: picked.name,
    );
  }

  Future<void> _start() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      // LiveKit needs mic permission even if we publish video-only on some
      // platforms; request it defensively.
      if (Platform.isAndroid || Platform.isIOS) {
        await Permission.microphone.request();
      }

      final settings = await SettingsStore.load();
      final token = await TokenClient(settings.tokenEndpoint).fetchToken(
        room: settings.roomName,
        identity: settings.identity,
        role: 'host',
        pairingCode: _pairingCode,
      );

      await _session.connect(url: settings.liveKitUrl, token: token);

      // Wire up data channel listener for incoming input events.
      _listener = _session.room.createListener();
      _listener!.on<DataReceivedEvent>(_onData);

      // Publish screen share. Desktop platforms (Windows / macOS / Linux)
      // require us to pick a specific source (monitor or window) — there is
      // no system picker like on mobile. We honour [autoStartShare] and
      // grab the primary monitor automatically; otherwise we show the
      // bundled ScreenSelectDialog and pass the chosen sourceId through.
      ScreenShareCaptureOptions? screenOpts;
      rtc.DesktopCapturerSource? pickedSource;
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        // Enumerate displays first; we may need them for the auto-pick.
        _displays = ScreenEnumerator.list();
        if (settings.autoStartShare) {
          try {
            final sources = await rtc.desktopCapturer.getSources(
              types: [rtc.SourceType.Screen],
            );
            if (sources.isEmpty) {
              throw Exception('No screens available to share.');
            }
            // Prefer the monitor flagged as primary by the OS. Fall back
            // to index 0 if our enumerator and libwebrtc disagree on
            // length (extremely unusual).
            final primaryIdx = _displays.indexWhere((d) => d.isPrimary);
            final idx = (primaryIdx >= 0 && primaryIdx < sources.length)
                ? primaryIdx
                : 0;
            pickedSource = sources[idx];
            // ignore: avoid_print
            print(
              '[host] auto-pick primary screen: '
              'sources[$idx]=${pickedSource.name} (id=${pickedSource.id})',
            );
          } catch (e) {
            // ignore: avoid_print
            print('[host] auto-pick failed, falling back to picker: $e');
          }
        }
        if (pickedSource == null) {
          if (!mounted) return;
          final source = await showDialog<rtc.DesktopCapturerSource>(
            context: context,
            barrierDismissible: false,
            builder: (_) => ScreenSelectDialog(),
          );
          if (source == null) {
            throw Exception('Screen share cancelled (no source selected).');
          }
          pickedSource = source;
        }
        screenOpts = ScreenShareCaptureOptions(
          sourceId: pickedSource.id,
          maxFrameRate: 15,
        );
      }

      // Resolve picked source to a DisplayInfo so the injector can constrain
      // events to that monitor (desktop only — Android falls through with
      // _activeDisplay == null, which is correct).
      if (_displays.isEmpty) _displays = ScreenEnumerator.list();
      _activeDisplay = pickedSource == null
          ? null
          : await _resolveDisplay(pickedSource);
      _injector.setTargetDisplay(_activeDisplay);
      // ignore: avoid_print
      print(
        '[host] active display: ${_activeDisplay?.label} '
        '(rect ${_activeDisplay?.x},${_activeDisplay?.y} '
        '${_activeDisplay?.width}x${_activeDisplay?.height})',
      );

      // On Android 14+ MediaProjection requires a running foreground
      // service of type `mediaProjection` BEFORE the capture starts,
      // otherwise SecurityException is thrown. Start ours, then publish.
      if (Platform.isAndroid) {
        // Notification runtime permission (Android 13+).
        await Permission.notification.request();
        try {
          await _androidChannel.invokeMethod('startScreenCaptureService');
        } catch (_) {
          // Best-effort; setScreenShareEnabled will surface a clearer error.
        }
      }

      // On Android this triggers MediaProjection; the foreground service
      // started above satisfies the OS requirement.
      await _session.room.localParticipant?.setScreenShareEnabled(
        true,
        screenShareCaptureOptions: screenOpts,
      );

      // Send initial screenInfo to anyone in the room.
      final info = await _injector.screenInfo();
      await _session.sendData(info.encode(), reliable: true);

      // Start streaming "is editable focused" → controllers as ImeStateEvent
      // so touch-only clients can pop their soft keyboard automatically.
      await _focusSub?.cancel();
      _lastFocusBroadcast = false;
      _focusSub = _focusWatcher.editableFocused.listen((v) {
        if (v == _lastFocusBroadcast) return;
        _lastFocusBroadcast = v;
        // Best-effort; ignore send failures (room may be tearing down).
        _session
            .sendData(ImeStateEvent(open: v).encode(), reliable: true)
            .catchError((_) {});
      });

      setState(() {
        _connecting = false;
        _connected = true;
      });
    } catch (e) {
      // If anything failed after we started the foreground service, stop it
      // so the user doesn't have a stale notification.
      if (Platform.isAndroid) {
        try {
          await _androidChannel.invokeMethod('stopScreenCaptureService');
        } catch (_) {}
      }
      setState(() {
        _connecting = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _stop() async {
    await _focusSub?.cancel();
    _focusSub = null;
    await _listener?.dispose();
    _listener = null;
    await _session.dispose();
    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod('stopScreenCaptureService');
      } catch (_) {}
    }
    _injector.setTargetDisplay(null);
    if (mounted) {
      setState(() {
        _connected = false;
        _activeDisplay = null;
      });
    }
  }

  /// Pick a different monitor and republish the screen-share track.
  /// Desktop-only — hidden on Android/iOS.
  Future<void> _switchScreen() async {
    if (!_connected || _switching) return;
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      final source = await showDialog<rtc.DesktopCapturerSource>(
        context: context,
        barrierDismissible: true,
        builder: (_) => ScreenSelectDialog(),
      );
      if (source == null) {
        setState(() => _switching = false);
        return;
      }
      final lp = _session.room.localParticipant;
      if (lp == null) throw Exception('Not connected.');

      // Unpublish current screen share, then republish with the new source.
      await lp.setScreenShareEnabled(false);
      await lp.setScreenShareEnabled(
        true,
        screenShareCaptureOptions: ScreenShareCaptureOptions(
          sourceId: source.id,
          maxFrameRate: 15,
        ),
      );

      _displays = ScreenEnumerator.list();
      _activeDisplay = await _resolveDisplay(source);
      _injector.setTargetDisplay(_activeDisplay);
      // ignore: avoid_print
      print(
        '[host] switched to: ${_activeDisplay?.label} '
        '(rect ${_activeDisplay?.x},${_activeDisplay?.y} '
        '${_activeDisplay?.width}x${_activeDisplay?.height})',
      );

      // Refresh controllers' mapping with the new monitor's pixel size.
      final info = await _injector.screenInfo();
      await _session.sendData(info.encode(), reliable: true);

      if (mounted) setState(() => _switching = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _switching = false;
          _error = 'Switch screen failed: $e';
        });
      }
    }
  }

  void _onData(DataReceivedEvent ev) {
    final event = InputEvent.decode(ev.data);
    if (event == null) return;
    // Drop everything except our supported inputs.
    _injector.handle(event);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppShutdown.unregister(_shutdownHook);
    _focusSub?.cancel();
    _focusWatcher.dispose();
    _listener?.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Host')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: _injectorReady
                  ? Colors.green.withValues(alpha: 0.15)
                  : Colors.orange.withValues(alpha: 0.15),
              child: ListTile(
                leading: Icon(
                  _injectorReady ? Icons.check_circle : Icons.warning,
                ),
                title: Text(
                  _injectorReady
                      ? 'Input injection ready'
                      : 'Input injection NOT ready',
                ),
                subtitle: Text(_injectorPermissionHint()),
                trailing: TextButton(
                  onPressed: () async {
                    await _injector.requestPermissions();
                    await _refreshInjectorStatus();
                  },
                  child: const Text('Open settings'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('Pairing code'),
                    const SizedBox(height: 8),
                    SelectableText(
                      _pairingCode,
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Share this code with the controller.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Card(
                color: Colors.red.withValues(alpha: 0.2),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: Icon(_connected ? Icons.stop : Icons.play_arrow),
                    label: Text(_connected ? 'Stop sharing' : 'Start sharing'),
                    onPressed: _connecting
                        ? null
                        : (_connected ? _stop : _start),
                  ),
                ),
              ],
            ),
            if (_connected) ...[
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cast_connected),
                  title: const Text('Connected'),
                  subtitle: Text(
                    _activeDisplay == null
                        ? 'Screen is being shared. Anyone with the pairing '
                              'code who joins this room can control this device.'
                        : 'Sharing & controlling: ${_activeDisplay!.label}',
                  ),
                ),
              ),
              if (Platform.isWindows ||
                  Platform.isMacOS ||
                  Platform.isLinux) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(_switching ? 'Switching…' : 'Switch screen'),
                  onPressed: _switching ? null : _switchScreen,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _injectorPermissionHint() {
    if (Platform.isWindows) {
      return 'No extra setup needed. To control elevated apps, run this '
          'app as Administrator.';
    }
    if (Platform.isMacOS) {
      return 'Grant Accessibility AND Screen Recording in '
          'System Settings → Privacy & Security.';
    }
    if (Platform.isAndroid) {
      return 'Enable the "Remote Desk Input" Accessibility Service in '
          'Settings → Accessibility.';
    }
    return 'Hosting is not supported on this platform.';
  }
}
