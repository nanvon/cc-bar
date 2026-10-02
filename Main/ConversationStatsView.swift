import AppKit
import SwiftUI

private extension ConversationQuerySort {
    @MainActor
    var label: String {
        switch self {
        case .recent: return tr("Recent", "最近")
        case .tokens: return tr("Tokens", "Tokens")
        case .cost: return tr("Cost", "费用")
        }
    }
}

struct ConversationStatsView: View {
    @Environment(AppState.self) private var appState
    @Binding var granularity: StatsGranularity
    @Binding var range: StatsRange
    @Binding var customFrom: Date
    @Binding var customTo: Date
    let serviceFilter: StatsServiceFilter
    /// 从概览 / 项目页跳来的目标（选中对话、按排行口径排序、按项目筛选），消费后清空。
    @Binding var navigation: StatsNavigationRequest?

    @State private var search = ""
    @State private var sort: ConversationQuerySort = .recent
    @State private var projectKey: String?
    @State private var selection: String?
    @State private var visibleLimit = 200

    var body: some View {
        let result = queryResult
        VStack(spacing: 0) {
            HSplitView {
                // 分栏尺寸与项目页共用（`StatsSplitMetrics`），切换视图时分隔线不跳。
                conversationList(result)
                    .frame(
                        minWidth: StatsSplitMetrics.listMinWidth,
                        idealWidth: StatsSplitMetrics.listWidth,
                        maxWidth: StatsSplitMetrics.listWidth,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                detailPane(result)
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
            reconcileSelection()
        }
        .onChange(of: navigation) { _, _ in applyNavigation() }
        .onChange(of: serviceFilter) { _, _ in reconcileScope() }
        .onChange(of: range) { _, _ in reconcileScope() }
        .onChange(of: projectKey) { _, _ in reconcileSelection() }
        .onChange(of: result.projectKeys) { _, keys in
            if let projectKey, !keys.contains(projectKey) { self.projectKey = nil }
            reconcileSelection()
        }
        .onChange(of: result.rows.map(\.id)) { _, _ in reconcileSelection() }
    }

    /// 列表栏顶部过滤行：搜索、项目菜单、排序，外观与项目页过滤行一致。
    private func filterRow(_ result: ConversationQueryResult) -> some View {
        HStack(spacing: 6) {
            StatsSearchField(prompt: tr("Search title or project", "搜索标题或项目"), text: $search)
            projectMenu(result)
            StatsFilterMenu(items: ConversationQuerySort.allCases, label: { $0.label }, selection: $sort)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private func projectMenu(_ result: ConversationQueryResult) -> some View {
        let options = result.projectOptions
        // unverified（受保护目录，未做存在性检查）与可用项目同组展示，不显示“已不存在”。
        let openable = options.filter { $0.status == .available || $0.status == .unverified }
        let recent = Array(openable.sorted { $0.lastAt > $1.lastAt }.prefix(5))
        let available = openable.sorted {
            projectLabel($0, duplicateNames: result.duplicateProjectNames)
                .localizedCaseInsensitiveCompare(projectLabel($1, duplicateNames: result.duplicateProjectNames)) == .orderedAscending
        }
        let unavailable = options.filter { $0.status == .unavailable }.sorted {
            projectLabel($0, duplicateNames: result.duplicateProjectNames)
                .localizedCaseInsensitiveCompare(projectLabel($1, duplicateNames: result.duplicateProjectNames)) == .orderedAscending
        }
        return Menu {
            Button {
                projectKey = nil
            } label: {
                menuLabel(
                    tr("All projects", "全部项目"),
                    count: result.projectConversationCount,
                    selected: projectKey == nil
                )
            }

            if !recent.isEmpty {
                Section(tr("Recent", "最近使用")) {
                    ForEach(recent) { option in projectButton(option, duplicateNames: result.duplicateProjectNames) }
                }
            }
            if !available.isEmpty {
                Section(tr("All projects", "全部项目")) {
                    ForEach(available) { option in projectButton(option, duplicateNames: result.duplicateProjectNames) }
                }
            }
            if !unavailable.isEmpty {
                Section(tr("Unavailable", "已不存在")) {
                    ForEach(unavailable) { option in projectButton(option, duplicateNames: result.duplicateProjectNames) }
                }
            }
            if let option = options.first(where: { $0.status == .unassigned }) {
                Section { projectButton(option, duplicateNames: result.duplicateProjectNames) }
            }
            if let option = options.first(where: { $0.status == .system }) {
                Section { projectButton(option, duplicateNames: result.duplicateProjectNames) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(selectedProjectLabel(result))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .pointingHandCursor()
        .help(selectedProjectHelp(result))
        .modifier(CappedWidth(maxWidth: 150))
    }

    private func projectButton(_ option: ConversationProjectOption, duplicateNames: Set<String>) -> some View {
        Button {
            projectKey = option.key
        } label: {
            menuLabel(
                projectLabel(option, duplicateNames: duplicateNames),
                count: option.conversationCount,
                selected: projectKey == option.key
            )
        }
        .help(projectHelp(option))
    }

    private func menuLabel(_ title: String, count: Int, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func conversationList(_ result: ConversationQueryResult) -> some View {
        let rows = result.rows
        return VStack(spacing: 0) {
            filterRow(result)

            // 空态规则同项目页：首次整理 → 范围内没有对话 → 搜索无匹配。
            if isOrganizing {
                StatsOrganizingState(progress: appState.usageService.scanProgress)
            } else if rows.isEmpty, search.isEmpty {
                StatsListEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: range == .today
                        ? tr("No conversations today", "今天还没有对话")
                        : tr("No conversations in this range", "该范围内没有对话"),
                    message: tr(
                        "Conversations come from local Claude Code, Codex, Pi, OpenCode and DSH logs.",
                        "对话来自本机 Claude Code、Codex、Pi、OpenCode、DSH 的日志。"
                    ),
                    showLast30Days: range != .last30 && range != .all ? {
                        granularity = .day
                        range = .last30
                    } : nil
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    tr("No matching conversations", "没有匹配的对话"),
                    systemImage: "magnifyingglass",
                    description: Text(tr("Try another keyword.", "请换一个关键词。"))
                )
            } else {
                StatsSelectionList(items: Array(rows.prefix(visibleLimit)), selection: $selection) { row in
                    ConversationListRow(summary: row)
                } trailing: {
                    if rows.count > visibleLimit {
                        Button(tr("Show more", "显示更多")) { visibleLimit += 200 }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isOrganizing: Bool {
        appState.usageService.conversationAggregator.isEmpty && appState.usageService.isScanning
    }

    @ViewBuilder
    private func detailPane(_ result: ConversationQueryResult) -> some View {
        if let selection,
           let detail = appState.usageService.conversationAggregator.detail(
               key: selection,
               metric: SettingsStore.shared.statsRankMetric
           ) {
            ConversationDetailView(detail: detail)
        } else {
            // 与项目页一致：列表有内容时默认选中第一条。列表为空时空态已在列表栏说明，详情栏留空。
            Text(result.rows.isEmpty ? "" : tr("Select a conversation", "选择对话查看详情"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var queryResult: ConversationQueryResult {
        let bounds = range.bounds(customFrom: customFrom, customTo: customTo)
        let aggregator = appState.usageService.conversationAggregator
        return aggregator.query(ConversationQueryRequest(
            revision: aggregator.revision,
            app: selectedApp,
            projectKey: projectKey,
            from: bounds.from,
            to: bounds.to,
            search: search,
            sort: sort
        ))
    }

    private var selectedApp: UsageApp? {
        switch serviceFilter {
        case .all: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .cursor: return nil
        case .pi: return .pi
        case .opencode: return .opencode
        case .dsh: return .dsh
        }
    }

    private func selectedProjectLabel(_ result: ConversationQueryResult) -> String {
        guard let projectKey,
              let option = result.projectOptions.first(where: { $0.key == projectKey }) else {
            return tr("All projects", "全部项目")
        }
        return projectLabel(option, duplicateNames: result.duplicateProjectNames)
    }

    private func selectedProjectHelp(_ result: ConversationQueryResult) -> String {
        guard let projectKey,
              let option = result.projectOptions.first(where: { $0.key == projectKey }) else {
            return tr("Filter conversations by project", "按项目筛选对话")
        }
        return projectHelp(option)
    }

    private func projectLabel(_ option: ConversationProjectOption, duplicateNames: Set<String>) -> String {
        if PrivacyDisplay.isEnabled && option.status.isPathBased { return PrivacyDisplay.project(option.key) }
        switch option.status {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("CCBar system tasks", "CCBar 系统任务")
        case .available, .unavailable, .unverified:
            guard duplicateNames.contains(option.name) else { return option.name }
            let parent = URL(fileURLWithPath: option.path).deletingLastPathComponent().lastPathComponent
            return "\(option.name) — \(parent)"
        }
    }

    private func projectHelp(_ option: ConversationProjectOption) -> String {
        if PrivacyDisplay.isEnabled && option.status.isPathBased { return PrivacyDisplay.project(option.key) }
        switch option.status {
        case .unassigned: return tr("No reliable project could be identified", "未能可靠识别项目")
        case .system: return tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
        case .unavailable: return "\(option.path) · \(tr("Unavailable", "已不存在"))"
        case .available, .unverified: return option.path
        }
    }

    private func applyNavigation() {
        guard let request = navigation else { return }
        switch request.target {
        case .conversation(let key):
            search = ""
            projectKey = nil
            selection = key
        case .conversationsByRank:
            search = ""
            projectKey = nil
            sort = SettingsStore.shared.statsRankMetric == .tokens ? .tokens : .cost
        case .conversationsInProject(let key):
            search = ""
            projectKey = key
        case .projectsList, .project, .unattributed:
            return
        }
        visibleLimit = 200
        navigation = nil
    }

    private func reconcileScope() {
        let result = queryResult
        if let projectKey, !result.projectKeys.contains(projectKey) {
            self.projectKey = nil
        }
        visibleLimit = 200
        reconcileSelection()
    }

    /// 没有选中、或选中项已不在列表里时，默认选中列表第一条；列表为空时清空选中。
    private func reconcileSelection() {
        let rows = queryResult.rows
        if let selection, rows.contains(where: { $0.id == selection }) { return }
        selection = rows.first?.id
    }
}

struct ConversationScanStatus: View {
    let isScanning: Bool
    let isEmpty: Bool
    let lastScanAt: Date?

    @ViewBuilder
    var body: some View {
        if isScanning && isEmpty {
            Text(tr("Organizing history…", "正在整理历史对话…"))
                .foregroundStyle(.secondary)
        } else if let lastScanAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(tr("Updated \(relativeAge(lastScanAt, now: context.date)) ago", "\(relativeAge(lastScanAt, now: context.date)) 前更新"))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(tr("Waiting for data", "等待数据"))
                .foregroundStyle(.secondary)
        }
    }

    private func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

private struct ConversationListRow: View {
    @Environment(AppState.self) private var appState
    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ServiceTile(app: summary.info.app, size: 14)
                Text(PrivacyDisplay.conversation(summary.info))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(StatsFormatter.day(summary.rangeLastAt)) \(StatsFormatter.time(summary.rangeLastAt))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            HStack(spacing: 6) {
                // 项目名完整显示，放不下时只截断模型列表（设计稿同）。
                Text(projectLabel)
                    .lineLimit(1)
                    .fixedSize()
                    .help(projectHelp)
                Text("·")
                Text(summary.models.joined(separator: ", ")).lineLimit(1)
                UsageSpeedBadge(summary: summary.speed.summary)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("\(summary.totals.requestCount) requests", "\(summary.totals.requestCount) 次请求"))
                Spacer()
                Text("\(StatsFormatter.compactToken(summary.totals.totalTokens)) Tokens")
                Text(costLabel(summary.costs))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var projectLabel: String {
        if PrivacyDisplay.isEnabled {
            return StatsProjectLabel.name(appState.usageService.conversationAggregator.statsProjectIdentity(for: summary.info))
        }
        switch summary.info.projectStatus {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("System task", "系统任务")
        case .available, .unavailable, .unverified: return summary.info.projectName
        }
    }

    private var projectHelp: String {
        if PrivacyDisplay.isEnabled { return projectLabel }
        switch summary.info.projectStatus {
        case .unassigned: return tr("No reliable project could be identified", "未能可靠识别项目")
        case .system: return tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
        case .unavailable: return "\(summary.info.projectPath) · \(tr("Unavailable", "已不存在"))"
        case .available, .unverified: return summary.info.projectPath
        }
    }
}

private struct ConversationDetailView: View {
    let detail: ConversationDetail

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                let isWide = proxy.size.width >= StatsSplitMetrics.wideDetailWidth
                let width = max(0, proxy.size.width - 40)
                VStack(alignment: .leading, spacing: 14) {
                    header
                    kpis
                    StatsSplitRow(isWide: isWide, width: width, leadingFraction: 0.5) {
                        tokenComposition(fillHeight: isWide)
                    } trailing: {
                        costDetails(fillHeight: isWide)
                    }
                    StatsSplitRow(isWide: isWide, width: width, leadingFraction: 0.58) {
                        modelDetails(fillHeight: isWide)
                    } trailing: {
                        speedDetails(fillHeight: isWide)
                    }
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceTile(app: detail.info.app, size: 14)
                Text(detail.info.app.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(tr("All time", "全部时间"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .help(tr(
                        "This detail always shows the conversation's full history, regardless of the time range filter above.",
                        "该详情展示该对话的全部时间数据,不受上方时间范围筛选影响。"
                    ))
                UsageSpeedBadge(summary: detail.speed.summary)
                Spacer()
            }
            Text(PrivacyDisplay.conversation(detail.info))
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            PrivacySensitiveText(text: projectText, sensitive: detail.info.projectStatus.isPathBased)
                .font(.system(size: 11, design: detail.info.projectStatus.isPathBased ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(PrivacyDisplay.help(projectText))
            // 一行放不下时对话 ID 换到第二行。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    timeItems
                    conversationIDItem
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) { timeItems }
                    conversationIDItem
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var timeItems: some View {
        if let branch = detail.info.gitBranch, !branch.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                PrivacySensitiveText(text: branch, kind: .branch)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
        }
        HStack(spacing: 4) {
            Image(systemName: "clock")
            Text("\(StatsFormatter.day(detail.info.firstAt)) \(StatsFormatter.time(detail.info.firstAt)) – \(StatsFormatter.day(detail.info.lastAt)) \(StatsFormatter.time(detail.info.lastAt)) · \(durationText)")
                .lineLimit(1)
        }
        if detail.info.includesSubtasks {
            Text(tr("Includes subtask usage", "包含子任务用量"))
                .lineLimit(1)
        }
    }

    private var conversationIDItem: some View {
        HStack(spacing: 4) {
            Text(tr("Conversation ID", "对话 ID"))
            PrivacySensitiveText(text: detail.info.conversationID, kind: .identifier)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            if !PrivacyDisplay.isEnabled {
                Button {
                    guard !PrivacyDisplay.isEnabled else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail.info.conversationID, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(tr("Copy conversation ID", "复制对话 ID"))
            }
        }
    }

    private var kpis: some View {
        HStack(spacing: 12) {
            KPICard(
                english: "Total tokens",
                chinese: "总 Tokens",
                value: StatsFormatter.compactToken(detail.totals.totalTokens),
                delta: nil,
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Estimated cost",
                chinese: "估算费用",
                value: costLabel(detail.costs),
                delta: nil,
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Requests",
                chinese: "请求数",
                value: StatsFormatter.token(detail.totals.requestCount),
                delta: nil,
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Cache hit rate",
                chinese: "缓存命中率",
                value: hitRateText(detail.totals.cacheHitRate),
                delta: nil,
                app: nil,
                dimmed: false
            )
        }
    }

    /// 堆叠条与占比的分母都是 输入 + 输出 + 缓存读取（与概览 Token 拆分一致）；
    /// 缓存写入只列数值，不画圆点、不算占比。
    private func tokenComposition(fillHeight: Bool) -> some View {
        let totals = detail.totals
        let denominator = totals.inputTokens + totals.outputTokens + totals.cacheReadTokens
        func share(_ tokens: Int) -> String {
            StatsFormatter.sharePercent(denominator > 0 ? Double(tokens) / Double(denominator) : 0)
        }
        return DetailPanel(title: tr("Token composition", "Token 构成"), fillHeight: fillHeight) {
            VStack(spacing: 10) {
                TokenStackBar(totals: totals)
                VStack(spacing: 0) {
                    DetailValueRow(
                        label: tr("Input", "输入"),
                        value: StatsFormatter.compactToken(totals.inputTokens),
                        token: (TokenCategoryStyle.input, share(totals.inputTokens))
                    )
                    Divider()
                    DetailValueRow(
                        label: tr("Output", "输出"),
                        value: StatsFormatter.compactToken(totals.outputTokens),
                        token: (TokenCategoryStyle.output, share(totals.outputTokens))
                    )
                    Divider()
                    DetailValueRow(
                        label: tr("Cache read", "缓存读取"),
                        value: StatsFormatter.compactToken(totals.cacheReadTokens),
                        token: (TokenCategoryStyle.cacheRead, share(totals.cacheReadTokens))
                    )
                    Divider()
                    DetailValueRow(
                        label: tr("Cache write", "缓存写入"),
                        value: cacheCreationText,
                        token: (0, "")
                    )
                }
            }
        }
    }

    /// 先列 Standard / Fast，再列按最终档位价格汇总的四项；合计已在 KPI 卡，不再重复。
    private func costDetails(fillHeight: Bool) -> some View {
        DetailPanel(title: tr("Estimated cost breakdown", "估算费用构成"), fillHeight: fillHeight) {
            VStack(spacing: 0) {
                DetailValueRow(label: "Standard", value: StatsFormatter.tierCost(
                    detail.speed.standard.costUSD,
                    hasUnpricedUsage: detail.speed.standardHasUnpricedCost
                ))
                Divider()
                DetailValueRow(label: "Fast", value: StatsFormatter.tierCost(
                    detail.speed.fast.costUSD,
                    hasUnpricedUsage: detail.speed.fastHasUnpricedCost
                ))
                Divider()
                    .padding(.vertical, 4)
                DetailValueRow(label: tr("Input", "输入"), value: StatsFormatter.tierCostPrecise(
                    detail.costs.input,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                ))
                Divider()
                DetailValueRow(label: tr("Output", "输出"), value: StatsFormatter.tierCostPrecise(
                    detail.costs.output,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                ))
                Divider()
                DetailValueRow(label: tr("Cache read", "缓存读取"), value: StatsFormatter.tierCostPrecise(
                    detail.costs.cacheRead,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                ))
                Divider()
                DetailValueRow(
                    label: tr("Cache write", "缓存写入"),
                    value: detail.info.cacheCreationAvailable ? StatsFormatter.tierCostPrecise(
                        detail.costs.cacheCreation,
                        hasUnpricedUsage: detail.costs.hasUnpricedUsage
                    ) : "N/A"
                )
            }
        }
    }

    private func modelDetails(fillHeight: Bool) -> some View {
        DetailPanel(title: tr("By model", "按模型"), fillHeight: fillHeight) {
            VStack(spacing: 0) {
                ForEach(detail.models) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.model)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            UsageSpeedBadge(summary: item.speed.summary)
                            Spacer(minLength: 6)
                            Text(StatsFormatter.compactToken(item.totals.totalTokens))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Text(costLabel(item.costs))
                                .font(.system(size: 11.5, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: 76, alignment: .trailing)
                        }
                        Text("in \(StatsFormatter.compactToken(item.totals.inputTokens))  ·  out \(StatsFormatter.compactToken(item.totals.outputTokens))  ·  cache \(StatsFormatter.compactToken(item.totals.cacheReadTokens))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.speed.fast.requestCount > 0 {
                            Text("Fast \(StatsFormatter.compactToken(item.speed.fast.totalTokens))  ·  \(tr("billing equivalent", "计费等效")) \(StatsFormatter.billingEquivalentTokens(item.speed))  ·  \(StatsFormatter.fastMultiplier(item.speed))  ·  \(StatsFormatter.tierCost(item.speed.fast.costUSD, hasUnpricedUsage: item.speed.fastHasUnpricedCost))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    if item.id != detail.models.last?.id { Divider() }
                }
            }
        }
    }

    /// Standard / Fast / 未识别三档的原始 Tokens 与请求数，底部一行 Fast 计费等效 Tokens 与倍率。
    private func speedDetails(fillHeight: Bool) -> some View {
        DetailPanel(title: tr("Speed tiers", "速度档位"), fillHeight: fillHeight) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(tr("Tier", "档位"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tokens")
                        .frame(width: 90, alignment: .trailing)
                    Text(tr("Requests", "请求"))
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
                Divider()
                speedRow("Standard", detail.speed.standard)
                Divider()
                speedRow("Fast", detail.speed.fast)
                Divider()
                speedRow(tr("Unrecognized", "未识别"), detail.speed.unknown)
                Divider()
                Text(tr(
                    "Billing equivalent \(StatsFormatter.billingEquivalentTokens(detail.speed)) tokens · Fast multiplier \(StatsFormatter.fastMultiplier(detail.speed))",
                    "计费等效 \(StatsFormatter.billingEquivalentTokens(detail.speed)) Tokens · Fast 倍率 \(StatsFormatter.fastMultiplier(detail.speed))"
                ))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
        }
    }

    private func speedRow(_ label: String, _ tier: UsageTotals) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(StatsFormatter.compactToken(tier.totalTokens))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(StatsFormatter.token(tier.requestCount))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.vertical, 5)
    }

    private var cacheCreationText: String {
        detail.info.cacheCreationAvailable ? StatsFormatter.compactToken(detail.totals.cacheCreationTokens) : "N/A"
    }

    private var projectText: String {
        switch detail.info.projectStatus {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("CCBar system task", "CCBar 系统任务")
        case .unavailable: return "\(detail.info.projectPath) · \(tr("Unavailable", "已不存在"))"
        case .available, .unverified: return detail.info.projectPath
        }
    }

    private var durationText: String {
        let seconds = max(0, Int(detail.info.lastAt.timeIntervalSince(detail.info.firstAt)))
        if seconds < 60 { return tr("\(seconds) sec", "\(seconds) 秒") }
        if seconds < 3600 { return tr("\(seconds / 60) min", "\(seconds / 60) 分钟") }
        if seconds < 86400 { return tr("\(seconds / 3600) hr", "\(seconds / 3600) 小时") }
        let days = seconds / 86400
        return tr(days == 1 ? "\(days) day" : "\(days) days", "\(days) 天")
    }
}

private struct UsageSpeedBadge: View {
    let summary: UsageSpeedSummary

    @ViewBuilder
    var body: some View {
        switch summary {
        case .fast:
            badge(tr("Fast", "Fast"), icon: "bolt.fill")
        case .mixed:
            badge(tr("Mixed", "混合"), icon: "arrow.left.arrow.right")
        case .standard, .unknown:
            EmptyView()
        }
    }

    private func badge(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.11), in: Capsule())
        .fixedSize()
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    var fillHeight = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .ccPanel(cornerRadius: 10)
    }
}

/// 详情面板里的「标签 … 数值」行。`token` 用于 Token 构成：圆点透明度（`TokenCategoryStyle`，
/// 0 表示只留圆点位置）与占比文字。
private struct DetailValueRow: View {
    let label: String
    let value: String
    var token: (dotOpacity: Double, share: String)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let token {
                Circle()
                    .fill(Color.primary.opacity(token.dotOpacity))
                    .frame(width: 8, height: 8)
            }
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            if let token {
                Text(token.share)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 7)
    }
}

/// 按内容取宽、最宽 `maxWidth`；内容更宽时按上限重新布局，让里面的文字截断。
/// `.frame(maxWidth:)` 做不到——它会把短内容也撑到上限宽度。
private struct CappedWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        CappedWidthLayout(maxWidth: maxWidth) { content }
    }
}

private struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(childProposal(proposal, subview))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func childProposal(_ proposal: ProposedViewSize, _ subview: LayoutSubview) -> ProposedViewSize {
        let ideal = subview.sizeThatFits(.unspecified).width
        let limit = min(maxWidth, proposal.width ?? .infinity)
        return ProposedViewSize(width: min(ideal, limit), height: proposal.height)
    }
}

private func costLabel(_ costs: ConversationCostTotals) -> String {
    return StatsFormatter.cost(costs.total)
}
