import BackgroundTasks
import Network
import os.log

private let log = OSLog(subsystem: "app.roamvault.sync", category: "SyncManager")

// MARK: - SyncManager

/// Manages all background sync activity for RoamVault.
///
/// Register and schedule calls must be made from the **main app target** — iOS
/// does not allow extensions to register BGTask identifiers. The extension can
/// call `scheduleBackgroundSync()` to top-up the schedule after each run.
///
/// Background Task Identifiers must be added to the main app's Info.plist under
/// the key `BGTaskSchedulerPermittedIdentifiers`.
public final class SyncManager {

    // MARK: - Task Identifiers

    /// Full sync — runs on WiFi + charging. Declared in Info.plist BGTaskSchedulerPermittedIdentifiers.
    public static let processingTaskID = "app.roamvault.sync.processing"

    /// Lightweight refresh — checks for new photos. Declared in Info.plist BGTaskSchedulerPermittedIdentifiers.
    public static let appRefreshTaskID = "app.roamvault.sync.refresh"

    // MARK: - Shared instance

    public static let shared = SyncManager()
    private init() {}

    // MARK: - Registration (call from AppDelegate.application(_:didFinishLaunchingWithOptions:))

    /// Register both background task handlers with `BGTaskScheduler`.
    /// Must be called before the app finishes launching.
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncManager.processingTaskID,
            using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncManager.appRefreshTaskID,
            using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task)
        }

        os_log("Background tasks registered", log: log, type: .info)
    }

    // MARK: - Scheduling

    /// Schedule (or reschedule) both background tasks.
    /// Safe to call from the app extension via `scheduleBackgroundSync()`.
    public func scheduleBackgroundSync() {
        scheduleProcessingTask()
        scheduleAppRefreshTask()
    }

    private func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: SyncManager.processingTaskID)
        // Require Wi-Fi to avoid burning mobile data on large uploads
        request.requiresNetworkConnectivity = true
        // Require external power so we don't drain the battery
        request.requiresExternalPower = true
        // Earliest start time: 15 minutes from now (iOS may delay further)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            os_log("Processing task scheduled", log: log, type: .debug)
        } catch {
            os_log("Failed to schedule processing task: %{public}@", log: log, type: .error,
                   error.localizedDescription)
        }
    }

    private func scheduleAppRefreshTask() {
        let request = BGAppRefreshTaskRequest(identifier: SyncManager.appRefreshTaskID)
        // Earliest start: 30 minutes from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            os_log("App refresh task scheduled", log: log, type: .debug)
        } catch {
            os_log("Failed to schedule refresh task: %{public}@", log: log, type: .error,
                   error.localizedDescription)
        }
    }

    // MARK: - Task handlers

    /// Full sync — uploads new photos found in the library. Runs on Wi-Fi + charging.
    public func handleProcessingTask(_ task: BGProcessingTask) {
        os_log("Processing task started", log: log, type: .info)

        // Re-schedule for the next opportunity before we begin
        scheduleProcessingTask()

        let uploader = PhotoUploader()

        // BGTask expiration handler — called by iOS if we run out of time
        task.expirationHandler = {
            os_log("Processing task expired — cancelling uploads", log: log, type: .info)
            uploader.cancelAll()
        }

        uploader.uploadNewPhotos { result in
            switch result {
            case .success(let count):
                os_log("Processing task complete — uploaded %d photo(s)", log: log, type: .info, count)
                task.setTaskCompleted(success: true)
            case .failure(let error):
                os_log("Processing task failed: %{public}@", log: log, type: .error,
                       error.localizedDescription)
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Lightweight refresh — checks whether new photos exist; queues a processing
    /// task if found. Completes quickly to respect the short app-refresh budget.
    public func handleAppRefresh(_ task: BGAppRefreshTask) {
        os_log("App refresh started", log: log, type: .info)

        // Re-schedule for the next opportunity
        scheduleAppRefreshTask()

        task.expirationHandler = {
            os_log("App refresh expired", log: log, type: .info)
            task.setTaskCompleted(success: false)
        }

        PhotoUploader().checkForNewPhotos { hasNew in
            if hasNew {
                os_log("New photos detected — scheduling processing task", log: log, type: .info)
                self.scheduleProcessingTask()
            }
            task.setTaskCompleted(success: true)
        }
    }
}
