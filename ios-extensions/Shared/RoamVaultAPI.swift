import Foundation
import Security

// MARK: - API Configuration

public enum RoamVaultAPI {
    // Base URL — override via shared UserDefaults (app group) at runtime if needed
    public static var baseURL: URL {
        if let stored = sharedDefaults?.string(forKey: "roamvault_api_base_url"),
           let url = URL(string: stored) {
            return url
        }
        return URL(string: "https://api.roamvault.app")!
    }

    public static let appGroupID = "group.app.roamvault"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}

// MARK: - Keychain Auth Token Storage

public enum AuthTokenStore {
    private static let service = "app.roamvault"
    private static let account = "auth_token"

    /// Persist the bearer token to Keychain (accessible after first unlock, shared via app group).
    public static func save(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw AuthError.encodingFailed
        }

        // Delete any existing item first
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            // Share across app + extensions via app group keychain access group:
            // kSecAttrAccessGroup: "$(AppIdentifierPrefix)app.roamvault",
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainError(status)
        }
    }

    /// Retrieve the bearer token from Keychain, or nil if absent.
    public static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    /// Delete the stored token (on sign-out).
    public static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum AuthError: Error {
        case encodingFailed
        case keychainError(OSStatus)
    }
}

// MARK: - URLSession helpers

public extension URLRequest {
    /// Returns a copy of this request with the stored bearer token attached.
    func authenticated() -> URLRequest {
        var req = self
        if let token = AuthTokenStore.load() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
}

// MARK: - API Response types

public struct FileListResponse: Decodable {
    public let files: [RemoteFile]
    public let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case files
        case nextPage = "next_page"
    }
}

public struct RemoteFile: Decodable {
    public let id: String
    public let filename: String
    public let size: Int64
    public let contentType: String
    public let modifiedAt: Date
    public let parentID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case size
        case contentType = "content_type"
        case modifiedAt = "modified_at"
        case parentID = "parent_id"
    }
}

// MARK: - API Client

public final class RoamVaultClient {
    public static let shared = RoamVaultClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: List files

    /// Fetch file listing from GET /api/files, optional pageToken for pagination.
    public func listFiles(
        parentID: String? = nil,
        pageToken: String? = nil,
        completion: @escaping (Result<FileListResponse, Error>) -> Void
    ) {
        var components = URLComponents(url: RoamVaultAPI.baseURL.appendingPathComponent("/api/files"),
                                       resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let pid = parentID { queryItems.append(URLQueryItem(name: "parent_id", value: pid)) }
        if let pt = pageToken  { queryItems.append(URLQueryItem(name: "page_token", value: pt)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        guard let url = components.url else {
            completion(.failure(APIError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request = request.authenticated()

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(APIError.noData)); return }
            do {
                let result = try self.decoder.decode(FileListResponse.self, from: data)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: Download file

    public func downloadFile(
        id: String,
        destination: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let url = RoamVaultAPI.baseURL.appendingPathComponent("/api/files/\(id)/download")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request = request.authenticated()

        session.downloadTask(with: request) { tempURL, _, error in
            if let error { completion(.failure(error)); return }
            guard let tempURL else { completion(.failure(APIError.noData)); return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: Upload file

    public func uploadMedia(
        fileURL: URL,
        filename: String,
        mimeType: String,
        completion: @escaping (Result<RemoteFile, Error>) -> Void
    ) {
        let url = RoamVaultAPI.baseURL.appendingPathComponent("/upload/media")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request = request.authenticated()

        let boundary = "RoamVaultBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(.failure(APIError.fileReadFailed))
            return
        }

        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)

        session.uploadTask(with: request, from: body) { [weak self] data, _, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(APIError.noData)); return }
            do {
                let file = try self.decoder.decode(RemoteFile.self, from: data)
                completion(.success(file))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    public enum APIError: Error {
        case invalidURL
        case noData
        case fileReadFailed
    }
}

// MARK: - Convenience

private extension String {
    var utf8Data: Data { Data(utf8) }
}
