import Foundation

/// Codex 凭据续期。
///
/// 与 Claude 侧不同,cc-bar **保留** Codex 的刷新能力:OpenAI 侧没有实测到
/// "第三方刷新把 CLI 挤下线"的问题,而且 OpenUsage / CodexBar / cc-switch
/// 也都在刷新并回写 `~/.codex/auth.json`。
///
/// 但 OpenAI 同样有 refresh_token 重用检测(`refresh_token_reused`),所以这里
/// 装了三道防撞:
/// 1. `Coordinator` 进程内串行 + 去重,避免 AppState 的多个入口同时拿同一份
///    refresh_token 各发一次请求;
/// 2. 发请求前 **重读存储**——`codex` CLI 可能已经自行轮换过,拿我们手里那份
///    陈腐副本去刷就会撞上重用检测;
/// 3. 写回失败不吞掉:重试一次,仍失败则大声记日志并继续返回本次刷到的 token
///    (它这次会话仍然可用),避免"服务端已轮换、盘上还留着废票"的静默损坏。
nonisolated enum CodexTokenRefresher {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let refreshSkew: TimeInterval = 300
    /// 写回失败后的重试间隔。
    static let writeBackRetryDelay: TimeInterval = 0.2

    struct Refreshed: Sendable {
        var accessToken: String
        var refreshToken: String
        var idToken: String?
    }

    /// 续期成功后,新 token 该落到哪里。
    /// - `codexAuthJSON`:回写 `~/.codex/auth.json`,默认账号(与 codex CLI 共享)用。
    /// - `importedAccount(id:)`:回写到 Keychain (ImportedCodexStore),用户手动导入的副账号用,
    ///   绝不触碰 `~/.codex/auth.json`。
    enum WriteBack: Sendable, Hashable {
        case codexAuthJSON
        case importedAccount(id: String)

        /// 去重键。不同导入账号必须各自独立,不能合流到同一次刷新。
        var coordinationKey: String {
            switch self {
            case .codexAuthJSON: return "auth.json"
            case .importedAccount(let id): return "imported:\(id)"
            }
        }
    }

    /// 若 access_token 即将过期则用 refresh_token 续期并按 `writeBack` 指示原子落盘。
    /// 返回当前可用的最新 access_token（未过期时即原值）。
    nonisolated static func ensureFreshAccessToken(
        currentAccessToken: String,
        refreshToken: String?,
        writeBack: WriteBack = .codexAuthJSON
    ) async -> Result<String, QuotaError> {
        let refreshed = await ensureFreshTokens(
            currentAccessToken: currentAccessToken,
            refreshToken: refreshToken,
            idToken: nil,
            writeBack: writeBack
        )
        return refreshed.map { $0.accessToken }
    }

    /// 若 access_token 即将过期则续期,并返回当前内存应采用的 token 三件套。
    nonisolated static func ensureFreshTokens(
        currentAccessToken: String,
        refreshToken: String?,
        idToken: String?,
        writeBack: WriteBack = .codexAuthJSON
    ) async -> Result<Refreshed, QuotaError> {
        if !isExpired(accessToken: currentAccessToken) {
            return .success(Refreshed(
                accessToken: currentAccessToken,
                refreshToken: refreshToken ?? "",
                idToken: idToken
            ))
        }
        guard let refreshToken, !refreshToken.isEmpty else {
            return .failure(.tokenRefreshFailed("no refresh_token"))
        }
        do {
            let r = try await Coordinator.shared.refresh(
                initialRefresh: refreshToken,
                fallbackIdToken: idToken,
                writeBack: writeBack
            )
            return .success(r)
        } catch let err as QuotaError {
            return .failure(err)
        } catch {
            return .failure(.tokenRefreshFailed("\(error)"))
        }
    }

    nonisolated static func isExpired(accessToken: String) -> Bool {
        guard let payload = JWT.decodePayload(accessToken),
              let exp = payload["exp"] as? Double
        else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < refreshSkew
    }

    // MARK: - Coordinator

    /// 进程内串行化 + 去重的刷新协调器,按 `WriteBack` 分键。
    private actor Coordinator {
        static let shared = Coordinator()
        private var inFlight: [String: Task<Refreshed, Error>] = [:]

        /// 同一账号的刷新合并:若已有刷新在飞行中,所有调用者共享同一结果,
        /// 避免 AppState 的多个入口几乎同时拿同一个 refresh_token 各发一次请求。
        func refresh(
            initialRefresh: String,
            fallbackIdToken: String?,
            writeBack: WriteBack
        ) async throws -> Refreshed {
            let key = writeBack.coordinationKey
            if let task = inFlight[key] {
                return try await task.value
            }
            let task = Task {
                try await CodexTokenRefresher.performRefresh(
                    initialRefresh: initialRefresh,
                    fallbackIdToken: fallbackIdToken,
                    writeBack: writeBack
                )
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            return try await task.value
        }
    }

    /// 真正的刷新主流程。
    nonisolated private static func performRefresh(
        initialRefresh: String,
        fallbackIdToken: String?,
        writeBack: WriteBack
    ) async throws -> Refreshed {
        var refreshToken = initialRefresh

        // 1) 拿锁后先 *重读* 一次存储:`codex` CLI(或 cc-bar 的另一个入口)
        //    可能在我们排队等锁时已经刷新过并写回了新值。拿陈腐的 refresh_token
        //    去刷会撞上 OpenAI 的重用检测,反而把有效登录搞掉。
        if let onDisk = peekStored(writeBack: writeBack) {
            if !isExpired(accessToken: onDisk.accessToken) {
                // 存储里的 access_token 已经新鲜,直接用,不发请求。
                return Refreshed(
                    accessToken: onDisk.accessToken,
                    refreshToken: onDisk.refreshToken ?? refreshToken,
                    idToken: onDisk.idToken ?? fallbackIdToken
                )
            }
            if let onDiskRefresh = onDisk.refreshToken, !onDiskRefresh.isEmpty {
                // 即便 access_token 仍过期,也优先用存储里的最新 refresh_token。
                refreshToken = onDiskRefresh
            }
        }

        // 2) 真正发刷新请求。
        let refreshed = try await performNetworkRefresh(
            using: refreshToken,
            fallbackIdToken: fallbackIdToken
        )

        // 3) 落盘。此时服务端已经轮换,旧 token 作废——写回失败绝不能静默,
        //    否则盘上留着废票,下次启动直接登录失效。
        await persist(refreshed, writeBack: writeBack)
        return refreshed
    }

    // MARK: - Network

    nonisolated private static func performNetworkRefresh(
        using refreshToken: String,
        fallbackIdToken: String?
    ) async throws -> Refreshed {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = "grant_type=refresh_token"
            + "&refresh_token=\(percent(refreshToken))"
            + "&client_id=\(clientID)"
            + "&scope=openid%20profile%20email"
        req.httpBody = body.data(using: .utf8)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw QuotaError.from(transport: error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.tokenRefreshFailed("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            // 代理 / 网关的拦截页也会带着 4xx 回来,但那不是 OAuth 端点在拒绝我们,
            // 报"令牌刷新失败"会把用户引向错误的方向。只有响应体像 HTML 页面时才
            // 转成 `.http` 让文案说清是拦截;真实的 OAuth 错误(invalid_grant、429 等
            // JSON 响应)保持 `.tokenRefreshFailed`,退避行为与文案都不变。
            let asHTTP = QuotaError.http(http.statusCode, msg)
            if asHTTP.looksLikeInterceptedResponse { throw asHTTP }
            throw QuotaError.tokenRefreshFailed("http \(http.statusCode): \(msg)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.tokenRefreshFailed("invalid json")
        }
        guard let newAccess = root["access_token"] as? String else {
            throw QuotaError.tokenRefreshFailed("no access_token in response")
        }
        return Refreshed(
            accessToken: newAccess,
            refreshToken: root["refresh_token"] as? String ?? refreshToken,
            idToken: root["id_token"] as? String ?? fallbackIdToken
        )
    }

    // MARK: - Peek stored tokens

    private struct StoredTokens: Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
    }

    nonisolated private static func peekStored(writeBack: WriteBack) -> StoredTokens? {
        switch writeBack {
        case .codexAuthJSON:
            let url = CodexAuth.authFileURL()
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String, !access.isEmpty
            else { return nil }
            return StoredTokens(
                accessToken: access,
                refreshToken: tokens["refresh_token"] as? String,
                idToken: tokens["id_token"] as? String
            )
        case .importedAccount(let id):
            guard let tokens = ImportedCodexStore.loadTokens(accountId: id),
                  !tokens.accessToken.isEmpty
            else { return nil }
            return StoredTokens(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                idToken: tokens.idToken
            )
        }
    }

    // MARK: - Write back

    /// 写回存储。失败时重试一次;仍失败则记 error 日志并放行——本次刷到的 token
    /// 在内存里仍然可用,不该因为落盘失败就让整次取数失败。
    nonisolated private static func persist(_ refreshed: Refreshed, writeBack: WriteBack) async {
        do {
            try write(refreshed, writeBack: writeBack)
            return
        } catch {
            AppLog.warn(.credentials, "codex token write-back failed, retrying: \(Redact.error(error))")
        }
        try? await Task.sleep(nanoseconds: UInt64(writeBackRetryDelay * 1_000_000_000))
        do {
            try write(refreshed, writeBack: writeBack)
        } catch {
            // 服务端已经轮换过 token,而盘上还是旧的那份废票。下次启动会登录失效,
            // 需要用户重新 `codex login`。这条日志是排查这类"莫名掉线"的唯一线索。
            AppLog.error(.credentials, """
                codex token write-back failed twice (\(writeBack.coordinationKey)); \
                stored credentials now hold a rotated-away token: \(Redact.error(error))
                """)
        }
    }

    nonisolated private static func write(_ refreshed: Refreshed, writeBack: WriteBack) throws {
        switch writeBack {
        case .codexAuthJSON:
            try writeBackToAuthJSON(
                accessToken: refreshed.accessToken,
                idToken: refreshed.idToken,
                refreshToken: refreshed.refreshToken
            )
        case .importedAccount(let id):
            try ImportedCodexStore.saveTokens(
                ImportedCodexTokens(
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken,
                    idToken: refreshed.idToken
                ),
                accountId: id
            )
        }
    }

    nonisolated private static func writeBackToAuthJSON(
        accessToken: String,
        idToken: String?,
        refreshToken: String
    ) throws {
        let url = CodexAuth.authFileURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let idToken { tokens["id_token"] = idToken }
        tokens["refresh_token"] = refreshToken
        root["tokens"] = tokens
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: Date())

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: url, options: [.atomic])
    }

    nonisolated private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
