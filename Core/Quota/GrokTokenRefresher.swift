import Foundation
import os

/// 刷新 Grok Build OIDC access_token，并原子写回 `~/.grok/auth.json`。
///
/// 设计原则与 Claude 类似：只读监控、临期再刷、写回共享凭据文件时礼让 Grok CLI。
nonisolated enum GrokTokenRefresher {
    private static let log = Logger(subsystem: "com.cc-bar", category: "grok-refresh")
    static let defaultTokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!
    /// 与 Claude 一样偏保守：30s skew，减少与 Grok CLI 争抢 refresh_token。
    nonisolated static let refreshSkew: TimeInterval = 30

    struct Refreshed: Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    nonisolated static func ensureFreshAccessToken(
        account: inout GrokAccount
    ) async -> Result<String, QuotaError> {
        guard let current = account.accessToken else {
            return .failure(.missingToken)
        }
        if !isExpired(expiresAt: account.expiresAt) {
            return .success(current)
        }
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            return .failure(.tokenRefreshFailed("no refresh_token"))
        }
        do {
            let r = try await Coordinator.shared.refresh(
                storageKey: account.storageKey,
                clientId: account.oidcClientId,
                issuer: account.oidcIssuer,
                currentRefresh: refreshToken
            )
            account.accessToken = r.accessToken
            account.refreshToken = r.refreshToken
            account.expiresAt = r.expiresAt
            account.expiredGuess = false
            return .success(r.accessToken)
        } catch let err as QuotaError {
            return .failure(err)
        } catch {
            return .failure(.tokenRefreshFailed("\(error)"))
        }
    }

    nonisolated static func isExpired(expiresAt: Date?, skew: TimeInterval = refreshSkew) -> Bool {
        guard let expiresAt else {
            // 无明确过期时间时按 JWT exp 再判断一次；仍没有则视为需要刷新。
            return true
        }
        return expiresAt.timeIntervalSinceNow < skew
    }

    // MARK: - Coordinator

    private actor Coordinator {
        static let shared = Coordinator()
        private var inFlight: Task<Refreshed, Error>?

        func refresh(
            storageKey: String,
            clientId: String,
            issuer: String,
            currentRefresh: String
        ) async throws -> Refreshed {
            if let task = inFlight {
                return try await task.value
            }
            let task = Task {
                try await Coordinator.performRefresh(
                    storageKey: storageKey,
                    clientId: clientId,
                    issuer: issuer,
                    initialRefresh: currentRefresh
                )
            }
            inFlight = task
            defer { inFlight = nil }
            return try await task.value
        }

        private static func performRefresh(
            storageKey: String,
            clientId: String,
            issuer: String,
            initialRefresh: String
        ) async throws -> Refreshed {
            var refreshToken = initialRefresh

            // 发请求前重读文件：Grok CLI 可能已经刷过。
            if let onDisk = GrokTokenRefresher.peekStored(storageKey: storageKey) {
                if let exp = onDisk.expiresAt, !GrokTokenRefresher.isExpired(expiresAt: exp) {
                    return Refreshed(
                        accessToken: onDisk.accessToken,
                        refreshToken: onDisk.refreshToken ?? refreshToken,
                        expiresAt: exp
                    )
                }
                if let onDiskRefresh = onDisk.refreshToken, !onDiskRefresh.isEmpty {
                    refreshToken = onDiskRefresh
                }
            }

            let refreshed = try await GrokTokenRefresher.performNetworkRefresh(
                using: refreshToken,
                clientId: clientId,
                issuer: issuer
            )
            try GrokTokenRefresher.writeBack(
                storageKey: storageKey,
                refreshed: refreshed
            )
            return refreshed
        }
    }

    // MARK: - Network

    nonisolated static func performNetworkRefresh(
        using refreshToken: String,
        clientId: String,
        issuer: String
    ) async throws -> Refreshed {
        let endpoint = tokenEndpoint(for: issuer)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = "grant_type=refresh_token"
            + "&refresh_token=\(percent(refreshToken))"
            + "&client_id=\(percent(clientId))"
        req.httpBody = body.data(using: .utf8)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw QuotaError.tokenRefreshFailed("transport: \(error)")
        }
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.tokenRefreshFailed("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 400 || http.statusCode == 401 {
                if msg.localizedCaseInsensitiveContains("invalid_grant")
                    || msg.localizedCaseInsensitiveContains("invalid_token") {
                    throw QuotaError.tokenRevoked
                }
            }
            throw QuotaError.tokenRefreshFailed("http \(http.statusCode): \(msg)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = root["access_token"] as? String
        else {
            throw QuotaError.tokenRefreshFailed("invalid json / no access_token")
        }
        let newRefresh = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? refreshToken
        let expiresAt: Date = {
            if let seconds = root["expires_in"] as? Double {
                return Date().addingTimeInterval(seconds)
            }
            if let seconds = root["expires_in"] as? Int {
                return Date().addingTimeInterval(TimeInterval(seconds))
            }
            if let exp = JWT.decodePayload(newAccess)?["exp"] as? Double {
                return Date(timeIntervalSince1970: exp)
            }
            return Date().addingTimeInterval(6 * 3600)
        }()
        return Refreshed(accessToken: newAccess, refreshToken: newRefresh, expiresAt: expiresAt)
    }

    nonisolated private static func tokenEndpoint(for issuer: String) -> URL {
        let trimmed = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let url = URL(string: "\(trimmed)/oauth2/token") {
            return url
        }
        return defaultTokenEndpoint
    }

    // MARK: - Disk

    struct StoredSnapshot: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    nonisolated static func peekStored(storageKey: String) -> StoredSnapshot? {
        let url = GrokAuth.authFileURL()
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[storageKey] as? [String: Any],
              let access = entry["key"] as? String,
              !access.isEmpty
        else { return nil }
        let refresh = entry["refresh_token"] as? String
        let expiresAt = parseDate(entry["expires_at"])
            ?? JWT.decodePayload(access).flatMap { ($0["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } }
        return StoredSnapshot(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    nonisolated static func writeBack(storageKey: String, refreshed: Refreshed) throws {
        let url = GrokAuth.authFileURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var entry = root[storageKey] as? [String: Any] ?? [:]
        entry["key"] = refreshed.accessToken
        entry["refresh_token"] = refreshed.refreshToken
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["expires_at"] = iso.string(from: refreshed.expiresAt)
        root[storageKey] = entry

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: url, options: [.atomic])
        log.info("wrote refreshed grok tokens to auth.json")
    }

    nonisolated private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = any as? Double { return Date(timeIntervalSince1970: n) }
        return nil
    }

    nonisolated private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
