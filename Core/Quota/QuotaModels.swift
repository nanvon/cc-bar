import Foundation

nonisolated enum QuotaApp: String, Sendable, Codable, CaseIterable, Hashable {
    case codex
    case claude
    case antigravity
    case cursor
    case commandCode

    /// 对应的本地用量数据源；`nil` = 该服务没有可解析的本地日志。
    var usageApp: UsageApp? {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .antigravity, .cursor, .commandCode: return nil
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

nonisolated enum QuotaError: Error, CustomStringConvertible {
    case missingToken
    case http(Int, String)
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
        case .transport(let msg): return "transport: \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .tokenRefreshFailed(let msg): return "token refresh failed: \(msg)"
        case .credentialsExpired:
            return "Claude 凭据已过期,请打开 Claude Code(或在终端运行 claude)刷新登录后再回来"
        }
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
}
