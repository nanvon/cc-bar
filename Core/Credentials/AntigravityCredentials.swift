import CryptoKit
import Foundation

/// Antigravity（Google Antigravity / Gemini Code Assist）凭据读取（只读）。
///
/// 优先读取桌面端 / agy 共用的系统钥匙串，兼容旧版凭据文件。
/// cc-bar 不提取 client secret、不自行调用 Google OAuth 接口续期、也不写回任何官方凭据文件。
nonisolated struct AntigravityAccount: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var planType: String?
    var accessToken: String?
    var refreshToken: String?
    /// `oauth_creds.json` 的 `expiry_date`（毫秒）或 jetski 的 `expiry`（ISO8601）。
    var expiryDate: Date?
    var idToken: String?
    /// 原始登录凭据的指纹；用于判断登录态是否变化。
    var credentialSignature: String?
    /// 凭据来源。
    var source: CredentialFileSource = .jetski

    var refreshKey: String {
        let identity = credentialSignature ?? refreshToken ?? accessToken ?? ""
        return source.rawValue + ":" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func belongsToSameLogin(as other: AntigravityAccount) -> Bool {
        guard source == other.source else { return false }
        if let signature = credentialSignature, signature == other.credentialSignature { return true }
        if let a = refreshToken, let b = other.refreshToken { return a == b }
        return accessToken != nil && accessToken == other.accessToken
    }
}

nonisolated enum CredentialFileSource: String, Sendable, Equatable {
    case oauthCreds
    case jetski
    case cliToken
    case keychain
}

