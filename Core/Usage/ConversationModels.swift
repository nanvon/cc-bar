import Foundation

nonisolated enum ConversationProjectStatus: String, Sendable, Codable, Equatable {
    case available
    case unavailable
    /// 路径落在 TCC 保护目录（桌面/文稿等）或家目录之外，按隐私规则跳过文件系统验证。
    case unverified
    case unassigned
    case system

    /// 有真实路径身份、可按名称参与分组与去重的状态。
    var isPathBased: Bool {
        switch self {
        case .available, .unavailable, .unverified: return true
        case .unassigned, .system: return false
        }
    }
}

nonisolated enum ConversationProjectSource: String, Sendable, Codable, Equatable {
    case claudeHistory
    case gitRoot
    case cwd
    case systemRule
    case unassigned

    var priority: Int {
        switch self {
        case .claudeHistory: return 4
        case .gitRoot: return 3
        case .cwd: return 2
        case .systemRule: return 1
        case .unassigned: return 0
        }
    }
}

nonisolated struct ConversationProject: Sendable, Codable, Equatable {
    var key: String
    var name: String
    var path: String
    var status: ConversationProjectStatus
    var source: ConversationProjectSource

    static let unassigned = ConversationProject(
        key: "special:unassigned",
        name: "",
        path: "",
        status: .unassigned,
        source: .unassigned
    )
}

/// Scanner 发现的对话静态信息；同一对话可从多个源文件补全。
nonisolated struct ConversationSeed: Sendable, Equatable {
    var key: String
    var id: String
    var app: UsageApp
    var title: String?
    var project: ConversationProject
    var gitBranch: String?
    var sourcePath: String
    var includesSubtasks: Bool
    var cacheCreationAvailable: Bool
}

/// 持久化的对话档案。不保存消息正文，只保存最多 80 字的标题摘要。
nonisolated struct ConversationInfo: Sendable, Codable, Equatable, Identifiable {
    var key: String
    var conversationID: String
    var app: UsageApp
    var title: String?
    var projectKey: String
    var projectName: String
    var projectPath: String
    var projectStatus: ConversationProjectStatus
    var projectSource: ConversationProjectSource
    var gitBranch: String?
    var sourcePaths: [String]
    var firstAt: Date
    var lastAt: Date
    var includesSubtasks: Bool
    var cacheCreationAvailable: Bool

    var id: String { key }
}

/// (对话, 天, 模型, speed) 聚合桶；列表按范围过滤，详情聚合该对话全部桶。
nonisolated struct ConversationUsageBucket: Sendable, Codable, Equatable {
    var conversationKey: String
    var app: UsageApp
    var day: Date
    var model: String
    var speed: UsageSpeed
    var firstAt: Date
    var lastAt: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int
    var costUSD: Decimal
    var inputCostUSD: Decimal
    var outputCostUSD: Decimal
    var cacheReadCostUSD: Decimal
    var cacheCreationCostUSD: Decimal
    var hasUnpricedUsage: Bool

    enum CodingKeys: String, CodingKey {
        case conversationKey, app, day, model, speed, firstAt, lastAt
        case inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, requestCount
        case costUSD, inputCostUSD, outputCostUSD, cacheReadCostUSD, cacheCreationCostUSD
        case hasUnpricedUsage
    }

    init(
        conversationKey: String,
        app: UsageApp,
        day: Date,
        model: String,
        speed: UsageSpeed,
        firstAt: Date,
        lastAt: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        requestCount: Int,
        costUSD: Decimal,
        inputCostUSD: Decimal,
        outputCostUSD: Decimal,
        cacheReadCostUSD: Decimal,
        cacheCreationCostUSD: Decimal,
        hasUnpricedUsage: Bool
    ) {
        self.conversationKey = conversationKey
        self.app = app
        self.day = day
        self.model = model
        self.speed = speed
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.requestCount = requestCount
        self.costUSD = costUSD
        self.inputCostUSD = inputCostUSD
        self.outputCostUSD = outputCostUSD
        self.cacheReadCostUSD = cacheReadCostUSD
        self.cacheCreationCostUSD = cacheCreationCostUSD
        self.hasUnpricedUsage = hasUnpricedUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationKey = try c.decode(String.self, forKey: .conversationKey)
        app = try c.decode(UsageApp.self, forKey: .app)
        day = try c.decode(Date.self, forKey: .day)
        model = try c.decode(String.self, forKey: .model)
        speed = try c.decode(UsageSpeed.self, forKey: .speed)
        firstAt = try c.decode(Date.self, forKey: .firstAt)
        lastAt = try c.decode(Date.self, forKey: .lastAt)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        requestCount = try c.decode(Int.self, forKey: .requestCount)
        costUSD = Decimal(plainString: try c.decode(String.self, forKey: .costUSD)) ?? 0
        inputCostUSD = Decimal(plainString: try c.decode(String.self, forKey: .inputCostUSD)) ?? 0
        outputCostUSD = Decimal(plainString: try c.decode(String.self, forKey: .outputCostUSD)) ?? 0
        cacheReadCostUSD = Decimal(plainString: try c.decode(String.self, forKey: .cacheReadCostUSD)) ?? 0
        cacheCreationCostUSD = Decimal(plainString: try c.decode(String.self, forKey: .cacheCreationCostUSD)) ?? 0
        hasUnpricedUsage = try c.decode(Bool.self, forKey: .hasUnpricedUsage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationKey, forKey: .conversationKey)
        try c.encode(app, forKey: .app)
        try c.encode(day, forKey: .day)
        try c.encode(model, forKey: .model)
        try c.encode(speed, forKey: .speed)
        try c.encode(firstAt, forKey: .firstAt)
        try c.encode(lastAt, forKey: .lastAt)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(requestCount, forKey: .requestCount)
        try c.encode(costUSD.asPlainString, forKey: .costUSD)
        try c.encode(inputCostUSD.asPlainString, forKey: .inputCostUSD)
        try c.encode(outputCostUSD.asPlainString, forKey: .outputCostUSD)
        try c.encode(cacheReadCostUSD.asPlainString, forKey: .cacheReadCostUSD)
        try c.encode(cacheCreationCostUSD.asPlainString, forKey: .cacheCreationCostUSD)
        try c.encode(hasUnpricedUsage, forKey: .hasUnpricedUsage)
    }
}

