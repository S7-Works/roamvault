// TODO(slint): Replace Flutter widget tree with Slint UI once the
// slint-flutter plugin reaches production readiness.

import 'package:flutter/material.dart';

/// Placeholder data model for a single app's storage footprint.
class _AppStorageInfo {
  final String name;
  final int bytes;
  final IconData icon;

  const _AppStorageInfo({
    required this.name,
    required this.bytes,
    required this.icon,
  });
}

// Placeholder dataset — replace with real device data when the OS API is
// integrated (Android: PackageManager / UsageStatsManager; iOS: DeviceCheck).
const _placeholderApps = [
  _AppStorageInfo(
    name: 'WhatsApp',
    bytes: 1_420_000_000,
    icon: Icons.chat_bubble_outline,
  ),
  _AppStorageInfo(
    name: 'Google Photos',
    bytes: 980_000_000,
    icon: Icons.photo_library_outlined,
  ),
  _AppStorageInfo(
    name: 'Spotify',
    bytes: 540_000_000,
    icon: Icons.music_note_outlined,
  ),
  _AppStorageInfo(
    name: 'Maps (offline)',
    bytes: 430_000_000,
    icon: Icons.map_outlined,
  ),
  _AppStorageInfo(
    name: 'Camera Roll cache',
    bytes: 310_000_000,
    icon: Icons.camera_alt_outlined,
  ),
  _AppStorageInfo(
    name: 'Instagram',
    bytes: 210_000_000,
    icon: Icons.photo_camera_outlined,
  ),
  _AppStorageInfo(
    name: 'Other',
    bytes: 800_000_000,
    icon: Icons.folder_outlined,
  ),
];

class AppAnalysisScreen extends StatelessWidget {
  const AppAnalysisScreen({super.key});

  String _fmtBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final total = _placeholderApps.fold<int>(0, (s, a) => s + a.bytes);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Storage Analysis'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // ── Summary header ─────────────────────────────────────────────
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  'Total App Storage',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: cs.onPrimaryContainer,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtBytes(total),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: cs.primary,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '(placeholder data)',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onPrimaryContainer.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),

          // ── Per-app list ───────────────────────────────────────────────
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _placeholderApps.length,
              separatorBuilder: (_, __) => const Divider(height: 0),
              itemBuilder: (context, i) {
                final app = _placeholderApps[i];
                final fraction = total == 0 ? 0.0 : app.bytes / total;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: cs.secondaryContainer,
                    child: Icon(app.icon, color: cs.secondary, size: 20),
                  ),
                  title: Text(app.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: fraction,
                        backgroundColor: Colors.grey[200],
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
                  trailing: Text(
                    _fmtBytes(app.bytes),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
