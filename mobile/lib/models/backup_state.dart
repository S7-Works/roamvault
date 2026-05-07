import 'package:flutter/foundation.dart';

/// Tracks what is enabled for backup and current progress.
class BackupState extends ChangeNotifier {
  // --- toggles ---
  bool _cameraRollEnabled = true;
  bool _screenshotsEnabled = true;
  bool _whatsappEnabled = false;

  bool get cameraRollEnabled => _cameraRollEnabled;
  bool get screenshotsEnabled => _screenshotsEnabled;
  bool get whatsappEnabled => _whatsappEnabled;

  void setCameraRoll(bool v) {
    _cameraRollEnabled = v;
    notifyListeners();
  }

  void setScreenshots(bool v) {
    _screenshotsEnabled = v;
    notifyListeners();
  }

  void setWhatsapp(bool v) {
    _whatsappEnabled = v;
    notifyListeners();
  }

  // --- progress ---
  bool _isRunning = false;
  int _totalFiles = 0;
  int _uploadedFiles = 0;
  String? _lastError;

  bool get isRunning => _isRunning;
  int get totalFiles => _totalFiles;
  int get uploadedFiles => _uploadedFiles;
  String? get lastError => _lastError;

  double get progress =>
      _totalFiles == 0 ? 0.0 : _uploadedFiles / _totalFiles;

  void startBackup(int total) {
    _isRunning = true;
    _totalFiles = total;
    _uploadedFiles = 0;
    _lastError = null;
    notifyListeners();
  }

  void incrementUploaded() {
    _uploadedFiles++;
    notifyListeners();
  }

  void finishBackup({String? error}) {
    _isRunning = false;
    _lastError = error;
    notifyListeners();
  }

  // --- storage stats (populated after sync) ---
  int totalBackedUpBytes = 0;
  int spaceFreedBytes = 0;
  DateTime? lastSyncAt;

  void updateStats({
    required int backedUp,
    required int spaceFreed,
    required DateTime syncTime,
  }) {
    totalBackedUpBytes = backedUp;
    spaceFreedBytes = spaceFreed;
    lastSyncAt = syncTime;
    notifyListeners();
  }
}

/// Holds B2 / backend settings.
class AppSettings extends ChangeNotifier {
  String backendUrl = 'http://localhost:8080';
  String b2KeyId = '';
  String b2AppKey = '';
  String b2BucketId = '';
  int backupScheduleHours = 24; // hours between auto-backup
  int expiryDays = 90;

  void update({
    String? url,
    String? keyId,
    String? appKey,
    String? bucketId,
    int? scheduleHours,
    int? expiry,
  }) {
    if (url != null) backendUrl = url;
    if (keyId != null) b2KeyId = keyId;
    if (appKey != null) b2AppKey = appKey;
    if (bucketId != null) b2BucketId = bucketId;
    if (scheduleHours != null) backupScheduleHours = scheduleHours;
    if (expiry != null) expiryDays = expiry;
    notifyListeners();
  }
}
