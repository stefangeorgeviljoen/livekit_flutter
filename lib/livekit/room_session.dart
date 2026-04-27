import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

/// Thin wrapper around a [Room] handling connect/disconnect lifecycle.
class RoomSession {
  RoomSession();

  final Room _room = Room(
    roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
  );
  Room get room => _room;

  bool _connected = false;
  bool get isConnected => _connected;

  Future<void> connect({required String url, required String token}) async {
    await _room.connect(url, token);
    _connected = true;
  }

  Future<void> sendData(
    List<int> bytes, {
    bool reliable = true,
    List<String>? toIdentities,
  }) async {
    await _room.localParticipant?.publishData(
      bytes,
      reliable: reliable,
      destinationIdentities: toIdentities,
    );
  }

  Future<void> dispose() async {
    if (_connected) {
      await _room.disconnect();
      _connected = false;
    }
    await _room.dispose();
  }
}
