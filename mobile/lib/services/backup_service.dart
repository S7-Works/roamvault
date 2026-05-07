import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:path_provider/path_provider.dart';
import '../models/backup_state.dart';

/// Uploads photos/screenshots from the device camera roll to the RoamVault
/// backend at POST /upload/media.
class BackupService {
  final AppSettings settings;
  final BackupState state;

  BackupService({required this.settings, required this.state});

  /// Request photo library permission, then upload all assets that match the
  /// enabled toggles.
  Future<void> runBackup() async {
    // Request permission
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      state.finishBackup(error: 'Photo library permission denied.');
      return;
    }

    final albums = <AssetPathEntity>[];

    if (state.cameraRollEnabled) {
      final recentAlbum = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(
            sizeConstraint: SizeConstraint(ignoreSize: true),
          ),
        ),
      );
      albums.addAll(recentAlbum.where((a) => a.isAll));
    }

    if (state.screenshotsEnabled) {
      final all = await PhotoManager.getAssetPathList(type: RequestType.image);
      albums.addAll(
        all.where((a) => a.name.toLowerCase().contains('screenshot')),
      );
    }

    // Collect unique asset IDs
    final seen = <String>{};
    final assets = <AssetEntity>[];
    for (final album in albums) {
      final count = await album.assetCountAsync;
      final page = await album.getAssetListPaged(page: 0, size: count);
      for (final asset in page) {
        if (seen.add(asset.id)) assets.add(asset);
      }
    }

    state.startBackup(assets.length);

    int failed = 0;
    for (final asset in assets) {
      try {
        await _uploadAsset(asset);
        state.incrementUploaded();
      } catch (_) {
        failed++;
      }
    }

    state.finishBackup(
      error: failed > 0 ? '$failed files failed to upload.' : null,
    );
  }

  Future<void> _uploadAsset(AssetEntity asset) async {
    final file = await asset.originFile;
    if (file == null) return;

    final uri = Uri.parse('${settings.backendUrl}/upload/media');
    final req = http.MultipartRequest('POST', uri)
      ..fields['asset_id'] = asset.id
      ..fields['created_at'] = asset.createDateTime.toIso8601String()
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final response = await req.send();
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        'Upload failed for ${asset.id}: HTTP ${response.statusCode}',
      );
    }
  }

  /// Returns the total size in bytes of all local photo assets.
  Future<int> estimateLocalSize() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) return 0;

    final all = await PhotoManager.getAssetPathList(type: RequestType.image);
    int total = 0;
    for (final album in all.where((a) => a.isAll)) {
      final count = await album.assetCountAsync;
      final page = await album.getAssetListPaged(page: 0, size: count);
      for (final asset in page) {
        total += await asset.originBytes.then((b) => b?.length ?? 0);
      }
    }
    return total;
  }
}
