import Foundation

/// Antigravity（Google Antigravity / Gemini Code Assist）额度客户端（Cloud Mode）。
///
/// 直连 `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`，
/// 使用 `AntigravityCredentials` 读取的 `access_token` 作为 `Bearer`。
/// 解析 5小时（`primaryLimit`）与周（`secondaryLimit`）窗口，以及
/// Gemini 5小时（`geminiWindow`）/ 周（`geminiWeekly`）细粒度。
/// 富化链路：`loadCodeAssist`（tier / plan）→ `retrieveUserQuotaSummary`
/// （权威分组：Gemini / Claude+GPT 各含 5h + weekly，实测免费版即有）→
/// `fetchAvailableModels`（Gemini 轮换）→ `retrieveUserQuota`（按模型分桶，仅 5h）。
/// 见 `docs/草案-Antigravity支持-设计方案.md` §2。
nonisolated enum AntigravityQuotaClient {
    static let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let dailyEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    /// 取数结果，附带账号订阅层级。
    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var account: AntigravityAccount
    }

    nonisolated static func fetch(accessToken: String) async -> Result<Fetched, QuotaError> {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.missingToken) }

        // 官方 Antigravity 2.12.0 使用 daily 域；主域可能返回另一套基础额度池，
        // 即使请求成功也会造成套餐、用量与重置时间错配，因此仅作为回退。
        let endpoints = [dailyEndpoint, endpoint]
        var lastError: QuotaError?
        for url in endpoints {
            let result = await fetch(from: url, accessToken: token)
            switch result {
            case .success:
                return result
            case .failure(let err):
                // 401/403 直接返回，不再回退
                if err.isAuthFailure { return .failure(err) }
                lastError = err
                continue
            }
        }
        return .failure(lastError ?? .transport("no endpoint"))
    }

    private static func fetch(from url: URL, accessToken: String) async -> Result<Fetched, QuotaError> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 30
        // daily 域保持与官方客户端一致的空 body；旧主域回退保留既有 project 上下文。
        let payload: [String: Any] = url == dailyEndpoint ? [:] : [
            "cloudaicompanionProject": "aicode-consumers",
            "metadata": ["ideName": "antigravity"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            return .failure(.from(transport: error))
        }
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.transport("non-http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(http.statusCode, msg.isEmpty ? "antigravity loadCodeAssist failed" : msg))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decode("not json object"))
        }
        var fetched = parse(root: root)
        let fetchedAt = Date()
        // 二阶段富化（首选）：retrieveUserQuotaSummary 返回按组（Gemini / Claude+GPT）
        // 区分的 5h + weekly 窗口，与官方 UI 一致，是信息最全的真实数据源。
        // （实测免费版账号即有 4 桶：gemini-weekly/5h + 3p-weekly/5h。）
        if let enriched = await tryFetchUserQuotaSummary(baseURL: url, accessToken: accessToken, fetchedAt: fetchedAt) {
            fetched = merge(base: fetched, enrichment: enriched)
        }
        // 若已拿到完整权威分组配额（Gemini 主条 + Claude 组），无需发起后续三四阶段兜底请求，
        // 避免多余网络 RTT 并降低 Google 429 风险。
        let hasCompleteGroupedQuota = fetched.snapshot.primaryLimit != nil && !fetched.snapshot.auxiliaryLimits.isEmpty
        if !hasCompleteGroupedQuota {
            // 三阶段富化：loadCodeAssist 未返回额度时（如 daily 域回退），fetchAvailableModels
            // 提供 Gemini 轮换窗口；g1 账号缺少该接口时此步为空，不视为失败。
            if let enriched = await tryEnrichWithAvailableModels(baseURL: url, accessToken: accessToken, fetchedAt: fetchedAt) {
                fetched = merge(base: fetched, enrichment: enriched)
            }
            // 四阶段富化（兜底）：retrieveUserQuota 按模型分桶的剩余额度（仅 5h 语义），
            // 在 summary 不可用时仍可给出第三方/Gemini 的 5h 窗口。
            if let enriched = await tryFetchUserQuota(baseURL: url, accessToken: accessToken, fetchedAt: fetchedAt) {
                fetched = merge(base: fetched, enrichment: enriched)
            }
        }
        return .success(fetched)
    }

    /// 尝试用同一 host 的 `fetchAvailableModels` 补齐窗口；403/401 等视为无权，不算失败。
    private static func tryEnrichWithAvailableModels(baseURL: URL, accessToken: String, fetchedAt: Date) async -> Fetched? {
        let baseStr = baseURL.absoluteString
        // 将 v1internal:loadCodeAssist 替换为 v1internal:fetchAvailableModels
        let modelsStr = baseStr.replacingOccurrences(of: "loadCodeAssist", with: "fetchAvailableModels")
        guard let modelsURL = URL(string: modelsStr) else { return nil }
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        // fetchAvailableModels 不接受 cloudaicompanionProject 字段（实测 400），保持空 body
        req.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    /// 用同一 host 的 `retrieveUserQuotaSummary` 补齐按组区分的权威额度。
    /// 返回 `groups[]`：`{ displayName, buckets: [{ bucketId, window, remainingFraction, resetTime }] }`。
    /// bucketId 语义：`gemini-weekly` / `gemini-5h`（Gemini Models 组）、
    /// `3p-weekly` / `3p-5h`（Claude and GPT models 组）。
    private static func tryFetchUserQuotaSummary(baseURL: URL, accessToken: String, fetchedAt: Date) async -> Fetched? {
        let baseStr = baseURL.absoluteString
        // 将 v1internal:loadCodeAssist 替换为 v1internal:retrieveUserQuotaSummary
        let summaryStr = baseStr.replacingOccurrences(of: "loadCodeAssist", with: "retrieveUserQuotaSummary")
        guard summaryStr != baseStr, let summaryURL = URL(string: summaryStr) else { return nil }
        var req = URLRequest(url: summaryURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        // retrieveUserQuotaSummary 不接受 cloudaicompanionProject 等字段，保持空 body
        req.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    /// 用同一 host 的 `retrieveUserQuota` 补齐按模型分桶的真实额度。
    /// `buckets[]`：`{ modelId, remainingFraction, resetTime?, tokenType? }`。
    /// 与 `fetchAvailableModels` 不同，该端点区分第三方（Claude/GPT）5h 窗口与 Gemini 轮换窗口。
    private static func tryFetchUserQuota(baseURL: URL, accessToken: String, fetchedAt: Date) async -> Fetched? {
        let baseStr = baseURL.absoluteString
        // 将 v1internal:loadCodeAssist 替换为 v1internal:retrieveUserQuota
        let quotaStr = baseStr.replacingOccurrences(of: "loadCodeAssist", with: "retrieveUserQuota")
        guard quotaStr != baseStr, let quotaURL = URL(string: quotaStr) else { return nil }
        var req = URLRequest(url: quotaURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        // retrieveUserQuota 不接受 cloudaicompanionProject 等字段，保持空 body
        req.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    // MARK: - Merge

    /// 富化合并：base 有值则保留，缺失用富化补齐。
    /// 注意：`retrieveUserQuotaSummary` 是权威分组源，当它解析出真实窗口时，
    /// 富化（fetchAvailableModels / retrieveUserQuota 等 per-model 兜底）不得覆盖。
    /// 因此 merge 只做「缺失补齐」：base 有值一律保留，只有 nil 才由 enrichment 填充。
    static func merge(base: Fetched, enrichment: Fetched) -> Fetched {
        var snap = base.snapshot
        // 仅当 base 无窗口时，用富化结果补齐
        if snap.primaryLimit == nil { snap.primaryLimit = enrichment.snapshot.primaryLimit }
        if snap.secondaryLimit == nil { snap.secondaryLimit = enrichment.snapshot.secondaryLimit }
        if snap.geminiWindow == nil { snap.geminiWindow = enrichment.snapshot.geminiWindow }
        if snap.geminiWeekly == nil { snap.geminiWeekly = enrichment.snapshot.geminiWeekly }
        // 富化补齐了 weekly 且 base 已有 5h 主条 → 挂成 secondary；
        // 富化只有 weekly（无 5h）而 base 完全无窗口 → weekly 升为主条。
        if snap.secondaryLimit == nil, enrichment.snapshot.weeklyLimit != nil {
            if snap.primaryLimit?.kind == .fiveHour {
                snap.secondaryLimit = enrichment.snapshot.weeklyLimit
            } else if snap.primaryLimit == nil {
                snap.primaryLimit = enrichment.snapshot.weeklyLimit
            }
        }
        // 富化主窗口未命中（如合并顺序问题）时，若 primary 仍缺，用富化的补。
        if snap.primaryLimit == nil, enrichment.snapshot.primaryLimit != nil {
            snap.primaryLimit = enrichment.snapshot.primaryLimit
            if snap.secondaryLimit == nil {
                snap.secondaryLimit = enrichment.snapshot.secondaryLimit
            }
        }
        // auxiliaryLimits 同样缺失补齐：base 为空时采用富化（如 Claude 5H / Claude WK）。
        if snap.auxiliaryLimits.isEmpty {
            snap.auxiliaryLimits = enrichment.snapshot.auxiliaryLimits
        }
        // planType 保留 base，缺失时用富化的
        if snap.planType == nil { snap.planType = enrichment.snapshot.planType }
        var account = base.account
        if account.planType == nil { account.planType = enrichment.account.planType }
        return Fetched(snapshot: snap, account: account)
    }

    // MARK: - Parse

    nonisolated static func parse(root: [String: Any], fetchedAt: Date = Date()) -> Fetched {
        // 1. 尝试新版 loadCodeAssist 的 tier 结构
        // 典型字段：currentTier, paidTier, allowedTiers, project
        // 若包含显式额度 buckets（如 retrieveUserQuota / fetchAvailableModels 的 fallback），则走 buckets
        var fiveHour: QuotaWindow?   // 非分组源（fetchAvailableModels / retrieveUserQuota 兜底）的 5h
        var weekly: QuotaWindow?     // 非分组源兜底的 weekly
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var claude5h: QuotaWindow?   // 仅 retrieveUserQuotaSummary 分组源（3p-5h）
        var claudeWeekly: QuotaWindow? // 仅 retrieveUserQuotaSummary 分组源（3p-weekly）
        var planType: String?
        var hasGroupedData = false   // 是否拿到 retrieveUserQuotaSummary 的分组数据

        // Google AI 订阅身份在 paidTier；Pro 账号仍可能同时返回 currentTier=free-tier，
        // 后者是基础 Code Assist 层级，不能覆盖付费订阅。展示优先用官方套餐名。
        if let paid = root["paidTier"] as? [String: Any],
           let paidPlan = nonEmpty(paid["name"] as? String) ?? nonEmpty(paid["id"] as? String)
        {
            planType = paidPlan
        } else if let cur = root["currentTier"] as? [String: Any], let id = cur["id"] as? String {
            planType = id
        } else if let cur = root["currentTier"] as? String {
            planType = cur
        } else if let allowed = root["allowedTiers"] as? [[String: Any]], let first = allowed.first, let id = first["id"] as? String {
            planType = id
        } else if let tier = root["tier"] as? [String: Any], let id = tier["id"] as? String {
            planType = id
        }

        // 2. 若 root 顶层包含 "groups"（retrieveUserQuotaSummary 的权威结构，
        // 也是旧版语言服务器 RetrieveUserQuotaSummary 的兼容来源）
        if let groups = root["groups"] as? [[String: Any]] {
            let parsed = parseGroups(groups, fetchedAt: fetchedAt)
            // 分组源语义明确：5h/weekly = Claude/GPT 组，gemini* = Gemini 组。
            // 独立存一份用于“拿到分组数据”判定与组装映射。
            claude5h = parsed.fiveHour
            claudeWeekly = parsed.weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? geminiWeekly
            hasGroupedData = parsed.fiveHour != nil || parsed.weekly != nil
                || parsed.geminiWindow != nil || parsed.geminiWeekly != nil
            if planType == nil { planType = parsed.planType }
        }

        // 3. 若包含 "quota" / "buckets" / "models"
        // 常见于 fetchAvailableModels / retrieveUserQuota
        if let quota = root["quota"] as? [String: Any] {
            let parsed = parseQuotaDict(quota, fetchedAt: fetchedAt)
            fiveHour = fiveHour ?? parsed.fiveHour
            weekly = weekly ?? parsed.weekly
            geminiWindow = geminiWindow ?? parsed.geminiWindow
            geminiWeekly = geminiWeekly ?? parsed.geminiWeekly
        }
        if let buckets = root["buckets"] as? [[String: Any]] {
            let parsed = parseBuckets(buckets, fetchedAt: fetchedAt)
            // 与顶层 quotaInfo 反序不同：buckets 是 retrieveUserQuota 的主数据，信息最全，
            // 新解析值整体取代旧值（含 nil），保证富化第三段能真实覆盖早期宽松窗口。
            fiveHour = parsed.fiveHour ?? fiveHour
            weekly = parsed.weekly ?? weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? geminiWeekly
        }
        // 3b. 仅当 buckets 缺席时，才用 models 解析（buckets 优先级更高且语义更准）
        if root["buckets"] == nil, let models = root["models"] as? [[String: Any]] {
            let parsed = parseModels(models, fetchedAt: fetchedAt)
            if fiveHour == nil { fiveHour = parsed.fiveHour }
            if weekly == nil { weekly = parsed.weekly }
            if geminiWindow == nil { geminiWindow = parsed.geminiWindow }
            if geminiWeekly == nil { geminiWeekly = parsed.geminiWeekly }
        }
        // fetchAvailableModels 的 models 实际是 dict：{ "model-id": { ..., "quotaInfo": { remainingFraction, resetTime } } }
        if let modelsDict = root["models"] as? [String: Any] {
            let parsed = parseModelsDict(modelsDict, fetchedAt: fetchedAt)
            if fiveHour == nil { fiveHour = parsed.fiveHour }
            if weekly == nil { weekly = parsed.weekly }
            if geminiWindow == nil { geminiWindow = parsed.geminiWindow }
            if geminiWeekly == nil { geminiWeekly = parsed.geminiWeekly }
        }
        // 4. fetchAvailableModels 的 "availableModels"
        if let available = root["availableModels"] as? [[String: Any]] {
            let parsed = parseModels(available, fetchedAt: fetchedAt)
            if fiveHour == nil { fiveHour = parsed.fiveHour }
            if weekly == nil { weekly = parsed.weekly }
            if geminiWindow == nil { geminiWindow = parsed.geminiWindow }
            if geminiWeekly == nil { geminiWeekly = parsed.geminiWeekly }
        }
        // 5. 若仍无窗，尝试从 currentTier 的 quotaInfo（保留只在此分支填，避免覆盖前序结果）
        if fiveHour == nil, weekly == nil, geminiWindow == nil, geminiWeekly == nil, claude5h == nil, claudeWeekly == nil {
            if let info = root["quotaInfo"] as? [String: Any] {
                let parsed = parseQuotaDict(info, fetchedAt: fetchedAt)
                fiveHour = fiveHour ?? parsed.fiveHour
                weekly = weekly ?? parsed.weekly
                geminiWindow = geminiWindow ?? parsed.geminiWindow
                geminiWeekly = geminiWeekly ?? parsed.geminiWeekly
            }
        }

        // 组装 QuotaSnapshot：
        // - 分组源（retrieveUserQuotaSummary）可用时，按官方两组四窗口映射：
        //   primary = Gemini 5h，secondary = Gemini weekly，aux = [Claude 5h, Claude weekly]；
        // - 无分组源时退化为旧行为：优先 5h 主条，weekly 作副条。
        // 分组源数据优先：即便兜底（buckets/models）也填了 5h，也不覆盖分组语义。
        let primaryLimit: QuotaLimit?
        let secondaryLimit: QuotaLimit?
        let auxiliaryLimits: [QuotaLimit]
        if hasGroupedData {
            // Gemini 前两行：主条 5h + 副条 weekly（geminiWindow/geminiWeekly 可能缺失一档）
            primaryLimit = (geminiWindow ?? geminiWeekly).map {
                let kind = QuotaSnapshot.kind(for: $0, fallback: .fiveHour)
                let id = kind == .fiveHour ? "gemini-5h" : "gemini-weekly"
                return QuotaLimit(id: id, kind: kind, displayName: "Gemini \(kind == .fiveHour ? "5H" : "WK")", window: $0, isActive: nil)
            }
            let secondaryWindow = geminiWindow != nil ? geminiWeekly : nil
            secondaryLimit = secondaryWindow.map {
                QuotaLimit(id: "gemini-weekly", kind: .weekly, displayName: "Gemini WK", window: $0, isActive: nil)
            }
            // Claude 组两行进 auxiliary（原第三方主副条降级为普通行），使用独立 id 避免与 Gemini 组 weekly 冲突被去重丢弃
            var aux: [QuotaLimit] = []
            if let claude5h { aux.append(QuotaLimit(id: "claude-5h", kind: .fiveHour, displayName: "Claude 5H", window: claude5h, isActive: nil)) }
            if let claudeWeekly { aux.append(QuotaLimit(id: "claude-weekly", kind: .weekly, displayName: "Claude WK", window: claudeWeekly, isActive: nil)) }
            auxiliaryLimits = aux
        } else {
            let primaryWindow = fiveHour ?? weekly
            let secondaryWindow = fiveHour != nil ? weekly : nil
            primaryLimit = primaryWindow.map { QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0, fallback: .fiveHour), window: $0) }
            secondaryLimit = secondaryWindow.map { QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0, fallback: .weekly), window: $0) }
            auxiliaryLimits = []
        }

        let snapshot = QuotaSnapshot(
            app: .antigravity,
            primaryLimit: primaryLimit,
            secondaryLimit: secondaryLimit,
            auxiliaryLimits: auxiliaryLimits,
            // 分组源已把 Gemini 窗口映射进 primary/secondary/aux，细行字段留空；
            // 非分组 fallback（buckets/models 兜底）仍保留 geminiWindow/geminiWeekly 供 GM/GW 细行展示。
            geminiWindow: hasGroupedData ? nil : geminiWindow,
            geminiWeekly: hasGroupedData ? nil : geminiWeekly,
            planType: planType,
            fetchedAt: fetchedAt
        )
        let account = AntigravityAccount(email: nil, planType: planType, source: .jetski)
        return Fetched(snapshot: snapshot, account: account)
    }

    /// 用 `access_token` 调 Google UserInfo 端点解析当前登录账号邮箱。
    /// 返回 nil 仅表示拿不到（不视为失败，邮箱不是额度链路的必需项）。
    nonisolated static func fetchAccountEmail(accessToken: String) async -> String? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let email = root["email"] as? String
        return email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? email : nil
    }

    // MARK: - Groups parser（retrieveUserQuotaSummary 权威分组；兼容旧版 language_server Summary）

    private struct GroupParsed {
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var planType: String?
    }

    /// 解析 `retrieveUserQuotaSummary` 的 `groups[]`（也兼容旧版本地 Summary 结构）：
    /// 每组含 `buckets[]`，真实响应（免费版实测）：
    /// - Gemini Models：`gemini-weekly` / `gemini-5h`
    /// - Claude and GPT models：`3p-weekly` / `3p-5h`
    /// bucketId 前缀（`gemini-*` / `3p-*`）与 `window` 字段（weekly / 5h）最准确，
    /// 组 displayName 与桶内文案仅作兼容兜底；不再按名称把整组硬编码到某个窗口。
    private static func parseGroups(_ groups: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for group in groups {
            guard let groupBuckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupName = ((group["displayName"] as? String) ?? "").lowercased()
            for bucket in groupBuckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = remainingFraction(in: bucket) else { continue }
                let id = (bucket["bucketId"] as? String ?? "").lowercased()
                let name = (bucket["displayName"] as? String ?? "").lowercased()
                let windowTag = (bucket["window"] as? String ?? "").lowercased()
                let reset = resetDate(value: bucket["resetTime"])

                // 归属判定：显式 gemini-/3p- 前缀优先；其次组 displayName；
                // 旧结构缺前缀时按默认第三方（Claude/GPT）处理，Gemini 由组名命中。
                let isGemini: Bool
                if id.hasPrefix("gemini") {
                    isGemini = true
                } else if id.hasPrefix("3p") || id.hasPrefix("third") || id.hasPrefix("claude") || id.hasPrefix("gpt") {
                    isGemini = false
                } else {
                    isGemini = groupName.contains("gemini")
                }
                let isWeekly = id.contains("week") || windowTag.contains("week") || name.contains("week")
                if isGemini {
                    if isWeekly {
                        adoptMin(&result.geminiWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    } else {
                        adoptMin(&result.geminiWindow, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
                    }
                } else if isWeekly {
                    adoptMin(&result.weekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                } else {
                    adoptMin(&result.fiveHour, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
                }
            }
        }
        return result
    }

    /// 模型桶语义化归类（区分第三方与 Gemini 不同额度组）。
    private static func bucketFamily(_ bucket: [String: Any]) -> Family {
        let model = (bucket["modelId"] as? String ?? bucket["model"] as? String ?? "").lowercased()
        let bucketID = (bucket["bucketId"] as? String ?? "").lowercased()
        if model.contains("gemini") || model.contains("tab_") || model.contains("chat_") {
            return bucketID.contains("week") || bucketID.contains("weekly") ? .geminiWeekly : .geminiWindow
        }
        if bucketID.contains("week") || bucketID.contains("weekly") { return .weekly }
        if model.contains("claude") || model.contains("gpt") || model.contains("opus") || model.contains("sonnet") { return .thirdPartyWindow }
        // 内部补齐 / 完整标记类：无真实用量窗口
        return .internalPlaceholder
    }

    private enum Family {
        case weekly
        case geminiWeekly
        case geminiWindow
        case thirdPartyWindow
        case internalPlaceholder
    }

    private static func parseBuckets(_ buckets: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for bucket in buckets {
            guard let remaining = remainingFraction(in: bucket) else { continue }
            let family = bucketFamily(bucket)
            guard family != .internalPlaceholder else { continue }
            let reset = resetDate(value: bucket["resetTime"] ?? bucket["reset_time"])
            // remaining=1 且无 reset 的未消耗桶（如新账号从未用过的模型）不是真实额度窗口，
            // 不能合成未来重置时间后当成 0% 窗口展示，直接跳过。
            if remaining >= 1.0, reset == nil { continue }
            // 语义：第三方模型一律视为 5h 轮换（实测），Gemini 轮换同理；
            // 周额度（bucketId=weekly）无标准时长信息，windowSeconds 显式给 7 天，
            // 使 kind(for:fallback:) 能正确判定 .weekly。
            switch family {
            case .weekly:
                adoptMin(&result.weekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
            case .geminiWeekly:
                adoptMin(&result.geminiWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
            case .geminiWindow:
                adoptMin(&result.geminiWindow, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
            case .thirdPartyWindow:
                adoptMin(&result.fiveHour, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
            case .internalPlaceholder:
                continue
            }
        }
        return result
    }

    private static func adoptMin(_ slot: inout QuotaWindow?, remaining: Double, reset: Date?, windowSeconds: Int?) {
        guard let existing = slot else {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
            return
        }
        // 保留最紧张窗口（remaining 最小）；并列时优先带重置时间的
        if remaining < existing.remainingPercent / 100 {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
        } else if remaining == existing.remainingPercent / 100, existing.resetsAt == nil, reset != nil {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
        }
    }

    private static func parseModels(_ models: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for m in models {
            guard let remaining = m["remainingFraction"] as? Double ?? (m["remaining_fraction"] as? Double) else { continue }
            let modelId = (m["modelId"] as? String ?? m["name"] as? String ?? "").lowercased()
            let reset = resetDate(value: m["resetTime"] ?? m["reset_time"])
            let isWeekly = modelId.contains("week")
            let windowSecs: Int = isWeekly ? 7 * 24 * 3600 : 5 * 3600
            let window = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSecs)
            if modelId.contains("gemini") {
                // 启发式：第一个 gemini 当作 5h，第二个当 weekly
                if result.geminiWindow == nil { result.geminiWindow = window } else { result.geminiWeekly = window }
            } else {
                if result.fiveHour == nil { result.fiveHour = window } else { result.weekly = window }
            }
        }
        return result
    }

    /// fetchAvailableModels 的 models 是 dict：{ "model-id": { ..., "quotaInfo": { remainingFraction, resetTime } } }
    /// quotaInfo 无窗口类型标记，按 resetTime 距当前时间推断：
    ///   ~0.6h（<2h）→ Gemini 5h 轮换窗口；~5h（≥2h）→ Claude/GPT 5h 轮换窗口。
    /// 注意：该接口的 resetTime 不是自然周窗口，周额度不在本接口（由 loadCodeAssist 或旧 groups 提供）。
    private static func parseModelsDict(_ models: [String: Any], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        // Gemini 模型组 5h 轮换窗口：取剩余比例最小（最紧张）的一个作为主额度
        // 与 GM 细行的共同来源；其余同组模型不再重复填充。
        var gemini5h: QuotaWindow?
        var gemini5hRemaining = Double.greatestFiniteMagnitude
        for (key, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            let info = entry["quotaInfo"] as? [String: Any] ?? entry
            guard let remaining = remainingFraction(in: info) else { continue }
            let modelId = key.lowercased()
            let reset = resetDate(value: info["resetTime"] ?? info["reset_time"])
            let usedPercent = max(0, min(100, 100 - remaining * 100))
            let window = QuotaWindow(usedPercent: usedPercent, resetsAt: reset, windowSeconds: nil)
            let isGemini = modelId.contains("gemini") || modelId.contains("tab_") || modelId.contains("chat_")
            // 距当前 2h 内重置 → 5h 轮换窗口；其余（如 5h 整点/缺失）不算
            let isFiveHour = reset.map { fetchedAt.timeIntervalSince($0) > -2 * 3600 } ?? false
            if isGemini {
                if isFiveHour, remaining < gemini5hRemaining {
                    gemini5hRemaining = remaining
                    gemini5h = window
                }
            } else {
                if isFiveHour { result.fiveHour = window }
            }
        }
        // Gemini 组主条 5h 与 GM 细行共用最紧张窗口；fiveHour 与 geminiWindow 都填，
        // 保证 popover 主条（primaryLimit）与 GM 细行都有数可渲染。
        if let gemini5h {
            result.fiveHour = gemini5h
            result.geminiWindow = gemini5h
        }
        return result
    }

    private static func parseQuotaDict(_ dict: [String: Any], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for (k, v) in dict {
            guard let bucket = v as? [String: Any], let remaining = remainingFraction(in: bucket) else { continue }
            let key = k.lowercased()
            let reset = resetDate(value: bucket["resetTime"] ?? bucket["reset_time"])
            let isWeekly = key.contains("week")
            let windowSecs: Int = isWeekly ? 7 * 24 * 3600 : 5 * 3600
            let window = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSecs)
            if key.contains("gemini") {
                if key.contains("week") { result.geminiWeekly = window } else { result.geminiWindow = window }
            } else {
                if key.contains("week") { result.weekly = window } else { result.fiveHour = window }
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func remainingFraction(in bucket: [String: Any]) -> Double? {
        if let v = bucket["remainingFraction"] as? Double { return v }
        if let v = bucket["remaining_fraction"] as? Double { return v }
        if let v = bucket["remaining"] as? Double { return v > 1 ? v / 100 : v }
        if let v = bucket["remainingPercent"] as? Double { return 1 - v / 100 }
        if let s = bucket["remainingFraction"] as? String, let d = Double(s) { return d }
        if let n = bucket["remainingFraction"] as? NSNumber { return n.doubleValue }
        // remainingAmount / limit 推算
        if let used = bucket["usedPercent"] as? Double { return 1 - used / 100 }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func resetDate(value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            if let n = Double(s) {
                guard n > 0 else { return nil }
                return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
            }
        }
        if let n = value as? Double {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = value as? Int {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(n) > 1e12 ? Double(n) / 1000 : Double(n))
        }
        return nil
    }

}