nonisolated enum AntigravityCredentials {
    static let refreshSkew: TimeInterval = 300 // 5 分钟

    /// 钥匙串是 GUI / 新版 agy 的当前登录态，优先于可能已过期的遗留文件。
    /// 钥匙串存在但读不出时直接报错，不借用另一份可能属于旧账号的登录。
    /// 未登录时返回 `nil`，由调用方展示“未配置/未登录”引导。
    nonisolated static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychainLoader: () -> CLITokenLoad = { loadCLITokenFromKeychain() }
    ) throws -> AntigravityAccount? {
        switch keychainLoader() {
        case .found(let token): return token.account
        case .unreadable(let error): throw error
        case .missing: break
        }
        if let account = try loadJetskiToken(homeDirectory: homeDirectory) {
            return account
        }
        switch loadCLITokenFile(homeDirectory: homeDirectory) {
        case .found(let token): return token.account
        case .unreadable(let error): throw error
        case .missing: break
        }
        if let account = try loadOAuthCreds(homeDirectory: homeDirectory) {
            return account
        }
        return nil
    }

    /// 专供 `agy` CLI 调度前检查 CLI / 钥匙串登录态（只读，不读旧 jetski / oauth_creds）。
    nonisolated static func loadCLIToken(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychainLoader: () -> CLITokenLoad = { loadCLITokenFromKeychain() }
    ) -> CLITokenLoad {
        let result = keychainLoader()
        switch result {
        case .found, .unreadable:
            return result
        case .missing:
            return loadCLITokenFile(homeDirectory: homeDirectory)
        }
    }

    nonisolated static func oauthCredsURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/oauth_creds.json")
    }

    nonisolated static func jetskiTokenURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    }

    /// 旧版 agy CLI 的登录凭据文件，结构与 jetski 相同。cc-bar 只读不写。
    nonisolated static func cliTokenURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    /// 新版 agy CLI 把登录凭据存进钥匙串（go-keyring），内容为 `go-keyring-base64:` 加 base64 编码的 JSON，结构与文件相同。
    static let cliKeychainService = "gemini"
    static let cliKeychainAccount = "antigravity"

    /// 钥匙串 / CLI 文件里的一份登录凭据。
    nonisolated struct CLIToken: Sendable {
        var accessToken: String?
        var refreshToken: String?
        var expiryDate: Date?
        /// 凭据的指纹，用来判断用户是否重新登录过。
        var signature: String
        var source: CredentialFileSource = .cliToken
        var idToken: String?
        var fallbackEmail: String?

        var isValid: Bool {
            guard let accessToken, !accessToken.isEmpty else { return false }
            return !AntigravityCredentials.isExpired(expiryDate: expiryDate)
        }

        var account: AntigravityAccount {
            let claims = idToken.flatMap { JWT.decodePayload($0) }
            return AntigravityAccount(
                email: nonEmpty(claims?["email"] as? String) ?? fallbackEmail,
                displayName: nonEmpty(claims?["name"] as? String),
                accessToken: accessToken, refreshToken: refreshToken, expiryDate: expiryDate,
                idToken: idToken, credentialSignature: signature, source: source
            )
        }
    }

    nonisolated enum CLITokenLoad: Sendable {
        case found(CLIToken)
        /// 文件和钥匙串里都没有 agy 凭据，agy 未登录。
        case missing
        /// 凭据存在但读不出来（文件损坏、钥匙串授权被拒等），无法判断登录状态。
        case unreadable(QuotaError)
    }

    private static func loadCLITokenFile(homeDirectory: URL) -> CLITokenLoad {
        let url = cliTokenURL(homeDirectory: homeDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .unreadable(.decode("agy token file unreadable")) }
            let signature = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let token = cliToken(root: root, signature: signature, source: .cliToken)
            guard token.accessToken != nil || token.refreshToken != nil else {
                return .unreadable(.decode("Antigravity token file has no OAuth token"))
            }
            return .found(token)
        }
        return .missing
    }

    nonisolated private static func loadCLITokenFromKeychain() -> CLITokenLoad {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", cliKeychainService, "-a", cliKeychainAccount, "-w"]
        let pipe = Pipe()
        let err = Pipe()
        proc.standardOutput = pipe
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return .unreadable(.transport("agy keychain read failed: \(error)"))
        }
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        // 44 = errSecItemNotFound
        if proc.terminationStatus == 44 { return .missing }
        guard proc.terminationStatus == 0, !out.isEmpty else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .unreadable(.transport("agy keychain read failed: exit \(proc.terminationStatus) \(msg)"))
        }
        return parseKeychainToken(out)
    }

    static func parseKeychainToken(_ data: Data) -> CLITokenLoad {
        var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            text = Data(base64Encoded: String(text.dropFirst(prefix.count)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .unreadable(.decode("agy keychain token unreadable"))
        }
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let token = cliToken(root: root, signature: "keychain-\(digest)", source: .keychain)
        guard token.accessToken != nil || token.refreshToken != nil else {
            return .unreadable(.decode("Antigravity keychain has no OAuth token"))
        }
        return .found(token)
    }

    nonisolated private static func cliToken(root: [String: Any], signature: String, source: CredentialFileSource) -> CLIToken {
        let token = root["token"] as? [String: Any] ?? root
        let fallbackEmail = nonEmpty(root["id_token_email"] as? String ?? root["email"] as? String)
        return CLIToken(
            accessToken: nonEmpty(token["access_token"] as? String ?? token["accessToken"] as? String),
            refreshToken: nonEmpty(token["refresh_token"] as? String ?? token["refreshToken"] as? String),
            expiryDate: parseExpiryDate(token["expiry"] ?? token["expiry_date"] ?? token["expires_at"] ?? token["expiresAt"]),
            signature: signature, source: source,
            idToken: nonEmpty(token["id_token"] as? String ?? token["idToken"] as? String),
            fallbackEmail: fallbackEmail
        )
    }

    private static func loadOAuthCreds(homeDirectory: URL) throws -> AntigravityAccount? {
        let url = oauthCredsURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("oauth_creds.json is not a JSON object")
        }
        let accessToken = nonEmpty(root["access_token"] as? String)
        let refreshToken = nonEmpty(root["refresh_token"] as? String)
        let idToken = nonEmpty(root["id_token"] as? String)
        let expiryDate = parseExpiryDate(root["expiry_date"])
        var email: String?
        var displayName: String?
        if let idToken, let payload = JWT.decodePayload(idToken) {
            email = nonEmpty(payload["email"] as? String)
            displayName = nonEmpty(payload["name"] as? String) ?? nonEmpty(payload["given_name"] as? String)
        }
        guard accessToken != nil || refreshToken != nil else { return nil }
        return AntigravityAccount(
            email: email,
            displayName: displayName,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate,
            idToken: idToken,
            source: .oauthCreds
        )
    }

    private static func loadJetskiToken(homeDirectory: URL) throws -> AntigravityAccount? {
        let url = jetskiTokenURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("jetski token is not a JSON object")
        }
        let tokenDict: [String: Any]
        if let t = root["token"] as? [String: Any] {
            tokenDict = t
        } else {
            tokenDict = root
        }
        let accessToken = nonEmpty(tokenDict["access_token"] as? String ?? tokenDict["accessToken"] as? String)
        let refreshToken = nonEmpty(tokenDict["refresh_token"] as? String ?? tokenDict["refreshToken"] as? String)
        let expiryStr = tokenDict["expiry"] as? String ?? tokenDict["expiry_date"] as? String
        let expiryDate = expiryStr.flatMap { parseISO8601($0) } ?? parseExpiryDate(tokenDict["expiry_date"])
        guard accessToken != nil || refreshToken != nil else { return nil }
        return AntigravityAccount(
            email: nil,
            displayName: nil,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate,
            idToken: nil,
            source: .jetski
        )
    }

    // MARK: - Freshness

    nonisolated static func isExpired(expiryDate: Date?) -> Bool {
        guard let expiryDate else { return true }
        return expiryDate.timeIntervalSinceNow < refreshSkew
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func parseExpiryDate(_ any: Any?) -> Date? {
        if let n = any as? Double {
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        if let n = any as? Int {
            return Date(timeIntervalSince1970: Double(n) > 10_000_000_000 ? Double(n) / 1000 : Double(n))
        }
        if let s = any as? String, let n = Double(s) {
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        if let s = any as? String {
            return parseISO8601(s)
        }
        return nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }
}
