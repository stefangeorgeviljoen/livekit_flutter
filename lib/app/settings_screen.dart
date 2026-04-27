import 'package:flutter/material.dart';

import 'settings_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsStore? _store;
  late TextEditingController _urlCtl;
  late TextEditingController _tokenCtl;
  late TextEditingController _roomCtl;
  late TextEditingController _identityCtl;

  @override
  void initState() {
    super.initState();
    _urlCtl = TextEditingController();
    _tokenCtl = TextEditingController();
    _roomCtl = TextEditingController();
    _identityCtl = TextEditingController();
    SettingsStore.load().then((s) {
      setState(() {
        _store = s;
        _urlCtl.text = s.liveKitUrl;
        _tokenCtl.text = s.tokenEndpoint;
        _roomCtl.text = s.roomName;
        _identityCtl.text = s.identity;
      });
    });
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    _tokenCtl.dispose();
    _roomCtl.dispose();
    _identityCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = _store;
    if (s == null) return;
    await s.save(
      liveKitUrl: _urlCtl.text.trim(),
      tokenEndpoint: _tokenCtl.text.trim(),
      roomName: _roomCtl.text.trim(),
      identity: _identityCtl.text.trim(),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _store == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _field(
                  _urlCtl,
                  'LiveKit URL',
                  'wss://your-project.livekit.cloud',
                ),
                _field(
                  _tokenCtl,
                  'Token endpoint URL',
                  'https://your-server.example.com/token',
                ),
                _field(_roomCtl, 'Room name', 'remote-desk'),
                _field(_identityCtl, 'Your identity', 'user-abc123'),
                const SizedBox(height: 24),
                FilledButton(onPressed: _save, child: const Text('Save')),
                const SizedBox(height: 16),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'TODO (you):\n'
                      '  • Deploy the Node token server in /token-server.\n'
                      '  • Set LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET\n'
                      '    on that server (NEVER in this app).\n'
                      '  • Paste the public token endpoint URL above.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
