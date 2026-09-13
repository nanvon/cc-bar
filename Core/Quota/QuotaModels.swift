import Foundation

nonisolated enum QuotaApp: String, Sendable, Codable, CaseIterable, Hashable {
    case codex
    case claude
    case antigravity
    case cursor
    case commandCode

    /// 对应的用量数据源；`nil` = 该服务无用量统计数据（如仅提供额度监控）。
    var usageApp: UsageApp? {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .cursor: return .cursor
        case .antigravity, .commandCode: return nil
        }
    }
}

nonisolated struct QuotaProviderDescriptor: Sendable, Hashable, Identifiable {
    let app: QuotaApp
    let title: String
    let vendor: String
    let logoName: String
    let fallback: String
    /// Popover 是否展示今日 / 本周花费。Codex 与 Claude 是本机日志估算，
    /// Cursor 是账号远端计量；三者复用同一组既有费用展示位。
    let showsCost: Bool
    let supportsMenuBar: Bool
    let supportsFloatingHUD: Bool

    var id: QuotaApp { app }

    static let allProviders: [QuotaProviderDescriptor] = [
        QuotaProviderDescriptor(
            app: .codex,
            title: "Codex",
            vendor: "OpenAI",
            logoName: "codex",
            fallback: "C",
            showsCost: true,
            supportsMenuBar: true,
            supportsFloatingHUD: true
        ),
        QuotaProviderDescriptor(
            app: .claude,
            title: "Claude Code",
            vendor: "Anthropic",
            logoName: "claude",
            fallback: "K",
            showsCost: true,
            supportsMenuBar: true,
            supportsFloatingHUD: true
        ),
        QuotaProviderDescriptor(
            app: .antigravity,
            title: "Antigravity",
            vendor: "Google",
            logoName: "antigravity",
            fallback: "A",
            showsCost: false,
            supportsMenuBar: true,
            supportsFloatingHUD: true
        ),
        QuotaProviderDescriptor(
            app: .cursor,
            title: "Cursor",
            vendor: "Cursor",
            logoName: "cursor",
            fallback: "C",
            showsCost: true,
            supportsMenuBar: true,
            supportsFloatingHUD: true
        ),
        QuotaProviderDescriptor(
            app: .commandCode,
            title: "Command Code",
            vendor: "Command Code",
            logoName: "commandcode",
            fallback: "⌘",
            showsCost: false,
            supportsMenuBar: true,
            supportsFloatingHUD: true
        ),
    ]

    /// 兼容别名，三者当前都等同于 `allProviders`——设置页账号组、Popover 与统计页
    /// 都展示全部 Provider，没有各自的子集需要过滤。真正做过滤的只有下面两个
    /// (`menuBarProviders` / `floatingProviders`，按 `supportsMenuBar` / `supportsFloatingHUD`)。
    /// 保留这三个名字是为了让调用点自我说明它在渲染哪个界面；若将来某个界面要收窄范围，
    /// 改对应的这一个即可，不必再去找调用点。
    static var primaryProviders: [QuotaProviderDescriptor] { allProviders }

    static var accountProviders: [QuotaProviderDescriptor] { allProviders }

    static var popoverProviders: [QuotaProviderDescriptor] { allProviders }

    static var menuBarProviders: [QuotaProviderDescriptor] {
        allProviders.filter(\.supportsMenuBar)
    }

    static var floatingProviders: [QuotaProviderDescriptor] {
        allProviders.filter(\.supportsFloatingHUD)
    }

    static func descriptor(for app: QuotaApp) -> QuotaProviderDescriptor? {
        allProviders.first { $0.app == app }
    }
}

nonisolated enum QuotaSnapshotSource: String, Sendable, Codable {
    case api
    case local
    case cache
    case cliFallback

    var displayName: String {
        switch self {
        case .api: return "API"
        case .local: return "本机"
        case .cache: return "缓存"
        case .cliFallback: return "Claude CLI"
        }
    }
}

nonisolated enum QuotaRefreshReason: Sendable {
    case periodic
    case userInitiated
}

nonisolated struct QuotaRefreshState: Sendable, Equatable {
    var lastSuccessAt: Date?
    var lastAttemptAt: Date?
    var backoffUntil: Date?
    var lastError: String?
    /// `lastError` 是不是网络类失败。`lastError` 只是一句展示文案,结构信息在这里留一份,
    /// 让 header 能判断"所有服务都败在网络上"并说"网络不可用",而不是笼统的"刷新失败"。
    /// 与 `lastError` 同生共死:每个 `markXxxFailure` 设值,每个 `storeXxx` 清零。
    var lastErrorIsNetwork: Bool = false
    var inFlight: Bool = false
    var source: QuotaSnapshotSource?
}

