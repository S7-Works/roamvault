import FileProvider

// MARK: - FileProviderEnumerator

/// Fetches the file listing from the RoamVault API (GET /api/files) and
/// delivers batches of `NSFileProviderItem` objects to the system.
///
/// Each `NSFileProviderEnumerationObserver` call is on a background queue
/// supplied by the FileProvider framework.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    // MARK: - Properties

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let client: RoamVaultClient

    // MARK: - Init

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        client: RoamVaultClient = .shared
    ) {
        self.containerIdentifier = containerIdentifier
        self.client = client
        super.init()
    }

    // MARK: - NSFileProviderEnumerator

    func invalidate() {
        // No persistent state to clean up.
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // Decode the opaque page token (nil → first page).
        let pageToken: String? = {
            if page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
                || page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage {
                return nil
            }
            return String(data: page.rawValue, encoding: .utf8)
        }()

        // parentID is nil for the root container, else the folder's raw id.
        let parentID: String? = containerIdentifier == .rootContainer
            ? nil
            : containerIdentifier.rawValue

        fetchPage(parentID: parentID, pageToken: pageToken, observer: observer)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // Full re-enumerate on each sync; incremental change tracking would
        // require server-side cursor support (future work).
        observer.finishEnumeratingChanges(upTo: currentAnchor(), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentAnchor())
    }

    // MARK: - Private helpers

    private func fetchPage(
        parentID: String?,
        pageToken: String?,
        observer: NSFileProviderEnumerationObserver
    ) {
        client.listFiles(parentID: parentID, pageToken: pageToken) { result in
            switch result {
            case .success(let response):
                let items = response.files.map { FileProviderItem(remoteFile: $0) }
                observer.didEnumerate(items)

                if let nextToken = response.nextPage,
                   let tokenData = nextToken.data(using: .utf8) {
                    // More pages available — report them via the next page token.
                    observer.finishEnumerating(upTo: NSFileProviderPage(tokenData))
                } else {
                    observer.finishEnumerating(upTo: NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage)
                }

            case .failure(let error):
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// Produces a sync anchor based on the current timestamp (good enough for
    /// invalidation-based change tracking).
    private func currentAnchor() -> NSFileProviderSyncAnchor {
        let ts = Date().timeIntervalSince1970
        var bytes = ts.bitPattern
        let data = Data(bytes: &bytes, count: MemoryLayout<UInt64>.size)
        return NSFileProviderSyncAnchor(data)
    }
}
