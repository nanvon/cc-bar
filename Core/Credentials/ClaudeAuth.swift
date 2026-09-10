import Foundation

enum ClaudeAuth {
    nonisolated static func load() throws -> ClaudeAccount {
        var account = try loadFromFile() ?? loadFromKeychain()
        let profile = loadProfileFromConfig()
        if account.email == nil {
            account.email = profile.email
        }
        account.accountUuid = profile.accountUuid
        account.organizationUuid = profile.organizationUuid
        return account
    }

    /// `~/.claude.json` 顶层 `oauthAccount` 里的账号信息。
    nonisolated struct ConfigProfile: Sendable {
        var email: String?
        var accountUuid: String?
        var organizationUuid: String?
    }

    /// Claude 的 OAuth 凭据本身不含邮箱，CLI 登录时会把账号信息额外写到
    /// `~/.claude.json` 顶层的 `oauthAccount` 字段。这里读 emailAddress 作为邮箱兜底，
    /// 并取出 accountUuid / organizationUuid——`ClaudeDesktopAuth` 用它们判定
    /// Claude Desktop 缓存里的凭据是否属于同一个账号。
    nonisolated private static func loadProfileFromConfig() -> ConfigProfile {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return ConfigProfile() }
        func nonEmpty(_ key: String) -> String? {
            guard let value = oauth[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return ConfigProfile(
            email: nonEmpty("emailAddress"),
            accountUuid: nonEmpty("accountUuid"),
            organizationUuid: nonEmpty("organizationUuid")
        )
    }

    nonisolated private static func loadFromFile() throws -> ClaudeAccount? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try parse(data: data, source: .file)
    }

    nonisolated private static func loadFromKeychain() throws -> ClaudeAccount {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        let err = Pipe()
        proc.standardOutput = pipe
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, !out.isEmpty else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw CredentialError.keychainUnavailable(msg)
        }
        let trimmed = String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let bytes = trimmed.data(using: .utf8) else {
            throw CredentialError.decodeFailed("keychain output not utf8")
        }
        return try parse(data: bytes, source: .keychain)
    }

    nonisolated private static func parse(data: Data, source: CredentialSource) throws -> ClaudeAccount {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("not a JSON object")
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let email = oauth["emailAddress"] as? String ?? oauth["email"] as? String
        let sub = oauth["subscriptionType"] as? String
        let accessToken = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
        let refreshToken = oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
        let expiresAt: Date? = {
            if let n = oauth["expiresAt"] as? Double {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            if let s = oauth["expiresAt"] as? String, let n = Double(s) {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            return nil
        }()
        let expired = expiresAt.map { $0 < Date() } ?? false
        return ClaudeAccount(
            source: source,
            email: email,
            subscriptionType: sub,
            expiresAt: expiresAt,
            expiredGuess: expired,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }
}