nonisolated struct PrimaryQuotaState: Sendable, Equatable {
    var snapshot: QuotaSnapshot?
    var error: String?
    var source: QuotaSnapshotSource?
    var refresh = QuotaRefreshState()
}

nonisolated struct QuotaWindow: Sendable, Equatable, Codable {
    /// 0~100，已用百分比
    var usedPercent: Double
    /// 窗口重置时间
    var resetsAt: Date?
    /// 窗口长度（秒），可空
    var windowSeconds: Int?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

nonisolated enum QuotaLimitKind: String, Sendable, Equatable, Hashable, Codable {
    case fiveHour
    case weekly
    case modelWeekly
    case unknown
}

nonisolated struct QuotaLimit: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var kind: QuotaLimitKind
    var displayName: String?
    var window: QuotaWindow
    var isActive: Bool?

    nonisolated static func standard(
        kind: QuotaLimitKind,
        window: QuotaWindow,
        displayName: String? = nil,
        isActive: Bool? = nil
    ) -> QuotaLimit {
        let id: String
        switch kind {
        case .fiveHour: id = "five-hour"
        case .weekly: id = "weekly"
        case .modelWeekly:
            id = modelID(displayName ?? "model")
        case .unknown:
            id = "unknown-\(window.windowSeconds.map { String($0) } ?? "unspecified")"
        }
        return QuotaLimit(
            id: id,
            kind: kind,
            displayName: displayName,
            window: window,
            isActive: isActive
        )
    }

    nonisolated static func model(
        id rawID: String?,
        displayName: String,
        window: QuotaWindow,
        isActive: Bool?
    ) -> QuotaLimit {
        let trimmedID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuotaLimit(
            id: trimmedID.flatMap { $0.isEmpty ? nil : "model:\($0.lowercased())" }
                ?? modelID(displayName),
            kind: .modelWeekly,
            displayName: displayName,
            window: window,
            isActive: isActive
        )
    }

    nonisolated private static func modelID(_ displayName: String) -> String {
        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "model:\(normalized.isEmpty ? "unknown" : normalized)"
    }
}

