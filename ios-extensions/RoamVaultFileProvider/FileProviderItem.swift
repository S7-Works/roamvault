import FileProvider
import UniformTypeIdentifiers

// MARK: - FileProviderItem

/// Maps a RoamVault `RemoteFile` to the `NSFileProviderItem` protocol so iOS
/// Files.app and third-party apps can browse the user's cloud library.
final class FileProviderItem: NSObject, NSFileProviderItem {

    // MARK: - Stored properties

    private let remoteFile: RemoteFile

    init(remoteFile: RemoteFile) {
        self.remoteFile = remoteFile
        super.init()
    }

    // MARK: - NSFileProviderItem – Required

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(remoteFile.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let pid = remoteFile.parentID else {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(pid)
    }

    var filename: String {
        remoteFile.filename
    }

    var contentType: UTType {
        // Attempt to derive UTType from the MIME type stored on the remote file.
        UTType(mimeType: remoteFile.contentType) ?? .data
    }

    // MARK: - NSFileProviderItem – Metadata

    var documentSize: NSNumber? {
        NSNumber(value: remoteFile.size)
    }

    var contentModificationDate: Date? {
        remoteFile.modifiedAt
    }

    var creationDate: Date? {
        // B2 doesn't surface a separate creation timestamp; reuse modifiedAt.
        remoteFile.modifiedAt
    }

    var typeIdentifier: String {
        // Legacy UTI string required by older FileProvider API surface.
        contentType.identifier
    }

    // MARK: - NSFileProviderItem – Capabilities

    var capabilities: NSFileProviderItemCapabilities {
        // Users can read and write files; directories are read-only for now.
        var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsDeleting]
        if contentType != .folder {
            caps.insert(.allowsWriting)
            caps.insert(.allowsRenaming)
        }
        return caps
    }

    // MARK: - NSFileProviderItem – Versioning

    var itemVersion: NSFileProviderItemVersion {
        // Use modifiedAt timestamp bytes as the content version token.
        let ts = remoteFile.modifiedAt.timeIntervalSince1970
        var bytes = ts.bitPattern        // UInt64
        let data = Data(bytes: &bytes, count: MemoryLayout<UInt64>.size)
        return NSFileProviderItemVersion(contentVersion: data, metadataVersion: data)
    }

    // MARK: - NSFileProviderItem – Availability

    var isDownloaded: Bool { false }   // Items start as placeholders; fetched on demand
    var isUploaded: Bool   { true  }   // All items originate from the server
    var isUploading: Bool  { false }
    var isDownloading: Bool { false }
}

// MARK: - Root container placeholder

extension FileProviderItem {
    /// Sentinel item representing the root container of the file hierarchy.
    static var rootContainer: FileProviderItem {
        let root = RemoteFile(
            id: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "RoamVault",
            size: 0,
            contentType: "public.folder",
            modifiedAt: Date(),
            parentID: nil
        )
        return FileProviderItem(remoteFile: root)
    }
}
