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
                initialAccess: currentAccessToken,
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
        private var inFlight: [String: (refreshToken: String, task: Task<Refreshed, Error>)] = [:]

        /// 同一账号的刷新合并:若已有刷新在飞行中,所有调用者共享同一结果,
        /// 避免 AppState 的多个入口几乎同时拿同一个 refresh_token 各发一次请求。
        func refresh(
            initialAccess: String,
            initialRefresh: String,
            fallbackIdToken: String?,
            writeBack: WriteBack
        ) async throws -> Refreshed {
            let key = writeBack.coordinationKey
            if let request = inFlight[key] {
                guard request.refreshToken == initialRefresh else { throw loginChanged }
                return try await request.task.value
            }
            let task = Task {
                try await CodexTokenRefresher.performRefresh(
                    initialAccess: initialAccess,
                    initialRefresh: initialRefresh,
                    fallbackIdToken: fallbackIdToken,
                    writeBack: writeBack
                )
            }
            inFlight[key] = (initialRefresh, task)
            defer { inFlight[key] = nil }
            return try await task.value
        }
    }

    /// 真正的刷新主流程。
    nonisolated private static func performRefresh(
        initialAccess: String,
        initialRefresh: String,
        fallbackIdToken: String?,
        writeBack: WriteBack
    ) async throws -> Refreshed {
        // CLI 可能已经轮换凭据。只有同一用户和工作区才能采用磁盘上轮换后的令牌。
        guard let stored = peekStored(writeBack: writeBack),
              stored.tokens.refreshToken == initialRefresh
                || sameLogin(initialAccess, stored.tokens.accessToken)
        else { throw loginChanged }
        let tokens = stored.tokens
        if !isExpired(accessToken: tokens.accessToken) {
            return Refreshed(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken ?? "",
                idToken: tokens.idToken ?? fallbackIdToken
            )
        }
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else { throw loginChanged }

        // 2) 真正发刷新请求。
        let refreshed = try await performNetworkRefresh(
            using: refreshToken,
            fallbackIdToken: tokens.idToken ?? fallbackIdToken
        )

        // 3) 落盘。此时服务端已经轮换,旧 token 作废——写回失败绝不能静默,
        //    否则盘上留着废票,下次启动直接登录失效。
        try await persist(refreshed, matching: stored, writeBack: writeBack)
        return refreshed
    }

    private static let loginChanged = QuotaError.tokenRefreshFailed("Codex credentials changed during renewal")

    private static func sameLogin(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = JWT.decodePayload(lhs)?["https://api.openai.com/auth"] as? [String: Any],
              let right = JWT.decodePayload(rhs)?["https://api.openai.com/auth"] as? [String: Any],
              let account = left["chatgpt_account_id"] as? String, !account.isEmpty,
              let user = left["chatgpt_user_id"] as? String, !user.isEmpty else { return false }
        return account == right["chatgpt_account_id"] as? String
            && user == right["chatgpt_user_id"] as? String
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
            (data, resp) = try await NetworkProxy.data(for: req)
        } catch {
            throw QuotaError.from(transport: error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.tokenRefreshFailed("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            // 代理 / 网关的拦截页也会带着 4xx 回来,但那不是 OAuth 端点在拒绝我们,
            // 拦截页保留 HTTP 状态便于提示，429 保留状态码以触发退避。
            let asHTTP = QuotaError.http(http.statusCode, msg)
            if asHTTP.isRateLimited || asHTTP.looksLikeInterceptedResponse { throw asHTTP }
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
        var tokens: ImportedCodexTokens
        var authFileData: Data? = nil
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
                tokens: ImportedCodexTokens(
                    accessToken: access,
                    refreshToken: tokens["refresh_token"] as? String,
                    idToken: tokens["id_token"] as? String
                ),
                authFileData: data
            )
        case .importedAccount(let id):
            guard let tokens = ImportedCodexStore.loadTokens(accountId: id),
                  !tokens.accessToken.isEmpty
            else { return nil }
            return StoredTokens(tokens: tokens)
        }
    }

    // MARK: - Write back

    /// 写回存储。失败时重试一次;仍失败则记 error 日志并放行——本次刷到的 token
    /// 在内存里仍然可用,不该因为落盘失败就让整次取数失败。
    nonisolated private static func persist(
        _ refreshed: Refreshed, matching expected: StoredTokens, writeBack: WriteBack
    ) async throws {
        let updated: Bool
        do {
            updated = try write(refreshed, matching: expected, writeBack: writeBack)
        } catch {
            AppLog.warn(.credentials, "codex token write-back failed, retrying: \(Redact.error(error))")
            try? await Task.sleep(nanoseconds: UInt64(writeBackRetryDelay * 1_000_000_000))
            do {
                updated = try write(refreshed, matching: expected, writeBack: writeBack)
            } catch {
                AppLog.error(.credentials, "codex token write-back failed twice: \(Redact.error(error))")
                return
            }
        }
        guard updated else { throw loginChanged }
    }

    nonisolated private static func write(
        _ refreshed: Refreshed, matching expected: StoredTokens, writeBack: WriteBack
    ) throws -> Bool {
        switch writeBack {
        case .codexAuthJSON:
            guard let data = expected.authFileData else { return false }
            return try writeBackToAuthJSON(refreshed, matching: data)
        case .importedAccount(let id):
            return try ImportedCodexStore.replaceTokens(
                ImportedCodexTokens(
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken,
                    idToken: refreshed.idToken
                ),
                matching: expected.tokens, accountId: id
            )
        }
    }

    nonisolated private static func writeBackToAuthJSON(
        _ refreshed: Refreshed, matching expected: Data
    ) throws -> Bool {
        let url = CodexAuth.authFileURL()
        guard var root = try JSONSerialization.jsonObject(with: expected) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any] else { return false }
        tokens["access_token"] = refreshed.accessToken
        if let idToken = refreshed.idToken { tokens["id_token"] = idToken }
        tokens["refresh_token"] = refreshed.refreshToken
        root["tokens"] = tokens
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: Date())

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard (try? Data(contentsOf: url)) == expected else { return false }
        try out.write(to: url, options: [.atomic])
        return true
    }

    nonisolated private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
