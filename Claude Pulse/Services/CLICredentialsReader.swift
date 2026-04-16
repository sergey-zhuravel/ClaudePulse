//
//  CLICredentialsReader.swift
//  Claude Pulse
//
//  Reads Claude Code CLI credentials from the file system and Keychain.
//  Fallback chain: ~/.claude/.credentials.json → Keychain → regex extraction.
//

import Foundation

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

        // 4. Truncated Keychain data — regex fallback
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

    private func readCredentialsFile() -> String? {
        let paths = [
            claudeDirectory.appendingPathComponent(".credentials.json"),
            claudeDirectory.appendingPathComponent("credentials.json")
        ]

        for fileURL in paths {
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

    // MARK: - Keychain credentials (via /usr/bin/security CLI)

    /// Runs a Process with a timeout. Returns false if timed out (process is killed).
    private func runWithTimeout(_ process: Process, timeout: TimeInterval = 10) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            process.terminate()
            NSLog("[ClaudePulse] Process timed out: %@", process.arguments?.joined(separator: " ") ?? "")
            return false
        }
        return true
    }

    private func readKeychainCredentials() throws -> String? {
        let serviceName = resolveServiceName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-a", NSUserName(), "-w"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        guard runWithTimeout(process) else {
            NSLog("[ClaudePulse] Keychain read timed out")
            return nil
        }

        switch process.terminationStatus {
        case 0:
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case 44:
            return nil // item not found
        default:
            throw CLICredentialsError.keychainReadFailed(status: OSStatus(process.terminationStatus))
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

    private func keychainItemExists(serviceName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-a", NSUserName()]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard runWithTimeout(process) else { return false }
        return process.terminationStatus == 0
    }

    private func findHashedServiceName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["dump-keychain"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        guard runWithTimeout(process, timeout: 5) else {
            NSLog("[ClaudePulse] dump-keychain timed out")
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let prefix = "Claude Code-credentials-"

        for line in output.components(separatedBy: "\n") {
            guard line.contains("\"svce\""), line.contains(prefix),
                  let eq = line.range(of: "=\""),
                  let endQ = line.range(of: "\"", range: eq.upperBound..<line.endIndex) else { continue }
            let name = String(line[eq.upperBound..<endQ.lowerBound])
            if name.hasPrefix(prefix) { return name }
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