nonisolated struct QuotaSnapshot: Sendable, Equatable, Codable {
    var app: QuotaApp
    var primaryLimit: QuotaLimit?
    var secondaryLimit: QuotaLimit?
    var auxiliaryLimits: [QuotaLimit]
    var modelLimits: [QuotaLimit]
    var geminiWindow: QuotaWindow? // 仅 Antigravity
    var geminiWeekly: QuotaWindow? // 仅 Antigravity
    var isUnlimited: Bool?
    var planType: String?
    var fetchedAt: Date

    init(
        app: QuotaApp,
        primaryLimit: QuotaLimit?,
        secondaryLimit: QuotaLimit?,
        auxiliaryLimits: [QuotaLimit] = [],
        modelLimits: [QuotaLimit] = [],
        geminiWindow: QuotaWindow? = nil,
        geminiWeekly: QuotaWindow? = nil,
        isUnlimited: Bool? = nil,
        planType: String?,
        fetchedAt: Date
    ) {
        self.app = app
        self.primaryLimit = primaryLimit
        self.secondaryLimit = secondaryLimit
        self.auxiliaryLimits = auxiliaryLimits
        self.modelLimits = modelLimits
        self.geminiWindow = geminiWindow
        self.geminiWeekly = geminiWeekly
        self.isUnlimited = isUnlimited
        self.planType = planType
        self.fetchedAt = fetchedAt
    }

    var primaryWindow: QuotaWindow? { primaryLimit?.window }

    var fiveHourLimit: QuotaLimit? {
        [primaryLimit, secondaryLimit].compactMap { $0 }.first { $0.kind == .fiveHour }
    }

    var weeklyLimit: QuotaLimit? {
        [primaryLimit, secondaryLimit].compactMap { $0 }.first { $0.kind == .weekly }
    }

    /// 兼容仍按标准窗口取值的调用点；新展示入口应优先使用 primaryLimit。
    var fiveHour: QuotaWindow? { fiveHourLimit?.window }
    var weekly: QuotaWindow? { weeklyLimit?.window }

    var secondaryWindow: QuotaWindow? { secondaryLimit?.window }

    var weeklyOpus: QuotaWindow? {
        modelLimit(named: "opus")?.window
    }

    var weeklySonnet: QuotaWindow? {
        modelLimit(named: "sonnet")?.window
    }

    var allLimits: [QuotaLimit] {
        [primaryLimit, secondaryLimit].compactMap { $0 } + auxiliaryLimits + modelLimits
    }

    func preservingFutureResetDates(
        from previous: QuotaSnapshot?,
        now: Date = Date()
    ) -> QuotaSnapshot {
        guard let previous, previous.app == app else { return self }
        let previousByID = Dictionary(
            previous.allLimits.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var next = self
        next.primaryLimit = carryingReset(for: primaryLimit, previousByID: previousByID, now: now)
        next.secondaryLimit = carryingReset(for: secondaryLimit, previousByID: previousByID, now: now)
        next.auxiliaryLimits = auxiliaryLimits.map {
            carryingReset(for: $0, previousByID: previousByID, now: now) ?? $0
        }
        next.modelLimits = modelLimits.map {
            carryingReset(for: $0, previousByID: previousByID, now: now) ?? $0
        }
        // Gemini 窗口单独保活
        if next.geminiWindow?.resetsAt == nil, let prev = previous.geminiWindow, let reset = prev.resetsAt, reset > now {
            next.geminiWindow?.resetsAt = reset
        }
        if next.geminiWeekly?.resetsAt == nil, let prev = previous.geminiWeekly, let reset = prev.resetsAt, reset > now {
            next.geminiWeekly?.resetsAt = reset
        }
        return next
    }

    private func modelLimit(named fragment: String) -> QuotaLimit? {
        modelLimits.first {
            $0.displayName?.localizedCaseInsensitiveContains(fragment) == true
        }
    }

    private func carryingReset(
        for limit: QuotaLimit?,
        previousByID: [String: QuotaLimit],
        now: Date
    ) -> QuotaLimit? {
        guard var limit, limit.window.resetsAt == nil,
              let previous = previousByID[limit.id],
              previous.kind == limit.kind,
              let reset = previous.window.resetsAt,
              reset > now
        else { return limit }
        limit.window.resetsAt = reset
        return limit
    }

    private enum CodingKeys: String, CodingKey {
        case app
        case primaryLimit
        case secondaryLimit
        case auxiliaryLimits
        case modelLimits
        case geminiWindow
        case geminiWeekly
        case isUnlimited
        case planType
        case fetchedAt
        // v2 及更早缓存字段。
        case fiveHour
        case weekly
        case weeklyOpus
        case weeklySonnet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(QuotaApp.self, forKey: .app)
        isUnlimited = try container.decodeIfPresent(Bool.self, forKey: .isUnlimited)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        geminiWindow = try container.decodeIfPresent(QuotaWindow.self, forKey: .geminiWindow)
        geminiWeekly = try container.decodeIfPresent(QuotaWindow.self, forKey: .geminiWeekly)

        if container.contains(.primaryLimit)
            || container.contains(.secondaryLimit)
            || container.contains(.auxiliaryLimits)
            || container.contains(.modelLimits)
        {
            primaryLimit = try container.decodeIfPresent(QuotaLimit.self, forKey: .primaryLimit)
            secondaryLimit = try container.decodeIfPresent(QuotaLimit.self, forKey: .secondaryLimit)
            auxiliaryLimits = try container.decodeIfPresent([QuotaLimit].self, forKey: .auxiliaryLimits) ?? []
            modelLimits = try container.decodeIfPresent([QuotaLimit].self, forKey: .modelLimits) ?? []
            return
        }

        let legacyFiveHour = try container.decodeIfPresent(QuotaWindow.self, forKey: .fiveHour)
        let legacyWeekly = try container.decodeIfPresent(QuotaWindow.self, forKey: .weekly)
        let assumedPrimaryKind: QuotaLimitKind = app == .codex ? .unknown : .fiveHour
        primaryLimit = legacyFiveHour.map {
            QuotaLimit.standard(kind: Self.kind(for: $0, fallback: assumedPrimaryKind), window: $0)
        }
        secondaryLimit = legacyWeekly.map {
            QuotaLimit.standard(kind: Self.kind(for: $0, fallback: .weekly), window: $0)
        }
        if primaryLimit == nil, let secondaryLimit {
            primaryLimit = secondaryLimit
            self.secondaryLimit = nil
        }

        auxiliaryLimits = []
        modelLimits = []
        if let opus = try container.decodeIfPresent(QuotaWindow.self, forKey: .weeklyOpus) {
            modelLimits.append(.model(id: nil, displayName: "Opus", window: opus, isActive: nil))
        }
        if let sonnet = try container.decodeIfPresent(QuotaWindow.self, forKey: .weeklySonnet) {
            modelLimits.append(.model(id: nil, displayName: "Sonnet", window: sonnet, isActive: nil))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encodeIfPresent(primaryLimit, forKey: .primaryLimit)
        try container.encodeIfPresent(secondaryLimit, forKey: .secondaryLimit)
        try container.encode(auxiliaryLimits, forKey: .auxiliaryLimits)
        try container.encode(modelLimits, forKey: .modelLimits)
        try container.encodeIfPresent(geminiWindow, forKey: .geminiWindow)
        try container.encodeIfPresent(geminiWeekly, forKey: .geminiWeekly)
        try container.encodeIfPresent(isUnlimited, forKey: .isUnlimited)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encode(fetchedAt, forKey: .fetchedAt)
    }

    nonisolated static func kind(
        for window: QuotaWindow,
        fallback: QuotaLimitKind = .unknown
    ) -> QuotaLimitKind {
        switch window.windowSeconds {
        case 5 * 60 * 60: return .fiveHour
        case 7 * 24 * 60 * 60: return .weekly
        default: return fallback
        }
    }
}

/// 网络层失败的成因。
///
/// 存在的理由:`URLError` 直接插值进字符串会得到
/// `URLError(_nsError: Error Domain=NSURLErrorDomain Code=-1009 "…" UserInfo={…})`
/// 这种调试转储,Popover 截断后只剩一截乱码,用户既看不出是断网还是账号问题。
/// 把它在**产生错误的地方**收敛成有限几类,UI 才能给出一句人话。
nonisolated enum NetworkFailureKind: String, Sendable, Equatable, Codable {
    /// 本机没有网络。
    case offline
    /// 连不上目标主机:代理断线、端口不通、DNS 解析失败。代理挂掉最常落在这里。
    case cannotConnect
    /// 超时。代理进程还在、但不再转发流量时最常见。
    case timedOut
    /// TLS 握手失败。中间人代理的证书未被系统信任时会走到这里。
    case tls
    /// 其余 `URLError`,以及非 `URLError` 的传输失败。
    case other

    nonisolated init(_ code: URLError.Code) {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .dnsLookupFailed, .resourceUnavailable:
            self = .cannotConnect
        case .timedOut:
            self = .timedOut
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .tls
        default:
            self = .other
        }
    }
}

nonisolated enum QuotaError: Error, CustomStringConvertible {
    case missingToken
    case http(Int, String)
    /// 网络不可达一类的失败,见 `NetworkFailureKind`。
    case network(NetworkFailureKind)
    /// 非网络的传输失败(子进程、URL 构造等本地环节)。网络失败一律走 `.network`。
    case transport(String)
    case decode(String)
    case tokenRefreshFailed(String)
    /// 本地存着的 access_token 已过期,且 cc-bar 不会自己去刷新
    /// (刷新会作废 Claude Code 手里的 refresh_token,把用户挤下线,
    /// 详见 `ClaudeTokenRefresher` 的说明)。
    /// 需要用户打开 Claude Code / 运行 `claude`,由它刷新登录态。
    case credentialsExpired

    var description: String {
        switch self {
        case .missingToken: return "missing access token"
        case .http(let code, let msg): return "http \(code): \(msg)"
        case .network(let kind): return "network: \(kind.rawValue)"
        case .transport(let msg): return "transport: \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .tokenRefreshFailed(let msg): return "token refresh failed: \(msg)"
        case .credentialsExpired:
            return "claude credentials expired; waiting for Claude Code to refresh"
        }
    }

    /// 把 `URLSession` 抛出的错误收敛成 `QuotaError`。
    /// 所有取数 / 续期链路的 `catch` 都应走这里,不要再把原始 error 插值成字符串。
    nonisolated static func from(transport error: Error) -> QuotaError {
        guard let urlError = error as? URLError else { return .network(.other) }
        return .network(NetworkFailureKind(urlError.code))
    }

    var httpStatusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var isRateLimited: Bool {
        httpStatusCode == 429
    }

    var isAuthFailure: Bool {
        httpStatusCode == 401 || httpStatusCode == 403
    }

    /// 是否为"需要用户去 Claude Code 刷新登录态"级别的失败。
    /// UI 可据此降级提示文案;取数侧可据此走 CLI 兜底。
    var isCredentialsExpired: Bool {
        if case .credentialsExpired = self { return true }
        return false
    }

    /// 是否为网络不可达一类的失败(断网、代理断线、超时、TLS)。
    var isNetworkFailure: Bool {
        if case .network = self { return true }
        return false
    }

    /// HTTP 错误体看起来是 HTML 页面而不是 API 的 JSON 回应。
    ///
    /// 企业代理登录页、网关 502 页面都长这样。此时 401 / 403 说明的是
    /// "请求没走到 API",而不是"账号真的失效了"——不能据此提示用户重新登录。
    var looksLikeInterceptedResponse: Bool {
        guard case .http(_, let body) = self else { return false }
        let head = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(200)
            .lowercased()
        guard !head.isEmpty else { return false }
        return head.hasPrefix("<") || head.contains("<html") || head.contains("<!doctype")
    }
}

// MARK: - 用户可见文案
//
// 分层:`description` 是技术串,只进日志与调试;UI 一律用 `userMessage`。
// 见 docs/界面布局.md §1.4.5。
//
// 旧实现把 `err.description` 直接塞进 Popover,于是断网时用户看到的是
// `transport: URLError(_nsError: Error Domain=NSURLErro…`——既不可读,也分不清
// 到底是网络问题还是账号问题。

@MainActor
extension NetworkFailureKind {
    var userMessage: String {
        switch self {
        case .offline:
            return tr("No network connection", "网络未连接")
        case .cannotConnect:
            return tr(
                "Can't reach the service — check your network or proxy",
                "连不上服务,请检查网络或代理"
            )
        case .timedOut:
            return tr(
                "Connection timed out — check your network or proxy",
                "连接超时,请检查网络或代理"
            )
        case .tls:
            // 不提 TLS / 握手 / 证书:那是协议术语。用户能做的就是检查代理,
            // 而中间人代理的证书没被系统信任正是这一档最常见的成因。
            return tr(
                "Secure connection failed — check your proxy settings",
                "安全连接失败,请检查代理设置"
            )
        case .other:
            return tr("Network connection failed", "网络连接失败")
        }
    }
}

@MainActor
extension QuotaError {
    /// Popover / 其他账号行展示用的一句话。短、可读、双语,不含技术细节。
    var userMessage: String {
        switch self {
        case .missingToken:
            return tr("Not signed in", "未登录")
        case .credentialsExpired:
            return tr(
                "Sign-in expired — open Claude Code to sign in again",
                "登录已过期,请打开 Claude Code 重新登录"
            )
        case .network(let kind):
            return kind.userMessage
        case .http(let code, _):
            return Self.httpMessage(code: code, intercepted: looksLikeInterceptedResponse)
        case .decode:
            return tr("Got an unreadable response", "返回的数据无法识别")
        case .tokenRefreshFailed:
            // 不说"令牌":那是实现词。失败在哪一步(没有 refresh_token / 响应里
            // 没有 access_token / 候选 client 全失败)对用户没有可操作性,细节留在
            // description 与日志里。也不直接写"请重新登录"——刷新端点临时 5xx
            // 也会走到这里,那时让用户去重新登录是白折腾。
            return tr("Couldn't renew your sign-in", "登录续期失败")
        case .transport:
            return tr("Couldn't fetch the data", "获取数据失败")
        }
    }

    /// 状态码只在**兜底的未知档**露出来——那时它是唯一线索。401 / 429 / 5xx 这些
    /// 常见档对用户没有信息量,完整的 `http {code}: {body}` 本来就在 description
    /// 和日志里,不必占用 Popover 里那一行。
    private static func httpMessage(code: Int, intercepted: Bool) -> String {
        if intercepted {
            return tr(
                "Blocked by a network proxy — check your proxy settings",
                "被网络代理拦截,请检查代理设置"
            )
        }
        switch code {
        case 429:
            return tr("Too many requests — try again later", "请求过于频繁,请稍后再试")
        case 401, 403:
            return tr("Sign-in is no longer valid — sign in again", "登录已失效,请重新登录")
        case 500...599:
            return tr("Service is temporarily unavailable", "服务暂时不可用,请稍后再试")
        default:
            return tr("Request failed (HTTP \(code))", "获取失败(HTTP \(code))")
        }
    }
}