nonisolated struct ConversationCostTotals: Sendable, Equatable {
    var input: Decimal = 0
    var output: Decimal = 0
    var cacheRead: Decimal = 0
    var cacheCreation: Decimal = 0
    var hasUnpricedUsage = false

    var total: Decimal { input + output + cacheRead + cacheCreation }
}

nonisolated struct ConversationSummary: Sendable, Equatable, Identifiable {
    var info: ConversationInfo
    var totals: UsageTotals
    var costs: ConversationCostTotals
    var speed: UsageSpeedBreakdown
    var models: [String]
    var rangeLastAt: Date

    var id: String { info.key }
}

nonisolated struct ConversationProjectOption: Sendable, Equatable, Identifiable {
    var key: String
    var name: String
    var path: String
    var status: ConversationProjectStatus
    var conversationCount: Int
    var lastAt: Date

    var id: String { key }
}

nonisolated enum ConversationQuerySort: String, Sendable, Hashable, CaseIterable, Identifiable {
    case recent
    case tokens
    case cost

    var id: String { rawValue }
}

nonisolated struct ConversationQueryRequest: Sendable, Hashable {
    var revision: UInt64
    var app: UsageApp?
    var projectKey: String?
    var from: Date
    var to: Date
    var search: String
    var sort: ConversationQuerySort
}

nonisolated struct ConversationQueryResult: Sendable {
    var rows: [ConversationSummary]
    var projectOptions: [ConversationProjectOption]
    var projectConversationCount: Int
    var projectKeys: Set<String>
    var duplicateProjectNames: Set<String>

    static let empty = ConversationQueryResult(
        rows: [],
        projectOptions: [],
        projectConversationCount: 0,
        projectKeys: [],
        duplicateProjectNames: []
    )
}

nonisolated struct ConversationModelSummary: Sendable, Equatable, Identifiable {
    var model: String
    var totals: UsageTotals
    var costs: ConversationCostTotals
    var speed: UsageSpeedBreakdown
    var id: String { model }
}

nonisolated struct ConversationDetail: Sendable, Equatable {
    var info: ConversationInfo
    var totals: UsageTotals
    var costs: ConversationCostTotals
    var speed: UsageSpeedBreakdown
    var models: [ConversationModelSummary]
}

