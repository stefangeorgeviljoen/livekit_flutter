import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import '../app/settings_store.dart';
import '../livekit/room_session.dart';
import '../livekit/token_client.dart';
import '../main.dart' show AppShutdown;
import '../protocol/input_event.dart' as proto;
import 'ime_bridge.dart';

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  final _session = RoomSession();
  final _codeCtl = TextEditingController();
  final _focusNode = FocusNode();
  late final ImeBridge _ime = ImeBridge(send: _send);

  bool _connecting = false;
  bool _connected = false;
  bool _imeOpen = false;
  String? _error;
  VideoTrack? _remoteVideo;
  EventsListener<RoomEvent>? _listener;

  /// Captured surface size in host pixels, reported via ScreenInfoEvent.
  /// Used to compute the letterboxed video rect inside the renderer so
  /// taps line up regardless of host vs. controller aspect ratio.
  int? _hostW;
  int? _hostH;

  /// Per-pointer touch state used to convert a long-press into a remote
  /// right-click and a quick tap into a remote left-click.
  final Map<int, _TouchState> _touches = {};

  /// True if the platform has a soft keyboard / no built-in mouse: we then
  /// expose the long-press → right-click affordance and the keyboard FAB.
  bool get _isTouchPlatform => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    AppShutdown.register(_shutdownHook);
  }

  Future<void> _shutdownHook() async {
    _ime.detach();
    await _session.dispose();
  }

  @override
  void dispose() {
    AppShutdown.unregister(_shutdownHook);
    _ime.detach();
    for (final t in _touches.values) {
      t.longPressTimer?.cancel();
    }
    _touches.clear();
    _listener?.dispose();
    _codeCtl.dispose();
    _focusNode.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final settings = await SettingsStore.load();
      final token = await TokenClient(settings.tokenEndpoint).fetchToken(
        room: settings.roomName,
        identity: settings.identity,
        role: 'controller',
        pairingCode: _codeCtl.text.trim(),
      );

      await _session.connect(url: settings.liveKitUrl, token: token);

      _listener = _session.room.createListener();
      _listener!.on<TrackSubscribedEvent>((e) {
        if (e.track is VideoTrack) {
          if (mounted) setState(() => _remoteVideo = e.track as VideoTrack);
        }
      });

      _listener!.on<DataReceivedEvent>((e) {
        final ev = proto.InputEvent.decode(e.data);
        if (ev is proto.ScreenInfoEvent && ev.width > 0 && ev.height > 0) {
          if (mounted) {
            setState(() {
              _hostW = ev.width;
              _hostH = ev.height;
            });
          }
        } else if (ev is proto.ImeStateEvent) {
          // The host says focus moved on/off an editable field. Pop the
          // OS keyboard up (or dismiss) on touch platforms only — no
          // reason to do anything on desktop where the user has a
          // physical keyboard already.
          if (!_isTouchPlatform) return;
          if (ev.open && !_imeOpen) {
            _ime.attach();
            if (mounted) setState(() => _imeOpen = true);
          } else if (!ev.open && _imeOpen) {
            _ime.detach();
            if (mounted) setState(() => _imeOpen = false);
          }
        }
      });

      // Pick up any already-published tracks.
      for (final p in _session.room.remoteParticipants.values) {
        for (final pub in p.videoTrackPublications) {
          if (pub.track != null) {
            setState(() => _remoteVideo = pub.track as VideoTrack);
          }
        }
      }

      setState(() {
        _connecting = false;
        _connected = true;
      });
      _focusNode.requestFocus();
    } catch (e) {
      setState(() {
        _connecting = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    _ime.detach();
    for (final t in _touches.values) {
      t.longPressTimer?.cancel();
    }
    _touches.clear();
    await _listener?.dispose();
    _listener = null;
    await _session.dispose();
    if (mounted) {
      setState(() {
        _connected = false;
        _remoteVideo = null;
        _hostW = null;
        _hostH = null;
        _imeOpen = false;
      });
    }
  }

  void _send(proto.InputEvent ev, {bool reliable = true}) {
    if (!_connected) return;
    _session.sendData(ev.encode(), reliable: reliable);
  }

  /// Letterboxed rect occupied by the host's video inside [container].
  /// Matches `VideoViewFit.contain` (centered, preserve aspect). When the
  /// host's pixel size isn't known yet, returns the full container so we
  /// don't drop the first taps.
  Rect _videoRect(Size container) {
    final hw = _hostW;
    final hh = _hostH;
    if (hw == null || hh == null || hw <= 0 || hh <= 0) {
      return Offset.zero & container;
    }
    final cw = container.width;
    final ch = container.height;
    if (cw <= 0 || ch <= 0) return Offset.zero & container;
    final hostA = hw / hh;
    final contA = cw / ch;
    double w, h;
    if (hostA > contA) {
      // Host is wider: pillarbox top/bottom… actually letterbox top/bottom.
      w = cw;
      h = cw / hostA;
    } else {
      h = ch;
      w = ch * hostA;
    }
    final x = (cw - w) / 2.0;
    final y = (ch - h) / 2.0;
    return Rect.fromLTWH(x, y, w, h);
  }

  /// Translate a local pointer to the host's normalized 0..1 space.
  /// Returns null if [strict] and the point falls outside the video rect
  /// (used for button down/up so clicks in the letterbox are ignored).
  Offset? _toHost(Offset local, Rect rect, {bool strict = false}) {
    if (rect.width <= 0 || rect.height <= 0) return null;
    final nx = (local.dx - rect.left) / rect.width;
    final ny = (local.dy - rect.top) / rect.height;
    if (strict && (nx < 0 || nx > 1 || ny < 0 || ny > 1)) return null;
    return Offset(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Controller'),
        actions: [
          if (_connected)
            IconButton(icon: const Icon(Icons.logout), onPressed: _disconnect),
        ],
      ),
      body: _connected ? _buildSession() : _buildJoin(),
      floatingActionButton: (_connected && _isTouchPlatform)
          ? FloatingActionButton(
              heroTag: 'kbd',
              tooltip: _imeOpen ? 'Hide keyboard' : 'Show keyboard',
              onPressed: () {
                if (_imeOpen) {
                  _ime.detach();
                  setState(() => _imeOpen = false);
                } else {
                  _ime.attach();
                  setState(() => _imeOpen = true);
                }
              },
              child: Icon(_imeOpen ? Icons.keyboard_hide : Icons.keyboard),
            )
          : null,
    );
  }

  Widget _buildJoin() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Enter the 6-digit pairing code shown on the host device.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeCtl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Pairing code',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _connecting ? null : _connect,
            child: Text(_connecting ? 'Connecting…' : 'Connect'),
          ),
        ],
      ),
    );
  }

  Widget _buildSession() {
    final video = _remoteVideo;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullSize = Size(constraints.maxWidth, constraints.maxHeight);
        final videoRect = _videoRect(fullSize);
        // Android's edge swipe-back / swipe-up reserved zones, expressed
        // in body-local pixels (== same coord system as videoRect &
        // PointerEvent.localPosition coming out of the body-filling
        // Listener). Zero everywhere except on Android.
        final gi = MediaQuery.of(context).systemGestureInsets;

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Listener(
            // Translucent: this Listener fills the whole body, but only
            // the handlers below consume the event. Pointer hits on the
            // letterbox / gesture-insets fall through and are dropped by
            // _isInsideActiveArea(), letting OS gestures reach the OS.
            behavior: HitTestBehavior.translucent,
            onPointerHover: (e) => _onHover(e, videoRect, gi),
            onPointerDown: (e) => _onPointerDown(e, videoRect, gi),
            onPointerMove: (e) => _onPointerMove(e, videoRect, gi),
            onPointerUp: (e) => _onPointerUp(e, videoRect, gi),
            onPointerCancel: (e) => _onPointerCancel(e),
            onPointerSignal: (e) => _onPointerSignal(e, videoRect, gi),
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: Container(
                    color: Colors.black,
                    child: video == null
                        ? const Center(
                            child: Text(
                              'Waiting for host video…',
                              style: TextStyle(color: Colors.white70),
                            ),
                          )
                        : VideoTrackRenderer(video, fit: VideoViewFit.contain),
                  ),
                ),
                // Faint white border around the video rect so the user
                // can see exactly where taps register.
                if (video != null && _hostW != null && _hostH != null)
                  Positioned.fromRect(
                    rect: videoRect,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// True when [local] (body-local pixels, i.e. PointerEvent.localPosition)
  /// is inside the visible video AND outside the OS gesture-reserved bands.
  /// `gi` is in body-local pixels: `gi.left/top` are coordinates from the
  /// body origin, `gi.right/bottom` are widths measured from the far edge.
  bool _isInsideActiveArea(Offset local, Rect videoRect, EdgeInsets gi) {
    if (!videoRect.contains(local)) return false;
    if (local.dx < gi.left) return false;
    if (local.dy < gi.top) return false;
    final mq = MediaQuery.maybeOf(context);
    final fullSize = mq?.size ?? videoRect.size;
    if (local.dx > fullSize.width - gi.right) return false;
    if (local.dy > fullSize.height - gi.bottom) return false;
    return true;
  }

  // --------- Pointer handlers ---------

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) {
    final isDown = evt is KeyDownEvent || evt is KeyRepeatEvent;
    int mods = 0;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight)) {
      mods |= proto.KeyMods.shift;
    }
    if (keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight)) {
      mods |= proto.KeyMods.ctrl;
    }
    if (keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight)) {
      mods |= proto.KeyMods.alt;
    }
    if (keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight)) {
      mods |= proto.KeyMods.meta;
    }
    _send(
      proto.KeyInputEvent(
        logicalKey: evt.logicalKey.keyId,
        physicalKey: evt.physicalKey.usbHidUsage,
        down: isDown,
        modifiers: mods,
      ),
    );
    if (isDown &&
        evt.character != null &&
        evt.character!.isNotEmpty &&
        mods & (proto.KeyMods.ctrl | proto.KeyMods.meta | proto.KeyMods.alt) ==
            0) {
      _send(proto.TextEvent(text: evt.character!));
    }
    return KeyEventResult.handled;
  }

  void _onHover(PointerHoverEvent e, Rect rect, EdgeInsets gi) {
    if (!_isInsideActiveArea(e.localPosition, rect, gi)) return;
    final n = _toHost(e.localPosition, rect, strict: true);
    if (n == null) return;
    _send(proto.MouseMoveEvent(x: n.dx, y: n.dy), reliable: false);
  }

  void _onPointerDown(PointerDownEvent e, Rect rect, EdgeInsets gi) {
    // localPosition is body-local — the same coord system as videoRect —
    // because the Listener fills the body. No global offset to subtract.
    if (!_isInsideActiveArea(e.localPosition, rect, gi)) return;
    final n = _toHost(e.localPosition, rect, strict: true);
    if (n == null) return;

    if (e.kind == PointerDeviceKind.touch) {
      // Defer click decision until we know if this is a tap, drag, or
      // long-press.
      final state = _TouchState(start: e.localPosition, startNorm: n);
      _touches[e.pointer] = state;
      state.longPressTimer = Timer(const Duration(milliseconds: 500), () {
        // Long-press from a touch → remote right-click.
        state.longPressFired = true;
        _send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.right,
            down: true,
            x: n.dx,
            y: n.dy,
          ),
        );
        _send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.right,
            down: false,
            x: n.dx,
            y: n.dy,
          ),
        );
      });
      return;
    }

    // Mouse / stylus: send button-down immediately.
    _send(
      proto.MouseButtonEvent(
        button: _mapButton(e.buttons),
        down: true,
        x: n.dx,
        y: n.dy,
      ),
    );
  }

  void _onPointerMove(PointerMoveEvent e, Rect rect, EdgeInsets gi) {
    if (!_isInsideActiveArea(e.localPosition, rect, gi)) {
      // Pointer wandered into a dead zone mid-gesture; just stop sending
      // moves but don't kill the in-flight touch state — it will be
      // resolved on PointerUp/Cancel.
      return;
    }
    final n = _toHost(e.localPosition, rect, strict: true);
    if (n == null) return;

    if (e.kind == PointerDeviceKind.touch) {
      final st = _touches[e.pointer];
      if (st != null && !st.dragging && !st.longPressFired) {
        final dx = e.localPosition.dx - st.start.dx;
        final dy = e.localPosition.dy - st.start.dy;
        if ((dx * dx + dy * dy) > (12 * 12)) {
          // Promote to drag: cancel long-press timer, emit a real
          // left-down at the original position, then start streaming
          // moves.
          st.longPressTimer?.cancel();
          st.dragging = true;
          _send(
            proto.MouseButtonEvent(
              button: proto.MouseButton.left,
              down: true,
              x: st.startNorm.dx,
              y: st.startNorm.dy,
            ),
          );
        }
      }
      if (st?.longPressFired == true) return; // already issued right-click
    }

    _send(proto.MouseMoveEvent(x: n.dx, y: n.dy), reliable: false);
  }

  void _onPointerUp(PointerUpEvent e, Rect rect, EdgeInsets gi) {
    final n = _toHost(e.localPosition, rect, strict: true);
    if (n == null || !_isInsideActiveArea(e.localPosition, rect, gi)) {
      _touches.remove(e.pointer)?.longPressTimer?.cancel();
      return;
    }

    if (e.kind == PointerDeviceKind.touch) {
      final st = _touches.remove(e.pointer);
      st?.longPressTimer?.cancel();
      if (st == null) return;
      if (st.longPressFired) return; // right-click already fully sent
      if (st.dragging) {
        // End of drag: just release the left button.
        _send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.left,
            down: false,
            x: n.dx,
            y: n.dy,
          ),
        );
      } else {
        // Quick tap → synthesize a click pair.
        _send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.left,
            down: true,
            x: st.startNorm.dx,
            y: st.startNorm.dy,
          ),
        );
        _send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.left,
            down: false,
            x: st.startNorm.dx,
            y: st.startNorm.dy,
          ),
        );
      }
      return;
    }

    // Mouse / stylus.
    _send(
      proto.MouseButtonEvent(
        button: _mapButton(e.buttons),
        down: false,
        x: n.dx,
        y: n.dy,
      ),
    );
  }

  void _onPointerCancel(PointerCancelEvent e) {
    final st = _touches.remove(e.pointer);
    st?.longPressTimer?.cancel();
    if (st != null && st.dragging) {
      _send(
        proto.MouseButtonEvent(
          button: proto.MouseButton.left,
          down: false,
          x: st.startNorm.dx,
          y: st.startNorm.dy,
        ),
      );
    }
  }

  void _onPointerSignal(PointerSignalEvent e, Rect rect, EdgeInsets gi) {
    if (e is PointerScrollEvent) {
      if (!_isInsideActiveArea(e.localPosition, rect, gi)) return;
      final n = _toHost(e.localPosition, rect, strict: true);
      if (n == null) return;
      _send(
        proto.MouseWheelEvent(
          dx: -e.scrollDelta.dx / 50,
          dy: -e.scrollDelta.dy / 50,
        ),
      );
    }
  }

  proto.MouseButton _mapButton(int buttons) {
    if (buttons & kSecondaryMouseButton != 0) return proto.MouseButton.right;
    if (buttons & kMiddleMouseButton != 0) return proto.MouseButton.middle;
    return proto.MouseButton.left;
  }
}

/// Per-pointer state used by the touch → mouse translation logic. We
/// hold off on emitting a `mouseDown` until we know whether the gesture
/// is a tap, a drag, or a long-press; this lets us materialize:
///   • short tap        → left-click pair
///   • drag             → real left-down / move… / left-up
///   • long-press (>500ms) → right-click pair
class _TouchState {
  _TouchState({required this.start, required this.startNorm});
  final Offset start; // pixels in video-rect-local coords
  final Offset startNorm; // 0..1 in host space
  Timer? longPressTimer;
  bool dragging = false;
  bool longPressFired = false;
}
