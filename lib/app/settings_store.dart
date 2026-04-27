import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent app settings.
///
/// All values are user-supplied at runtime via [SettingsScreen]; nothing
/// secret is bundled with the app.
class SettingsStore {
  SettingsStore._(this._prefs);

  static const _kLiveKitUrl = 'livekit_url';
  static const _kTokenEndpoint = 'token_endpoint';
  static const _kRoomName = 'room_name';
  static const _kIdentity = 'identity';
  static const _kAutoStartShare = 'auto_start_share';

  // TODO: (user) Replace these defaults via the in-app Settings screen.
  // Do NOT bake real keys/secrets here.
  static const String defaultLiveKitUrl = 'wss://vc-sdk-0h5x4vfr.livekit.cloud';
  static const String defaultTokenEndpoint =
      'https://lzqjxmwr-4317.inc1.devtunnels.ms/api/token';
  static const String defaultRoomName = 'remote-desk';

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore._(prefs);
  }

  String get liveKitUrl => _prefs.getString(_kLiveKitUrl) ?? defaultLiveKitUrl;
  String get tokenEndpoint =>
      _prefs.getString(_kTokenEndpoint) ?? defaultTokenEndpoint;
  String get roomName => _prefs.getString(_kRoomName) ?? defaultRoomName;
  String get identity => _prefs.getString(_kIdentity) ?? _generateIdentity();

  /// When true (default), the host skips the screen-picker on Start and
  /// immediately publishes the primary monitor. The user can still pick
  /// a different screen with the "Switch screen" button.
  bool get autoStartShare => _prefs.getBool(_kAutoStartShare) ?? true;

  Future<void> save({
    required String liveKitUrl,
    required String tokenEndpoint,
    required String roomName,
    required String identity,
    bool? autoStartShare,
  }) async {
    await _prefs.setString(_kLiveKitUrl, liveKitUrl);
    await _prefs.setString(_kTokenEndpoint, tokenEndpoint);
    await _prefs.setString(_kRoomName, roomName);
    await _prefs.setString(_kIdentity, identity);
    if (autoStartShare != null) {
      await _prefs.setBool(_kAutoStartShare, autoStartShare);
    }
  }

  Future<void> setAutoStartShare(bool value) async {
    await _prefs.setBool(_kAutoStartShare, value);
  }

  String _generateIdentity() {
    final r = Random();
    final id = 'user-${r.nextInt(1 << 32).toRadixString(36)}';
    _prefs.setString(_kIdentity, id);
    return id;
  }
}
