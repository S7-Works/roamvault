// TODO(slint): Replace Flutter widget tree with Slint UI once the
// slint-flutter plugin reaches production readiness.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/backup_state.dart';
import '../services/backup_service.dart';

class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BackupState>();
    final settings = context.read<AppSettings>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Source toggles ─────────────────────────────────────────────
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Camera Roll'),
                  subtitle: const Text('Back up all photos and videos'),
                  secondary: const Icon(Icons.photo_library_outlined),
                  value: state.cameraRollEnabled,
                  onChanged:
                      state.isRunning ? null : state.setCameraRoll,
                ),
                const Divider(height: 0),
                SwitchListTile(
                  title: const Text('Screenshots'),
                  subtitle: const Text('Back up screenshots separately'),
                  secondary: const Icon(Icons.screenshot_outlined),
                  value: state.screenshotsEnabled,
                  onChanged:
                      state.isRunning ? null : state.setScreenshots,
                ),
                const Divider(height: 0),
                SwitchListTile(
                  title: const Text('WhatsApp Media'),
                  subtitle: const Text('Accept .zip shares from WhatsApp'),
                  secondary: const Icon(Icons.chat_outlined),
                  value: state.whatsappEnabled,
                  onChanged:
                      state.isRunning ? null : state.setWhatsapp,
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Progress ───────────────────────────────────────────────────
          if (state.isRunning || state.totalFiles > 0) ...[
            Text(
              state.isRunning
                  ? 'Uploading ${state.uploadedFiles} / ${state.totalFiles}'
                  : state.lastError != null
                      ? 'Finished with errors'
                      : 'Backup complete',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: state.isRunning ? state.progress : 1.0,
              backgroundColor: Colors.grey[200],
              minHeight: 8,
            ),
            if (state.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                state.lastError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
          ],

          // ── Backup Now button ──────────────────────────────────────────
          FilledButton.icon(
            onPressed: state.isRunning
                ? null
                : () async {
                    final svc = BackupService(
                      settings: settings,
                      state: state,
                    );
                    await svc.runBackup();
                  },
            icon: state.isRunning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            label: Text(state.isRunning ? 'Backing up…' : 'Backup Now'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
