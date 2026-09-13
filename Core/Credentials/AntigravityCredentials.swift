import Foundation
import os

/// Antigravity（Google Antigravity / Gemini Code Assist）凭据管理。
///
/// 与旧版 `ps` / `lsof` 本地端口探测不同，本版采用 **OpenUsage 模式**：
/// 读取本机 `~/.gemini/jetski-standalone-oauth-token`（优先，Antigravity 生态：
/// agy CLI / IDE 插件登录即写此文件），`~/.gemini/oauth_creds.json` 仅兜底。
/// 直连 Google Cloud Code 配额端点。无需打开 VSCode / Antigravity App 即可刷新额度。
///
/// 产品定位：cc-bar 的 Antigravity 额度 = agy 生态登录的账号（与 Codex / Claude 同构）。
/// 旧版 Gemini CLI 已被 Google 弃用（登录即被拒），oauth_creds.json 不再是 Antigravity
/// 的凭据真源，仅作为 jetski 不存在时的兜底。
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
    /// 凭据来源，便于写回时定位文件。
    var source: CredentialFileSource = .jetski
}

nonisolated enum CredentialFileSource: String, Sendable, Equatable {
    case oauthCreds
    case jetski
}

nonisolated enum AntigravityCredentials {
    private static let log = Logger(subsystem: "com.cc-bar", category: "antigravity-credentials")
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
    /// Antigravity App（`~/.gemini/bin/agy` 二进制）各自内置了自己的 client secret，
    /// 这些 secret 属于官方客户端、对安装者公开，从本机读取等于“读取自己机器上的官方组件”，
    /// 且永远与官方客户端同步，不受 Google 轮换影响。
    private static func extractClientSecretsFromLocalTools() -> [String: String] {
        var result: [String: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser

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

    /// 从文本中扫描 `GOCSPX-` 开头的 OAuth client secret 及其邻近的 client ID，写入 result。
    /// 注意：bundle 中 client ID 与 secret 通常相邻出现（同一变量赋值对），
    /// 二进制中则可能相距很远且多个 secret 粘连。策略：
    /// 1. 正则匹配 `GOCSPX-` 打头的 token，若同一 match 内出现多次 `GOCSPX` 则拆分；
    /// 2. 近距（512 字符内）优先就近配对；
    /// 3. 剩余按出现顺序平摊（适用于二进制分离布局）。
    private static func extractSecrets(from text: String, into result: inout [String: String]) {
        let idPattern = #"[0-9]{10,}-[a-z0-9]+\.apps\.googleusercontent\.com"#
        let secretPattern = #"GOCSPX-[A-Za-z0-9_-]{20,}"#
        guard let idRegex = try? NSRegularExpression(pattern: idPattern),
              let secretRegex = try? NSRegularExpression(pattern: secretPattern) else { return }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        var idRanges: [(loc: Int, val: String)] = []
        idRegex.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, m.range.location != NSNotFound else { return }
            idRanges.append((m.range.location, ns.substring(with: m.range)))
        }

        // 拆分裂：一个 match 可能含多个粘连的 secret（如 "K58F..9YQW..https"）
        var secrets: [(loc: Int, val: String)] = []
        secretRegex.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, m.range.location != NSNotFound else { return }
            let matched = ns.substring(with: m.range)
            let parts = matched.components(separatedBy: "GOCSPX-")
            var offset = m.range.location
            // 每个分片（除第一个空串）本身以 "GOCSPX-" 开头；offset 必须按真实字节位置累进，
            // 否则后续分片的配对定位漂移，导致多个 secret 都就近错配到同一个 client id。
            var consumed = 0
            for part in parts.dropFirst() {
                offset = m.range.location + consumed + 7 // 跳过本次 "GOCSPX-" 前缀
                let token = "GOCSPX-" + part
                secrets.append((offset, token))
                consumed += 7 + part.count
            }
        }
        let pairingWindow = 512
        var usedIDs = Set<Int>()
        var usedSecrets = Set<Int>()
        for (sLoc, secret) in secrets {
            // 截掉粘连的尾缀（如 "...ZtsXhttps"）
            let clean = secret.split(separator: "http", maxSplits: 1).first.map(String.init) ?? secret
            var best: Int?
            var bestDist = Int.max
            for (idx, (loc, _)) in idRanges.enumerated() where !usedIDs.contains(idx) {
                let dist = abs(loc - sLoc)
                if dist < pairingWindow && dist < bestDist {
                    bestDist = dist
                    best = idx
                }
            }
            if let best {
                result[idRanges[best].val] = clean
                usedIDs.insert(best)
                usedSecrets.insert(sLoc)
            }
        }
        // 窗口内未配对的 secret：保留在全集里（返回给调用方做多候选遍历）。
        // 不再「平摊」到远处 client id——二进制里 secret 与 id 可能相距甚远（>512 字符），
        // 按顺序硬配对会把 s1/s2 错配给错误的 client，导致刷新 401/unauthorized。
        // 调用方已对所有内置 clientID 依次尝试（含无 secret 兜底），
        // 这里只需保证每个 secret 都保留。
        for (sLoc, secret) in secrets where !usedSecrets.contains(sLoc) {
            let clean = secret.split(separator: "http", maxSplits: 1).first.map(String.init) ?? secret
            result["unmatched-\(sLoc)"] = clean
        }
    }

    /// 优先读取 `~/.gemini/jetski-standalone-oauth-token`（Antigravity 生态真源），
    /// `~/.gemini/oauth_creds.json` 仅作兜底（旧 Gemini CLI 遗留，已弃用）。
    /// 未登录时返回 `nil`，由调用方展示“未配置/未登录”引导。
    nonisolated static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> AntigravityAccount? {
        if let account = try loadJetskiToken(homeDirectory: homeDirectory) {
            return account
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

    /// 若 `access_token` 临近过期则通过 Google OAuth 静默刷新并回写本地文件。
    /// 返回当前可用的 `access_token`。
    nonisolated static func ensureFreshAccessToken(
        account: inout AntigravityAccount
    ) async -> Result<String, QuotaError> {
        guard let current = account.accessToken, !current.isEmpty else {
            return .failure(.missingToken)
        }
        if !isExpired(expiryDate: account.expiryDate) {
            return .success(current)
        }
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            return .failure(.tokenRefreshFailed("no refresh_token for antigravity"))
        }
        do {
            let refreshed = try await Coordinator.shared.refresh(
                refreshToken: refreshToken,
                source: account.source
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

        func refresh(refreshToken: String, source: CredentialFileSource) async throws -> RefreshedToken {
            let key = source.rawValue
            if let task = inFlight[key] {
                return try await task.value
            }
            let task = Task {
                try await AntigravityCredentials.performRefresh(refreshToken: refreshToken, source: source)
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            return try await task.value
        }
    }

    private struct RefreshedToken: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiryDate: Date?
    }

    // MARK: - Network refresh

    nonisolated private static func performRefresh(
        refreshToken: String,
        source: CredentialFileSource
    ) async throws -> RefreshedToken {
        // 重读存储：Google CLI 可能已刷新过
        do {
            if let onDisk = try load(homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
               let token = onDisk.accessToken, !token.isEmpty,
               let expiry = onDisk.expiryDate, !isExpired(expiryDate: expiry) {
                return RefreshedToken(accessToken: token, refreshToken: onDisk.refreshToken, expiryDate: expiry)
            }
        } catch {}

        // 候选 client：Antigravity 原生 client 优先（jetski 真源，agy 生态），Gemini CLI 次之。
        // client_secret 从本机官方组件按需提取，不硬编码进源码。
        let localSecrets = extractClientSecretsFromLocalTools()
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

        var lastErr: Error?
        for cand in candidates {
            // 清理提取值：粘连的尾缀（如 "...ZtsXhttps"）在此剔除
            let secret = cand.secret.flatMap { $0.split(separator: "http", maxSplits: 1).first.map(String.init) }
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
                (data, resp) = try await URLSession.shared.data(for: req)
            } catch {
                lastErr = QuotaError.from(transport: error)
                continue
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
                let newRefresh = root["refresh_token"] as? String
                let expiresIn = (root["expires_in"] as? Double) ?? (root["expires_in"] as? Int).map(Double.init) ?? 3600
                let expiryDate = Date().addingTimeInterval(expiresIn)
                let refreshed = RefreshedToken(accessToken: newAccess, refreshToken: newRefresh, expiryDate: expiryDate)
                try writeBack(refreshed, source: source)
                return refreshed
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            // 401/400 且提示 client_secret 缺失时尝试下一候选，其余 4xx 直接重试下一候选
            // 代理 / 网关拦截页同样会带 4xx 回来，但换 client 候选救不了它，
            // 文案也不该说成"令牌刷新失败"——同 CodexTokenRefresher，只按响应体形状区分。
            let asHTTP = QuotaError.http(http.statusCode, msg)
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

    private static func writeBack(_ token: RefreshedToken, source: CredentialFileSource) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
            log.info("antigravity oauth_creds.json refreshed")
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
            log.info("antigravity jetski token refreshed")
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
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
