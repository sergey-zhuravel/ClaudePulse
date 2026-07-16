//
//  CLICredentialsReader.swift
//  Claude Pulse
//
//  Reads Claude Code CLI credentials from the file system and Keychain.
//  Fallback chain: ~/.claude/.credentials.json → Keychain → regex extraction.
//

import Foundation
import Security

final class CLICredentialsReader {

    static let shared = CLICredentialsReader()
    private var resolvedServiceName: String?
    private init() {}

    // MARK: - Public API

    /// Reads and validates CLI credentials JSON. Returns nil if not logged in.
    func readCredentials() throws -> String? {
        // Skip everything if Claude Code is not installed
        guard FileManager.default.fileExists(atPath: claudeDirectory.path) else {
            return nil
        }

        // 1. Try file first (most reliable, no subprocess needed)
        if let fileJSON = readCredentialsFile() {
            return fileJSON
        }

        // 2. Try Keychain (only if .claude dir exists but credentials file is missing)
        let rawJSON = try readKeychainCredentials()
        guard let raw = rawJSON else { return nil }

        // 3. Validate JSON
        if let data = raw.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return raw
        }

        // 4. Malformed Keychain data — regex fallback
        if let token = extractAccessTokenViaRegex(from: raw) {
            return "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
        }

        throw CLICredentialsError.invalidJSON
    }

    /// Extracts OAuth access token from credentials JSON
    func extractAccessToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    /// Extracts subscription type
    func extractSubscriptionType(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return oauth["subscriptionType"] as? String
    }

    /// Token expiry date (handles both ms and seconds epoch)
    func extractTokenExpiry(from json: String) -> Date? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            return nil
        }
        let epochSeconds = expiresAt > 1e12 ? expiresAt / 1000.0 : expiresAt
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Returns true if token is expired
    func isTokenExpired(_ json: String) -> Bool {
        guard let expiry = extractTokenExpiry(from: json) else { return false }
        return Date() > expiry
    }

    /// Reads Claude Code version from ~/.claude.json (lastOnboardingVersion)
    func readCLIVersion() -> String? {
        guard let dict = readClaudeJSON() else { return nil }
        return dict["lastOnboardingVersion"] as? String
    }

    /// Reads email from ~/.claude.json (oauthAccount.emailAddress)
    func readEmail() -> String? {
        guard let dict = readClaudeJSON(),
              let account = dict["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              !email.isEmpty else { return nil }
        return email
    }

    /// Reads and parses ~/.claude.json
    private func readClaudeJSON() -> [String: Any]? {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fileURL = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    // MARK: - File-based credentials

    private var claudeDirectory: URL {
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: configDir)
        }
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude")
    }

    private var credentialsFilePaths: [URL] {
        [
            claudeDirectory.appendingPathComponent(".credentials.json"),
            claudeDirectory.appendingPathComponent("credentials.json")
        ]
    }

    private func readCredentialsFile() -> String? {
        for fileURL in credentialsFilePaths {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty,
                  let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return jsonString
        }
        return nil
    }

    // MARK: - Writing credentials back

    /// Writes refreshed credentials to the same store the read chain uses:
    /// the credentials file when one exists, otherwise the Keychain item.
    /// Keeping Claude Code's store current is what prevents a rotated refresh
    /// token from silently logging the CLI out.
    func writeCredentials(_ json: String) -> Bool {
        for fileURL in credentialsFilePaths where FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try json.write(to: fileURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return true
            } catch {
                NSLog("[ClaudePulse] Credentials file write failed: %@", error.localizedDescription)
                return false
            }
        }
        return writeKeychainCredentials(json)
    }

    private func writeKeychainCredentials(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resolveServiceName(),
            kSecAttrAccount as String: NSUserName()
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status != errSecSuccess {
            NSLog("[ClaudePulse] Keychain credentials update failed (status: %d)", status)
        }
        return status == errSecSuccess
    }

    // MARK: - Keychain credentials (SecItemCopyMatching)

    /// `kSecUseDataProtectionKeychain` is deliberately absent from every query
    /// in this file: Claude Code stores its item in the legacy login (file-based)
    /// keychain, and the data-protection keychain cannot see it (TN3137).
    /// Reading the secret prompts the user for ACL approval on the app's behalf;
    /// "Always Allow" then sticks to Claude Pulse's code signature.
    private func readKeychainCredentials() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resolveServiceName(),
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed:
            // User denied the ACL prompt (or no UI session) — treat as unreadable, not fatal
            NSLog("[ClaudePulse] Keychain access denied (status: %d)", status)
            return nil
        default:
            throw CLICredentialsError.keychainReadFailed(status: status)
        }
    }

    private func extractAccessTokenViaRegex(from raw: String) -> String? {
        let pattern = "\"accessToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        return String(raw[range])
    }

    // MARK: - Keychain service name discovery

    private static let legacyServiceName = "Claude Code-credentials"

    private func resolveServiceName() -> String {
        if let cached = resolvedServiceName { return cached }

        if keychainItemExists(serviceName: Self.legacyServiceName) {
            resolvedServiceName = Self.legacyServiceName
            return Self.legacyServiceName
        }

        if let hashed = findHashedServiceName() {
            resolvedServiceName = hashed
            return hashed
        }

        resolvedServiceName = Self.legacyServiceName
        return Self.legacyServiceName
    }

    /// Attribute-only queries don't touch the secret, so they never trigger
    /// the keychain ACL prompt.
    private func keychainItemExists(serviceName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func findHashedServiceName() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return nil
        }

        let prefix = "Claude Code-credentials-"
        for item in items {
            if let service = item[kSecAttrService as String] as? String, service.hasPrefix(prefix) {
                return service
            }
        }
        return nil
    }
}

// MARK: - Errors

enum CLICredentialsError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    case keychainReadFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Claude Code credentials found. Please run `claude login` first."
        case .invalidJSON:
            return "Claude Code credentials are corrupted or invalid."
        case .keychainReadFailed(let status):
            return "Failed to read credentials from Keychain (status: \(status))."
        }
    }
}
