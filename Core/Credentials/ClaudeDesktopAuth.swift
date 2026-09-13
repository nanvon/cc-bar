import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// Claude Desktop 的 Electron 凭据缓存读取器。
///
/// **Claude Code CLI 与 Claude Desktop 是两个平等的一等凭据源**,不是主备关系。
/// 很多用户(尤其订阅用户)日常只开 Claude Desktop,几乎不碰终端里的 `claude`;
/// 对他们来说 Desktop 才是那个"我明明登录着、用得好好的"的客户端。cc-bar 之前
/// 只认 CLI 凭据,于是这类用户每天都被提示「凭据已过期,请登录」——账号没问题,
/// 只是我们在看错的地方。本文件让两边都算数:
///
/// - 有 CLI 凭据、但它过期了(CLI 的 access_token 只有 8 小时,Desktop 聊天不会
///   刷新它) → `borrowToken(for:)` 用 Desktop 的 token 继续出数;
/// - 压根没有 CLI 凭据(从没跑过 `claude`) → `discoverAccount()` 直接从 Desktop
///   认出账号,不再报"未配置 Claude"。
///
/// 两个源读到的是同一份账号额度(同一个额度池),已逐字段实测核对:`utilization`、
/// `limits`、`extra_usage`、`spend` 全部相同,`resets_at` 只差微秒——服务端每次
/// 请求重新计算所致,落在 `QuotaCycleStore` 既有的抖动容差内。
///
/// **只读取 access_token,永不读取、永不使用其 refresh_token。**
///
/// 这是本文件存在的前提。Anthropic 的 refresh_token 一次性轮换并带重用检测,
/// 任何一方刷新都会作废其他副本(cc-bar 曾因此把用户从 Claude Code 挤下线,
/// 见 `ClaudeTokenRefresher` 的说明与提交 60f17ee)。access_token 则没有这个
/// 问题:它是只读凭证,拿去调 usage 端点不产生任何轮换。openusage 的
/// `ClaudeDesktopAuthStore` 出于同样理由做了同样的取舍。
///
/// Desktop 缓存里的 token 有效期以月计(实测签发自 Claude Code 官方 client 的
/// 那份接近一年),所以这条路径本身很少需要"等谁来刷新"。真到期了也不代刷,
/// 退回提示用户去客户端登录。
///
/// 存储格式(Electron safeStorage):
/// - `~/Library/Application Support/Claude/config.json` 的 `oauth:tokenCacheV2`
///   / `oauth:tokenCache` 是 base64,解码后以 `v10` 开头;
/// - 其后为 AES-128-CBC 密文,IV 为 16 个空格;
/// - 密钥 = PBKDF2-SHA1(钥匙串 `Claude Safe Storage` / `Claude Key` 的密码,
///   salt `saltysalt`, 1003 轮, 16 字节)。
///
/// 明文是一个字典,键形如
/// `acct:<accountUuid>|<clientID>:<orgUuid>:<audience>:<scopes>:`,
/// 值含 `token` / `refreshToken` / `expiresAt` 等字段——本文件只取 `token`。
nonisolated enum ClaudeDesktopAuth {
    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccount = "Claude Key"
    private static let cacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
    /// Claude Code 官方 OAuth client。同账号下优先选它签发的 token。
    private static let claudeCodeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// 读取 usage 端点所需的 scope,缓存键里带不上它的条目直接跳过。
    private static let usageScope = "user:profile"
    /// 判定"还够用"的临期 skew,与 `ClaudeTokenRefresher.adoptSkew` 同义。
    private static let expirySkew: TimeInterval = 5
    /// 用户拒绝过钥匙串授权后不再自动重试的标记。
    private static let denialDefaultsKey = "claudeDesktopSafeStorageAccessDeniedV1"

    /// 借到的凭据。刻意不含 refreshToken——调用方拿不到,也就无从误用。
    struct BorrowedToken: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var clientID: String?
    }

    // MARK: - 对外入口

    /// 读取与 `account` 同属一个账号的、未过期且可读 usage 的 Desktop token。
    ///
    /// 只有 `accountUuid` 与 `organizationUuid` 都对得上才会返回,避免用户在 CLI 与
    /// Desktop 登录不同账号时把别人的额度显示成自己的。两个 UUID 任一缺失(旧版
    /// Claude Code 没写 `~/.claude.json`)时保守放弃,不做"大概是同一个人"的猜测。
    static func borrowToken(for account: ClaudeAccount) -> BorrowedToken? {
        guard let accountUuid = account.accountUuid?.lowercased(),
              let organizationUuid = account.organizationUuid?.lowercased()
        else {
            AppLog.info(.credentials, "skip Claude Desktop: local account identity unknown")
            return nil
        }
        guard !hasUserDeniedAccess else {
            AppLog.info(.credentials, "skip Claude Desktop: user previously denied keychain access")
            return nil
        }
        guard let key = deriveEncryptionKey() else { return nil }
        guard let entries = loadCacheEntries(key: key) else { return nil }

        let matching = entries.filter {
            $0.accountUuid == accountUuid && $0.organizationUuid == organizationUuid
        }
        guard let best = bestUsable(among: matching) else {
            AppLog.info(.credentials, "no usable Claude Desktop token for this account (\(entries.count) entries scanned)")
            return nil
        }
        AppLog.info(.credentials, "using Claude Desktop access token (official client: \(best.clientID == claudeCodeClientID))")
        return BorrowedToken(
            accessToken: best.accessToken,
            expiresAt: best.expiresAt,
            clientID: best.clientID
        )
    }

    /// 在没有任何 Claude Code CLI 凭据时,直接从 Claude Desktop 认出当前账号。
    ///
    /// 面向只用 Claude Desktop、从没跑过 `claude` 的用户:他们没有
    /// `~/.claude/.credentials.json`、没有 Keychain 条目、也没有 `~/.claude.json`,
    /// 因此拿不到邮箱——身份由 `accountUuid` 承担(`QuotaHistoryAccountKey`
    /// 对应有 uuid 派生的 key 分支)。
    ///
    /// 账号选择:优先 `config.json` 的 `lastKnownAccountUuid`,即 Desktop 当前登录的
    /// 那个;它缺失时才退而用可用条目里最优的一条。
    static func discoverAccount() -> ClaudeAccount? {
        guard !hasUserDeniedAccess else { return nil }
        guard let key = deriveEncryptionKey(),
              let entries = loadCacheEntries(key: key)
        else { return nil }

        let preferredUuid = lastKnownAccountUuid()
        let scoped = preferredUuid.map { uuid in
            entries.filter { $0.accountUuid == uuid }
        } ?? entries
        guard let best = bestUsable(among: scoped) ?? bestUsable(among: entries) else {
            AppLog.info(.credentials, "Claude Desktop has no usable token to identify an account")
            return nil
        }

        AppLog.info(.credentials, "discovered Claude account from Claude Desktop (no CLI credentials present)")
        return ClaudeAccount(
            source: .desktop,
            email: nil,
            accountUuid: best.accountUuid,
            organizationUuid: best.organizationUuid,
            subscriptionType: best.subscriptionType,
            expiresAt: best.expiresAt,
            expiredGuess: false,
            accessToken: best.accessToken,
            refreshToken: nil
        )
    }

    private static func lastKnownAccountUuid() -> String? {
        guard let root = loadConfigJSON(),
              let uuid = root["lastKnownAccountUuid"] as? String,
              !uuid.isEmpty
        else { return nil }
        return uuid.lowercased()
    }

    /// 可读 usage、未过期的条目里挑最优:Claude Code 官方 client 优先,
    /// 同档内取有效期最长的那份。
    private static func bestUsable(among entries: [CacheEntry]) -> CacheEntry? {
        let now = Date()
        return entries
            .filter { $0.hasUsageScope
                && $0.expiresAt.map { $0.timeIntervalSince(now) > expirySkew } == true }
            .max { lhs, rhs in
                let lhsOfficial = lhs.clientID == claudeCodeClientID
                let rhsOfficial = rhs.clientID == claudeCodeClientID
                if lhsOfficial != rhsOfficial { return rhsOfficial }
                return (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
            }
    }

    /// Claude Desktop 是否留下了凭据缓存。用于在完全没装 Desktop 时跳过后续开销,
    /// 只读明文 JSON,不碰钥匙串,不会弹授权框。
    static var hasCredentialMaterial: Bool {
        guard let root = loadConfigJSON() else { return false }
        return cacheKeys.contains { root[$0] is String }
    }

    static var hasUserDeniedAccess: Bool {
        UserDefaults.standard.bool(forKey: denialDefaultsKey)
    }

    /// 供设置项重置用:清掉"用户拒绝过"的标记,下次过期时会重新尝试。
    static func clearDenial() {
        UserDefaults.standard.removeObject(forKey: denialDefaultsKey)
    }

    // MARK: - 钥匙串

    /// 读 `Claude Safe Storage` 的密码并派生 AES 密钥。
    ///
    /// 先做一次不允许交互的探测:命中就直接用,不打扰用户。只有确实需要授权时才
    /// 弹一次系统框;用户拒绝后记下标记,不再反复弹。
    private static func deriveEncryptionKey() -> Data? {
        guard let password = readSafeStoragePassword() else { return nil }
        return pbkdf2SHA1(
            password: password,
            salt: Data("saltysalt".utf8),
            rounds: 1003,
            keyLength: kCCKeySizeAES128
        )
    }

    private static func readSafeStoragePassword() -> String? {
        if let password = copySafeStoragePassword(allowInteraction: false) {
            return password
        }
        // 无交互读不到,再弹一次授权框。
        switch copySafeStoragePasswordStatus(allowInteraction: true) {
        case .success(let password):
            return password
        case .denied:
            UserDefaults.standard.set(true, forKey: denialDefaultsKey)
            AppLog.info(.credentials, "user denied Claude Safe Storage access; will not ask again automatically")
            return nil
        case .missing:
            return nil
        }
    }

    private enum PasswordReadResult {
        case success(String)
        case denied
        case missing
    }

    private static func copySafeStoragePassword(allowInteraction: Bool) -> String? {
        guard case .success(let password) =
            copySafeStoragePasswordStatus(allowInteraction: allowInteraction)
        else { return nil }
        return password
    }

    private static func copySafeStoragePasswordStatus(
        allowInteraction: Bool
    ) -> PasswordReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: safeStorageService,
            kSecAttrAccount as String: safeStorageAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else { return .missing }
            return .success(password)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return allowInteraction ? .denied : .missing
        default:
            return .missing
        }
    }

    // MARK: - 解密与解析

    private struct CacheEntry {
        var accountUuid: String
        var organizationUuid: String
        var clientID: String?
        var hasUsageScope: Bool
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
    }

    private static func loadConfigJSON() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(configRelativePath)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    private static func loadCacheEntries(key: Data) -> [CacheEntry]? {
        guard let root = loadConfigJSON() else { return nil }
        var entries: [CacheEntry] = []
        var seen = Set<String>()
        for cacheKey in cacheKeys {
            guard let encoded = root[cacheKey] as? String,
                  let plaintext = decryptSafeStorage(base64: encoded, key: key),
                  let cache = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8))
                    as? [String: Any]
            else { continue }
            for (rawKey, rawValue) in cache {
                guard let dict = rawValue as? [String: Any],
                      let entry = parseEntry(rawKey: rawKey, dict: dict),
                      !seen.contains(entry.accessToken)
                else { continue }
                seen.insert(entry.accessToken)
                entries.append(entry)
            }
        }
        return entries.isEmpty ? nil : entries
    }

    /// 解析缓存键 `acct:<accountUuid>|<clientID>:<orgUuid>:<audience>:<scopes>:`。
    ///
    /// audience 与 scopes 都含冒号(`https://api.anthropic.com`、`user:profile`),
    /// 精确切分既脆弱又没必要——只需前三段身份信息,scope 用子串判定即可。
    private static func parseEntry(rawKey: String, dict: [String: Any]) -> CacheEntry? {
        // 只取 token。refreshToken 存在于字典里,但刻意不读。
        guard let accessToken = dict["token"] as? String, !accessToken.isEmpty else { return nil }

        guard rawKey.hasPrefix("acct:") else { return nil }
        let body = rawKey.dropFirst("acct:".count)
        let identityParts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard identityParts.count == 2 else { return nil }
        let accountUuid = String(identityParts[0]).lowercased()
        guard !accountUuid.isEmpty else { return nil }

        let rest = identityParts[1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard rest.count >= 2 else { return nil }
        let clientID = String(rest[0])
        let organizationUuid = String(rest[1]).lowercased()
        guard !organizationUuid.isEmpty else { return nil }

        let expiresAt: Date? = {
            guard let raw = dict["expiresAt"] as? Double else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }()

        return CacheEntry(
            accountUuid: accountUuid,
            organizationUuid: organizationUuid,
            clientID: clientID.isEmpty ? nil : clientID,
            hasUsageScope: rawKey.contains(usageScope),
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: dict["subscriptionType"] as? String
        )
    }

    private static func decryptSafeStorage(base64: String, key: Data) -> String? {
        guard let blob = Data(base64Encoded: base64), blob.count > 3 else { return nil }
        guard blob.prefix(3) == Data("v10".utf8) else {
            AppLog.info(.credentials, "unexpected Claude Desktop safeStorage prefix; skipping")
            return nil
        }
        let ciphertext = blob.dropFirst(3)
        guard let plaintext = aes128CBCDecrypt(
            ciphertext: Data(ciphertext),
            key: key,
            iv: Data(repeating: 0x20, count: kCCBlockSizeAES128)
        ) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    // MARK: - CommonCrypto 原语

    private static func pbkdf2SHA1(
        password: String,
        salt: Data,
        rounds: UInt32,
        keyLength: Int
    ) -> Data? {
        var derived = Data(count: keyLength)
        let passwordBytes = Array(password.utf8)
        let status = derived.withUnsafeMutableBytes { derivedBuffer -> Int32 in
            guard let derivedBase = derivedBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return salt.withUnsafeBytes { saltBuffer -> Int32 in
                guard let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                    saltBase, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    rounds,
                    derivedBase, keyLength
                )
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    private static func aes128CBCDecrypt(ciphertext: Data, key: Data, iv: Data) -> Data? {
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedCount = 0
        let status = output.withUnsafeMutableBytes { outputBuffer -> Int32 in
            guard let outputBase = outputBuffer.baseAddress else { return Int32(kCCParamError) }
            return ciphertext.withUnsafeBytes { cipherBuffer -> Int32 in
                guard let cipherBase = cipherBuffer.baseAddress else { return Int32(kCCParamError) }
                return key.withUnsafeBytes { keyBuffer -> Int32 in
                    guard let keyBase = keyBuffer.baseAddress else { return Int32(kCCParamError) }
                    return iv.withUnsafeBytes { ivBuffer -> Int32 in
                        guard let ivBase = ivBuffer.baseAddress else { return Int32(kCCParamError) }
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBase, key.count,
                            ivBase,
                            cipherBase, ciphertext.count,
                            outputBase, outputBuffer.count,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(decryptedCount)
    }
}
