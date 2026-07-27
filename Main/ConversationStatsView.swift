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
    @Binding var range: StatsRange
    @Binding var customFrom: Date
    @Binding var customTo: Date
    let serviceFilter: StatsServiceFilter

    @State private var search = ""
    @State private var sort: ConversationQuerySort = .recent
    @State private var projectKey: String?
    @State private var selection: String?
    @State private var visibleLimit = 200

    var body: some View {
        let result = queryResult
        VStack(spacing: 0) {
            toolbar(result)
            Divider()
            HSplitView {
                conversationList(rows: result.rows)
                    .frame(minWidth: 390, idealWidth: 460, maxHeight: .infinity, alignment: .top)
                detailPane
                    .frame(minWidth: 390, idealWidth: 520, maxHeight: .infinity, alignment: .top)
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
        .onChange(of: serviceFilter) { _, _ in reconcileScope() }
        .onChange(of: range) { _, _ in reconcileScope() }
        .onChange(of: projectKey) { _, _ in reconcileSelection() }
        .onChange(of: result.projectKeys) { _, keys in
            if let projectKey, !keys.contains(projectKey) { self.projectKey = nil }
            reconcileSelection()
        }
    }

    private func toolbar(_ result: ConversationQueryResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("Search title or project", "搜索标题或项目"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 280)

            projectMenu(result)

            Picker("", selection: $sort) {
                ForEach(ConversationQuerySort.allCases) { item in Text(item.label).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            ConversationScanStatus(
                isScanning: appState.usageService.isScanning,
                isEmpty: appState.usageService.conversationAggregator.isEmpty,
                lastScanAt: appState.usageService.lastScanAt
            )

            Button {
                Task { await appState.usageService.scanNow() }
            } label: {
                if appState.usageService.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help(tr("Refresh local usage", "刷新本地用量"))

            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { item in
                    Text(tr(item.englishLabel, item.chineseLabel)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func projectMenu(_ result: ConversationQueryResult) -> some View {
        let options = result.projectOptions
        let recent = Array(options.filter { $0.status == .available }.sorted { $0.lastAt > $1.lastAt }.prefix(5))
        let available = options.filter { $0.status == .available }.sorted {
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
            Label(selectedProjectLabel(result), systemImage: "folder")
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .help(selectedProjectHelp(result))
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

    private func conversationList(rows: [ConversationSummary]) -> some View {
        VStack(spacing: 0) {
            if range == .custom {
                HStack(spacing: 8) {
                    DatePicker(tr("From", "起"), selection: $customFrom, displayedComponents: .date)
                    DatePicker(tr("To", "止"), selection: $customTo, in: customFrom..., displayedComponents: .date)
                }
                .labelsHidden()
                .padding(10)
                Divider()
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    tr("No conversations", "暂无对话"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(tr("Try another time range or refresh local usage.", "请切换时间范围或刷新本地用量。"))
                )
            } else {
                List(selection: $selection) {
                    ForEach(Array(rows.prefix(visibleLimit))) { row in
                        ConversationListRow(summary: row)
                            .tag(row.id)
                    }
                    if rows.count > visibleLimit {
                        Button(tr("Show more", "显示更多")) { visibleLimit += 200 }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selection,
           let detail = appState.usageService.conversationAggregator.detail(key: selection) {
            ConversationDetailView(detail: detail)
        } else {
            ContentUnavailableView(
                tr("Select a conversation", "请选择对话"),
                systemImage: "sidebar.right",
                description: Text(tr("Token and estimated cost details appear here.", "这里会显示 Token 与估算费用明细。"))
            )
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
        case .grok: return .grok
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
        switch option.status {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("CCBar system tasks", "CCBar 系统任务")
        case .available, .unavailable:
            guard duplicateNames.contains(option.name) else { return option.name }
            let parent = URL(fileURLWithPath: option.path).deletingLastPathComponent().lastPathComponent
            return "\(option.name) — \(parent)"
        }
    }

    private func projectHelp(_ option: ConversationProjectOption) -> String {
        switch option.status {
        case .unassigned: return tr("No reliable project could be identified", "未能可靠识别项目")
        case .system: return tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
        case .unavailable: return "\(option.path) · \(tr("Unavailable", "已不存在"))"
        case .available: return option.path
        }
    }

    private func reconcileScope() {
        let result = queryResult
        if let projectKey, !result.projectKeys.contains(projectKey) {
            self.projectKey = nil
        }
        visibleLimit = 200
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard let selection else { return }
        if !queryResult.rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }
}

private struct ConversationScanStatus: View {
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

private func usageAccent(_ app: UsageApp) -> Color {
    switch app {
    case .codex: return .codexAccent
    case .claude: return .claudeAccent
    case .grok: return .grokAccent
    }
}

private func usageTitle(_ app: UsageApp) -> String {
    switch app {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .grok: return "Grok"
    }
}

private struct ConversationListRow: View {
    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ServiceMark(color: usageAccent(summary.info.app), size: 8)
                Text(summary.info.title ?? tr("Untitled", "（无标题）"))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(StatsFormatter.day(summary.rangeLastAt)) \(StatsFormatter.time(summary.rangeLastAt))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(projectLabel)
                    .help(projectHelp)
                Text("·")
                Text(summary.models.joined(separator: ", ")).lineLimit(1)
                UsageSpeedBadge(summary: summary.speed.summary)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            HStack {
                Text(tr("\(summary.totals.requestCount) requests", "\(summary.totals.requestCount) 次请求"))
                Spacer()
                Text("\(StatsFormatter.compactToken(summary.totals.totalTokens)) Tokens")
                Text(costLabel(summary.costs))
                    .fontWeight(.semibold)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private var projectLabel: String {
        switch summary.info.projectStatus {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("System task", "系统任务")
        case .available, .unavailable: return summary.info.projectName
        }
    }

    private var projectHelp: String {
        switch summary.info.projectStatus {
        case .unassigned: return tr("No reliable project could be identified", "未能可靠识别项目")
        case .system: return tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
        case .unavailable: return "\(summary.info.projectPath) · \(tr("Unavailable", "已不存在"))"
        case .available: return summary.info.projectPath
        }
    }
}

private struct ConversationDetailView: View {
    let detail: ConversationDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                TokenBreakdownView(totals: detail.totals)
                    .padding(14)
                    .ccPanel(cornerRadius: 10)
                tokenDetails
                speedDetails
                costDetails
                modelDetails
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ServiceMark(color: usageAccent(detail.info.app), size: 9)
                Text(usageTitle(detail.info.app))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(tr("All time", "全部时间"))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .help(tr(
                        "This detail always shows the conversation's full history, regardless of the time range filter above.",
                        "该详情展示该对话的全部时间数据,不受上方时间范围筛选影响。"
                    ))
                UsageSpeedBadge(summary: detail.speed.summary)
                Spacer()
            }
            Text(detail.info.title ?? tr("Untitled", "（无标题）"))
                .font(.system(size: 18, weight: .semibold))
            metadataRow(tr("Conversation ID", "对话 ID"), detail.info.conversationID, copyable: true)
            metadataRow(tr("Project", "项目"), projectText)
            if let branch = detail.info.gitBranch, !branch.isEmpty { metadataRow(tr("Branch", "分支"), branch) }
            metadataRow(
                tr("Time", "时间"),
                "\(StatsFormatter.day(detail.info.firstAt)) \(StatsFormatter.time(detail.info.firstAt)) – \(StatsFormatter.day(detail.info.lastAt)) \(StatsFormatter.time(detail.info.lastAt))"
            )
            metadataRow(tr("Duration", "持续时间"), durationText)
            if detail.info.includesSubtasks {
                Label(tr("Includes subtask usage", "包含子任务用量"), systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var tokenDetails: some View {
        DetailPanel(title: tr("Token details", "Token 明细")) {
            DetailGrid(items: [
                (tr("Input", "输入"), StatsFormatter.compactToken(detail.totals.inputTokens)),
                (tr("Output", "输出"), StatsFormatter.compactToken(detail.totals.outputTokens)),
                (tr("Cache read", "缓存读取"), StatsFormatter.compactToken(detail.totals.cacheReadTokens)),
                (tr("Cache write", "缓存写入"), cacheCreationText),
                (tr("Requests", "请求数"), StatsFormatter.token(detail.totals.requestCount)),
                (tr("Estimated cost", "API 等值估算费用"), costLabel(detail.costs))
            ])
        }
    }

    private var costDetails: some View {
        DetailPanel(title: tr("Estimated cost breakdown", "估算费用构成")) {
            DetailGrid(items: [
                (tr("Standard cost", "Standard 费用"), StatsFormatter.tierCost(
                    detail.speed.standard.costUSD,
                    hasUnpricedUsage: detail.speed.standardHasUnpricedCost
                )),
                (tr("Fast estimated cost", "Fast 估算费用"), StatsFormatter.tierCost(
                    detail.speed.fast.costUSD,
                    hasUnpricedUsage: detail.speed.fastHasUnpricedCost
                )),
                (tr("Input", "输入"), StatsFormatter.tierCostPrecise(
                    detail.costs.input,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                )),
                (tr("Output", "输出"), StatsFormatter.tierCostPrecise(
                    detail.costs.output,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                )),
                (tr("Cache read", "缓存读取"), StatsFormatter.tierCostPrecise(
                    detail.costs.cacheRead,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                )),
                (tr("Cache write", "缓存写入"), detail.info.cacheCreationAvailable ? StatsFormatter.tierCostPrecise(
                    detail.costs.cacheCreation,
                    hasUnpricedUsage: detail.costs.hasUnpricedUsage
                ) : "N/A"),
                (tr("Total", "合计"), costLabel(detail.costs))
            ])
        }
    }

    private var speedDetails: some View {
        DetailPanel(title: tr("Speed usage", "速度档位用量")) {
            DetailGrid(items: [
                (tr("Standard tokens", "Standard Tokens"), StatsFormatter.compactToken(detail.speed.standard.totalTokens)),
                (tr("Fast tokens", "Fast Tokens"), StatsFormatter.compactToken(detail.speed.fast.totalTokens)),
                (tr("Billing-equivalent tokens", "计费等效 Tokens"), StatsFormatter.billingEquivalentTokens(detail.speed)),
                (tr("Fast multiplier", "Fast 倍率"), StatsFormatter.fastMultiplier(detail.speed)),
                (tr("Unrecognized tokens", "未识别 Tokens"), StatsFormatter.compactToken(detail.speed.unknown.totalTokens)),
                (tr("Standard requests", "Standard 请求"), StatsFormatter.token(detail.speed.standard.requestCount)),
                (tr("Fast requests", "Fast 请求"), StatsFormatter.token(detail.speed.fast.requestCount)),
                (tr("Unrecognized requests", "未识别请求"), StatsFormatter.token(detail.speed.unknown.requestCount))
            ])
        }
    }

    private var modelDetails: some View {
        DetailPanel(title: tr("By model", "按模型")) {
            VStack(spacing: 8) {
                ForEach(detail.models) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.model).fontWeight(.medium)
                            UsageSpeedBadge(summary: item.speed.summary)
                            Spacer()
                            Text("\(StatsFormatter.compactToken(item.totals.totalTokens)) Tokens")
                            Text(costLabel(item.costs)).fontWeight(.semibold)
                        }
                        Text("in \(StatsFormatter.compactToken(item.totals.inputTokens))  ·  out \(StatsFormatter.compactToken(item.totals.outputTokens))  ·  cache \(StatsFormatter.compactToken(item.totals.cacheReadTokens))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if item.speed.fast.requestCount > 0 {
                            Text("Fast \(StatsFormatter.compactToken(item.speed.fast.totalTokens))  ·  \(tr("billing equivalent", "计费等效")) \(StatsFormatter.billingEquivalentTokens(item.speed))  ·  \(StatsFormatter.fastMultiplier(item.speed))  ·  \(StatsFormatter.tierCost(item.speed.fast.costUSD, hasUnpricedUsage: item.speed.fastHasUnpricedCost))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if item.id != detail.models.last?.id { Divider() }
                }
            }
        }
    }

    private var cacheCreationText: String {
        detail.info.cacheCreationAvailable ? StatsFormatter.compactToken(detail.totals.cacheCreationTokens) : "N/A"
    }

    private var projectText: String {
        switch detail.info.projectStatus {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("CCBar system task", "CCBar 系统任务")
        case .unavailable: return "\(detail.info.projectPath) · \(tr("Unavailable", "已不存在"))"
        case .available: return detail.info.projectPath
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

    private func metadataRow(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(2)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 10.5))
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
        Label(text, systemImage: icon)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.11), in: Capsule())
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            content()
        }
        .padding(14)
        .ccPanel(cornerRadius: 10)
    }
}

private struct DetailGrid: View {
    let items: [(String, String)]
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(item.1).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                }
            }
        }
    }
}

private func costLabel(_ costs: ConversationCostTotals) -> String {
    return StatsFormatter.cost(costs.total)
}
