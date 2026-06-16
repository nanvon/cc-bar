import Foundation

enum ClaudeAuth {
    nonisolated static func load() throws -> ClaudeAccount {
        var account = try loadFromFile() ?? loadFromKeychain()
        if account.email == nil, let email = loadEmailFromConfig() {
            account.email = email
        }
        return account
    }

    /// Claude 的 OAuth 凭据本身不含邮箱，CLI 登录时会把账号信息额外写到
    /// `~/.claude.json` 顶层的 `oauthAccount` 字段。订阅组织名有时才是当前
    /// Claude Code 额度归属账号,因此优先从 organizationName 中提取邮箱。
    nonisolated private static func loadEmailFromConfig() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        if let organizationName = oauth["organizationName"] as? String,
           let email = extractEmail(from: organizationName) {
            return email
        }
        return nonEmpty(oauth["emailAddress"] as? String)
            ?? nonEmpty(oauth["email"] as? String)
    }

    nonisolated private static func extractEmail(from text: String) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let emailRange = Range(match.range, in: text)
        else { return nil }
        return String(text[emailRange])
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
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