/// 把日志 cwd 归一为稳定项目身份。每次扫描只对少量唯一原始路径做文件系统检查。
///
/// 隐私分级：只有家目录以内、且不在 TCC 保护目录（桌面/文稿/下载/音乐/图片/影片）
/// 之下的路径才允许做存在性检查与 git root 探测；其余路径（含可移动卷、网络宗卷、
/// 其他用户目录）只按字符串归组（status = .unverified）。非沙盒 App 访问这些路径
/// 会触发系统“文件与文件夹”授权弹窗，惊扰用户且并无收益。
nonisolated struct ConversationProjectResolver {
    /// 全部小写：`allowsFileSystemCheck` 会先把路径分量小写化再比对，
    /// 这里若留首字母大写则永远命中不到，等于分级失效。
    private static let protectedHomeFolders: Set<String> = [
        "desktop", "documents", "downloads", "music", "pictures", "movies",
    ]

    private var cache: [String: ConversationProject] = [:]
    private let fm = FileManager.default
    private let home: String

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) {
        self.home = home
    }

    /// 是否允许对 `standardizedPath` 做文件系统访问。大小写不敏感比较，
    /// 拿不准一律返回 false：宁可少查一次，不可多弹一次窗。
    static func allowsFileSystemCheck(standardizedPath: String, home: String) -> Bool {
        let path = standardizedPath.lowercased()
        let homePrefix = home.lowercased() + "/"
        guard path.hasPrefix(homePrefix) else { return false }
        let top = path.dropFirst(homePrefix.count)
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let top else { return false }
        return !protectedHomeFolders.contains(String(top))
    }

    mutating func resolve(rawPath: String, source: ConversationProjectSource) -> ConversationProject {
        let raw = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unassigned }
        let cacheKey = "\(source.rawValue):\(raw)"
        if let cached = cache[cacheKey] { return cached }

        let expanded = NSString(string: raw).expandingTildeInPath
        let standardizedURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let standardizedPath = standardizedURL.path
        let lower = standardizedPath.lowercased()

        if lower.contains("/ccbar-codex-wakeup/")
            || lower.contains("/application support/ccbar/claudeprobe")
            || lower.contains("/application support/codexbar/claudeprobe")
            || lower.contains("/application support/claudebar/probe") {
            let project = ConversationProject(
                key: "special:ccbar-system",
                name: "CCBar",
                path: standardizedPath,
                status: .system,
                source: .systemRule
            )
            cache[cacheKey] = project
            return project
        }

        if standardizedPath == "/" || standardizedPath == home {
            cache[cacheKey] = .unassigned
            return .unassigned
        }

        guard Self.allowsFileSystemCheck(standardizedPath: standardizedPath, home: home) else {
            let project = ConversationProject(
                key: "path:\(standardizedPath)",
                name: standardizedURL.lastPathComponent,
                path: standardizedPath,
                status: .unverified,
                source: source
            )
            cache[cacheKey] = project
            return project
        }

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: standardizedPath, isDirectory: &isDirectory)
        let canonicalURL = exists ? standardizedURL.resolvingSymlinksInPath() : standardizedURL
        let canonicalPath = canonicalURL.path
        let gitRoot = exists && isDirectory.boolValue ? nearestGitRoot(from: canonicalURL) : nil
        let resolvedPath = gitRoot?.path ?? canonicalPath
        let resolvedSource: ConversationProjectSource = gitRoot == nil ? source : (source == .claudeHistory ? .claudeHistory : .gitRoot)
        let project = ConversationProject(
            key: "path:\(resolvedPath)",
            name: URL(fileURLWithPath: resolvedPath).lastPathComponent,
            path: resolvedPath,
            status: fm.fileExists(atPath: resolvedPath) ? .available : .unavailable,
            source: resolvedSource
        )
        cache[cacheKey] = project
        return project
    }

    mutating func resolveClaude(
        historyPath: String?,
        candidates: [(path: String, isSidechain: Bool, container: String)]
    ) -> ConversationProject {
        if let historyPath, !historyPath.isEmpty {
            let historyProject = resolve(rawPath: historyPath, source: .claudeHistory)
            if historyProject.status != .unassigned { return historyProject }
        }

        let usable = candidates.filter { !$0.path.isEmpty }
        guard !usable.isEmpty else { return .unassigned }
        let resolved = usable.map { candidate in
            (candidate: candidate, project: resolve(rawPath: candidate.path, source: .cwd))
        }
        let normal = resolved.filter { $0.project.status.isPathBased }
        let uniqueProjects = Dictionary(grouping: normal, by: { $0.project.key })
        if uniqueProjects.count == 1, let project = normal.first?.project { return project }

        let mainProjects = normal.filter { !$0.candidate.isSidechain }
        let uniqueMain = Dictionary(grouping: mainProjects, by: { $0.project.key })
        if uniqueMain.count == 1, let project = mainProjects.first?.project { return project }

        let containerMatches = normal.filter {
            claudeContainerName(for: $0.candidate.path) == $0.candidate.container
        }
        let uniqueContainerMatches = Dictionary(grouping: containerMatches, by: { $0.project.key })
        if uniqueContainerMatches.count == 1, let project = containerMatches.first?.project { return project }

        let nested = normal.sorted { $0.project.path.count < $1.project.path.count }
        if let root = nested.first?.project,
           root.path != home,
           nested.allSatisfy({ $0.project.path == root.path || $0.project.path.hasPrefix(root.path + "/") }) {
            return root
        }

        if let special = resolved.map(\.project).first(where: { $0.status == .system }) {
            return special
        }
        return .unassigned
    }

    private func nearestGitRoot(from url: URL) -> URL? {
        var current = url
        // 只在家目录范围内向上找；家目录之上不属于用户项目，也无需触碰。
        while current.path != "/", current.path == home || current.path.hasPrefix(home + "/") {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func claudeContainerName(for rawPath: String) -> String {
        let path = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath).standardizedFileURL.path
        return path.replacingOccurrences(of: "/", with: "-")
    }
}
