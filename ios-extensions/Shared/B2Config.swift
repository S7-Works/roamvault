import Foundation

// MARK: - B2 Bucket Configuration
//
// All values are stored in the shared app-group UserDefaults so both the main
// Flutter app and the iOS extensions can read them without IPC.
//
// Keys are namespaced under "b2_" to avoid collisions with Flutter plugin keys.

public struct B2Config {

    // MARK: - Keys

    private enum Key {
        static let bucketID       = "b2_bucket_id"
        static let bucketName     = "b2_bucket_name"
        static let applicationKey = "b2_application_key"
        static let keyID          = "b2_key_id"
        static let endpoint       = "b2_endpoint"
        static let region         = "b2_region"
        static let publicCDN      = "b2_public_cdn"
    }

    // MARK: - Storage

    private static var defaults: UserDefaults {
        // Falls back to standard if the app group is not configured (e.g. unit tests).
        UserDefaults(suiteName: RoamVaultAPI.appGroupID) ?? .standard
    }

    // MARK: - Bucket Identity

    /// Backblaze B2 bucket ID (e.g. "4a48fe8875c6214145260818").
    public static var bucketID: String? {
        get { defaults.string(forKey: Key.bucketID) }
        set { defaults.set(newValue, forKey: Key.bucketID) }
    }

    /// Human-readable bucket name (e.g. "roamvault-media").
    public static var bucketName: String? {
        get { defaults.string(forKey: Key.bucketName) }
        set { defaults.set(newValue, forKey: Key.bucketName) }
    }

    // MARK: - Credentials
    //
    // NOTE: These are application-key credentials scoped to this bucket only.
    // Sensitive values should ideally live in Keychain; UserDefaults is used
    // here for convenience since the app group Keychain requires a provisioning
    // profile with the correct access group. Replace with Keychain calls before
    // shipping to production.

    /// Backblaze B2 applicationKeyId.
    public static var keyID: String? {
        get { defaults.string(forKey: Key.keyID) }
        set { defaults.set(newValue, forKey: Key.keyID) }
    }

    /// Backblaze B2 applicationKey (secret).
    public static var applicationKey: String? {
        get { defaults.string(forKey: Key.applicationKey) }
        set { defaults.set(newValue, forKey: Key.applicationKey) }
    }

    // MARK: - Endpoints

    /// S3-compatible endpoint for the bucket region (e.g. "https://s3.us-west-004.backblazeb2.com").
    public static var endpoint: URL? {
        get {
            guard let raw = defaults.string(forKey: Key.endpoint) else { return nil }
            return URL(string: raw)
        }
        set { defaults.set(newValue?.absoluteString, forKey: Key.endpoint) }
    }

    /// AWS-style region string mapped from the B2 endpoint (e.g. "us-west-004").
    public static var region: String? {
        get { defaults.string(forKey: Key.region) }
        set { defaults.set(newValue, forKey: Key.region) }
    }

    /// Optional Cloudflare (or other CDN) base URL that fronts the bucket.
    /// When set, presigned download URLs are rewritten to use this origin.
    public static var publicCDNBase: URL? {
        get {
            guard let raw = defaults.string(forKey: Key.publicCDN) else { return nil }
            return URL(string: raw)
        }
        set { defaults.set(newValue?.absoluteString, forKey: Key.publicCDN) }
    }

    // MARK: - Validation

    /// Returns true if the minimum required config is present.
    public static var isConfigured: Bool {
        bucketID != nil && keyID != nil && applicationKey != nil && endpoint != nil
    }

    // MARK: - Bulk Write (called by Flutter on first launch / sign-in)

    public struct Snapshot {
        public let bucketID: String
        public let bucketName: String
        public let keyID: String
        public let applicationKey: String
        public let endpoint: URL
        public let region: String
        public let publicCDNBase: URL?

        public init(
            bucketID: String,
            bucketName: String,
            keyID: String,
            applicationKey: String,
            endpoint: URL,
            region: String,
            publicCDNBase: URL? = nil
        ) {
            self.bucketID = bucketID
            self.bucketName = bucketName
            self.keyID = keyID
            self.applicationKey = applicationKey
            self.endpoint = endpoint
            self.region = region
            self.publicCDNBase = publicCDNBase
        }
    }

    public static func apply(_ snapshot: Snapshot) {
        bucketID       = snapshot.bucketID
        bucketName     = snapshot.bucketName
        keyID          = snapshot.keyID
        applicationKey = snapshot.applicationKey
        endpoint       = snapshot.endpoint
        region         = snapshot.region
        publicCDNBase  = snapshot.publicCDNBase
        defaults.synchronize()
    }

    // MARK: - URL Helpers

    /// Constructs the public download URL for a given object key.
    /// Uses the CDN base when available, otherwise falls back to the S3 endpoint.
    public static func downloadURL(forKey objectKey: String) -> URL? {
        guard isConfigured else { return nil }
        let base = publicCDNBase ?? endpoint!
        let bucketPath = publicCDNBase != nil ? objectKey : "\(bucketName ?? "")/\(objectKey)"
        return base.appendingPathComponent(bucketPath)
    }
}
