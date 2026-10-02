import AppKit
import Charts
import SwiftUI

/// 项目列表排序：API 等值 / Tokens / 最近活跃。特殊项目（无明确项目、系统任务）始终排在末尾。
/// 默认值跟随设置里的排行口径，菜单切换只作用于本次查看、不持久化。
enum ProjectListSort: Hashable, CaseIterable {
    case cost
    case tokens
    case recent

    init(_ metric: StatsRankMetric) {
        switch metric {
        case .tokens: self = .tokens
        case .cost: self = .cost
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .cost: return tr("Cost", "费用")
        case .tokens: return tr("Tokens", "Tokens")
        case .recent: return tr("Recently active", "最近活跃")
        }
    }
}

// MARK: - 未归属

/// 「未归属」按来源拆分：Cursor 远端（精确），其余本地残差（补录与早期历史，只有按天汇总的数据）。
/// 逐 (天, 服务) 计算「日桶 − 已归属到对话的用量」并截断到 0，两行之和即未归属合计。
struct UnattributedBreakdown: Equatable {
    var total = UsageTotals.zero
    var cursor = UsageTotals.zero
    var local = UsageTotals.zero
    var localApps: [UsageApp] = []
    var localFirstDay: Date?
    var localLastDay: Date?
    var dailyCursor: [Date: UsageTotals] = [:]
    var dailyLocal: [Date: UsageTotals] = [:]
    /// 同一过滤条件下的概览总量，用于「占概览总额」。
    var overviewTotals = UsageTotals.zero

    static func build(
        buckets: [UsageBucket],
        apps: Set<UsageApp>,
        from: Date,
        to: Date,
        attributedByDayApp: [UsageDayAppKey: UsageTotals]
    ) -> UnattributedBreakdown {
        var daily: [UsageDayAppKey: UsageTotals] = [:]
        var result = UnattributedBreakdown()
        for bucket in buckets where apps.contains(bucket.app) && bucket.day >= from && bucket.day < to {
            daily[UsageDayAppKey(day: bucket.day, app: bucket.app), default: .zero].add(bucket)
            result.overviewTotals.add(bucket)
        }
        var localApps: Set<UsageApp> = []
        for (key, totals) in daily {
            let residual = totals.clampedSubtracting(attributedByDayApp[key] ?? .zero)
            guard residual.hasUsage else { continue }
            result.total.add(residual)
            if key.app == .cursor {
                result.cursor.add(residual)
                result.dailyCursor[key.day, default: .zero].add(residual)
            } else {
                result.local.add(residual)
                result.dailyLocal[key.day, default: .zero].add(residual)
                localApps.insert(key.app)
                result.localFirstDay = min(result.localFirstDay ?? key.day, key.day)
                result.localLastDay = max(result.localLastDay ?? key.day, key.day)
            }
        }
        result.localApps = UsageApp.allCases.filter { localApps.contains($0) }
        return result
    }
}

/// 项目页的列表数据：项目汇总 + 未归属拆分。同步记忆，输入不变不重算。
final class ProjectPageCache {
    struct Input: Equatable {
        let usageRevision: UInt64
        let conversationRevision: UInt64
        let from: Date
        let to: Date
        let apps: Set<UsageApp>
        let metric: StatsRankMetric
    }

    struct Output {
        let overview: ConversationOverviewResult
        let unattributed: UnattributedBreakdown
    }

    private var input: Input?
    private var output: Output?

    func output(for input: Input, build: () -> Output) -> Output {
        if let output, self.input == input { return output }
        let built = build()
        self.input = input
        self.output = built
        return built
    }
}

// MARK: - ProjectStatsView

struct ProjectStatsView: View {
    @Environment(AppState.self) private var appState
    @Binding var granularity: StatsGranularity
    @Binding var range: StatsRange
    @Binding var customFrom: Date
    @Binding var customTo: Date
    let serviceFilter: StatsServiceFilter
    @Binding var navigation: StatsNavigationRequest?
    let navigate: (StatsNavigationRequest.Target) -> Void
    let showServiceInOverview: (UsageApp) -> Void

    @State private var search = ""
    @State private var sort = ProjectListSort(SettingsStore.shared.statsRankMetric)
    @State private var selection: String?
    @State private var cache = ProjectPageCache()

    private static let unattributedSelection = "special:__unattributed__"

