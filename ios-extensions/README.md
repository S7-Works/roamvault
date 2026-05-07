# RoamVault iOS Extensions

Native Swift extensions that integrate RoamVault into the iOS system — Files.app browsing
(FileProvider) and background photo upload (BGTaskScheduler). They are authored as standalone
source targets and embedded into the Flutter Xcode project at integration time.

---

## Directory layout

```
ios-extensions/
├── Shared/
│   ├── RoamVaultAPI.swift      – URLSession client, Keychain token storage, API types
│   └── B2Config.swift          – B2 bucket config in shared UserDefaults
├── RoamVaultFileProvider/
│   ├── FileProviderExtension.swift  – NSFileProviderExtension principal class
│   ├── FileProviderItem.swift       – NSFileProviderItem wrapping RemoteFile metadata
│   ├── FileProviderEnumerator.swift – NSFileProviderEnumerator fetching GET /api/files
│   └── Info.plist                   – Extension bundle config
└── RoamVaultSync/
    ├── SyncManager.swift       – BGTaskScheduler registration + task handlers
    └── PhotoUploader.swift     – PHPhotoLibrary fetch + POST /upload/media
```

---

## Embedding into the Flutter Xcode project

Flutter generates a standard Xcode workspace at `ios/Runner.xcworkspace`. App extensions are
added as separate targets inside that project.

### Step-by-step

1. **Open the workspace**

   ```
   open ios/Runner.xcworkspace
   ```

2. **Add the FileProvider target**

   - Xcode → File → New → Target → iOS → File Provider Extension
   - Product name: `RoamVaultFileProvider`
   - Bundle identifier: `app.roamvault.fileprovider`
   - Delete the generated stub files; drag the four source files from
     `ios-extensions/RoamVaultFileProvider/` into the new target.
   - Also drag `ios-extensions/Shared/` files into **both** the extension target and `Runner`.

3. **Add the Sync target**

   - File → New → Target → iOS → App Extension → (choose "None" / generic)
     or add the two Swift files directly to the `Runner` target if you prefer
     to run them in-process.
   - Drag `ios-extensions/RoamVaultSync/` files into the target.
   - Add `BackgroundTasks.framework` and `Photos.framework` to the target's
     *Frameworks and Libraries* section.

4. **Wire up `Info.plist` entries** for the `Runner` target (not the extensions):

   ```xml
   <!-- Background task identifiers -->
   <key>BGTaskSchedulerPermittedIdentifiers</key>
   <array>
       <string>app.roamvault.sync.processing</string>
       <string>app.roamvault.sync.refresh</string>
   </array>

   <!-- Photo library -->
   <key>NSPhotoLibraryUsageDescription</key>
   <string>RoamVault backs up your photos to cloud storage.</string>
   ```

5. **Call registration in AppDelegate** (or via a Flutter method channel):

   ```swift
   // ios/Runner/AppDelegate.swift
   import BackgroundTasks
   // ...
   SyncManager.shared.registerBackgroundTasks()
   SyncManager.shared.scheduleBackgroundSync()
   ```

6. **Build and test** — use the BGTask debugger to simulate launches:

   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.roamvault.sync.refresh"]
   ```

---

## Required entitlements

Add these to both `Runner.entitlements` and each extension's `.entitlements` file.

### FileProvider

```xml
<key>com.apple.developer.fileprovider.storage-usage</key>
<true/>

<!-- App group (shared UserDefaults + container) -->
<key>com.apple.security.application-groups</key>
<array>
    <string>group.app.roamvault</string>
</array>
```

### Background sync / Runner

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.app.roamvault</string>
</array>
```

No special entitlement is required for `BGTaskScheduler` — the permitted identifiers
in `Info.plist` are sufficient.

---

## App group setup

An **app group** lets the main app and extensions share a `UserDefaults` suite and a
sandboxed container directory.

1. In Xcode, select the `Runner` target → Signing & Capabilities → "+ Capability" → App Groups.
2. Register `group.app.roamvault` (must be globally unique; prefix with your Team ID in production).
3. Repeat for each extension target.
4. `B2Config` and `RoamVaultAPI` both reference `UserDefaults(suiteName: "group.app.roamvault")`.

For **Keychain sharing** between the main app and extensions, add the Keychain Sharing
capability to all targets and add a shared keychain group (e.g. `$(AppIdentifierPrefix)app.roamvault`).
Uncomment the `kSecAttrAccessGroup` line in `AuthTokenStore.save(token:)`.

---

## FileProvider entitlement — App Store requirements

Apple requires a **special entitlement** to ship a FileProvider extension on the App Store:

| Entitlement | Value |
|---|---|
| `com.apple.developer.fileprovider.storage-usage` | `true` |

**To request it:**

1. Log in to the Apple Developer portal.
2. Navigate to Certificates, Identifiers & Profiles → Identifiers → select your App ID.
3. Enable the **FileProvider** capability (labelled "iCloud Documents" in older portal versions).
4. Submit a request in App Store Connect → your app → App Review Information if Apple
   requires additional justification (common for new FileProvider adopters).

### Review checklist

- The extension must declare `NSExtensionFileProviderDocumentGroup` in its `Info.plist`
  (already set to `group.app.roamvault`).
- The extension bundle identifier must be a sub-bundle of the main app
  (`app.roamvault` → `app.roamvault.fileprovider`).
- `NSExtensionFileProviderSupportsEnumeration` must be `true` for Files.app browsing.
- Do not attempt to access the user's photo library from within the FileProvider extension
  process — that must be done from the main app or the Sync extension only.

---

## Background modes (UIBackgroundModes)

Add these to the main `Runner/Info.plist` (not the extensions):

```xml
<key>UIBackgroundModes</key>
<array>
    <!-- Required for BGTaskScheduler processing tasks -->
    <string>processing</string>
    <!-- Required for BGAppRefreshTask -->
    <string>fetch</string>
</array>
```

---

## Network security (ATS)

If your API runs on a custom domain, add an App Transport Security exception for it in
`Runner/Info.plist` if needed (all HTTPS traffic is allowed by default).

---

## Minimum deployment target

All source files target **iOS 14.0** (`BGTaskScheduler` requires 13.0+, `NSFileProviderEnumerator`
with `currentSyncAnchor` requires 14.0+). Update the Xcode project's deployment target to match.
