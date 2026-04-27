import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ModePickerScreen extends StatelessWidget {
  const ModePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controllerOnly = defaultTargetPlatform == TargetPlatform.iOS;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mago Remote Control'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose a mode',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),
              if (!controllerOnly) ...[
                _ModeCard(
                  icon: Icons.desktop_windows,
                  title: 'Host (be controlled)',
                  subtitle:
                      'Share this device\'s screen and accept remote input.\n'
                      'Supported on Windows, macOS, Android.',
                  onTap: () => Navigator.pushNamed(context, '/host'),
                ),
                const SizedBox(height: 16),
              ],
              _ModeCard(
                icon: Icons.mouse,
                title: 'Controller (drive remote)',
                subtitle:
                    'View a remote screen and send pointer/keyboard input.\n'
                    'Supported on any platform.',
                onTap: () => Navigator.pushNamed(context, '/controller'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 32),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        onTap: onTap,
      ),
    );
  }
}
