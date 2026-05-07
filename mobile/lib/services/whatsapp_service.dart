import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../models/backup_state.dart';

/// Listens for incoming Share intents (e.g. a WhatsApp exported .zip) and
/// uploads them to the RoamVault backend at POST /upload/whatsapp.
class WhatsappService {
  final AppSettings settings;
  final BackupState state;

  WhatsappService({required this.settings, required this.state});

  /// Call once from main() / app init.  Returns a [Stream] of incoming share
  /// events so the caller can react (e.g. show a snackbar).
  Stream<List<SharedMediaFile>> get shareStream =>
      ReceiveSharingIntent.instance.getMediaStream();

  /// Handle a list of shared files (called from shareStream listener).
  Future<void> handleSharedFiles(List<SharedMediaFile> files) async {
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      if (!path.toLowerCase().endsWith('.zip')) continue;
      await _uploadZip(File(path));
    }
  }

  /// Also handle the initial intent (app was launched via share).
  Future<void> handleInitialIntent() async {
    final files =
        await ReceiveSharingIntent.instance.getInitialMedia();
    await handleSharedFiles(files);
  }

  Future<void> _uploadZip(File zipFile) async {
    final uri = Uri.parse('${settings.backendUrl}/upload/whatsapp');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(
        await http.MultipartFile.fromPath('file', zipFile.path),
      );

    final response = await req.send();
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        'WhatsApp upload failed: HTTP ${response.statusCode}',
      );
    }
  }
}
