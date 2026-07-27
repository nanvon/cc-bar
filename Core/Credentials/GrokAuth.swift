import Foundation

/// 读取 Grok Build CLI 凭据：`~/.grok/auth.json`（OIDC，issuer `https://auth.x.ai`）。
enum GrokAuth {
    nonisolated static func load() throws -> GrokAccount {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], !root.isEmpty else {
            throw CredentialError.invalidJSON(url.path)
        }

        // 多 entry 时取 expires_at 最新的一条；同到期则按 key 排序取第一。
        var best: (key: String, entry: [String: Any], expires: Date?)?
        for (key, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            guard nonEmpty(entry["key"] as? String) != nil else { continue }
            let expires = parseDate(entry["expires_at"])
            if let current = best {
                let currentExp = current.expires ?? .distantPast
                let nextExp = expires ?? .distantPast
                if nextExp > currentExp || (nextExp == currentExp && key < current.key) {
                    best = (key, entry, expires)
                }
            } else {
                best = (key, entry, expires)
            }
        }
        guard let best else {
            throw CredentialError.decodeFailed("no grok auth entries in \(url.path)")
        }

        let entry = best.entry
        let accessToken = nonEmpty(entry["key"] as? String)
        let refreshToken = nonEmpty(entry["refresh_token"] as? String)
        let email = nonEmpty(entry["email"] as? String)
        let userId = nonEmpty(entry["user_id"] as? String)
            ?? nonEmpty(entry["principal_id"] as? String)
        let teamId = nonEmpty(entry["team_id"] as? String)
        let clientId = nonEmpty(entry["oidc_client_id"] as? String)
            ?? clientIdFromStorageKey(best.key)
            ?? "b1a00492-073a-47ea-816f-4c329264a828"
        let issuer = nonEmpty(entry["oidc_issuer"] as? String) ?? "https://auth.x.ai"
        let expiresAt = best.expires
            ?? accessToken.flatMap { JWT.decodePayload($0)?["exp"] as? Double }
                .map { Date(timeIntervalSince1970: $0) }

        let expiredGuess: Bool = {
            if let expiresAt { return expiresAt < Date() }
            return accessToken == nil
        }()

        return GrokAccount(
            storageKey: best.key,
            email: email,
            userId: userId,
            teamId: teamId,
            planType: nil,
            expiresAt: expiresAt,
            expiredGuess: expiredGuess,
            oidcIssuer: issuer,
            oidcClientId: clientId,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    nonisolated static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    nonisolated private static func clientIdFromStorageKey(_ key: String) -> String? {
        // "https://auth.x.ai::b1a00492-..."
        guard let range = key.range(of: "::", options: .backwards) else { return nil }
        let id = String(key[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
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
        if let n = any as? Int { return Date(timeIntervalSince1970: Double(n)) }
        return nil
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
