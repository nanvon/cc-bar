import CryptoKit
import Foundation
import LocalAuthentication
import os
import Security

/// Antigravity（Google Antigravity / Gemini Code Assist）凭据管理。
///
/// 优先复用桌面端 / agy 共用的系统钥匙串，兼容旧版凭据文件。
/// 仅安装并登录 GUI 即可直查云端额度，不要求安装或运行 agy。
///
/// 详细架构见 `docs/草案-Antigravity支持-设计方案.md` §1。
nonisolated struct AntigravityAccount: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var planType: String?
    var accessToken: String?
    var refreshToken: String?
    /// `oauth_creds.json` 的 `expiry_date`（毫秒）或 jetski 的 `expiry`（ISO8601）。
    var expiryDate: Date?
    var idToken: String?
    /// 原始登录凭据的指纹；续期不会改变它，GUI 切号 / 退出后必须重新识别。
    var credentialSignature: String?
    /// 凭据来源，避免把 GUI 的令牌写进旧 CLI 文件。
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
    /// Gemini CLI（最常见，~/.gemini/oauth_creds.json 即此 client）。客户端 ID 是公开标识。
    static let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    /// Antigravity 原生 client（部分新版 jetski 使用）。客户端 ID 是公开标识。
    static let antigravityClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let refreshSkew: TimeInterval = 300 // 5 分钟

    // MARK: - OAuth client 解析

    /// OAuth 候选列表：`(client_id, client_secret?)`。
    ///
    /// `client_secret` **不在源码硬编码**（开源仓库 + 分发的二进制不应携带官方客户端密钥）：
    /// 刷新时按需从本机已安装的官方组件中提取——Gemini CLI（npm 包 bundle）与
    /// Antigravity 桌面端 / agy 各自内置了自己的 client secret，
    /// 这些 secret 属于官方客户端、对安装者公开，从本机读取等于“读取自己机器上的官方组件”，
    /// 且永远与官方客户端同步，不受 Google 轮换影响。
    private static let extractedSecretsCache = OSAllocatedUnfairLock<(key: String, secrets: [String: String])?>(
        initialState: nil
    )

    static func extractClientSecretsFromLocalTools(
        homeDirectory home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationRoots: [URL]? = nil
    ) -> [String: String] {
        var candidateFiles: [URL] = desktopOAuthArtifacts(homeDirectory: home, applicationRoots: applicationRoots)

        // 1. Gemini CLI：npm 包 bundle（~/.gemini/… 或 /opt/homebrew/… 或 /usr/local/…）
        let candidateDirs: [URL] = [
            home.appendingPathComponent(".gemini/node_modules/@google/gemini-cli/bundle"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@google/gemini-cli/bundle"),
            URL(fileURLWithPath: "/opt/homebrew/Cellar/gemini-cli"),
        ]
        for dir in candidateDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            candidateFiles.append(contentsOf: files.filter { $0.pathExtension == "js" })
        }

        // 2. agy CLI 二进制（若桌面端未安装时作为 secret 提取来源）
        let agyPaths = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            home.appendingPathComponent(".gemini/bin/agy"),
            home.appendingPathComponent(".gemini/antigravity/bin/agy"),
        ]
        candidateFiles.append(contentsOf: agyPaths)

        var seenPaths = Set<String>()
        var existing: [(url: URL, signature: String)] = []
        for candidate in candidateFiles {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seenPaths.insert(resolved.path).inserted,
                  FileManager.default.fileExists(atPath: resolved.path) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            existing.append((resolved, "\(resolved.path)|\(modified)|\(size)"))
        }

        let cacheKey = existing.map(\.signature).joined(separator: "\n")
        if let cached = extractedSecretsCache.withLock({ $0 }), cached.key == cacheKey {
            return cached.secrets
        }

        var result: [String: String] = [:]
        for item in existing {
            guard let data = try? Data(contentsOf: item.url, options: [.mappedIfSafe]) else { continue }
            extractSecrets(fromData: data, into: &result)
        }
        extractedSecretsCache.withLock { $0 = (cacheKey, result) }
        return result
    }

    static func desktopOAuthArtifacts(homeDirectory: URL, applicationRoots: [URL]? = nil) -> [URL] {
        let roots = applicationRoots ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                         homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
        let relativePaths = [
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/app/out/main.js",
            "Contents/MacOS/Gemini",
        ]
        var bundles: [URL] = []
        for root in roots {
            bundles.append(root.appendingPathComponent("Antigravity.app", isDirectory: true))
            for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "app" {
                if let id = Bundle(url: url)?.bundleIdentifier,
                   ["com.google.antigravity", "com.google.antigravity-ide", "com.google.GeminiMacOS"].contains(id) {
                    bundles.append(url)
                }
            }
        }
        var seen = Set<String>()
        return bundles.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .flatMap { bundle in relativePaths.map { bundle.appendingPathComponent($0) } }
    }

    /// 官方 OAuth secret 是固定长度字符串；二进制字符串池不保证 ID 与 secret 相邻。
    /// 直接在字节里定位 `GOCSPX-` 与 `.apps.googleusercontent.com`，不把整个文件（桌面端
    /// language_server 约 200 MB）转成字符串。近邻配对只作为优先候选，所有 secret 都保留，
    /// 刷新时逐一核实，不按字符串池顺序硬配对。
    static func extractSecrets(fromData data: Data, into result: inout [String: String]) {
        let secretPrefix = Array("GOCSPX-".utf8)
        let idSuffix = Array(".apps.googleusercontent.com".utf8)
        let secretBodyLength = 28
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            func offsets(of pattern: [UInt8]) -> [Int] {
                var found: [Int] = []
                var position = 0
                pattern.withUnsafeBytes { needle in
                    while position < count,
                          let hit = memmem(base + position, count - position, needle.baseAddress, needle.count) {
                        let offset = base.distance(to: UnsafeRawPointer(hit))
                        found.append(offset)
                        position = offset + needle.count
                    }
                }
                return found
            }
            // client ID：后缀前面是 `数字{10,}-[a-z0-9]+`。
            var ids: [(offset: Int, id: String)] = []
            for suffixOffset in offsets(of: idSuffix) {
                var start = suffixOffset
                while start > 0 {
                    let byte = bytes[start - 1]
                    guard (0x30...0x39).contains(byte) || (0x61...0x7a).contains(byte) || byte == 0x2d else { break }
                    start -= 1
                }
                let head = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<suffixOffset]), as: UTF8.self)
                // 往前多吃进的字母 / 连字符要去掉：只取最后两段 `数字-字母数字`。
                let parts = head.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count >= 2 else { continue }
                let project = parts[parts.count - 2], suffix = parts[parts.count - 1]
                let digits = project.reversed().prefix { $0.isASCII && $0.isNumber }
                guard digits.count >= 10, !suffix.isEmpty else { continue }
                let id = String(digits.reversed()) + "-" + suffix
                ids.append((suffixOffset - id.utf8.count, id + ".apps.googleusercontent.com"))
            }
            for prefixOffset in offsets(of: secretPrefix) {
                let bodyStart = prefixOffset + secretPrefix.count
                let bodyEnd = bodyStart + secretBodyLength
                guard bodyEnd <= count else { continue }
                let body = UnsafeBufferPointer(rebasing: bytes[bodyStart..<bodyEnd])
                guard body.allSatisfy(isSecretByte) else { continue }
                let secret = "GOCSPX-" + String(decoding: body, as: UTF8.self)
                result["candidate-" + secretFingerprint(secret)] = secret
                if let nearest = ids.min(by: { abs($0.offset - prefixOffset) < abs($1.offset - prefixOffset) }),
                   abs(nearest.offset - prefixOffset) < 512 {
                    result[nearest.id] = secret
                }
            }
        }
    }

    private static func isSecretByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
            || byte == 0x5f || byte == 0x2d
    }

    /// secret 的短指纹：用于候选去重和记住可用的 client 配对，不保存 secret 本身。
    static func secretFingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

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
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("oauth_creds.json is not a JSON object")
        }
        let accessToken = nonEmpty(root["access_token"] as? String)
        let refreshToken = nonEmpty(root["refresh_token"] as? String)
        let idToken = nonEmpty(root["id_token"] as? String)
        let expiryDate = parseExpiryDate(root["expiry_date"])
        // 解析 id_token 获取身份
        var email: String?
        var displayName: String?
        if let idToken, let payload = JWT.decodePayload(idToken) {
            email = nonEmpty(payload["email"] as? String)
            displayName = nonEmpty(payload["name"] as? String) ?? nonEmpty(payload["given_name"] as? String)
        }
        // 若 accessToken 缺失但有 refreshToken，仍返回账号，后续刷新可恢复
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
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("jetski token is not a JSON object")
        }
        // jetski 结构：{ "token": { "access_token": "...", "refresh_token": "...", "expiry": "ISO8601" } }
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
        // jetski 本身不含 id_token（access_token 为不透明字符串，非 JWT），
        // 无法本地解析邮箱；账号展示依赖云端 loadCodeAssist 回填 plan/身份。
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

    /// GUI / agy 原始登录只读，续期结果保存在 CCBar 自己的钥匙串并绑定原始凭据指纹。
    /// 旧 jetski / oauth_creds 保留原有回写行为。所有 I/O 可注入，回归测试不访问用户登录。
    struct RefreshEnvironment: Sendable {
        var load: @Sendable () throws -> AntigravityAccount?
        var secrets: @Sendable () -> [String: String]
        var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        var cached: @Sendable (String) -> RefreshedToken?
        var save: @Sendable (RefreshedToken, AntigravityAccount) throws -> Void
        /// 上次续期成功的 client 配对（`client_id|secret 指纹`，无 secret 时指纹为 `none`），按凭据来源记。
        var loadClientHint: @Sendable (CredentialFileSource) -> String? = { _ in nil }
        var saveClientHint: @Sendable (CredentialFileSource, String?) -> Void = { _, _ in }
        /// 已被 Google 拒绝续期的登录（`refreshKey`）。原始凭据变化后 key 随之变化，自动解除。
        var isSignedOut: @Sendable (String) -> Bool = { _ in false }
        var markSignedOut: @Sendable (String) -> Void = { _ in }

        static let live = RefreshEnvironment(
            load: { try AntigravityCredentials.load() },
            secrets: { extractClientSecretsFromLocalTools() },
            send: { try await NetworkProxy.data(for: $0) },
            cached: { loadRefreshCache(key: $0) },
            save: { token, account in try persistRefreshedToken(token, account: account) },
            loadClientHint: { UserDefaults.standard.string(forKey: clientHintDefaultsKey + $0.rawValue) },
            saveClientHint: { source, hint in
                UserDefaults.standard.set(hint, forKey: clientHintDefaultsKey + source.rawValue)
            },
            isSignedOut: { UserDefaults.standard.string(forKey: signedOutDefaultsKey) == $0 },
            markSignedOut: { UserDefaults.standard.set($0, forKey: signedOutDefaultsKey) }
        )
    }

    private static let clientHintDefaultsKey = "antigravityOAuthClientHintV1."
    private static let signedOutDefaultsKey = "antigravitySignedOutRefreshKeyV1"

    /// 若 `access_token` 临近过期则通过 Google OAuth 静默刷新。
    /// 返回当前可用的 `access_token`。
    nonisolated static func ensureFreshAccessToken(
        account: inout AntigravityAccount,
        forceRefresh: Bool = false,
        environment: RefreshEnvironment = .live
    ) async -> Result<String, QuotaError> {
        if let current = account.accessToken, !current.isEmpty,
           !forceRefresh, !isExpired(expiryDate: account.expiryDate) {
            return .success(current)
        }
        guard account.refreshToken != nil else {
            // 没有 refresh_token 就只能等官方客户端重新登录，不再每轮尝试续期。
            return .failure(.antigravitySignedOut)
        }
        do {
            let refreshed = try await Coordinator.shared.refresh(
                account: account, forceRefresh: forceRefresh, environment: environment
            )
            account.accessToken = refreshed.accessToken
            account.expiryDate = refreshed.expiryDate
            // refresh_token 轮换时更新，Google 通常不轮换则保留原值
            if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                account.refreshToken = newRefresh
            }
            return .success(refreshed.accessToken)
        } catch let err as QuotaError {
            return .failure(err)
        } catch {
            return .failure(.tokenRefreshFailed(String(describing: error)))
        }
    }

    // MARK: - Coordinator (进程内去重)

    private actor Coordinator {
        static let shared = Coordinator()
        private var inFlight: [String: Task<RefreshedToken, Error>] = [:]

        func refresh(account: AntigravityAccount, forceRefresh: Bool, environment: RefreshEnvironment) async throws -> RefreshedToken {
            let key = account.refreshKey
            if let task = inFlight[key] {
                return try await task.value
            }
            let task = Task {
                try await AntigravityCredentials.performRefresh(account: account, forceRefresh: forceRefresh, environment: environment)
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            return try await task.value
        }
    }

    struct RefreshedToken: Sendable, Codable {
        var accessToken: String
        var refreshToken: String?
        var expiryDate: Date?
    }

    // MARK: - Network refresh

    nonisolated private static func performRefresh(
        account: AntigravityAccount, forceRefresh: Bool, environment: RefreshEnvironment
    ) async throws -> RefreshedToken {
        let current = try await Task.detached(priority: .utility) { try environment.load() }.value
        guard let current, account.belongsToSameLogin(as: current) else {
            throw QuotaError.tokenRefreshFailed("Antigravity login changed during refresh")
        }
        if let token = current.accessToken, !isExpired(expiryDate: current.expiryDate),
           !forceRefresh || token != account.accessToken {
            return RefreshedToken(accessToken: token, refreshToken: current.refreshToken, expiryDate: current.expiryDate)
        }
        let cached = await Task.detached(priority: .utility) { environment.cached(account.refreshKey) }.value
        if let cached, !isExpired(expiryDate: cached.expiryDate),
           !forceRefresh || cached.accessToken != account.accessToken { return cached }
        guard let refreshToken = cached?.refreshToken ?? current.refreshToken else { throw QuotaError.antigravitySignedOut }
        // Google 已拒绝过这份登录：不再发请求，等用户在 Antigravity 中重新登录（凭据变化即解除）。
        if environment.isSignedOut(account.refreshKey) { throw QuotaError.antigravitySignedOut }

        let localSecrets = await Task.detached(priority: .utility) { environment.secrets() }.value
        let hint = environment.loadClientHint(account.source)
        let candidates = refreshCandidates(source: account.source, secrets: localSecrets, hint: hint)

        var lastErr: Error?
        var sawInvalidGrant = false
        for (index, cand) in candidates.enumerated() {
            var req = URLRequest(url: tokenEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 30
            var body = "client_id=\(percent(cand.id))"
            if let secret = cand.secret, !secret.isEmpty {
                body += "&client_secret=\(percent(secret))"
            }
            body += "&refresh_token=\(percent(refreshToken))"
                + "&grant_type=refresh_token"
            req.httpBody = body.data(using: .utf8)

            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await environment.send(req)
            } catch {
                throw QuotaError.from(transport: error)
            }
            guard let http = resp as? HTTPURLResponse else {
                lastErr = QuotaError.tokenRefreshFailed("non-http response")
                continue
            }
            if (200..<300).contains(http.statusCode) {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccess = root["access_token"] as? String, !newAccess.isEmpty
                else {
                    lastErr = QuotaError.tokenRefreshFailed("no access_token in refresh response")
                    continue
                }
                let newRefresh = nonEmpty(root["refresh_token"] as? String) ?? refreshToken
                let expiresIn = (root["expires_in"] as? Double) ?? (root["expires_in"] as? Int).map(Double.init) ?? 3600
                guard expiresIn.isFinite, expiresIn > 0 else { throw QuotaError.decode("invalid OAuth expires_in") }
                let expiryDate = Date().addingTimeInterval(expiresIn)
                let refreshed = RefreshedToken(accessToken: newAccess, refreshToken: newRefresh, expiryDate: expiryDate)
                // 请求期间 GUI 可能切号 / 退出。先复核来源，再保存到该登录专属缓存。
                let latest = try await Task.detached(priority: .utility) { try environment.load() }.value
                guard let latest, account.belongsToSameLogin(as: latest) else {
                    throw QuotaError.tokenRefreshFailed("Antigravity login changed during refresh")
                }
                try await Task.detached(priority: .utility) { try environment.save(refreshed, account) }.value
                // 记住可用的配对，下次续期只发这一个请求。
                let fingerprint = cand.secret.map(secretFingerprint) ?? "none"
                environment.saveClientHint(account.source, "\(cand.id)|\(fingerprint)")
                return refreshed
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            // 代理 / 网关拦截页同样会带 4xx 回来，但换 client 候选救不了它，
            // 文案也不该说成"令牌刷新失败"——同 CodexTokenRefresher，只按响应体形状区分。
            let asHTTP = QuotaError.http(http.statusCode, msg)
            if http.statusCode == 429 || http.statusCode >= 500 || asHTTP.looksLikeInterceptedResponse { throw asHTTP }
            let errorCode = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if errorCode == "invalid_grant" {
                // 记住的配对已核实过 client，正确 client 返回 invalid_grant 即 refresh_token 失效，立即停止。
                if index == 0, hint != nil { return try signedOut(account, environment) }
                sawInvalidGrant = true
            } else if index == 0, hint != nil {
                // 记住的配对不再可用（官方客户端更新后 secret 轮换），清掉后继续试其它候选。
                environment.saveClientHint(account.source, nil)
            }
            lastErr = QuotaError.tokenRefreshFailed("http \(http.statusCode): \(msg) [client=\(cand.id.prefix(8))...]")
        }
        // 所有候选都没成功且有 invalid_grant：refresh_token 已失效，记下后不再重复请求。
        if sawInvalidGrant { return try signedOut(account, environment) }
        if let err = lastErr { throw err }
        throw QuotaError.tokenRefreshFailed("all OAuth clients failed")
    }

    private static func signedOut(_ account: AntigravityAccount, _ environment: RefreshEnvironment) throws -> RefreshedToken {
        environment.markSignedOut(account.refreshKey)
        AppLog.warn(.credentials, "antigravity refresh_token rejected (invalid_grant); waiting for a new Antigravity login")
        throw QuotaError.antigravitySignedOut
    }

    /// 续期候选顺序：上次成功的配对 → 按凭据来源确定的 client（GUI / agy / jetski 用 Antigravity client，
    /// oauth_creds 用 Gemini CLI client）带精确配对的 secret → 另一个 client → 未配对 secret → 不带 secret。
    /// 去重后返回；记住配对后正常情况下只发一个请求。
    static func refreshCandidates(
        source: CredentialFileSource, secrets: [String: String], hint: String?
    ) -> [(id: String, secret: String?)] {
        let preferred = source == .oauthCreds ? clientID : antigravityClientID
        let other = preferred == clientID ? antigravityClientID : clientID
        // 官方组件里 client ID 存在别名（npm bundle、agy 二进制各自内置）。
        let aliases = [
            clientID: "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com",
            antigravityClientID: "884354919052-36trc1jjb3tguiac32ov6cod268c5blh.apps.googleusercontent.com",
        ]
        func exact(_ id: String) -> String? { secrets[id] ?? aliases[id].flatMap { secrets[$0] } }
        let uniqueSecrets = Array(Set(secrets.values)).sorted()
        let single = uniqueSecrets.count == 1 ? uniqueSecrets.first : nil

        var list: [(id: String, secret: String?)] = []
        if let hint {
            let parts = hint.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, [clientID, antigravityClientID].contains(parts[0]) {
                if parts[1] == "none" {
                    list.append((parts[0], nil))
                } else if let secret = uniqueSecrets.first(where: { secretFingerprint($0) == parts[1] }) {
                    list.append((parts[0], secret))
                }
            }
        }
        list.append((preferred, exact(preferred) ?? single))
        list.append((other, exact(other) ?? single))
        for secret in uniqueSecrets { list.append((preferred, secret)) }
        for secret in uniqueSecrets { list.append((other, secret)) }
        list.append((preferred, nil))
        list.append((other, nil))
        var seen = Set<String>()
        return list.filter { seen.insert($0.id + "|" + ($0.secret ?? "")).inserted }
    }

    // MARK: - Write back

    static func persistRefreshedToken(
        _ token: RefreshedToken, account: AntigravityAccount,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheWriter: (RefreshedToken, String) throws -> Void = { try saveRefreshCache($0, key: $1) }
    ) throws {
        switch account.source {
        case .keychain, .cliToken: try cacheWriter(token, account.refreshKey)
        case .jetski, .oauthCreds: try writeBack(token, source: account.source, homeDirectory: homeDirectory)
        }
    }

    private static func writeBack(_ token: RefreshedToken, source: CredentialFileSource, homeDirectory home: URL) throws {
        switch source {
        case .oauthCreds:
            let url = oauthCredsURL(homeDirectory: home)
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            }
            root["access_token"] = token.accessToken
            if let refresh = token.refreshToken { root["refresh_token"] = refresh }
            // expiry_date 以毫秒时间戳写入，保持与原文件一致
            if let expiry = token.expiryDate {
                root["expiry_date"] = expiry.timeIntervalSince1970 * 1000
            }
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: [.atomic])
            AppLog.info(.credentials, "antigravity oauth_creds.json refreshed")
        case .jetski:
            let url = jetskiTokenURL(homeDirectory: home)
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            }
            var tokenDict = root["token"] as? [String: Any] ?? [:]
            tokenDict["access_token"] = token.accessToken
            if let refresh = token.refreshToken { tokenDict["refresh_token"] = refresh }
            if let expiry = token.expiryDate {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                tokenDict["expiry"] = iso.string(from: expiry)
            }
            root["token"] = tokenDict
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: [.atomic])
            AppLog.info(.credentials, "antigravity jetski token refreshed")
        case .keychain, .cliToken:
            // GUI / agy 的存储由官方客户端维护，永不把它降级写入 jetski 文件。
            break
        }
    }

    private static let refreshCacheService = "com.nanvon.ccbar.antigravity-refresh"

    private static func loadRefreshCache(key: String) -> RefreshedToken? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: refreshCacheService, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(RefreshedToken.self, from: data)
    }

    private static func saveRefreshCache(_ token: RefreshedToken, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: refreshCacheService,
            // 单条缓存，切号时替换，避免保留多个历史账号的令牌。
            kSecAttrAccount as String: key,
        ]
        let data = try JSONEncoder().encode(token)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            // 删除仅限 CCBar 自己的续期缓存，不接触 gemini / antigravity。
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: refreshCacheService] as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw QuotaError.transport("Antigravity refresh cache write failed: \(added)") }
        } else if status != errSecSuccess {
            throw QuotaError.transport("Antigravity refresh cache write failed: \(status)")
        }
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

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }
}
