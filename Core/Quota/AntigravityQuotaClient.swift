import Foundation

/// Antigravity 额度客户端：纯原生 HTTPS 直连 Google Cloud Code 接口，不启动 `agy` 子进程。
///
/// 每轮正常只发一个请求：daily 域 `retrieveUserQuotaSummary`。`loadCodeAssist`（project 与套餐）
/// 按登录缓存 `setupTTL`，缓存的 project 被拒时同轮重查一次。daily 返回的分组缺少该账号已知的桶时
/// 才补查主域 `cloudcode-pa.googleapis.com`；两域都没有分组时读 `retrieveUserQuota` 的 quota 桶。
/// 使用 `AntigravityCredentials` 读取的 `access_token` 作为 `Bearer`，携带 CLI 客户端标识的
/// `User-Agent` 后可拿到完整分组（含 Argon / Carbon 独立周额度、Gemini 5h/周、Claude+GPT 5h/周）。
nonisolated enum AntigravityQuotaClient {
    static let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let dailyEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    /// 取数结果，附带账号订阅层级与本轮使用的 `loadCodeAssist` 结果（供调用方缓存）。
    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var account: AntigravityAccount
        var setup: Setup?
    }

    /// `loadCodeAssist` 的有效结果：project 与套餐几小时内不变，按登录缓存，避免每轮多打一个请求。
    struct Setup: Sendable, Equatable {
        var project: String?
        var planType: String?
        var fetchedAt: Date

        func isFresh(now: Date) -> Bool {
            let age = now.timeIntervalSince(fetchedAt)
            return age >= 0 && age < AntigravityQuotaClient.setupTTL
        }
    }

    static let setupTTL: TimeInterval = 6 * 60 * 60

    /// 没有历史快照时用来判断 daily 分组是否完整的核心桶；有历史快照时改用上次实际见过的桶。
    static let coreGroupedLimitIDs: Set<String> = ["gemini-5h", "gemini-weekly", "claude-5h", "claude-weekly"]

    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // 携带 antigravity/cli 客户端标识与 cl 参数后，Cloud Code 会返回包含 Argon 独立周额度在内的完整分组。
    static let cloudUserAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/cli/1.5.13 (aidev_client; os_type=darwin; arch=\(arch); cl=1025641825; auth_method=consumer)"
    }()

    static let clientMetadata: [String: String] = [
        "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI",
    ]

    /// - Parameters:
    ///   - cachedSetup: 上次的 `loadCodeAssist` 结果，过期（`setupTTL`）则重查。
    ///   - expectedLimitIDs: 该账号上次实际返回的桶 ID；daily 缺其中任意一个才补查主域。为空时用核心四组。
    nonisolated static func fetch(
        accessToken: String,
        cachedSetup: Setup? = nil,
        expectedLimitIDs: Set<String> = [],
        dataLoader: @escaping DataLoader = { try await NetworkProxy.data(for: $0) }
    ) async -> Result<Fetched, QuotaError> {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.missingToken) }
        let fetchedAt = Date()
        let expected = expectedLimitIDs.isEmpty ? coreGroupedLimitIDs : expectedLimitIDs
        var setup = cachedSetup.flatMap { $0.isFresh(now: fetchedAt) ? $0 : nil }
        var setupFromCache = setup != nil
        var lastError: QuotaError = .decode("Antigravity returned no measured quota")
        let domains = [dailyEndpoint, endpoint]

        // 1. 分组额度：daily 优先；只有缺少已知桶时才补查主域，按稳定桶 ID 补缺，不覆盖已取得的值。
        var grouped: Fetched?
        var index = 0
        while index < domains.count {
            let baseURL = domains[index]
            if setup == nil {
                switch await loadSetup(baseURL: baseURL, token: token, fetchedAt: fetchedAt, dataLoader: dataLoader) {
                case .loaded(let value):
                    setup = value
                case .rejected:
                    return .failure(.http(403, "Antigravity OAuth client cannot read this account's quota"))
                case .failed(let error):
                    if error.httpStatusCode == 401 || error.isRateLimited { return .failure(error) }
                    lastError = error
                    index += 1
                    continue
                }
            }
            let summary = await cloudRequest(baseURL: baseURL, method: "retrieveUserQuotaSummary", token: token,
                                             body: requestBody(setup), dataLoader: dataLoader)
            switch summary {
            case .success(let value):
                let parsed = parse(root: value, fetchedAt: fetchedAt)
                if !parsed.snapshot.allLimits.isEmpty {
                    grouped = grouped.map { mergeGrouped(base: $0, enrichment: parsed) } ?? parsed
                }
            case .failure(let error):
                // 429 不允许被补查吞掉后继续请求其它域名。
                if error.httpStatusCode == 401 || error.isRateLimited { return .failure(error) }
                if setupFromCache, [400, 403, 404].contains(error.httpStatusCode ?? 0) {
                    // 缓存的 project 可能已失效：同一域重查一次 loadCodeAssist 再试。
                    setup = nil
                    setupFromCache = false
                    continue
                }
                lastError = error
            }
            if let grouped, Set(grouped.snapshot.allLimits.map(\.id)).isSuperset(of: expected) { break }
            index += 1
        }
        if let grouped { return .success(finishing(grouped, setup: setup)) }

        // 2. 没有分组源时读 retrieveUserQuota 的 quota 桶（语义明确的桶，不按模型列表猜窗口）。
        for baseURL in domains {
            let result = await cloudRequest(baseURL: baseURL, method: "retrieveUserQuota", token: token,
                                            body: requestBody(setup), dataLoader: dataLoader)
            switch result {
            case .success(let value):
                let parsed = parse(root: value, fetchedAt: fetchedAt)
                if !parsed.snapshot.allLimits.isEmpty { return .success(finishing(parsed, setup: setup)) }
            case .failure(let error):
                if error.httpStatusCode == 401 || error.isRateLimited { return .failure(error) }
                lastError = error
            }
        }
        return .failure(lastError)
    }

    private enum SetupResult {
        case loaded(Setup)
        /// 明确拒绝当前 OAuth client 读取该账号额度。
        case rejected
        case failed(QuotaError)
    }

    private static func loadSetup(
        baseURL: URL, token: String, fetchedAt: Date, dataLoader: DataLoader
    ) async -> SetupResult {
        switch await cloudRequest(baseURL: baseURL, method: "loadCodeAssist", token: token,
                                  body: ["metadata": clientMetadata], dataLoader: dataLoader) {
        case .success(let root):
            if rejectsConsumerClient(root) { return .rejected }
            return .loaded(Setup(project: projectID(in: root),
                                 planType: parse(root: root, fetchedAt: fetchedAt).snapshot.planType,
                                 fetchedAt: fetchedAt))
        case .failure(let error):
            return .failed(error)
        }
    }

    private static func requestBody(_ setup: Setup?) -> [String: Any] {
        setup?.project.map { ["project": $0] } ?? [:]
    }

    /// 套餐以 loadCodeAssist 的结果为准，缺失时保留额度响应里的值。
    private static func finishing(_ fetched: Fetched, setup: Setup?) -> Fetched {
        var result = fetched
        result.snapshot.planType = setup?.planType ?? fetched.snapshot.planType
        result.account.planType = result.snapshot.planType
        result.setup = setup
        return result
    }

    static func projectID(in root: [String: Any]) -> String? {
        let value = root["cloudaicompanionProject"]
        let raw = value as? String ?? (value as? [String: Any])?["id"] as? String
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func rejectsConsumerClient(_ root: [String: Any]) -> Bool {
        guard root["currentTier"] == nil, projectID(in: root) == nil else { return false }
        return (root["ineligibleTiers"] as? [[String: Any]] ?? []).contains {
            ($0["reasonCode"] as? String ?? $0["reason"] as? String) == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"
        }
    }

    private static let groupedLimitOrder = [
        "gemini-5h", "gemini-weekly", "gemini-carbon-wtu-weekly", "claude-5h", "claude-weekly", "gemini-argon-wtu-weekly",
    ]

    private static func assigningGroupedLimits(_ limits: [QuotaLimit], onto snapshot: inout QuotaSnapshot) {
        let sorted = limits.sorted {
            (groupedLimitOrder.firstIndex(of: $0.id) ?? 99) < (groupedLimitOrder.firstIndex(of: $1.id) ?? 99)
        }
        snapshot.primaryLimit = sorted.first
        snapshot.secondaryLimit = sorted.dropFirst().first
        snapshot.auxiliaryLimits = Array(sorted.dropFirst(2))
    }

    static func mergeGrouped(base: Fetched, enrichment: Fetched) -> Fetched {
        var limits = base.snapshot.allLimits
        let existing = Set(limits.map(\.id))
        limits.append(contentsOf: enrichment.snapshot.allLimits.filter { !existing.contains($0.id) })
        var result = base
        assigningGroupedLimits(limits, onto: &result.snapshot)
        result.snapshot.planType = base.snapshot.planType ?? enrichment.snapshot.planType
        result.account.planType = result.snapshot.planType
        return result
    }

    /// 兼容旧缓存中仍把 Argon 放在 primaryLimit 的快照，按当前分组展示顺序重排。
    static func reorderedGroupedSnapshot(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        guard snapshot.app == .antigravity,
              snapshot.primaryLimit?.id == "gemini-argon-wtu-weekly"
        else { return snapshot }
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 } + snapshot.auxiliaryLimits
        guard limits.count > 1 else { return snapshot }
        var updated = snapshot
        assigningGroupedLimits(limits, onto: &updated)
        return updated
    }

    private static func cloudRequest(
        baseURL: URL, method: String, token: String, body: [String: Any], dataLoader: DataLoader
    ) async -> Result<[String: Any], QuotaError> {
        let url = URL(string: baseURL.absoluteString.replacingOccurrences(of: "loadCodeAssist", with: method))!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cloudUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, String(data: data, encoding: .utf8) ?? "Antigravity request failed"))
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.decode("Antigravity response is not a JSON object"))
            }
            return .success(root)
        } catch { return .failure(.from(transport: error)) }
    }

    // MARK: - Parse

    nonisolated static func parse(root: [String: Any], fetchedAt: Date = Date()) -> Fetched {
        let root = root["response"] as? [String: Any] ?? root
        // 1. 尝试新版 loadCodeAssist 的 tier 结构
        // 典型字段：currentTier, paidTier, allowedTiers, project
        // 若包含显式额度 buckets（retrieveUserQuota 兜底），则走 buckets
        var fiveHour: QuotaWindow?   // 非分组源（retrieveUserQuota 兜底）的 5h
        var weekly: QuotaWindow?     // 非分组源兜底的 weekly
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var argonWeekly: QuotaWindow?
        var carbonWeekly: QuotaWindow?
        var claude5h: QuotaWindow?   // 仅 retrieveUserQuotaSummary 分组源（3p-5h）
        var claudeWeekly: QuotaWindow? // 仅 retrieveUserQuotaSummary 分组源（3p-weekly）
        var planType: String?
        var hasGroupedData = false   // 是否拿到 retrieveUserQuotaSummary 的分组数据

        // Google AI 订阅身份在 paidTier；Pro 账号仍可能同时返回 currentTier=free-tier，
        // 后者是基础 Code Assist 层级，不能覆盖付费订阅。展示优先用官方套餐名。
        if let paid = root["paidTier"] as? [String: Any],
           let paidPlan = paidTierPlanName(paid)
        {
            planType = paidPlan
        } else if let cur = root["currentTier"] as? [String: Any], let id = cur["id"] as? String {
            planType = tierPlanName(id)
        } else if let cur = root["currentTier"] as? String {
            planType = tierPlanName(cur)
        } else if let allowed = root["allowedTiers"] as? [[String: Any]], let first = allowed.first, let id = first["id"] as? String {
            planType = tierPlanName(id)
        } else if let tier = root["tier"] as? [String: Any], let id = tier["id"] as? String {
            planType = tierPlanName(id)
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
            argonWeekly = parsed.argonWeekly
            carbonWeekly = parsed.carbonWeekly
            hasGroupedData = parsed.fiveHour != nil || parsed.weekly != nil
                || parsed.geminiWindow != nil || parsed.geminiWeekly != nil || argonWeekly != nil
                || carbonWeekly != nil
            if planType == nil { planType = parsed.planType }
        }

        // 3. 若包含 "quota" / "buckets"（retrieveUserQuota）
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
            // 新解析值非 nil 时覆盖旧值；
            // buckets 缺某个窗口（nil）时保留 quotaInfo 解析出的旧值。
            fiveHour = parsed.fiveHour ?? fiveHour
            weekly = parsed.weekly ?? weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? geminiWeekly
        }
        // 模型列表（fetchAvailableModels 的 models / availableModels）没有窗口类型标记，只能按顺序或重置时间猜，
        // 猜错会显示语义错误的数字，因此不解析；分组与 quota 桶都没有时按失败处理并保留旧快照。
        // 4. 若仍无窗，尝试从 currentTier 的 quotaInfo（保留只在此分支填，避免覆盖前序结果）
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
        // 分组源固定顺序：Gemini 5h / weekly → Carbon 周（存在时）→ Claude 5h / weekly → Argon 周（存在时）。
        // 前两条分别落 primary / secondary，其余进入 auxiliary；不把 Argon / Carbon 合入普通 Gemini 周额度。
        // Argon 排在整组末尾，只在没有其它分组窗口时才落到主条。
        // - 无分组源（quota 桶）时：优先 5h 主条，weekly 作副条。
        // 分组源数据优先：即便兜底（buckets/models）也填了 5h，也不覆盖分组语义。
        let primaryLimit: QuotaLimit?
        let secondaryLimit: QuotaLimit?
        let auxiliaryLimits: [QuotaLimit]
        if hasGroupedData {
            var limits: [QuotaLimit] = []
            if let geminiWindow {
                limits.append(QuotaLimit(id: "gemini-5h", kind: .fiveHour, displayName: "Gemini 5H", window: geminiWindow, isActive: nil))
            }
            if let geminiWeekly {
                limits.append(QuotaLimit(id: "gemini-weekly", kind: .weekly, displayName: "Gemini WK", window: geminiWeekly, isActive: nil))
            }
            if let carbonWeekly {
                limits.append(QuotaLimit(id: "gemini-carbon-wtu-weekly", kind: .modelWeekly, displayName: "Gemini 4 Carbon", window: carbonWeekly, isActive: nil))
            }
            if let claude5h { limits.append(QuotaLimit(id: "claude-5h", kind: .fiveHour, displayName: "Claude 5H", window: claude5h, isActive: nil)) }
            if let claudeWeekly { limits.append(QuotaLimit(id: "claude-weekly", kind: .weekly, displayName: "Claude WK", window: claudeWeekly, isActive: nil)) }
            if let argonWeekly {
                limits.append(QuotaLimit(id: "gemini-argon-wtu-weekly", kind: .modelWeekly, displayName: "Gemini 4 Argon", window: argonWeekly, isActive: nil))
            }
            primaryLimit = limits.first
            secondaryLimit = limits.dropFirst().first
            auxiliaryLimits = Array(limits.dropFirst(2))
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
            // 非分组 quota 桶兜底仍保留 geminiWindow/geminiWeekly 供 GM/GW 细行展示。
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
        guard let (data, resp) = try? await NetworkProxy.data(for: req),
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
        var argonWeekly: QuotaWindow?
        var carbonWeekly: QuotaWindow?
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
                      let remaining = remainingFraction(in: bucket), remaining.isFinite,
                      (0...1).contains(remaining) else { continue }
                let id = (bucket["bucketId"] as? String ?? "").lowercased()
                let name = (bucket["displayName"] as? String ?? "").lowercased()
                let windowTag = (bucket["window"] as? String ?? "").lowercased()
                let reset = resetDate(value: bucket["resetTime"])

                if id == "gemini-argon-wtu-weekly" {
                    adoptMin(&result.argonWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    continue
                }
                // Carbon 的独立周额度（cockpit-tools 已识别该桶 ID），同样不能按前缀并入普通 Gemini 周池。
                if id == "gemini-carbon-wtu-weekly" {
                    adoptMin(&result.carbonWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    continue
                }

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

    /// 免费层 id 为 `free-tier`，官方名是「Antigravity Starter Quota」（paidTier）或「Antigravity」
    /// （currentTier），都看不出是免费层，统一显示 Free；其他层级保持原值。
    private static func tierPlanName(_ id: String) -> String {
        id == "free-tier" ? "Free" : id
    }

    private static func paidTierPlanName(_ tier: [String: Any]) -> String? {
        if let id = nonEmpty(tier["id"] as? String), id == "free-tier" { return tierPlanName(id) }
        return nonEmpty(tier["name"] as? String) ?? nonEmpty(tier["id"] as? String)
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
