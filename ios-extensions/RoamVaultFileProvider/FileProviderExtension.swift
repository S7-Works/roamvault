import FileProvider
import os.log

private let log = OSLog(subsystem: "app.roamvault.fileprovider", category: "FileProviderExtension")

// MARK: - FileProviderExtension

/// The principal class of the RoamVault FileProvider extension.
///
/// Registered in Info.plist under NSExtensionPrincipalClass.
/// Conforms to `NSFileProviderExtension` (pre-iOS 16 API surface compatible
/// with Flutter's minimum deployment target of iOS 12+).
///
/// For iOS 16+ you would instead adopt `NSFileProviderReplicatedExtension`.
class FileProviderExtension: NSFileProviderExtension {

    private let client = RoamVaultClient.shared
    private let fileManager = FileManager.default

    // MARK: - Item lookup

    override func item(
        for identifier: NSFileProviderItemIdentifier,
        completionHandler handler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        // Root container is a sentinel — return immediately.
        if identifier == .rootContainer {
            handler(FileProviderItem.rootContainer, nil)
            return
        }

        // Fetch metadata for this specific item from the API.
        client.listFiles(parentID: nil) { result in
            switch result {
            case .success(let response):
                if let match = response.files.first(where: { $0.id == identifier.rawValue }) {
                    handler(FileProviderItem(remoteFile: match), nil)
                } else {
                    handler(nil, NSFileProviderError(.noSuchItem))
                }
            case .failure(let error):
                os_log("item(for:) failed: %{public}@", log: log, type: .error, error.localizedDescription)
                handler(nil, error)
            }
        }
    }

    // MARK: - Enumerator

    override func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier
    ) throws -> NSFileProviderEnumerator {
        return FileProviderEnumerator(containerIdentifier: containerItemIdentifier, client: client)
    }

    // MARK: - Providing item URLs

    override func urlForItem(
        withPersistentIdentifier identifier: NSFileProviderItemIdentifier
    ) -> URL? {
        // Construct the on-disk placeholder URL using the standard storage mechanism.
        guard let manager = NSFileProviderManager.default else { return nil }
        return manager.documentStorageURL
            .appendingPathComponent(identifier.rawValue, isDirectory: false)
    }

    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        // Reverse: derive the identifier from the file path component.
        let component = url.deletingLastPathComponent().lastPathComponent
        return NSFileProviderItemIdentifier(component)
    }

    // MARK: - Providing file contents

    override func providePlaceholder(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        guard let identifier = persistentIdentifierForItem(at: url) else {
            handler(NSFileProviderError(.noSuchItem))
            return
        }

        item(for: identifier) { item, error in
            guard let item else {
                handler(error ?? NSFileProviderError(.noSuchItem))
                return
            }
            do {
                try NSFileProviderManager.writePlaceholder(
                    at: NSFileProviderExtension.placeholderURL(for: url),
                    withMetadata: item
                )
                handler(nil)
            } catch {
                handler(error)
            }
        }
    }

    override func startProvidingItem(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        guard let identifier = persistentIdentifierForItem(at: url) else {
            handler(NSFileProviderError(.noSuchItem))
            return
        }

        // If already downloaded, signal success immediately.
        if fileManager.fileExists(atPath: url.path) {
            handler(nil)
            return
        }

        // Otherwise download from the RoamVault API.
        client.downloadFile(id: identifier.rawValue, destination: url) { result in
            switch result {
            case .success:
                handler(nil)
            case .failure(let error):
                os_log("startProvidingItem failed: %{public}@", log: log, type: .error, error.localizedDescription)
                handler(error)
            }
        }
    }

    override func stopProvidingItem(at url: URL) {
        // Evict the local copy to reclaim space — the cloud copy remains.
        try? fileManager.removeItem(at: url)
        try? NSFileProviderManager.default?.signalEnumerator(
            for: persistentIdentifierForItem(at: url) ?? .rootContainer,
            completionHandler: { _ in }
        )
    }

    // MARK: - Importing documents

    override func importDocument(
        at fileURL: URL,
        toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
        completionHandler handler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        let filename = fileURL.lastPathComponent
        // Derive MIME type from the file extension.
        let mimeType = mimeType(forExtension: fileURL.pathExtension)

        client.uploadMedia(fileURL: fileURL, filename: filename, mimeType: mimeType) { result in
            switch result {
            case .success(let remoteFile):
                handler(FileProviderItem(remoteFile: remoteFile), nil)
            case .failure(let error):
                os_log("importDocument failed: %{public}@", log: log, type: .error, error.localizedDescription)
                handler(nil, error)
            }
        }
    }

    // MARK: - Helpers

    private func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "heic":        return "image/heic"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "pdf":         return "application/pdf"
        default:            return "application/octet-stream"
        }
    }
}
