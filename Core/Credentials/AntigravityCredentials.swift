import CryptoKit
import Foundation
import Security
import LocalAuthentication

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
    static func extractClientSecretsFromLocalTools(
        homeDirectory home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationRoots: [URL]? = nil
    ) -> [String: String] {
        var result: [String: String] = [:]

        // GUI 自带 OAuth 配置；不依赖另装 Gemini CLI / agy。只读，不启动桌面端。
        for path in desktopOAuthArtifacts(homeDirectory: home, applicationRoots: applicationRoots) {
            guard let data = try? Data(contentsOf: path, options: [.mappedIfSafe]) else { continue }
            extractSecrets(fromData: data, into: &result)
        }

        // 1. Gemini CLI：npm 包 bundle（~/.gemini/… 或 /opt/homebrew/… 或 /usr/local/…）
        let candidateDirs: [URL] = [
            home.appendingPathComponent(".gemini/node_modules/@google/gemini-cli/bundle"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@google/gemini-cli/bundle"),
            URL(fileURLWithPath: "/opt/homebrew/Cellar/gemini-cli"),
        ]
        for dir in candidateDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "js" {
                guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { continue }
                extractSecrets(from: text, into: &result)
            }
        }

        // 2. Antigravity App：~/.gemini/bin/agy 二进制
        let agyPaths = [
            home.appendingPathComponent(".gemini/bin/agy"),
            home.appendingPathComponent(".gemini/antigravity/bin/agy"),
        ]
        for path in agyPaths where FileManager.default.fileExists(atPath: path.path) {
            guard let data = try? Data(contentsOf: path) else { continue }
            extractSecrets(fromData: data, into: &result)
        }

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

    /// 从二进制数据中按块解码 ASCII 段并扫描 secret。
    private static func extractSecrets(fromData data: Data, into result: inout [String: String]) {
        if let text = String(data: data, encoding: .utf8) {
            extractSecrets(from: text, into: &result)
            return
        }
        // 二进制：整个文件按 Latin-1 转字符串（保留所有字节），
        // 以便跨块就近配对 client ID 与 secret。
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        extractSecrets(from: text, into: &result)
    }

    /// 官方 OAuth secret 是固定长度字符串；二进制字符串池不保证 ID 与 secret 相邻。
    /// 近邻配对只作为优先候选，所有 secret 都保留，刷新时逐一核实，不按字符串池顺序硬配对。
    private static func extractSecrets(from text: String, into result: inout [String: String]) {
        let idPattern = #"[0-9]{10,}-[a-z0-9]+\.apps\.googleusercontent\.com"#
        let secretPattern = #"GOCSPX-[A-Za-z0-9_-]{28}"#
        guard let ids = try? NSRegularExpression(pattern: idPattern),
              let secrets = try? NSRegularExpression(pattern: secretPattern) else { return }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let idMatches = ids.matches(in: text, range: range)
        for match in secrets.matches(in: text, range: range) {
            let secret = ns.substring(with: match.range)
            let key = SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            result["candidate-" + key] = secret
            if let nearest = idMatches.min(by: {
                abs($0.range.location - match.range.location) < abs($1.range.location - match.range.location)
            }), abs(nearest.range.location - match.range.location) < 512 {
                result[ns.substring(with: nearest.range)] = secret
            }
        }
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

    /// agy 的一份登录凭据。
    nonisolated struct CLIToken: Sendable {
        var accessToken: String?
        var refreshToken: String?
        var expiryDate: Date?
        /// 凭据的指纹，用来判断用户是否重新登录过（agy 自己续期后也会变）。
        var signature: String
        var source: CredentialFileSource = .cliToken
        var idToken: String?

        var account: AntigravityAccount {
            let claims = idToken.flatMap { JWT.decodePayload($0) }
            return AntigravityAccount(
                email: claims?["email"] as? String, displayName: claims?["name"] as? String,
                accessToken: accessToken, refreshToken: refreshToken, expiryDate: expiryDate,
                idToken: idToken, credentialSignature: signature, source: source
            )
        }

        /// access_token 是否还在有效期内（留 5 分钟余量）。
        var isValid: Bool { accessToken != nil && !AntigravityCredentials.isExpired(expiryDate: expiryDate) }
    }

    nonisolated enum CLITokenLoad: Sendable {
        case found(CLIToken)
        /// 文件和钥匙串里都没有 agy 凭据，agy 未登录。
        case missing
        /// 凭据存在但读不出来（文件损坏、钥匙串授权被拒等），无法判断登录状态。
        case unreadable(QuotaError)
    }

    /// 读取 GUI / agy 共用的登录凭据：钥匙串优先，缺失时读旧 CLI 文件。
    /// 钥匙串与 Claude 凭据一样经 `/usr/bin/security` 读取。agy 也是经 `security` 写入的，条目只信任 `security`，
    /// 所以读取不弹授权框，cc-bar 升级也不受影响；agy 改变写入方式时才可能询问。会阻塞，调用方放到后台执行。
    nonisolated static func loadCLIToken(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychainLoader: () -> CLITokenLoad = { loadCLITokenFromKeychain() }
    ) -> CLITokenLoad {
        switch keychainLoader() {
        case .missing: return loadCLITokenFile(homeDirectory: homeDirectory)
        case let result: return result
        }
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
        return CLIToken(
            accessToken: nonEmpty(token["access_token"] as? String ?? token["accessToken"] as? String),
            refreshToken: nonEmpty(token["refresh_token"] as? String ?? token["refreshToken"] as? String),
            expiryDate: parseExpiryDate(token["expiry"] ?? token["expiry_date"] ?? token["expires_at"] ?? token["expiresAt"]),
            signature: signature, source: source,
            idToken: nonEmpty(token["id_token"] as? String ?? token["idToken"] as? String)
        )
    }

    nonisolated enum CLISignInProbe: Sendable {
        /// refresh_token 可用，agy 能自己续期。
        case valid
        /// Google 明确拒绝了 refresh_token（`invalid_grant`）或没有 refresh_token，agy 需要重新登录。
        case signedOut
        /// 网络、服务端或 client secret 原因无法判断。
        case unknown(QuotaError)
    }

    /// 从 agy 二进制里提取 OAuth client secret（`[client_id 或 unmatched-位置: secret]`）。
    /// 二进制很大，调用方按文件签名缓存结果。
    nonisolated static func clientSecrets(inBinary url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [:] }
        var result: [String: String] = [:]
        extractSecrets(fromData: data, into: &result)
        return result
    }

    /// 用 agy 的 refresh_token 向 Google 试着续期一次，只用来判断 agy 的登录是否还有效。
    /// 拿到的新 token 直接丢弃，不写回任何文件；agy 随后会自己续期并写回。
    /// 只试 Antigravity client（agy 登录页里的 client_id），secret 来自 agy 二进制。
    nonisolated static func probeCLISignIn(
        token: CLIToken,
        secrets: [String: String]
    ) async -> CLISignInProbe {
        guard let refreshToken = token.refreshToken else { return .signedOut }

        // 精确配对的 secret 优先，其余 secret 逐个试，最后试不带 secret。
        var candidates: [String?] = []
        for secret in [secrets[antigravityClientID]].compactMap({ $0 }) + Array(secrets.values)
        where !candidates.contains(secret) {
            candidates.append(secret)
        }
        candidates.append(nil)

        var lastErr = QuotaError.tokenRefreshFailed("agy refresh probe: no usable OAuth client")
        for secret in candidates {
            var req = URLRequest(url: tokenEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 30
            var body = "client_id=\(percent(antigravityClientID))"
            if let secret, !secret.isEmpty {
                body += "&client_secret=\(percent(secret))"
            }
            body += "&refresh_token=\(percent(refreshToken))&grant_type=refresh_token"
            req.httpBody = body.data(using: .utf8)

            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await NetworkProxy.data(for: req)
            } catch {
                return .unknown(QuotaError.from(transport: error))
            }
            guard let http = resp as? HTTPURLResponse else {
                return .unknown(.tokenRefreshFailed("agy refresh probe: non-http response"))
            }
            if (200..<300).contains(http.statusCode) { return .valid }
            let msg = String(data: data, encoding: .utf8) ?? ""
            let asHTTP = QuotaError.http(http.statusCode, msg)
            if asHTTP.looksLikeInterceptedResponse || http.statusCode >= 500 || http.statusCode == 429 {
                return .unknown(asHTTP)
            }
            // client 校验在 grant 校验之前：secret 不对时是 invalid_client，换下一个；
            // 只有 client 通过后 Google 才会就 refresh_token 本身回 invalid_grant。
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if root?["error"] as? String == "invalid_grant" { return .signedOut }
            lastErr = .tokenRefreshFailed("agy refresh probe: http \(http.statusCode): \(msg)")
        }
        return .unknown(lastErr)
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

        static let live = RefreshEnvironment(
            load: { try AntigravityCredentials.load() },
            secrets: { extractClientSecretsFromLocalTools() },
            send: { try await NetworkProxy.data(for: $0) },
            cached: { loadRefreshCache(key: $0) },
            save: { token, account in try persistRefreshedToken(token, account: account) }
        )
    }

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
            return .failure(.tokenRefreshFailed("no refresh_token for antigravity"))
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
        guard let refreshToken = cached?.refreshToken ?? current.refreshToken else { throw QuotaError.missingToken }

        // 候选 client：Antigravity 原生 client 优先（jetski 真源，agy 生态），Gemini CLI 次之。
        // client_secret 从本机官方组件按需提取，不硬编码进源码。
        let localSecrets = await Task.detached(priority: .utility) { environment.secrets() }.value
        // 官方组件内的 client ID 与 secret 存在多种来源与顺序（npm bundle、agy 二进制），
        // 无法保证精确配对。策略：为每个内置 clientID 在提取结果中做多重候选回退：
        // 1. 精确 key；2. 已知别名 key；3. 仅有一个 secret 时直接采用。
        let secretPool = localSecrets
        let geminiSecret = secretPool[clientID]
            ?? secretPool["764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com"]
        let antigravitySecret = secretPool[antigravityClientID]
            ?? secretPool["884354919052-36trc1jjb3tguiac32ov6cod268c5blh.apps.googleusercontent.com"]
        // 窗口内未配对成功的 secret 也并入候选池（二进制中 secret 与 id 距离常超过 512 字符，
        // 无法就近配对；把这些 secret 都作为「无精确配对」候选逐一尝试）。
        let unmatched = secretPool.values.filter { $0 != geminiSecret && $0 != antigravitySecret }
        let extras: [(id: String, secret: String?)] = unmatched.flatMap { s in
            [(antigravityClientID, s), (clientID, s)]
        }
        let single = secretPool.count == 1 ? secretPool.values.first : nil
        var candidates: [(id: String, secret: String?)] = [
            (antigravityClientID, antigravitySecret ?? single),
            (clientID, geminiSecret ?? single),
            (antigravityClientID, nil), // 无 secret 兜底：部分 Google client 允许缺省
            (clientID, nil),
        ]
        candidates.append(contentsOf: extras)
        if account.source == .oauthCreds { candidates.swapAt(0, 1) }

        var lastErr: Error?
        for cand in candidates {
            // 清理提取值：粘连的尾缀（如 "...ZtsXhttps"）在此剔除
            let secret = cand.secret
            var req = URLRequest(url: tokenEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 30
            var body = "client_id=\(percent(cand.id))"
            if let secret, !secret.isEmpty {
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
                return refreshed
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            // 401/400 且提示 client_secret 缺失时尝试下一候选，其余 4xx 直接重试下一候选
            // 代理 / 网关拦截页同样会带 4xx 回来，但换 client 候选救不了它，
            // 文案也不该说成"令牌刷新失败"——同 CodexTokenRefresher，只按响应体形状区分。
            let asHTTP = QuotaError.http(http.statusCode, msg)
            if http.statusCode == 429 || http.statusCode >= 500 || asHTTP.looksLikeInterceptedResponse { throw asHTTP }
            lastErr = asHTTP.looksLikeInterceptedResponse
                ? asHTTP
                : QuotaError.tokenRefreshFailed("http \(http.statusCode): \(msg) [client=\(cand.id.prefix(8))...]")
            // 若是明确的 client mismatch，继续下一候选；否则也继续（Gemini/Antigravity 需遍历）
            continue
        }
        if let err = lastErr { throw err }
        throw QuotaError.tokenRefreshFailed("all OAuth clients failed")
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
