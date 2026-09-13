import Foundation

/// Claude 凭据读取器。
///
/// **cc-bar 只读 Claude 的 OAuth 凭据,不刷新、不写回。**
///
/// 原因:Anthropic 的 refresh_token 是一次性的,刷新即轮换,并且带重用检测。
/// 同一个 `client_id` 下不存在"两份同时有效的 refresh_token"——cc-bar 每成功刷新
/// 一次,Claude Code CLI / Desktop 手里那份就立刻变成废票,它们下次刷新会拿到
/// `invalid_grant`,整条 token family 被撤销,用户被迫重新登录。
///
/// 关键权衡:cc-bar 需要刷新的时刻,恰好是数据不会变的时刻——access_token 过期
/// 意味着用户已经很久没用 Claude Code,额度本来就没消耗。为一个不变的数字赌上
/// 用户主力工具的登录态,不划算。
///
/// 因此过期时的策略是"等 Claude Code 自己刷":重读一次凭据存储,如果它刚刷新过
/// 就直接采用;否则向上报 `credentialsExpired`,由 AppState 保留上一次快照并在
/// 用户手动刷新时走 `claude` CLI 兜底取数(CLI 用自己的会话身份,刷新是安全的)。
///
/// 重读落空后还有一层:借 Claude Desktop 缓存里同一账号的 access_token
/// (`ClaudeDesktopAuth`)。CLI 的 token 只有 8 小时有效期,用户改用 Claude Desktop
/// 聊天时不会刷新它,隔夜必然过期;而 Desktop 那份有效期以月计。同样只借不刷,
/// 不碰任何 refresh_token,所以上面那条"不刷新"的结论依然成立。
///
/// 同类工具的做法可参考:OpenChamber 与 cc-switch 完全只读;CodexBar 刷新但只写
/// 自己的缓存条目,从不回写 `Claude Code-credentials`。
nonisolated enum ClaudeTokenRefresher {
    /// access_token 临期判定 skew。判定"手上这份还能不能用"。
    nonisolated static let refreshSkew: TimeInterval = 30
    /// 采用存储里那份时的临期 skew。比 `refreshSkew` 宽松——只要够撑完这次取数即可,
    /// 没必要因为剩 20 秒就判死,否则会白白丢掉一次可用数据。
    nonisolated static let adoptSkew: TimeInterval = 5
    /// 若凭据存储在最近这么久内被改过,认为 Claude Code 正在刷新,值得等一拍再重读。
    static let politeMtimeWindow: TimeInterval = 10
    /// 等待外部客户端把新凭据写回存储的延时。
    static let adoptDelay: TimeInterval = 1.0
    static let keychainService = "Claude Code-credentials"

    /// 从存储里偷读到的凭据快照,只取我们关心的字段。
    struct StoredSnapshot: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    /// 返回当前可用的 access_token,并同步更新 `account` 内的 token / expiresAt。
    ///
    /// 手上这份没过期就直接用;过期了**不会**自己去刷新,而是重读存储,期待
    /// Claude Code 已经刷过并写下了新值。重读仍拿不到有效 token 时返回
    /// `credentialsExpired`。
    nonisolated static func ensureFreshAccessToken(
        account: inout ClaudeAccount
    ) async -> Result<String, QuotaError> {
        guard let current = account.accessToken else {
            return .failure(.missingToken)
        }
        if !isExpired(expiresAt: account.expiresAt) {
            return .success(current)
        }
        if let fresh = await Coordinator.shared.adoptFresh(source: account.source) {
            account.accessToken = fresh.accessToken
            account.refreshToken = fresh.refreshToken ?? account.refreshToken
            account.expiresAt = fresh.expiresAt
            account.expiredGuess = false
            return .success(fresh.accessToken)
        }
        // Claude Code 那份也过期了(用户多半改用 Claude Desktop 聊天,它不会刷新
        // CLI 的 8 小时 token)。借 Desktop 缓存里同一账号的 access_token 顶上——
        // 只借不刷,不碰它的 refresh_token,详见 `ClaudeDesktopAuth`。
        if let borrowed = borrowDesktopToken(for: account) {
            account.accessToken = borrowed.accessToken
            account.expiresAt = borrowed.expiresAt
            account.expiredGuess = false
            account.source = .desktop
            return .success(borrowed.accessToken)
        }
        AppLog.info(.credentials, "stored Claude credentials are expired; waiting for Claude Code to refresh")
        return .failure(.credentialsExpired)
    }

    /// 借用 Claude Desktop 的 access_token。Desktop 没装 / 没登录 / 不是同一账号 /
    /// 用户拒绝过钥匙串授权时都返回 nil,调用方据此退回 `credentialsExpired`。
    nonisolated private static func borrowDesktopToken(
        for account: ClaudeAccount
    ) -> ClaudeDesktopAuth.BorrowedToken? {
        guard ClaudeDesktopAuth.hasCredentialMaterial else { return nil }
        return ClaudeDesktopAuth.borrowToken(for: account)
    }

    nonisolated static func isExpired(expiresAt: Date?, skew: TimeInterval = refreshSkew) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < skew
    }

    // MARK: - Coordinator

    /// 重读存储的进程内去重器。菜单栏 / 悬浮窗 / Popover 可能同时触发刷新,
    /// 而 keychain 读要过一次 ACL,不便宜——合并成一次读。
    private actor Coordinator {
        static let shared = Coordinator()
        private var inFlight: Task<StoredSnapshot?, Never>?

        func adoptFresh(source: CredentialSource) async -> StoredSnapshot? {
            if let task = inFlight {
                return await task.value
            }
            let task = Task { await Coordinator.reread(source: source) }
            inFlight = task
            defer { inFlight = nil }
            return await task.value
        }

        private static func reread(source: CredentialSource) async -> StoredSnapshot? {
            if let fresh = ClaudeTokenRefresher.freshStored(source: source) {
                return fresh
            }
            // 存储刚被改过 = Claude Code 大概率正在刷新的半途,等一拍再读一次。
            guard ClaudeTokenRefresher.storeChangedRecently(source: source) else { return nil }
            try? await Task.sleep(
                nanoseconds: UInt64(ClaudeTokenRefresher.adoptDelay * 1_000_000_000)
            )
            return ClaudeTokenRefresher.freshStored(source: source)
        }
    }

    // MARK: - Peek stored credentials (cheap re-read, bypass ClaudeAuth.load)

    /// 重读存储,仅当里面的 access_token 还够用时才返回。
    nonisolated private static func freshStored(source: CredentialSource) -> StoredSnapshot? {
        guard let onDisk = peekStored(source: source),
              let expiresAt = onDisk.expiresAt,
              !isExpired(expiresAt: expiresAt, skew: adoptSkew)
        else { return nil }
        return onDisk
    }

    nonisolated static func peekStored(source: CredentialSource) -> StoredSnapshot? {
        switch source {
        case .file: return peekFile()
        case .keychain: return peekKeychain()
        // Desktop 的凭据不由 Claude Code 写,"重读一次、期待它刚刷新过"这套对它没有
        // 意义;真要换 Desktop 的新 token 走的是 `borrowDesktopToken`。
        case .desktop: return nil
        }
    }

    nonisolated private static func peekFile() -> StoredSnapshot? {
        let url = credentialsFileURL()
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return parseOAuth(oauth)
    }

    nonisolated private static func peekKeychain() -> StoredSnapshot? {
        guard let root = try? readKeychainJSON(),
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return parseOAuth(oauth)
    }

    nonisolated private static func parseOAuth(_ oauth: [String: Any]) -> StoredSnapshot? {
        let access = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
        guard let access, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
        let expiresAt: Date? = {
            if let n = oauth["expiresAt"] as? Double {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            if let s = oauth["expiresAt"] as? String, let n = Double(s) {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            return nil
        }()
        return StoredSnapshot(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    // MARK: - "刚被改过吗" 探测

    /// 凭据存储是否在礼让窗口内被改动过。两个源都支持:
    /// - 文件源看 mtime;
    /// - keychain 源看条目属性里的 `mdat`。读属性(不带 `-w`)不碰密文,
    ///   因此不会触发钥匙串授权弹窗,成本远低于读一次密码。
    nonisolated static func storeChangedRecently(source: CredentialSource) -> Bool {
        switch source {
        case .file: return fileMtimeWithinPoliteWindow()
        case .keychain: return keychainMdatWithinPoliteWindow()
        // 同上:Desktop 源没有"礼让 Claude Code 写完"这一说。
        case .desktop: return false
        }
    }

    nonisolated static func fileMtimeWithinPoliteWindow() -> Bool {
        let url = credentialsFileURL()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(mtime) < politeMtimeWindow
    }

    nonisolated static func keychainMdatWithinPoliteWindow() -> Bool {
        guard let mdat = keychainModificationDate() else { return false }
        return Date().timeIntervalSince(mdat) < politeMtimeWindow
    }

    /// 读钥匙串条目的最后修改时间。输出形如 `"mdat"<timedate>=0x...  "20260823084709Z\000"`。
    nonisolated private static func keychainModificationDate() -> Date? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: out, encoding: .utf8)
        else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"mdat\"") }) else {
            return nil
        }
        // 取最后一对引号里的内容,即 `20260823084709Z\000`。
        let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
        guard let raw = quoted.dropLast().last else { return nil }
        let stamp = raw.replacingOccurrences(of: "\\000", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMddHHmmss'Z'"
        return fmt.date(from: stamp)
    }

    nonisolated private static func credentialsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    nonisolated private static func readKeychainJSON() throws -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, !out.isEmpty,
              let str = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let data = str.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw QuotaError.tokenRefreshFailed("read keychain failed")
        }
        return root
    }
}
