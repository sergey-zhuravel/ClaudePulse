//
//  OAuthTokenRefresher.swift
//  Claude Pulse
//
//  Refreshes the Claude Code OAuth access token using the stored refresh
//  token, so usage data keeps updating even when the user isn't running
//  Claude Code (which otherwise is the only thing that refreshes the token).
//
//  Contract mirrors Claude Code's own refresh flow (verified against CLI
//  2.1.207): POST platform.claude.com/v1/oauth/token with a JSON body; the
//  response may rotate the refresh token, so callers must write the returned
//  credentials back to the store Claude Code reads.
//

import Foundation

final class OAuthTokenRefresher {

    static let shared = OAuthTokenRefresher()
    private init() {}

    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let defaultScopes = [
        "user:profile", "user:inference", "user:sessions:claude_code",
        "user:mcp_servers", "user:file_upload"
    ]

    /// Refreshes the access token embedded in the full credentials JSON and
    /// returns the updated JSON with only the token fields replaced — every
    /// other key (mcpOAuth, scopes, subscriptionType, …) survives untouched
    /// so the result is safe to write back for Claude Code.
    func refresh(credentialsJSON: String) async throws -> String {
        guard let data = credentialsJSON.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String,
              !refreshToken.isEmpty else {
            throw TokenRefreshError.missingRefreshToken
        }

        if let rtExpiry = oauth["refreshTokenExpiresAt"] as? TimeInterval {
            let epochSeconds = rtExpiry > 1e12 ? rtExpiry / 1000.0 : rtExpiry
            guard Date().timeIntervalSince1970 < epochSeconds else {
                throw TokenRefreshError.refreshTokenExpired
            }
        }

        let scopes = (oauth["scopes"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultScopes

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": scopes.joined(separator: " ")
        ])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TokenRefreshError.malformedResponse
        }
        guard http.statusCode == 200 else {
            // 400/401 mean the refresh token itself was rejected (revoked or
            // already rotated by a concurrent Claude Code refresh) — permanent
            // for this token, unlike transient 5xx/network failures.
            if http.statusCode == 400 || http.statusCode == 401 {
                throw TokenRefreshError.invalidGrant
            }
            throw TokenRefreshError.httpError(statusCode: http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval else {
            throw TokenRefreshError.malformedResponse
        }

        // expiresAt is stored as epoch milliseconds, matching Claude Code
        let nowMs = Date().timeIntervalSince1970 * 1000
        oauth["accessToken"] = accessToken
        oauth["expiresAt"] = Int(nowMs + expiresIn * 1000)
        if let newRefreshToken = json["refresh_token"] as? String, !newRefreshToken.isEmpty {
            oauth["refreshToken"] = newRefreshToken
        }
        if let rtExpiresIn = json["refresh_token_expires_in"] as? TimeInterval {
            oauth["refreshTokenExpiresAt"] = Int(nowMs + rtExpiresIn * 1000)
        }
        root["claudeAiOauth"] = oauth

        let updated = try JSONSerialization.data(withJSONObject: root)
        guard let updatedJSON = String(data: updated, encoding: .utf8) else {
            throw TokenRefreshError.malformedResponse
        }
        return updatedJSON
    }
}

// MARK: - Errors

enum TokenRefreshError: LocalizedError {
    case missingRefreshToken
    case refreshTokenExpired
    case invalidGrant
    case httpError(statusCode: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Credentials contain no refresh token."
        case .refreshTokenExpired:
            return "Refresh token has expired."
        case .invalidGrant:
            return "Refresh token was rejected by the server."
        case .httpError(let code):
            return "Token refresh failed with HTTP \(code)."
        case .malformedResponse:
            return "Token refresh returned an unexpected response."
        }
    }
}
