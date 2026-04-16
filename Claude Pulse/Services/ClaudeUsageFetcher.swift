//
//  ClaudeUsageFetcher.swift
//  Claude Pulse
//
//  Fetches Claude usage data via two alternating endpoints:
//  1. GET /api/oauth/usage — JSON with session, weekly, and sonnet utilization
//  2. POST /v1/messages — minimal haiku request, parses rate-limit headers
//  Alternating halves the request load on each endpoint.
//

import Foundation

final class ClaudeUsageFetcher {

    static let shared = ClaudeUsageFetcher()
    private init() {}

    enum Endpoint {
        case oauthUsage
        case messagesHeaders
    }

    private lazy var userAgent: String = {
        let version = CLICredentialsReader.shared.readCLIVersion() ?? "2.1.85"
        return "claude-code/\(version)"
    }()

    private func makeRequest(url: URL, accessToken: String, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = timeout
        return request
    }

    // MARK: - Public API

    /// Validates that an access token is accepted by the API.
    func validateToken(accessToken: String) async -> Bool {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return false }

        var request = makeRequest(url: url, accessToken: accessToken, timeout: 10)
        request.httpMethod = "GET"

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200 || http.statusCode == 429
    }

    /// Fetches usage via the specified endpoint.
    func fetchUsage(accessToken: String, endpoint: Endpoint) async throws -> ClaudeUsage {
        switch endpoint {
        case .oauthUsage:
            return try await fetchViaOAuthUsage(accessToken: accessToken)
        case .messagesHeaders:
            return try await fetchViaMessagesHeaders(accessToken: accessToken)
        }
    }

    // MARK: - Endpoint 1: GET /api/oauth/usage

    private func fetchViaOAuthUsage(accessToken: String) async throws -> ClaudeUsage {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw UsageFetchError.invalidURL
        }

        var request = makeRequest(url: url, accessToken: accessToken)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.invalidResponse
        }

        if http.statusCode == 429 {
            throw UsageFetchError.rateLimited(retryAfter: retryDelay(from: http))
        }

        guard http.statusCode == 200 else {
            throw UsageFetchError.httpError(statusCode: http.statusCode)
        }

        return try parseUsageJSON(data)
    }

    // MARK: - Endpoint 2: POST /v1/messages (rate-limit headers)

    private func fetchViaMessagesHeaders(accessToken: String) async throws -> ClaudeUsage {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw UsageFetchError.invalidURL
        }

        var request = makeRequest(url: url, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.invalidResponse
        }

        if http.statusCode == 429 {
            throw UsageFetchError.rateLimited(retryAfter: retryDelay(from: http))
        }

        guard http.statusCode == 200 else {
            throw UsageFetchError.httpError(statusCode: http.statusCode)
        }

        return parseRateLimitHeaders(http)
    }

    // MARK: - Parse JSON (oauth/usage)

    private func parseUsageJSON(_ data: Data) throws -> ClaudeUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.parsingFailed
        }

        var sessionPercentage = 0.0
        var sessionResetTime = Date().addingTimeInterval(5 * 3600)
        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let util = fiveHour["utilization"] { sessionPercentage = parseNumber(util) }
            if let resetsAt = fiveHour["resets_at"] as? String {
                sessionResetTime = parseISO8601(resetsAt) ?? sessionResetTime
            }
        }

        var weeklyPercentage = 0.0
        var weeklyResetTime = Date().nextMonday1259pm()
        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let util = sevenDay["utilization"] { weeklyPercentage = parseNumber(util) }
            if let resetsAt = sevenDay["resets_at"] as? String {
                weeklyResetTime = parseISO8601(resetsAt) ?? weeklyResetTime
            }
        }

        var sonnetPercentage = 0.0
        var sonnetResetTime: Date? = nil
        if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
            if let util = sonnet["utilization"] { sonnetPercentage = parseNumber(util) }
            if let resetsAt = sonnet["resets_at"] as? String {
                sonnetResetTime = parseISO8601(resetsAt)
            }
        }

        return ClaudeUsage(
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: weeklyResetTime,
            sonnetPercentage: sonnetPercentage,
            sonnetResetTime: sonnetResetTime,
            lastUpdated: Date()
        )
    }

    // MARK: - Parse rate-limit headers (v1/messages)

    private func parseRateLimitHeaders(_ response: HTTPURLResponse) -> ClaudeUsage {
        func headerDouble(_ name: String) -> Double? {
            response.value(forHTTPHeaderField: name).flatMap(Double.init)
        }

        let sessionUtil = headerDouble("anthropic-ratelimit-unified-5h-utilization") ?? 0
        // ceil() to match oauth/usage which rounds up
        var sessionPercentage = ceil(sessionUtil * 100.0)
        let sessionResetTs = headerDouble("anthropic-ratelimit-unified-5h-reset") ?? 0
        let sessionResetTime = sessionResetTs > 0
            ? Date(timeIntervalSince1970: sessionResetTs)
            : Date().addingTimeInterval(5 * 3600)
        if sessionResetTime < Date() { sessionPercentage = 0.0 }

        let weeklyUtil = headerDouble("anthropic-ratelimit-unified-7d-utilization") ?? 0
        let weeklyPercentage = ceil(weeklyUtil * 100.0)
        let weeklyResetTs = headerDouble("anthropic-ratelimit-unified-7d-reset") ?? 0
        let weeklyResetTime = weeklyResetTs > 0
            ? Date(timeIntervalSince1970: weeklyResetTs)
            : Date().nextMonday1259pm()

        // Messages API doesn't return sonnet-specific data;
        // sonnet values stay at 0 — the provider merges from previous oauth/usage response.
        return ClaudeUsage(
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: weeklyResetTime,
            sonnetPercentage: 0,
            sonnetResetTime: nil,
            lastUpdated: Date()
        )
    }

    // MARK: - Helpers

    private func retryDelay(from http: HTTPURLResponse) -> Double {
        let headerValue = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Double.init) ?? 0
        return max(headerValue, 30)
    }

    private func parseNumber(_ value: Any) -> Double {
        if let i = value as? Int { return Double(i) }
        if let d = value as? Double { return d }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

// MARK: - Errors

enum UsageFetchError: LocalizedError {
    case noCredentials
    case tokenExpired
    case noAccessToken
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case rateLimited(retryAfter: Double)
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code credentials found. Run `claude login` first."
        case .tokenExpired:
            return "OAuth token has expired. Run `claude login` to refresh."
        case .noAccessToken:
            return "Could not extract access token from credentials."
        case .invalidURL:
            return "Invalid API endpoint URL."
        case .invalidResponse:
            return "Invalid response from API."
        case .httpError(let code):
            return "API returned HTTP \(code)."
        case .rateLimited:
            return "Rate limited. Retrying shortly..."
        case .parsingFailed:
            return "Failed to parse usage response."
        }
    }
}
