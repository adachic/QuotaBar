import Foundation
import Security
import CryptoKit
import LocalAuthentication

public enum ClaudeCredentials {
    // Query only the Claude Code item. Never enumerate unrelated Keychain credentials.
    public static func read(allowInteraction: Bool = false, configDirectory: String? = nil) throws -> String {
        let custom = configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let directory = (custom?.isEmpty == false ? custom : environmentDirectory)
            .map { ($0 as NSString).expandingTildeInPath }
        var service = "Claude Code-credentials"
        if let directory {
            let hash = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
            service += "-" + hash.prefix(8)
        }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecMatchLimit as String: kSecMatchLimitOne,
                                   kSecReturnData as String: true]
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try token(from: data) }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw UsageError.keychainLocked
        }
        if status != errSecItemNotFound { throw UsageError.keychainLocked }
        // Claude Code's own file-backed credential store, when Keychain is not in use.
        let folder = directory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".credentials.json")) else {
            throw UsageError.notSignedIn(.claude)
        }
        return try token(from: data)
    }

    static func token(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw UsageError.notSignedIn(.claude) }
        if let expiry = oauth["expiresAt"] as? Double, expiry / 1000 <= Date().timeIntervalSince1970 {
            throw UsageError.notSignedIn(.claude)
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") { throw UsageError.missingScope }
        return token
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ClaudeClient {
    public static func fetch(allowInteraction: Bool = false, configDirectory: String? = nil) async throws -> UsageSnapshot {
        let token = try await Task.detached(priority: .utility) {
            try ClaudeCredentials.read(allowInteraction: allowInteraction, configDirectory: configDirectory)
        }.value
        // Internal read-only usage endpoint, also used by Claude Code /usage.
        // Tokens are kept in memory and sent only to this fixed HTTPS origin.
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar/1.0.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
            try validate(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            guard data.count < 1_000_000 else { throw UsageError.invalidResponse }
            return try UsageParser.claude(data)
        } catch let error as URLError {
            throw error.code == .timedOut ? UsageError.timeout : UsageError.offline
        }
    }

    public static func validate(status: Int, retryAfter: String? = nil) throws {
        switch status {
        case 200: return
        case 401: throw UsageError.notSignedIn(.claude)
        case 403: throw UsageError.missingScope
        case 429:
            let seconds = retryAfter.flatMap(Double.init) ?? retryAfter.flatMap { text -> TimeInterval? in
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                return f.date(from: text)?.timeIntervalSinceNow
            } ?? 300
            throw UsageError.throttled(min(86_400, max(60, seconds)))
        default: throw UsageError.http(status)
        }
    }
}