    var body: some View {
        let output = pageOutput
        let rows = listRows(output.overview.projects)
        VStack(spacing: 0) {
            HSplitView {
                projectList(rows: rows, output: output)
                    .frame(
                        minWidth: StatsSplitMetrics.listMinWidth,
                        idealWidth: StatsSplitMetrics.listWidth,
                        maxWidth: StatsSplitMetrics.listWidth,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                detailPane(rows: rows, output: output)
                    .frame(minWidth: StatsSplitMetrics.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if appState.usageService.lastScanAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                await appState.usageService.scanNow()
            }
        }
        .onAppear {
            applyNavigation()
            reconcileSelection(rows: rows)
        }
        .onChange(of: navigation) { _, _ in applyNavigation() }
        .onChange(of: rows.map(\.key)) { _, _ in reconcileSelection(rows: rows) }
        .onChange(of: SettingsStore.shared.statsRankMetric) { _, metric in sort = ProjectListSort(metric) }
    }

    /// 列表行大号数字与工具构成细条的口径：按 Tokens / 费用排序时跟随排序，按最近活跃时跟随设置。
    private var listMetric: StatsRankMetric {
        switch sort {
        case .tokens: return .tokens
        case .cost: return .cost
        case .recent: return SettingsStore.shared.statsRankMetric
        }
    }

    private func filterRow(projectCount: Int) -> some View {
        HStack(spacing: 6) {
            StatsSearchField(prompt: tr("Search project name or path", "搜索项目名或路径"), text: $search)
            Text(tr("\(projectCount) projects", "\(projectCount) 个项目"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
            StatsFilterMenu(items: ProjectListSort.allCases, label: { $0.label }, selection: $sort)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    // MARK: List

    @ViewBuilder
    private func projectList(rows: [ProjectUsageRow], output: ProjectPageCache.Output) -> some View {
        VStack(spacing: 0) {
            filterRow(projectCount: output.overview.projects.count)

            if isOrganizing {
                organizingState
            } else if output.overview.projects.isEmpty {
                emptyState
            } else if rows.isEmpty {
                ContentUnavailableView(
                    tr("No matching projects", "没有匹配的项目"),
                    systemImage: "magnifyingglass",
                    description: Text(tr("Try another keyword.", "请换一个关键词。"))
                )
            } else {
                let metric = listMetric
                // 细条按口径最大值归一：按最近活跃排序时第一行不一定最大。
                let maxValue = rows.filter { !$0.isSpecial }.map { metric.value($0.totals) }.max()
                    ?? rows.map { metric.value($0.totals) }.max() ?? 0
                StatsSelectionList(items: rows, selection: $selection) { row in
                    ProjectListRow(
                        row: row,
                        isGitRepository: row.status == .available
                            ? appState.usageService.conversationAggregator.isGitRepository(row.path)
                            : nil,
                        widthRatio: StatsRankMetric.ratio(metric.value(row.totals), to: maxValue),
                        metric: metric
                    )
                }
            }

            Divider()
            UnattributedListRow(
                totals: output.unattributed.total,
                isSelected: selection == Self.unattributedSelection
            ) {
                selection = Self.unattributedSelection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isOrganizing: Bool {
        appState.usageService.conversationAggregator.isEmpty && appState.usageService.isScanning
    }

    private var organizingState: some View {
        StatsOrganizingState(progress: appState.usageService.scanProgress)
    }

    private var emptyState: some View {
        StatsListEmptyState(
            systemImage: "folder",
            title: range == .today
                ? tr("No project usage today", "今天还没有项目用量")
                : tr("No project usage in this range", "该范围内没有项目用量"),
            message: tr(
                "Project usage comes from local Claude Code, Codex, Pi, OpenCode and DSH conversation logs.",
                "项目用量来自本机 Claude Code、Codex、Pi、OpenCode、DSH 的对话日志。"
            ),
            showLast30Days: range != .last30 && range != .all ? {
                granularity = .day
                range = .last30
            } : nil
        )
    }

    // MARK: Detail

    @ViewBuilder
    private func detailPane(rows: [ProjectUsageRow], output: ProjectPageCache.Output) -> some View {
        if selection == Self.unattributedSelection {
            UnattributedDetailView(
                breakdown: output.unattributed,
                cursorVisible: selectedApps.contains(.cursor),
                granularity: granularity,
                showCursorInOverview: { showServiceInOverview(.cursor) }
            )
        } else if let selection, rows.contains(where: { $0.key == selection }),
                  let detail = projectDetail(key: selection) {
            ProjectDetailView(
                detail: detail,
                row: rows.first { $0.key == selection },
                rangeLabel: tr(range.englishLabel, range.chineseLabel),
                rangeDayCount: rangeDayCount(firstUsedDay: detail.firstUsedDay),
                granularity: granularity,
                metric: SettingsStore.shared.statsRankMetric,
                navigate: navigate
            )
        } else {
            // 列表为空时空态已在列表栏说明，详情栏留空。
            Text(output.overview.projects.isEmpty ? "" : tr("Select a project", "选择项目查看详情"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Data

    private var bounds: (from: Date, to: Date) {
        range.bounds(customFrom: customFrom, customTo: customTo)
    }

    private var selectedApps: Set<UsageApp> {
        let serviceApp = serviceFilter.usageApp
        return Set(SettingsStore.shared.visibleUsageApps.filter { serviceApp == nil || $0 == serviceApp })
    }

    private var pageOutput: ProjectPageCache.Output {
        let aggregator = appState.usageService.aggregator
        let conversations = appState.usageService.conversationAggregator
        let bounds = self.bounds
        let apps = selectedApps
        let metric = SettingsStore.shared.statsRankMetric
        let input = ProjectPageCache.Input(
            usageRevision: aggregator.revision,
            conversationRevision: conversations.revision,
            from: bounds.from,
            to: bounds.to,
            apps: apps,
            metric: metric
        )
        return cache.output(for: input) {
            // 与概览使用相同的请求（前 5 个对话），两个视图切换时命中同一份缓存。
            let overview = conversations.overviewBreakdown(ConversationOverviewRequest(
                revision: conversations.revision,
                from: bounds.from,
                to: bounds.to,
                apps: apps,
                topConversationLimit: 5,
                metric: metric
            ))
            let unattributed = UnattributedBreakdown.build(
                buckets: aggregator.snapshot(),
                apps: apps,
                from: bounds.from,
                to: bounds.to,
                attributedByDayApp: overview.attributedByDayApp
            )
            return ProjectPageCache.Output(overview: overview, unattributed: unattributed)
        }
    }

    private func projectDetail(key: String) -> ProjectDetail? {
        let conversations = appState.usageService.conversationAggregator
        let previous = range.previousBounds(customFrom: customFrom, customTo: customTo)
        return conversations.projectDetail(ProjectDetailRequest(
            revision: conversations.revision,
            projectKey: key,
            from: bounds.from,
            to: bounds.to,
            previous: previous.map { $0.from..<$0.to },
            apps: selectedApps,
            metric: SettingsStore.shared.statsRankMetric
        ))
    }

    private func listRows(_ projects: [ProjectUsageRow]) -> [ProjectUsageRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? projects : projects.filter { row in
            "\(row.isSpecial ? StatsProjectLabel.name(StatsProjectIdentity(key: row.key, name: row.name, path: row.path, status: row.status)) : row.name) \(row.path)"
                .lowercased()
                .contains(query)
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isSpecial != rhs.isSpecial { return !lhs.isSpecial }
            if lhs.isSpecial {
                // 无明确项目在前，系统任务在后。
                return lhs.status == .unassigned && rhs.status != .unassigned
            }
            switch sort {
            case .cost:
                return ConversationAggregator.projectOrder(lhs, rhs)
            case .tokens:
                if lhs.totals.totalTokens == rhs.totals.totalTokens { return ConversationAggregator.projectOrder(lhs, rhs) }
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            case .recent:
                if lhs.lastAt == rhs.lastAt { return ConversationAggregator.projectOrder(lhs, rhs) }
                return lhs.lastAt > rhs.lastAt
            }
        }
    }

    /// 「活跃天数」分母：范围内的自然日数；「全部」从项目首次使用算起；不超过今天。
    private func rangeDayCount(firstUsedDay: Date?) -> Int {
        let calendar = StatsRange.weekStartMondayCalendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        var from = bounds.from
        if range == .all { from = firstUsedDay ?? calendar.startOfDay(for: Date()) }
        let to = min(bounds.to, tomorrow)
        guard to > from else { return 0 }
        return max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: to).day ?? 0)
    }

    private func applyNavigation() {
        guard let request = navigation else { return }
        switch request.target {
        case .project(let key):
            search = ""
            selection = key
        case .unattributed:
            selection = Self.unattributedSelection
        case .projectsList:
            search = ""
        case .conversation, .conversationsByRank, .conversationsInProject:
            return
        }
        navigation = nil
    }

    private func reconcileSelection(rows: [ProjectUsageRow]) {
        if selection == Self.unattributedSelection { return }
        if let selection, rows.contains(where: { $0.key == selection }) { return }
        selection = rows.first?.key
    }
}

// MARK: - List rows

private struct ProjectListRow: View {
    let row: ProjectUsageRow
    /// nil = 未检查（受保护目录 / 路径不存在）。
    let isGitRepository: Bool?
    /// 相对第一名的宽度比例，工具构成细条据此缩放。
    let widthRatio: Double
    /// 大号数字与细条分段的口径，另一项降为次级。
    let metric: StatsRankMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(StatsProjectLabel.name(identity))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(row.isSpecial ? Color.secondary : Color.primary)
                    .lineLimit(1)
                ForEach(badges, id: \.self) { badge in
                    ProjectBadge(text: badge)
                }
                Spacer(minLength: 6)
                Text(metric == .tokens ? StatsFormatter.compactToken(row.totals.totalTokens) : StatsFormatter.cost(row.totals.costUSD))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                PrivacySensitiveText(text: subtitle, sensitive: row.status.isPathBased)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                Text("\(metric == .tokens ? StatsFormatter.cost(row.totals.costUSD) : "\(StatsFormatter.compactToken(row.totals.totalTokens)) Tokens") · \(StatsRelativeDay.text(row.lastAt))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ServiceMixBar(totalsByApp: row.totalsByApp, widthRatio: widthRatio, metric: metric)
        }
    }

    private var identity: StatsProjectIdentity {
        StatsProjectIdentity(key: row.key, name: row.name, path: row.path, status: row.status)
    }

    private var subtitle: String {
        switch row.status {
        case .unassigned: return tr("Started from home or a temporary folder", "从主目录或临时目录启动的对话")
        case .system: return tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
        case .available, .unavailable, .unverified: return CompositionBuilder.pathTail(row.path)
        }
    }

    private var badges: [String] {
        var result: [String] = []
        if row.worktreeCount > 0 {
            result.append(tr("\(row.worktreeCount) worktree", "含 \(row.worktreeCount) 个 worktree"))
        }
        if row.status == .unavailable {
            result.append(tr("Unavailable", "已不存在"))
        } else if isGitRepository == false {
            result.append(tr("Not a Git folder", "非 Git 目录"))
        }
        return result
    }
}

private struct ProjectBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// 工具构成细条：按服务色分段，整体宽度按该项目占第一名的比例缩放。
private struct ServiceMixBar: View {
    let totalsByApp: [UsageApp: UsageTotals]
    let widthRatio: Double
    let metric: StatsRankMetric

    var body: some View {
        GeometryReader { proxy in
            let items = UsageApp.allCases.compactMap { app -> (UsageApp, Double)? in
                guard let totals = totalsByApp[app], totals.hasUsage else { return nil }
                return (app, weight(totals))
            }
            let total = items.reduce(0) { $0 + $1.1 }
            let width = proxy.size.width * max(0.02, min(1, widthRatio))
            HStack(spacing: 1) {
                ForEach(items.indices, id: \.self) { index in
                    items[index].0.tintColor
                        .frame(width: total > 0 ? max(1, width * items[index].1 / total) : 0)
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
    }

    private var usesCost: Bool {
        metric == .cost && totalsByApp.values.contains { $0.costUSD > 0 }
    }

    private func weight(_ totals: UsageTotals) -> Double {
        usesCost ? NSDecimalNumber(decimal: totals.costUSD).doubleValue : Double(totals.totalTokens)
    }
}

private struct UnattributedListRow: View {
    let totals: UsageTotals
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        StatsSelectableRow(isSelected: isSelected, action: action) {
            HStack(spacing: 8) {
                CompositionSwatch(role: .unattributed, size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Unattributed", "未归属"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(tr(
                        "Cursor remote usage, backfilled and early history have no project",
                        "Cursor 远端用量、补录和早期历史没有项目信息"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(StatsFormatter.cost(totals.costUSD))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Text("\(StatsFormatter.compactToken(totals.totalTokens)) Tokens")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
    }
}

// MARK: - Project detail

private struct ProjectDetailView: View {
    let detail: ProjectDetail
    let row: ProjectUsageRow?
    let rangeLabel: String
    let rangeDayCount: Int
    let granularity: StatsGranularity
    /// 排行口径：工具占比、模型行大号数字与高消耗对话跟随它（排序已由 `ProjectDetailRequest` 完成）。
    let metric: StatsRankMetric
    let navigate: (StatsNavigationRequest.Target) -> Void

    /// 卡片高度只由固定行数决定、不随项目内容变化，切换项目时各卡片不跳：
    /// 用量图那一排固定 250（设计稿）；工具与模型最多 5 行；分支预留 5 行、高消耗对话预留 3 行，
    /// 内容少时卡片下方留白。「仓库与 worktree」在最下方按内容显示，只影响页面长度。
    private static let chartRowHeight: CGFloat = 250
    private static let modelSlots = 5
    private static let branchSlots = 5
    private static let topConversationSlots = 3

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                // 沿用概览的 880pt 会让默认窗口退成单列，用两页共用的阈值。
                let isWide = proxy.size.width >= StatsSplitMetrics.wideDetailWidth
                let width = max(0, proxy.size.width - 40)
                VStack(alignment: .leading, spacing: 14) {
                    header
                    kpis
                    allTimeLine
                    StatsSplitRow(
                        isWide: isWide,
                        width: width,
                        leadingFraction: 0.58,
                        minHeight: isWide ? Self.chartRowHeight : nil
                    ) {
                        DetailSection(title: tr(granularity.panelTitleEnglish, granularity.panelTitleChinese), fillHeight: isWide) {
                            ProjectDailyChart(dailyByApp: detail.dailyByApp, granularity: granularity)
                        }
                    } trailing: {
                        DetailSection(title: tr("Tools & models", "工具与模型"), fillHeight: isWide) {
                            toolsAndModels
                        }
                    }
                    StatsSplitRow(isWide: isWide, width: width, leadingFraction: 0.5) {
                        DetailSection(title: tr("Branches", "分支"), fillHeight: isWide) {
                            branchTable
                        }
                    } trailing: {
                        DetailSection(
                            title: tr("Top conversations", "高消耗对话"),
                            right: AnyView(StatsLinkButton(title: tr("View in Conversations ›", "在对话页查看 ›")) {
                                navigate(.conversationsInProject(detail.project.key))
                            }),
                            fillHeight: isWide
                        ) {
                            topConversations
                        }
                    }
                    if !detail.worktrees.isEmpty {
                        DetailSection(title: tr("Repository & worktrees", "仓库与 worktree")) {
                            worktreeTable
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(StatsProjectLabel.name(detail.project))
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                if let row, row.worktreeCount > 0 {
                    ProjectBadge(text: tr("Git · \(row.worktreeCount) worktree", "Git · 含 \(row.worktreeCount) 个 worktree"))
                } else if detail.project.status == .unavailable {
                    ProjectBadge(text: tr("Unavailable", "已不存在"))
                }
                Spacer()
                if !PrivacyDisplay.isEnabled && (detail.project.status == .available || detail.project.status == .unverified) {
                    Button(tr("Show in Finder", "在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: detail.project.path)])
                    }
                    .controlSize(.small)
                }
            }
            if detail.project.status.isPathBased {
                PrivacySensitiveText(text: detail.project.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var kpis: some View {
        HStack(spacing: 12) {
            KPICard(
                english: "Tokens",
                chinese: "Tokens",
                value: StatsFormatter.compactToken(detail.totals.totalTokens),
                delta: delta(Double(detail.totals.totalTokens), detail.previousTotals.map { Double($0.totalTokens) }),
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Cost",
                chinese: "费用",
                value: StatsFormatter.cost(detail.totals.costUSD),
                delta: delta(
                    NSDecimalNumber(decimal: detail.totals.costUSD).doubleValue,
                    detail.previousTotals.map { NSDecimalNumber(decimal: $0.costUSD).doubleValue }
                ),
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Conversations",
                chinese: "对话数",
                value: StatsFormatter.token(detail.conversationCount),
                delta: nil,
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Active days",
                chinese: "活跃天数",
                value: "\(detail.activeDays) / \(rangeDayCount)",
                delta: nil,
                app: nil,
                dimmed: false
            )
        }
    }

    /// 与概览 KPI 的 delta 规则一致：没有上一区间、上一区间为 0 或当前为 0 时不显示。
    private func delta(_ current: Double, _ previous: Double?) -> Double? {
        guard let previous, previous > 0, current > 0 else { return nil }
        return (current - previous) / previous * 100
    }

    private var allTimeLine: some View {
        let first = detail.firstUsedDay.map { StatsFormatter.day($0) } ?? "—"
        return Text(tr(
            "Above: \(rangeLabel). All time: \(StatsFormatter.compactToken(detail.allTimeTotals.totalTokens)) tokens · \(StatsFormatter.cost(detail.allTimeTotals.costUSD)) · first used \(first)",
            "以上为\(rangeLabel)。全部时间：\(StatsFormatter.compactToken(detail.allTimeTotals.totalTokens)) Tokens · \(StatsFormatter.cost(detail.allTimeTotals.costUSD)) · 首次使用 \(first)"
        ))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var toolsAndModels: some View {
        let apps = UsageApp.allCases.filter { detail.totalsByApp[$0]?.hasUsage == true }
        // 最多 5 行：超过 5 个模型时列前 4 个，第 5 行为「其余 N 个模型」。
        let limit = detail.models.count > Self.modelSlots ? Self.modelSlots - 1 : Self.modelSlots
        let models = Array(detail.models.prefix(limit))
        let restModels = detail.models.dropFirst(limit)
        return VStack(alignment: .leading, spacing: 10) {
            CompositionShareBar(segments: apps.map {
                CompositionShareBar.Segment(id: $0.rawValue, role: .service($0), share: share(detail.totalsByApp[$0] ?? .zero))
            })
            HStack(spacing: 12) {
                ForEach(apps, id: \.self) { app in
                    HStack(spacing: 4) {
                        ServiceTile(app: app, size: 12)
                        Text("\(app.displayName) \(StatsFormatter.percent(share(detail.totalsByApp[app] ?? .zero)))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Divider()
            VStack(spacing: 6) {
                ForEach(models) { model in
                    HStack(spacing: 6) {
                        ForEach(UsageApp.allCases.filter { model.apps.contains($0) }, id: \.self) { app in
                            ServiceTile(app: app, size: 12)
                        }
                        Text(model.model)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Spacer(minLength: 6)
                        Text(metric == .tokens ? StatsFormatter.cost(model.totals.costUSD) : StatsFormatter.compactToken(model.totals.totalTokens))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(metric == .tokens ? StatsFormatter.compactToken(model.totals.totalTokens) : StatsFormatter.cost(model.totals.costUSD))
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                }
                if !restModels.isEmpty {
                    let restTotals = restModels.reduce(into: UsageTotals.zero) { $0.add($1.totals) }
                    HStack {
                        Text(tr("\(restModels.count) other models", "其余 \(restModels.count) 个模型"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(metric == .tokens ? StatsFormatter.compactToken(restTotals.totalTokens) : StatsFormatter.cost(restTotals.costUSD))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// 最多 5 行：超过 5 个分支时列前 4 个，第 5 行为「另有 N 个分支」；按 5 行预留高度。
    private var branchTable: some View {
        let limit = detail.branches.count > Self.branchSlots ? Self.branchSlots - 1 : Self.branchSlots
        let rows = Array(detail.branches.prefix(limit))
        let rest = detail.branches.dropFirst(limit)
        return VStack(spacing: 0) {
            HStack {
                tableHeader(tr("Branch", "分支"), alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                tableHeader(tr("Chats", "对话数"), alignment: .trailing).frame(width: 52, alignment: .trailing)
                tableHeader("Tokens", alignment: .trailing).frame(width: 74, alignment: .trailing)
                tableHeader(tr("Cost", "费用"), alignment: .trailing).frame(width: 76, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(rows) { branch in
                Divider()
                HStack {
                    PrivacySensitiveText(text: branch.branch ?? tr("(no branch info)", "（无分支信息）"), kind: .branch, sensitive: branch.branch != nil)
                        .font(.system(size: 11.5, design: branch.branch == nil ? .default : .monospaced))
                        .foregroundStyle(branch.branch == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(StatsFormatter.token(branch.conversationCount), width: 52)
                    cell(StatsFormatter.compactToken(branch.totals.totalTokens), width: 74)
                    cell(StatsFormatter.cost(branch.totals.costUSD), width: 76, emphasized: true)
                }
                .padding(.vertical, 5)
            }
            if !rest.isEmpty {
                Divider()
                Text(tr("\(rest.count) more branches", "另有 \(rest.count) 个分支"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
            if rows.isEmpty {
                Text(tr("No data", "无数据"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .reservingHeight {
            VStack(spacing: 0) {
                tableHeader(" ", alignment: .leading)
                    .padding(.bottom, 6)
                ForEach(0..<Self.branchSlots, id: \.self) { _ in
                    Divider()
                    cell(" ", width: 52)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    /// 按 3 行预留高度；占位行与 `TopConversationRowView` 紧凑版同高（两行文字 + 上下 6）。
    private var topConversations: some View {
        let rows = Array(detail.topConversations.prefix(Self.topConversationSlots))
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                TopConversationRowView(
                    index: index,
                    row: row,
                    share: share(row.summary.totals),
                    barRatio: rows.first.map { StatsRankMetric.ratio(row.rankValue(metric), to: $0.rankValue(metric)) } ?? 0,
                    showsProject: false,
                    metric: metric
                ) {
                    navigate(.conversation(row.id))
                }
            }
            if rows.isEmpty {
                Text(tr("No data", "无数据"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .reservingHeight {
            VStack(spacing: 0) {
                ForEach(0..<Self.topConversationSlots, id: \.self) { index in
                    if index > 0 { Divider() }
                    VStack(spacing: 2) {
                        Text(" ").font(.system(size: 12.5, weight: .medium))
                        Text(" ").font(.system(size: 10.5))
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func share(_ totals: UsageTotals) -> Double {
        metric.share(of: totals, in: detail.totals)
    }

    private var worktreeTable: some View {
        VStack(spacing: 0) {
            ForEach(Array(detail.worktrees.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                HStack(spacing: 8) {
                    Image(systemName: item.isMain ? "folder.fill" : "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            PrivacySensitiveText(text: item.path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if item.isMain { ProjectBadge(text: tr("Main repository", "主仓库")) }
                        }
                        PrivacySensitiveText(text: item.branch ?? tr("(branch unknown)", "（分支未知）"), kind: .branch, sensitive: item.branch != nil)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    cell(StatsFormatter.compactToken(item.totals.totalTokens), width: 74)
                    cell(StatsFormatter.cost(item.totals.costUSD), width: 76, emphasized: true)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func tableHeader(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func cell(_ text: String, width: CGFloat, emphasized: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: emphasized ? .semibold : .regular))
            .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }
}

// MARK: - Unattributed detail

private struct UnattributedDetailView: View {
    let breakdown: UnattributedBreakdown
    let cursorVisible: Bool
    let granularity: StatsGranularity
    let showCursorInOverview: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Unattributed", "未归属"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(tr(
                        "This usage counts toward the Overview total but does not appear in any project.",
                        "这些用量计入概览总量，但不出现在任何项目里。"
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    KPICard(english: "Tokens", chinese: "Tokens",
                            value: StatsFormatter.compactToken(breakdown.total.totalTokens),
                            delta: nil, app: nil, dimmed: false)
                    KPICard(english: "Cost", chinese: "费用",
                            value: StatsFormatter.cost(breakdown.total.costUSD),
                            delta: nil, app: nil, dimmed: false)
                    KPICard(english: "Share of Overview", chinese: "占概览总额",
                            value: overviewShare,
                            delta: nil, app: nil, dimmed: false)
                }

                DetailSection(title: tr("Sources", "来源")) {
                    VStack(spacing: 0) {
                        if cursorVisible {
                            sourceRow(
                                role: .service(.cursor),
                                title: tr("Cursor remote usage", "Cursor 远端用量"),
                                reason: tr("Cursor only reports account-level metering.", "Cursor 只提供账号级计量。"),
                                totals: breakdown.cursor,
                                link: (tr("Filter Cursor in Overview ›", "在概览中筛选 Cursor ›"), showCursorInOverview)
                            )
                            Divider()
                        }
                        sourceRow(
                            role: .unattributed,
                            title: tr("Backfilled and early history", "补录与早期历史"),
                            reason: localReason,
                            totals: breakdown.local,
                            link: nil
                        )
                    }
                }

                DetailSection(title: tr(granularity.panelTitleEnglish, granularity.panelTitleChinese)) {
                    UnattributedDailyChart(breakdown: breakdown, granularity: granularity)
                }
            }
            .padding(20)
        }
    }

    private var overviewShare: String {
        guard breakdown.overviewTotals.costUSD > 0 else {
            guard breakdown.overviewTotals.totalTokens > 0 else { return "—" }
            return StatsFormatter.percent(Double(breakdown.total.totalTokens) / Double(breakdown.overviewTotals.totalTokens))
        }
        return StatsFormatter.percent(NSDecimalNumber(decimal: breakdown.total.costUSD / breakdown.overviewTotals.costUSD).doubleValue)
    }

    private var localReason: String {
        var text = tr("Only daily totals are available.", "只有按天汇总的数据。")
        if let first = breakdown.localFirstDay, let last = breakdown.localLastDay {
            let span = first == last ? StatsFormatter.day(first) : "\(StatsFormatter.day(first)) – \(StatsFormatter.day(last))"
            let apps = breakdown.localApps.map(\.displayName).joined(separator: " · ")
            text += " \(span) · \(apps)"
        }
        return text
    }

    private func sourceRow(
        role: CompositionColorRole,
        title: String,
        reason: String,
        totals: UsageTotals,
        link: (String, () -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CompositionSwatch(role: role, size: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    StatsLinkButton(title: link.0, action: link.1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(StatsFormatter.cost(totals.costUSD))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                Text("\(StatsFormatter.compactToken(totals.totalTokens)) Tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
    }
}

/// 未归属每日图：Cursor 用服务色，补录与早期历史用灰色斜纹，按粒度归并。
private struct UnattributedDailyChart: View {
    let breakdown: UnattributedBreakdown
    let granularity: StatsGranularity

    private struct Column: Identifiable {
        let day: Date
        var cursor = 0
        var local = 0
        var id: Date { day }
        var total: Int { cursor + local }
    }

    var body: some View {
        let columns = self.columns
        let maxValue = max(1, columns.map(\.total).max() ?? 1)
        let barWidth = StatsOverviewModel.barWidth(forSampleCount: columns.count)
        if columns.isEmpty {
            Text(tr("No unattributed usage in this range", "该范围内没有未归属用量"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 140)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: max(2, barWidth * 0.6)) {
                        ForEach(columns) { column in
                            VStack(spacing: 0) {
                                if column.local > 0 {
                                    UnattributedStripes()
                                        .frame(height: 130 * CGFloat(column.local) / CGFloat(maxValue))
                                }
                                if column.cursor > 0 {
                                    UsageApp.cursor.tintColor
                                        .frame(height: 130 * CGFloat(column.cursor) / CGFloat(maxValue))
                                }
                            }
                            .frame(width: barWidth)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            .help("\(granularity.periodLabel(column.day)) · \(StatsFormatter.compactToken(column.total)) Tokens")
                        }
                    }
                    .frame(height: 130, alignment: .bottom)
                }
                HStack {
                    Text(granularity.periodLabel(columns.first?.day ?? Date()))
                    Spacer()
                    Text(granularity.periodLabel(columns.last?.day ?? Date()))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var columns: [Column] {
        var byPeriod: [Date: Column] = [:]
        for (day, totals) in breakdown.dailyCursor {
            let start = granularity.bucketStart(for: day)
            byPeriod[start, default: Column(day: start)].cursor += totals.totalTokens
        }
        for (day, totals) in breakdown.dailyLocal {
            let start = granularity.bucketStart(for: day)
            byPeriod[start, default: Column(day: start)].local += totals.totalTokens
        }
        return byPeriod.values.filter { $0.total > 0 }.sorted { $0.day < $1.day }
    }
}

// MARK: - Shared detail pieces

/// 项目页详情里的分区卡片。
private struct DetailSection<Content: View>: View {
    let title: String
    var right: AnyView? = nil
    var fillHeight = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let right { right }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .ccPanel(cornerRadius: 10)
    }
}

/// 项目详情的每日用量（按服务堆叠），按粒度把日数据归并成柱。
private struct ProjectDailyChart: View {
    let dailyByApp: [UsageDayAppKey: UsageTotals]
    let granularity: StatsGranularity

    private struct Point: Identifiable {
        let key: String
        let app: UsageApp
        let tokens: Int
        var id: String { "\(key)|\(app.rawValue)" }
    }

    var body: some View {
        let points = self.points
        let keys = Array(Set(points.map(\.key))).sorted()
        let apps = UsageApp.allCases.filter { app in points.contains { $0.app == app } }
        if points.isEmpty {
            Text(tr("No data", "无数据"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Chart(points) { point in
                    BarMark(
                        x: .value("Period", point.key),
                        y: .value("Tokens", Double(point.tokens)),
                        width: .fixed(StatsOverviewModel.barWidth(forSampleCount: keys.count)),
                        stacking: .standard
                    )
                    .foregroundStyle(point.app.tintColor)
                    .cornerRadius(2)
                }
                .chartXScale(domain: keys)
                .chartXAxis {
                    AxisMarks(values: StatsOverviewModel.axisKeys(from: keys, maxCount: 5)) { value in
                        AxisValueLabel {
                            if let key = value.as(String.self), let date = StatsPeriodKey.date(from: key) {
                                Text(date, format: granularity.axisDateFormat)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let tokens = value.as(Double.self) {
                                Text(StatsFormatter.compactToken(Int(tokens)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                // 理想高 150pt；宽画布下所在一排被拉高时随之变高。
                .frame(minHeight: 150, idealHeight: 150, maxHeight: .infinity)
                HStack(spacing: 10) {
                    ForEach(apps, id: \.self) { app in
                        HStack(spacing: 4) {
                            ServiceMark(color: app.tintColor, size: 8)
                            Text(app.displayName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var points: [Point] {
        var merged: [String: [UsageApp: Int]] = [:]
        for (key, totals) in dailyByApp {
            let periodKey = StatsPeriodKey.key(for: granularity.bucketStart(for: key.day))
            merged[periodKey, default: [:]][key.app, default: 0] += totals.totalTokens
        }
        var result: [Point] = []
        for (period, byApp) in merged {
            for (app, tokens) in byApp where tokens > 0 {
                result.append(Point(key: period, app: app, tokens: tokens))
            }
        }
        result.sort { lhs, rhs in
            if lhs.key == rhs.key { return lhs.app.rawValue < rhs.app.rawValue }
            return lhs.key < rhs.key
        }
        return result
    }
}

/// 「最近活跃」文案：今天 / 昨天 / N 天前 / 日期。
enum StatsRelativeDay {
    @MainActor
    static func text(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return tr("today", "今天")
        case 1: return tr("yesterday", "昨天")
        case 2..<30: return tr("\(days)d ago", "\(days) 天前")
        default: return StatsFormatter.day(date)
        }
    }
}

private extension View {
    /// 按占位内容预留高度：实际内容更少时下方留白，切换项目时卡片高度不变。
    func reservingHeight<Placeholder: View>(@ViewBuilder _ placeholder: () -> Placeholder) -> some View {
        ZStack(alignment: .top) {
            placeholder()
                .frame(maxWidth: .infinity)
                .hidden()
            self
        }
    }
}
