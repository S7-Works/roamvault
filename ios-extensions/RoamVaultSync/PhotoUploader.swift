import Photos
import os.log

private let log = OSLog(subsystem: "app.roamvault.sync", category: "PhotoUploader")

// MARK: - PhotoUploader

/// Fetches unsynced assets from `PHPhotoLibrary` and uploads them to the
/// RoamVault backend via `POST /upload/media`.
///
/// "Unsynced" is tracked by recording each successfully uploaded local
/// identifier in shared `UserDefaults` (app group).
public final class PhotoUploader {

    // MARK: - UserDefaults key

    private static let uploadedIDsKey = "roamvault_uploaded_asset_ids"

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: RoamVaultAPI.appGroupID) ?? .standard
    }

    // MARK: - State

    private var isCancelled = false
    private var activeTasks: [URLSessionTask] = []
    private let tasksQueue = DispatchQueue(label: "app.roamvault.uploader.tasks")

    // MARK: - Public API

    /// Cancels any in-flight uploads. Called by the BGTask expiration handler.
    public func cancelAll() {
        isCancelled = true
        tasksQueue.sync {
            activeTasks.forEach { $0.cancel() }
            activeTasks.removeAll()
        }
    }

    /// Checks whether the photo library contains assets not yet uploaded.
    /// Completes on a background queue.
    public func checkForNewPhotos(completion: @escaping (Bool) -> Void) {
        let uploaded = Self.uploadedAssetIDs()
        let assets = fetchAssets()
        let hasNew = assets.contains(where: { !uploaded.contains($0.localIdentifier) })
        completion(hasNew)
    }

    /// Uploads all new (not-yet-synced) photos to RoamVault.
    /// - Parameter completion: Called on a background queue with the count of newly uploaded assets, or an error.
    public func uploadNewPhotos(completion: @escaping (Result<Int, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                os_log("Photo library access denied", log: log, type: .info)
                completion(.failure(UploaderError.photoAccessDenied))
                return
            }
            self.performUpload(completion: completion)
        }
    }

    // MARK: - Private

    private func performUpload(completion: @escaping (Result<Int, Error>) -> Void) {
        let uploaded = Self.uploadedAssetIDs()
        let assets = fetchAssets().filter { !uploaded.contains($0.localIdentifier) }

        guard !assets.isEmpty else {
            completion(.success(0))
            return
        }

        os_log("Found %d asset(s) to upload", log: log, type: .info, assets.count)

        var uploadedCount = 0
        var lastError: Error?
        let group = DispatchGroup()

        // Process assets sequentially to avoid memory spikes during a background task.
        let queue = DispatchQueue(label: "app.roamvault.uploader.serial")
        queue.async {
            for asset in assets {
                guard !self.isCancelled else { break }
                group.enter()
                self.upload(asset: asset) { result in
                    switch result {
                    case .success:
                        uploadedCount += 1
                        Self.markUploaded(localIdentifier: asset.localIdentifier)
                    case .failure(let error):
                        lastError = error
                        os_log("Upload failed for %{public}@: %{public}@",
                               log: log, type: .error,
                               asset.localIdentifier, error.localizedDescription)
                    }
                    group.leave()
                }
                group.wait()
            }

            if let error = lastError, uploadedCount == 0 {
                completion(.failure(error))
            } else {
                completion(.success(uploadedCount))
            }
        }
    }

    private func upload(asset: PHAsset, completion: @escaping (Result<Void, Error>) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        if asset.mediaType == .video {
            uploadVideo(asset: asset, completion: completion)
        } else {
            uploadPhoto(asset: asset, options: options, completion: completion)
        }
    }

    private func uploadPhoto(
        asset: PHAsset,
        options: PHImageRequestOptions,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Request the full-resolution image data to preserve HEIC originals.
        let dataOptions = PHImageRequestOptions()
        dataOptions.isNetworkAccessAllowed = true
        dataOptions.version = .original

        PHImageManager.default().requestImageDataAndOrientation(
            for: asset,
            options: dataOptions
        ) { [weak self] data, uti, _, info in
            guard let self else { return }

            if let error = info?[PHImageErrorKey] as? Error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(UploaderError.assetDataUnavailable))
                return
            }

            let filename = self.filename(for: asset, uti: uti)
            let mimeType = self.mimeType(forUTI: uti)

            // Write to a temp file so RoamVaultClient can stream it via URLSession
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(filename.components(separatedBy: ".").last ?? "jpg")

            do {
                try data.write(to: tempURL)
            } catch {
                completion(.failure(error))
                return
            }

            RoamVaultClient.shared.uploadMedia(
                fileURL: tempURL,
                filename: filename,
                mimeType: mimeType
            ) { result in
                try? FileManager.default.removeItem(at: tempURL)
                completion(result.map { _ in () })
            }
        }
    }

    private func uploadVideo(
        asset: PHAsset,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
            if let error = info?[PHImageErrorKey] as? Error {
                completion(.failure(error))
                return
            }
            guard let urlAsset = avAsset as? AVURLAsset else {
                completion(.failure(UploaderError.assetDataUnavailable))
                return
            }

            let filename = asset.value(forKey: "filename") as? String
                ?? "video_\(Int(Date().timeIntervalSince1970)).mov"

            RoamVaultClient.shared.uploadMedia(
                fileURL: urlAsset.url,
                filename: filename,
                mimeType: "video/quicktime"
            ) { result in
                completion(result.map { _ in () })
            }
        }
    }

    // MARK: - PHAsset helpers

    private func fetchAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Fetch images and videos added in the last 30 days for initial scope;
        // subsequent runs use the uploaded-IDs set to skip already-synced assets.
        options.predicate = NSPredicate(
            format: "creationDate > %@",
            Date(timeIntervalSinceNow: -30 * 24 * 3600) as NSDate
        )
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func filename(for asset: PHAsset, uti: String?) -> String {
        if let name = asset.value(forKey: "filename") as? String { return name }
        let ext: String
        switch uti {
        case "public.heic": ext = "heic"
        case "public.jpeg": ext = "jpg"
        case "public.png":  ext = "png"
        default:            ext = "jpg"
        }
        return "photo_\(Int(asset.creationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)).\(ext)"
    }

    private func mimeType(forUTI uti: String?) -> String {
        switch uti {
        case "public.heic":  return "image/heic"
        case "public.jpeg":  return "image/jpeg"
        case "public.png":   return "image/png"
        default:             return "image/jpeg"
        }
    }

    // MARK: - Persistence of uploaded IDs

    private static func uploadedAssetIDs() -> Set<String> {
        let array = sharedDefaults.stringArray(forKey: uploadedIDsKey) ?? []
        return Set(array)
    }

    private static func markUploaded(localIdentifier: String) {
        var ids = uploadedAssetIDs()
        ids.insert(localIdentifier)
        sharedDefaults.set(Array(ids), forKey: uploadedIDsKey)
    }

    // MARK: - Errors

    public enum UploaderError: Error {
        case photoAccessDenied
        case assetDataUnavailable
    }
}
