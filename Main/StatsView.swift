import SwiftUI
import Charts

// MARK: - StatsRange

enum StatsRange: Hashable, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case thisYear
    case last7
    case last30
    case all
    case custom

    var englishLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "Week"
        case .thisMonth: return "Month"
        case .thisYear: return "Year"
        case .last7: return "7d"
        case .last30: return "30d"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    var chineseLabel: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        case .thisYear: return "本年"
        case .last7: return "7 天"
        case .last30: return "30 天"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    private static var weekStartMondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    func bounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date) {
        let cal = Self.weekStartMondayCalendar
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        switch self {
        case .today:
            return (startOfToday, startOfTomorrow)
        case .yesterday:
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return (yesterdayStart, startOfToday)
        case .thisWeek:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let weekStart = cal.date(from: comps) ?? startOfToday
            return (weekStart, startOfTomorrow)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: comps) ?? startOfToday
            return (monthStart, startOfTomorrow)
        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let yearStart = cal.date(from: comps) ?? startOfToday
            return (yearStart, startOfTomorrow)
        case .last7:
            let from = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .last30:
            let from = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .all:
            return (.distantPast, .distantFuture)
        case .custom:
            let from = cal.startOfDay(for: customFrom)
            let toBase = cal.startOfDay(for: customTo)
            let to = cal.date(byAdding: .day, value: 1, to: toBase) ?? toBase
            return (from, max(from, to))
        }
    }

    /// 上一个等长区间(用于 delta 对比)。`.all` / `.custom` 返回 nil(无法对比)。
    func previousBounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date)? {
        switch self {
        case .all, .custom:
            return nil
        default:
            break
        }
        let current = bounds(now: now, customFrom: customFrom, customTo: customTo)
        let length = current.to.timeIntervalSince(current.from)
        guard length > 0, length.isFinite else { return nil }
        return (current.from.addingTimeInterval(-length), current.from)
    }
}

// MARK: - Service filter (sidebar)

enum StatsServiceFilter: Hashable, CaseIterable {
    case all
    case codex
    case claude
    case grok

    var englishLabel: String {
        switch self {
        case .all: return "All"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        }
    }

    var chineseLabel: String {
        switch self {
        case .all: return "全部"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        }
    }

    var tint: Color? {
        switch self {
        case .all: return nil
        case .codex: return .codexAccent
        case .claude: return .claudeAccent
        case .grok: return .grokAccent
        }
    }
}

enum StatsViewMode: Hashable {
    case overview
    case conversations
    case timeline
}

// MARK: - StatsView

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var range: StatsRange = .today
    @State private var serviceFilter: StatsServiceFilter = .all
    @State private var viewMode: StatsViewMode = .overview
    @State private var selectedDay: Date?
    @State private var customFrom: Date = Calendar.current.startOfDay(
        for: Date().addingTimeInterval(-7 * 86400)
    )
    @State private var customTo: Date = Calendar.current.startOfDay(for: Date())

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            if viewMode == .conversations {
                ConversationStatsView(
                    range: $range,
                    customFrom: $customFrom,
                    customTo: $customTo,
                    serviceFilter: serviceFilter
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        mainContent(canvasWidth: proxy.size.width)
                    }
                }
            }
        }
    }

    /// 宽度断点:主画布达到该宽度时,时间线的折线图与表格改为左右并排;
    /// 更窄(如最小窗口)时回落单列堆叠,避免内容挤压截断。
    private static let wideCanvasWidth: CGFloat = 880

    @ViewBuilder
    private func mainContent(canvasWidth: CGFloat) -> some View {
        let isWide = canvasWidth >= Self.wideCanvasWidth
        switch viewMode {
        case .overview:
            overviewContent
        case .conversations:
            EmptyView()
        case .timeline:
            timelineContent(isWide: isWide)
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if range == .custom { customRangeRow }

            kpiRow.padding(.top, 6)

            tokenBreakdownPanel
            byServicePanel

            dailyUsagePanel

            byModelPanel
        }
        .padding(20)
    }

    private func timelineContent(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            timelineHeader
            if timelineSections.isEmpty {
                placeholderHeight(220, message: tr("No accounts", "暂无账号"))
                    .ccPanel(cornerRadius: 12)
            } else {
                ForEach(timelineSections) { section in
                    QuotaTimelineAccountPanel(section: section, isWide: isWide)
                }
            }
        }
        .padding(20)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: "Service", chinese: "服务") {
                ForEach(StatsServiceFilter.allCases, id: \.self) { item in
                    sidebarItem(
                        english: item.englishLabel,
                        chinese: item.chineseLabel,
                        tint: item.tint,
                        active: serviceFilter == item
                    ) {
                        serviceFilter = item
                    }
                }
            }

            sidebarGroup(title: "View", chinese: "视图") {
                sidebarItem(
                    english: "Overview",
                    chinese: "概览",
                    icon: "rectangle.split.2x2",
                    active: viewMode == .overview
                ) {
                    viewMode = .overview
                }
                sidebarItem(
                    english: "Conversations",
                    chinese: "对话",
                    icon: "bubble.left.and.bubble.right",
                    active: viewMode == .conversations
                ) {
                    viewMode = .conversations
                }
                sidebarItem(
                    english: "Timeline",
                    chinese: "时间线",
                    icon: "chart.line.uptrend.xyaxis",
                    active: viewMode == .timeline
                ) {
                    viewMode = .timeline
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func sidebarGroup<Content: View>(
        title: String,
        chinese: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tr(title, chinese).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            content()
        }
    }

    private func sidebarItem(
        english: String,
        chinese: String,
        tint: Color? = nil,
        icon: String? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 13, height: 13)
                        .foregroundStyle(active ? Color.white : Color.secondary)
                } else if let tint {
                    ServiceMark(color: tint, size: 8)
                        .frame(width: 13, height: 13, alignment: .center)
                } else {
                    Color.clear.frame(width: 13, height: 13)
                }

                Text(tr(english, chinese))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: Top bar (segmented + custom)

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer()
            if appState.usageService.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(tr("Recalculating usage…", "正在重新计算用量…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { r in
                    Text(tr(r.englishLabel, r.chineseLabel)).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var customRangeRow: some View {
        HStack(spacing: 12) {
            DatePicker(tr("From", "起"), selection: $customFrom, displayedComponents: .date)
                .datePickerStyle(.compact)
            DatePicker(tr("To", "止"), selection: $customTo, in: customFrom..., displayedComponents: .date)
                .datePickerStyle(.compact)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: KPI row

    private var kpiRow: some View {
        HStack(spacing: 12) {
            KPICard(
                english: "Total tokens",
                chinese: "总 Tokens",
                value: StatsFormatter.compactToken(currentTotalsAll.totalTokens),
                delta: deltaPercent(current: Double(currentTotalsAll.totalTokens),
                                    previous: Double(previousTotalsAll.totalTokens)),
                tint: nil,
                dimmed: false
            )
            KPICard(
                english: "Total spend",
                chinese: "总花费",
                value: StatsFormatter.tierCost(
                    currentTotalsAll.costUSD,
                    hasUnpricedUsage: currentTotalsAll.hasUnpricedUsage
                ),
                delta: costDelta(current: currentTotalsAll, previous: previousTotalsAll),
                tint: nil,
                dimmed: false
            )
            KPICard(
                english: "Codex",
                chinese: "Codex",
                value: serviceFilter != .all && serviceFilter != .codex
                    ? "—"
                    : StatsFormatter.tierCost(
                        currentTotals(.codex).costUSD,
                        hasUnpricedUsage: currentTotals(.codex).hasUnpricedUsage
                    ),
                delta: serviceFilter != .all && serviceFilter != .codex
                    ? nil
                    : costDelta(current: currentTotals(.codex), previous: previousTotals(.codex)),
                tint: .codexAccent,
                dimmed: serviceFilter != .all && serviceFilter != .codex
            )
            KPICard(
                english: "Claude Code",
                chinese: "Claude Code",
                value: serviceFilter != .all && serviceFilter != .claude
                    ? "—"
                    : StatsFormatter.tierCost(
                        currentTotals(.claude).costUSD,
                        hasUnpricedUsage: currentTotals(.claude).hasUnpricedUsage
                    ),
                delta: serviceFilter != .all && serviceFilter != .claude
                    ? nil
                    : costDelta(current: currentTotals(.claude), previous: previousTotals(.claude)),
                tint: .claudeAccent,
                dimmed: serviceFilter != .all && serviceFilter != .claude
            )
            KPICard(
                english: "Grok",
                chinese: "Grok",
                value: serviceFilter != .all && serviceFilter != .grok
                    ? "—"
                    : StatsFormatter.tierCost(
                        currentTotals(.grok).costUSD,
                        hasUnpricedUsage: currentTotals(.grok).hasUnpricedUsage
                    ),
                delta: serviceFilter != .all && serviceFilter != .grok
                    ? nil
                    : costDelta(current: currentTotals(.grok), previous: previousTotals(.grok)),
                tint: .grokAccent,
                dimmed: serviceFilter != .all && serviceFilter != .grok
            )
        }
    }

    // MARK: Token breakdown panel

    private var tokenBreakdownPanel: some View {
        Panel(title: "Token breakdown", chinese: "Token 拆分") {
            VStack(alignment: .leading, spacing: 12) {
                // 隐藏 hero:总 Tokens 与 KPI 卡 1 重复;分项使用横排图例。
                TokenBreakdownView(totals: currentTotalsAll, showsHero: false)
                if currentSpeedBreakdown.fast.requestCount > 0 {
                    Divider()
                    FastUsageSummaryView(breakdown: currentSpeedBreakdown)
                }
            }
        }
    }

    // MARK: Daily usage panel

    private var dailyUsagePanel: some View {
        Panel(title: "Daily usage", chinese: "每日用量", right: AnyView(
            HStack(spacing: 8) {
                if chartUsesContextWindow {
                    Text(tr("Last 14 days · highlighted = selected", "近 14 天 · 高亮为所选范围"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                LegendChip(color: .codexAccent, label: "Codex")
                LegendChip(color: .claudeAccent, label: "Claude Code")
                LegendChip(color: .grokAccent, label: "Grok")
            }
        )) {
            VStack(spacing: 6) {
                if dailySamples.isEmpty {
                    if appState.usageService.isScanning {
                        loadingPlaceholder(160, message: tr("Recalculating…", "正在计算中…"))
                    } else {
                        placeholderHeight(160, message: tr("No data", "无数据"))
                    }
                } else {
                    Chart {
                        ForEach(dailySamples) { sample in
                            BarMark(
                                x: .value("Day", sample.day, unit: .day),
                                y: .value("Cost", sample.codexCost.doubleValue),
                                width: .fixed(dailyBarWidth),
                                stacking: .standard
                            )
                            .foregroundStyle(Color.codexAccent)
                            .opacity(barOpacity(for: sample))
                            .cornerRadius(2)

                            BarMark(
                                x: .value("Day", sample.day, unit: .day),
                                y: .value("Cost", sample.claudeCost.doubleValue),
                                width: .fixed(dailyBarWidth),
                                stacking: .standard
                            )
                            .foregroundStyle(Color.claudeAccent)
                            .opacity(barOpacity(for: sample))
                            .cornerRadius(2)

                            BarMark(
                                x: .value("Day", sample.day, unit: .day),
                                y: .value("Cost", sample.grokCost.doubleValue),
                                width: .fixed(dailyBarWidth),
                                stacking: .standard
                            )
                            .foregroundStyle(Color.grokAccent)
                            .opacity(barOpacity(for: sample))
                            .cornerRadius(2)
                        }

                        if let selected = selectedSample {
                            RuleMark(x: .value("Day", selected.day, unit: .day))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                                .annotation(
                                    position: .top,
                                    spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                                ) {
                                    DailyTooltip(sample: selected)
                                }
                        }
                    }
                    .chartXSelection(value: $selectedDay)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: max(1, dailySamples.count / 5))) { value in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                                           centered: true)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 160)
                    .animation(.easeOut(duration: 0.12), value: selectedDay)
                    .onChange(of: range) { _, _ in selectedDay = nil }
                    .onChange(of: serviceFilter) { _, _ in selectedDay = nil }
                }
            }
        }
    }

    // MARK: By service panel

    private var byServicePanel: some View {
        Panel(title: "By service", chinese: "按服务") {
            HStack(alignment: .top, spacing: 16) {
                ByServiceRow(
                    title: "Codex",
                    subtitle: "OpenAI",
                    tint: .codexAccent,
                    value: currentTotals(.codex).costUSD,
                    totalValue: currentTotalsAll.costUSD,
                    totals: currentTotals(.codex),
                    speed: currentSpeedBreakdown(.codex)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                ByServiceRow(
                    title: "Claude Code",
                    subtitle: "Anthropic",
                    tint: .claudeAccent,
                    value: currentTotals(.claude).costUSD,
                    totalValue: currentTotalsAll.costUSD,
                    totals: currentTotals(.claude),
                    speed: currentSpeedBreakdown(.claude)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                ByServiceRow(
                    title: "Grok",
                    subtitle: "xAI",
                    tint: .grokAccent,
                    value: currentTotals(.grok).costUSD,
                    totalValue: currentTotalsAll.costUSD,
                    totals: currentTotals(.grok),
                    speed: currentSpeedBreakdown(.grok)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: By model panel(保留旧的按模型聚合)

    private var byModelPanel: some View {
        Panel(title: "By model", chinese: "按模型") {
            VStack(alignment: .leading, spacing: 10) {
                if serviceFilter == .all || serviceFilter == .codex {
                    modelGroup(title: "Codex", tint: .codexAccent, rows: modelRows(for: .codex))
                }
                if serviceFilter == .all {
                    Divider()
                }
                if serviceFilter == .all || serviceFilter == .claude {
                    modelGroup(title: "Claude Code", tint: .claudeAccent, rows: modelRows(for: .claude))
                }
                if serviceFilter == .all {
                    Divider()
                }
                if serviceFilter == .all || serviceFilter == .grok {
                    modelGroup(title: "Grok", tint: .grokAccent, rows: modelRows(for: .grok))
                }
            }
        }
    }

    // MARK: Timeline

    private var timelineHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Today's Primary Quota", "今日主要额度"))
                    .font(.system(size: 18, weight: .semibold))
                Text(tr("Only quota changes are shown.", "仅展示额度发生变化的时间点。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(StatsFormatter.day(Date()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var timelineSections: [QuotaTimelineSection] {
        var sections: [QuotaTimelineSection] = []

        if serviceFilter == .all || serviceFilter == .codex {
            let key = QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
            var addedPrimaryCodex = false
            if shouldShowTimelineSection(key: key, snapshot: appState.codexQuota, accountExists: appState.codexAccount != nil) {
                sections.append(timelineSection(
                    key: key,
                    title: "Codex",
                    tint: .codexAccent,
                    snapshot: appState.codexQuota,
                    isLoading: appState.refreshState(for: .codex).inFlight
                ))
                addedPrimaryCodex = true
            }

            for (idx, account) in appState.importedCodexAccounts.enumerated() {
                // 展示层去重:主账号段已展示时,跳过与它同身份的镜像导入项(历史 key 不变,仍在盘上)。
                if addedPrimaryCodex && appState.importedCodexAccountMirrorsPrimary(account) { continue }
                let key = QuotaHistoryAccountKey.codexImported(id: account.id)
                sections.append(timelineSection(
                    key: key,
                    title: importedCodexTimelineTitle(account, index: idx),
                    tint: .codexAccent,
                    snapshot: appState.importedCodexQuota(for: account),
                    isLoading: appState.importedCodexRefreshState(for: account).inFlight
                ))
            }
        }

        if serviceFilter == .all || serviceFilter == .claude {
            let key = QuotaHistoryAccountKey.claudePrimary()
            if shouldShowTimelineSection(key: key, snapshot: appState.claudeQuota, accountExists: appState.claudeAccount != nil) {
                sections.append(timelineSection(
                    key: key,
                    title: "Claude Code",
                    tint: .claudeAccent,
                    snapshot: appState.claudeQuota,
                    isLoading: appState.refreshState(for: .claude).inFlight
                ))
            }
        }

        if serviceFilter == .all || serviceFilter == .grok {
            let key = QuotaHistoryAccountKey.grokPrimary(userId: appState.grokAccount?.userId)
            if shouldShowTimelineSection(key: key, snapshot: appState.grokQuota, accountExists: appState.grokAccount != nil) {
                sections.append(timelineSection(
                    key: key,
                    title: "Grok",
                    tint: .grokAccent,
                    snapshot: appState.grokQuota,
                    isLoading: appState.refreshState(for: .grok).inFlight
                ))
            }
        }

        return sections
    }

    private func timelineSection(
        key: String,
        title: String,
        tint: Color,
        snapshot: QuotaSnapshot?,
        isLoading: Bool
    ) -> QuotaTimelineSection {
        let events = timelineEvents(for: key)
        let sample = appState.quotaHistory.lastSamples[key]
        return QuotaTimelineSection(
            accountKey: key,
            title: title,
            tint: tint,
            limitKind: sample?.limitKind ?? snapshot?.primaryLimit?.kind,
            currentRemaining: sample?.remainingPercent ?? roundedRemaining(snapshot),
            totalDelta: events.reduce(0) { $0 + $1.deltaPercent },
            latestEventAt: events.last?.sampledAt,
            events: events,
            isLoading: isLoading
        )
    }

    private func shouldShowTimelineSection(key: String, snapshot: QuotaSnapshot?, accountExists: Bool) -> Bool {
        accountExists || snapshot != nil || appState.quotaHistory.lastSamples[key] != nil || !timelineEvents(for: key).isEmpty
    }

    private func timelineEvents(for key: String) -> [QuotaChangeEvent] {
        appState.quotaHistory.events
            .filter { $0.accountKey == key }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    private func roundedRemaining(_ snapshot: QuotaSnapshot?) -> Int? {
        guard let remaining = snapshot?.primaryWindow?.remainingPercent else { return nil }
        return max(0, min(100, Int(remaining.rounded())))
    }

    private func importedCodexTimelineTitle(_ account: ImportedCodexAccount, index: Int) -> String {
        if SettingsStore.shared.privacyMode {
            return tr("Codex · Account \(index + 1)", "Codex · 账号 \(index + 1)")
        }
        if !account.alias.isEmpty { return "Codex · \(account.alias)" }
        if let email = account.email, !email.isEmpty {
            return "Codex · \(email.components(separatedBy: "@").first ?? email)"
        }
        return "Codex · \(account.id)"
    }

    private func modelGroup(title: String, tint: Color, rows: [ModelRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ServiceMark(color: tint, size: 6, cornerRadius: 1.5)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.tertiary)
            }
            if rows.isEmpty {
                Text(tr("No data", "无数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.model)
                                .font(.system(size: 12.5))
                            Spacer()
                            Text("\(StatsFormatter.compactToken(row.totals.totalTokens)) Tokens")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                            Text(StatsFormatter.tierCost(
                                row.totals.costUSD,
                                hasUnpricedUsage: row.totals.hasUnpricedUsage
                            ))
                                .font(.system(size: 12.5, weight: .semibold))
                                .monospacedDigit()
                        }
                        TokenBreakdownInlineRow(totals: row.totals)
                        if row.speed.fast.requestCount > 0 {
                            FastUsageInlineRow(breakdown: row.speed)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    // MARK: Data helpers

    private var rangeBounds: (from: Date, to: Date) {
        range.bounds(customFrom: customFrom, customTo: customTo)
    }

    private var previousRangeBounds: (from: Date, to: Date)? {
        range.previousBounds(customFrom: customFrom, customTo: customTo)
    }

    private var filteredBuckets: [UsageBucket] {
        let (from, to) = rangeBounds
        return filteredBuckets(from: from, to: to)
    }

    private func filteredBuckets(from: Date, to: Date) -> [UsageBucket] {
        let buckets = appState.usageService.aggregator.snapshot()
            .filter { $0.day >= from && $0.day < to }
        switch serviceFilter {
        case .all:
            return buckets
        case .codex:
            return buckets.filter { $0.app == .codex }
        case .claude:
            return buckets.filter { $0.app == .claude }
        case .grok:
            return buckets.filter { $0.app == .grok }
        }
    }

    /// 所选范围只有一天(今天 / 昨天 / 单日自定义)时,每日用量图表扩展为近 14 天上下文,
    /// 范围内柱子高亮、范围外降透明;KPI 与其他面板口径不变。
    private var chartUsesContextWindow: Bool {
        let (from, to) = rangeBounds
        // 单日跨度按 ≤1.5 天判断,容忍夏令时导致的 23/25 小时。
        return to > from && to.timeIntervalSince(from) <= 86400 * 1.5
    }

    /// 图表展示窗口:上下文模式取「范围结束日往前 14 天」,保证过去的单日自定义也有前文可看。
    private var chartBounds: (from: Date, to: Date) {
        let bounds = rangeBounds
        guard chartUsesContextWindow else { return bounds }
        let from = Calendar.current.date(byAdding: .day, value: -14, to: bounds.to) ?? bounds.from
        return (min(from, bounds.from), bounds.to)
    }

    private var currentTotalsAll: UsageTotals {
        var t = UsageTotals.zero
        for b in filteredBuckets { t.add(b) }
        return t
    }

    private func currentTotals(_ app: UsageApp) -> UsageTotals {
        var t = UsageTotals.zero
        for b in filteredBuckets where b.app == app { t.add(b) }
        return t
    }

    private var currentSpeedBreakdown: UsageSpeedBreakdown {
        var result = UsageSpeedBreakdown()
        for bucket in filteredBuckets { result.add(bucket) }
        return result
    }

    private func currentSpeedBreakdown(_ app: UsageApp) -> UsageSpeedBreakdown {
        var result = UsageSpeedBreakdown()
        for bucket in filteredBuckets where bucket.app == app { result.add(bucket) }
        return result
    }

    private var previousTotalsAll: UsageTotals {
        guard let bounds = previousRangeBounds else { return .zero }
        let buckets = appState.usageService.aggregator.snapshot()
            .filter { $0.day >= bounds.from && $0.day < bounds.to }
        var t = UsageTotals.zero
        for b in buckets {
            switch serviceFilter {
            case .all: break
            case .codex where b.app != .codex: continue
            case .claude where b.app != .claude: continue
            case .grok where b.app != .grok: continue
            default: break
            }
            t.add(b)
        }
        return t
    }

    private func previousTotals(_ app: UsageApp) -> UsageTotals {
        guard let bounds = previousRangeBounds else { return .zero }
        let buckets = appState.usageService.aggregator.snapshot()
            .filter { $0.app == app && $0.day >= bounds.from && $0.day < bounds.to }
        var t = UsageTotals.zero
        for b in buckets { t.add(b) }
        return t
    }

    private func deltaPercent(current: Double, previous: Double) -> Double? {
        guard previousRangeBounds != nil else { return nil }
        guard previous > 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    private func costDelta(current: UsageTotals, previous: UsageTotals) -> Double? {
        return deltaPercent(current: current.costUSD.doubleValue, previous: previous.costUSD.doubleValue)
    }

    private var dailySamples: [DailySample] {
        let (from, to) = chartBounds
        var byDay: [Date: (codex: UsageTotals, claude: UsageTotals, grok: UsageTotals)] = [:]
        for b in filteredBuckets(from: from, to: to) {
            var triple = byDay[b.day] ?? (.zero, .zero, .zero)
            switch b.app {
            case .codex: triple.codex.add(b)
            case .claude: triple.claude.add(b)
            case .grok: triple.grok.add(b)
            }
            byDay[b.day] = triple
        }
        return byDay
            .map {
                DailySample(
                    day: $0.key,
                    codex: $0.value.codex,
                    claude: $0.value.claude,
                    grok: $0.value.grok
                )
            }
            .sorted { $0.day < $1.day }
    }

    /// 把 chartXSelection 吸附到的连续 Date 映射到最近的那一天。
    private var selectedSample: DailySample? {
        guard let selectedDay else { return nil }
        return dailySamples.min {
            abs($0.day.timeIntervalSince(selectedDay)) < abs($1.day.timeIntervalSince(selectedDay))
        }
    }

    /// 悬浮选中某天时,非选中柱降透明以聚焦;无悬浮时,上下文窗口内
    /// 只有所选范围内的柱子全彩,范围外的上下文柱降透明。
    private func barOpacity(for sample: DailySample) -> Double {
        if let selected = selectedSample {
            return selected.id == sample.id ? 1 : 0.35
        }
        guard chartUsesContextWindow else { return 1 }
        let (from, to) = rangeBounds
        return (sample.day >= from && sample.day < to) ? 1 : 0.35
    }

    /// 柱宽用固定值而非交给 Swift Charts 自动计算——天数很少(极端情况只有 1 天)时,
    /// 自动宽度会把柱子撑到接近整个绘图区;天数越多则相应调窄,避免拥挤。
    private var dailyBarWidth: CGFloat {
        switch dailySamples.count {
        case 0...3: return 28
        case 4...14: return 18
        case 15...45: return 10
        default: return 5
        }
    }

    private func modelRows(for app: UsageApp) -> [ModelRow] {
        var byModel: [String: (totals: UsageTotals, speed: UsageSpeedBreakdown)] = [:]
        for b in filteredBuckets where b.app == app {
            var item = byModel[b.model] ?? (.zero, UsageSpeedBreakdown())
            item.totals.add(b)
            item.speed.add(b)
            byModel[b.model] = item
        }
        return byModel
            .map { ModelRow(model: $0.key, totals: $0.value.totals, speed: $0.value.speed) }
            .sorted {
                if $0.totals.costUSD == $1.totals.costUSD {
                    return $0.model < $1.model
                }
                return $0.totals.costUSD > $1.totals.costUSD
            }
    }

    private func placeholderHeight(_ height: CGFloat, message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    /// 区分"还在扫描/刷新中"和"确实没有数据"两种空态,避免用户误以为没有记录。
    private func loadingPlaceholder(_ height: CGFloat, message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

// MARK: - Panel container

private struct Panel<Content: View>: View {
    let title: String
    let chinese: String
    var right: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr(title, chinese))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let right { right }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }
}

private struct LegendChip: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            ServiceMark(color: color, size: 9)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Daily usage tooltip

/// 每日用量柱状图的悬浮浮层:展示某天各服务花费、合计花费与合计 tokens。
private struct DailyTooltip: View {
    let sample: DailySample

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StatsFormatter.day(sample.day))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            serviceRow(color: .codexAccent, label: "Codex", value: StatsFormatter.tierCost(
                sample.codexCost,
                hasUnpricedUsage: sample.codex.hasUnpricedUsage
            ))
            serviceRow(color: .claudeAccent, label: "Claude Code", value: StatsFormatter.tierCost(
                sample.claudeCost,
                hasUnpricedUsage: sample.claude.hasUnpricedUsage
            ))
            serviceRow(color: .grokAccent, label: "Grok", value: StatsFormatter.tierCost(
                sample.grokCost,
                hasUnpricedUsage: sample.grok.hasUnpricedUsage
            ))

            Divider()

            totalRow(label: tr("Total", "合计"), value: StatsFormatter.tierCost(
                sample.totalCost,
                hasUnpricedUsage: sample.totalUsage.hasUnpricedUsage
            ), emphasized: true)
            totalRow(label: "Tokens", value: StatsFormatter.compactToken(sample.totalTokens), emphasized: true)

            Divider()

            totalRow(label: tr("Input", "输入"), value: StatsFormatter.compactToken(sample.totalUsage.inputTokens), emphasized: false)
            totalRow(label: tr("Output", "输出"), value: StatsFormatter.compactToken(sample.totalUsage.outputTokens), emphasized: false)
            totalRow(label: tr("Cache hit", "缓存命中"), value: StatsFormatter.compactToken(sample.totalUsage.cacheReadTokens), emphasized: false)
            totalRow(label: tr("Hit rate", "命中率"), value: hitRateText(sample.totalUsage.cacheHitRate), emphasized: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 200, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .ccPanelStroke(cornerRadius: 8)
    }

    private func serviceRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            ServiceMark(color: color)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func totalRow(label: String, value: String, emphasized: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: emphasized ? 12 : 10.5, weight: emphasized ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: emphasized ? 12 : 10.5, weight: emphasized ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? .primary : .secondary)
    }
}

// MARK: - KPI card

private struct KPICard: View {
    let english: String
    let chinese: String
    let value: String
    let delta: Double?
    let tint: Color?
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let tint {
                    ServiceMark(color: tint, size: 6, cornerRadius: 1.5)
                }
                Text(tr(english, chinese))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .kerning(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                if let delta, delta != 0 {
                    Text(formatDelta(delta))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(delta >= 0 ? Color.red : Color.green)
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 10)
        .opacity(dimmed ? 0.35 : 1)
    }

    private func formatDelta(_ value: Double) -> String {
        let arrow = value >= 0 ? "↑" : "↓"
        let abs = Swift.abs(value)
        return "\(arrow) \(String(format: "%.1f", abs))%"
    }
}

// MARK: - Token breakdown

private func hitRateText(_ rate: Double) -> String {
    "\(Int((max(0, min(1, rate)) * 100).rounded()))%"
}

private enum TokenCategoryStyle {
    static let input = 0.85
    static let output = 0.6
    static let cacheRead = 0.4
}

/// KPI 行下方的 Token 拆分面板内容:总量 + 命中率 + 迷你堆叠条 + 输入/输出/缓存命中三项。
/// 缓存写入(创建)不展示——量级小、Codex 协议也不上报,详见与用户的讨论。
struct TokenBreakdownView: View {
    let totals: UsageTotals
    /// 概览面板传 false:总 Tokens 与 KPI 卡重复不再展示,分项改为横排图例。
    /// 对话明细保持默认 true(hero 版:大数字 + 横排 3 列)。
    var showsHero: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHero {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Total tokens", "总 Tokens"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(StatsFormatter.compactToken(totals.totalTokens))
                            .font(.system(size: 20, weight: .semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tr("Cache hit rate", "缓存命中率"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(hitRateText(totals.cacheHitRate))
                            .font(.system(size: 20, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.green)
                    }
                }

                TokenStackBar(totals: totals)

                HStack(spacing: 0) {
                    stat(tr("Input", "输入"), StatsFormatter.compactToken(totals.inputTokens), dot: TokenCategoryStyle.input)
                    stat(tr("Output", "输出"), StatsFormatter.compactToken(totals.outputTokens), dot: TokenCategoryStyle.output)
                    stat(tr("Cache hit", "缓存命中"), StatsFormatter.compactToken(totals.cacheReadTokens), dot: TokenCategoryStyle.cacheRead)
                }
            } else {
                TokenStackBar(totals: totals)

                HStack(spacing: 0) {
                    stat(tr("Input", "输入"), StatsFormatter.compactToken(totals.inputTokens), dot: TokenCategoryStyle.input)
                    stat(tr("Output", "输出"), StatsFormatter.compactToken(totals.outputTokens), dot: TokenCategoryStyle.output)
                    stat(tr("Cache hit", "缓存命中"), StatsFormatter.compactToken(totals.cacheReadTokens), dot: TokenCategoryStyle.cacheRead)
                    stat(tr("Hit rate", "命中率"), hitRateText(totals.cacheHitRate), valueColor: .green)
                }
                .padding(.top, 2)
            }
        }
    }

    private func stat(
        _ label: String,
        _ value: String,
        dot: Double? = nil,
        valueColor: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(dot.map { Color.primary.opacity($0) } ?? Color.clear)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 输入 / 输出 / 缓存命中 三段迷你堆叠条,风格延续 `ProgressBar`(Capsule + 灰底轨道)。
private struct TokenStackBar: View {
    let totals: UsageTotals
    var height: CGFloat = 8

    private var segments: [(tokens: Int, opacity: Double)] {
        [
            (totals.inputTokens, TokenCategoryStyle.input),
            (totals.outputTokens, TokenCategoryStyle.output),
            (totals.cacheReadTokens, TokenCategoryStyle.cacheRead)
        ]
    }

    private var total: Int { segments.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Color.primary.opacity(segment.opacity)
                        .frame(width: proxy.size.width * ratio(segment.tokens))
                }
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.18))
        .clipShape(Capsule())
    }

    private func ratio(_ tokens: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(tokens) / Double(total)
    }
}

/// 「按服务」「按模型」行下的紧凑一行:入 / 出 / 缓存命中 + 命中率。
private struct TokenBreakdownInlineRow: View {
    let totals: UsageTotals

    var body: some View {
        HStack(spacing: 10) {
            item(tr("in", "入"), StatsFormatter.compactToken(totals.inputTokens))
            item(tr("out", "出"), StatsFormatter.compactToken(totals.outputTokens))
            item(tr("cache hit", "缓存命中"), StatsFormatter.compactToken(totals.cacheReadTokens))
            Spacer(minLength: 4)
            item(tr("hit rate", "命中率"), hitRateText(totals.cacheHitRate), emphasized: true)
        }
        .font(.system(size: 10.5))
    }

    private func item(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .monospacedDigit()
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? Color.green : Color.secondary)
        }
    }
}

/// Overview 的 Fast 汇总：原始 Tokens 与计费等效 Tokens 分开展示，避免污染总 Tokens 口径。
private struct FastUsageSummaryView: View {
    let breakdown: UsageSpeedBreakdown

    var body: some View {
        HStack(spacing: 0) {
            item(tr("Fast tokens", "Fast Tokens"), StatsFormatter.compactToken(breakdown.fast.totalTokens))
            item(tr("Billing-equivalent tokens", "计费等效 Tokens"), StatsFormatter.billingEquivalentTokens(breakdown))
            item(tr("Fast multiplier", "Fast 倍率"), StatsFormatter.fastMultiplier(breakdown))
            item(tr("Fast estimated cost", "Fast 估算费用"), StatsFormatter.tierCost(
                breakdown.fast.costUSD,
                hasUnpricedUsage: breakdown.fastHasUnpricedCost
            ))
            item(tr("Fast share", "Fast 占比"), fastShare)
        }
    }

    private var fastShare: String {
        let total = breakdown.standard.totalTokens + breakdown.fast.totalTokens + breakdown.unknown.totalTokens
        guard total > 0 else { return "0%" }
        return "\(Int((Double(breakdown.fast.totalTokens) / Double(total) * 100).rounded()))%"
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FastUsageInlineRow: View {
    let breakdown: UsageSpeedBreakdown

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8.5, weight: .semibold))
            Text("Fast \(StatsFormatter.compactToken(breakdown.fast.totalTokens))")
            Text("·")
            Text("\(tr("billing equivalent", "计费等效")) \(StatsFormatter.billingEquivalentTokens(breakdown))")
            Text("·")
            Text(StatsFormatter.fastMultiplier(breakdown))
            Text("·")
            Text(StatsFormatter.tierCost(
                breakdown.fast.costUSD,
                hasUnpricedUsage: breakdown.fastHasUnpricedCost
            ))
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

// MARK: - By service row

private struct ByServiceRow: View {
    let title: String
    let subtitle: String
    let tint: Color
    let value: Decimal
    let totalValue: Decimal
    let totals: UsageTotals
    let speed: UsageSpeedBreakdown

    var body: some View {
        // 花费金额不再展示:与 KPI 行的 Codex / Claude Code 卡完全重复,此处保留占比 + 量。
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ServiceMark(color: tint, size: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text(tr("of spend", "占比"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ProgressBar(value: ratio, tint: tint, height: 5)
                .padding(.leading, 16)
            Text("\(StatsFormatter.compactToken(totals.totalTokens)) Tokens")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.leading, 16)
            TokenBreakdownInlineRow(totals: totals)
                .padding(.leading, 16)
            if speed.fast.requestCount > 0 {
                FastUsageInlineRow(breakdown: speed)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 8)
    }

    private var ratio: Double {
        guard totalValue > 0 else { return 0 }
        let n = NSDecimalNumber(decimal: value).doubleValue
        let d = NSDecimalNumber(decimal: totalValue).doubleValue
        guard d > 0 else { return 0 }
        return n / d
    }
}

// MARK: - Quota timeline

private struct QuotaTimelineAccountPanel: View {
    let section: QuotaTimelineSection
    var isWide: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if section.events.isEmpty {
                if section.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(tr("Loading…", "加载中…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                } else {
                    Text(tr("No changes today", "今天暂无变动"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                }
            } else if isWide {
                // 图表与表格是同一数据的两个视角,宽画布下左图右表,压缩面板高度。
                HStack(alignment: .top, spacing: 14) {
                    QuotaTimelineChart(events: section.events, tint: section.tint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                    QuotaTimelineTable(events: section.events)
                        .frame(width: 384)
                }
            } else {
                QuotaTimelineChart(events: section.events, tint: section.tint)
                    .frame(height: 180)
                QuotaTimelineTable(events: section.events)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 7) {
                ServiceMark(color: section.tint, size: 8)
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                if let kind = section.limitKind {
                    Text(limitKindLabel(kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            Spacer()
            timelineMetric(label: tr("Current", "当前"), value: currentText)
            timelineMetric(label: tr("Today", "今日"), value: StatsFormatter.quotaDelta(section.totalDelta))
            timelineMetric(label: tr("Latest", "最近"), value: latestText)
        }
    }

    private func timelineMetric(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var currentText: String {
        guard let value = section.currentRemaining else { return "--" }
        return "\(value)%"
    }

    private var latestText: String {
        guard let date = section.latestEventAt else { return "--" }
        return StatsFormatter.time(date)
    }

    private func limitKindLabel(_ kind: QuotaLimitKind) -> String {
        switch kind {
        case .fiveHour: return "5H"
        case .weekly: return "WK"
        case .modelWeekly: return tr("MODEL", "模型")
        case .unknown: return tr("CURRENT", "当前")
        }
    }
}

private struct QuotaTimelineChart: View {
    let events: [QuotaChangeEvent]
    let tint: Color

    var body: some View {
        Chart(events) { event in
            LineMark(
                x: .value("Time", event.sampledAt),
                y: .value("Remaining", event.afterRemainingPercent)
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

            PointMark(
                x: .value("Time", event.sampledAt),
                y: .value("Remaining", event.afterRemainingPercent)
            )
            .foregroundStyle(statusColor(remainingPercent: Double(event.afterRemainingPercent), tint: tint))
            .symbolSize(34)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) { value in
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        // 左:Y 轴刻度不贴面板内容左缘;右:末尾数据点 / X 轴标签不贴相邻表格。
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }
}

private struct QuotaTimelineTable: View {
    let events: [QuotaChangeEvent]

    /// 行数超过该值时,表体固定高度内部滚动(表头固定),保证面板高度稳定。
    private static let maxVisibleRows = 8
    /// 单行高度估算:11.5pt 行文本(~14pt)+ 上下 7pt padding + Divider。
    private static let rowHeight: CGFloat = 29

    private var rows: [QuotaChangeEvent] {
        events.sorted { $0.sampledAt > $1.sampledAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if rows.count > Self.maxVisibleRows {
                ScrollView {
                    VStack(spacing: 0) {
                        rowsBody
                    }
                }
                .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight)
            } else {
                rowsBody
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var rowsBody: some View {
        ForEach(rows) { event in
            Divider()
            row(event)
        }
    }

    private var headerRow: some View {
        HStack {
            tableHeader("Time", "时间", width: 82, alignment: .leading)
            tableHeader("Change", "变动值", width: 82, alignment: .trailing)
            tableHeader("After", "变动后剩余", width: 104, alignment: .trailing)
            tableHeader("Reset", "重置时间", width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
    }

    private func row(_ event: QuotaChangeEvent) -> some View {
        HStack {
            tableText(StatsFormatter.time(event.sampledAt), width: 82, alignment: .leading)
            tableText(StatsFormatter.quotaDelta(event.deltaPercent), width: 82, alignment: .trailing)
                .foregroundStyle(event.deltaPercent < 0 ? Color.red : Color.green)
            tableText("\(event.afterRemainingPercent)%", width: 104, alignment: .trailing)
                .foregroundStyle(statusColor(remainingPercent: Double(event.afterRemainingPercent), tint: .secondary))
            tableText(StatsFormatter.resetTime(event.resetsAt), width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func tableHeader(
        _ english: String,
        _ chinese: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(tr(english, chinese))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Daily / Model row models

private struct DailySample: Identifiable {
    var id: Date { day }
    let day: Date
    let codex: UsageTotals
    let claude: UsageTotals
    let grok: UsageTotals

    var codexCost: Decimal { codex.costUSD }
    var claudeCost: Decimal { claude.costUSD }
    var grokCost: Decimal { grok.costUSD }
    var totalCost: Decimal { codexCost + claudeCost + grokCost }
    var totalTokens: Int { totalUsage.totalTokens }

    /// 各服务合并后的口径,供每日悬浮明细展示 token 拆分 + 命中率。
    var totalUsage: UsageTotals {
        var t = UsageTotals.zero
        t.inputTokens = codex.inputTokens + claude.inputTokens + grok.inputTokens
        t.outputTokens = codex.outputTokens + claude.outputTokens + grok.outputTokens
        t.cacheReadTokens = codex.cacheReadTokens + claude.cacheReadTokens + grok.cacheReadTokens
        t.cacheCreationTokens = codex.cacheCreationTokens + claude.cacheCreationTokens + grok.cacheCreationTokens
        t.costUSD = totalCost
        t.hasUnpricedUsage = codex.hasUnpricedUsage || claude.hasUnpricedUsage || grok.hasUnpricedUsage
        return t
    }
}

private struct ModelRow: Identifiable {
    var id: String { model }
    let model: String
    let totals: UsageTotals
    let speed: UsageSpeedBreakdown
}

private struct QuotaTimelineSection: Identifiable {
    var id: String { accountKey }
    let accountKey: String
    let title: String
    let tint: Color
    let limitKind: QuotaLimitKind?
    let currentRemaining: Int?
    let totalDelta: Int
    let latestEventAt: Date?
    let events: [QuotaChangeEvent]
    var isLoading: Bool = false
}

// MARK: - Formatter

enum StatsFormatter {
    static func cost(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "$\(f.string(from: ns) ?? "0.00")"
    }

    static func costPrecise(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.minimumFractionDigits = 4
        f.maximumFractionDigits = 6
        return "$\(f.string(from: ns) ?? "0.0000")"
    }

    @MainActor
    static func tierCost(_ value: Decimal, hasUnpricedUsage _: Bool) -> String {
        return cost(value)
    }

    @MainActor
    static func tierCostPrecise(_ value: Decimal, hasUnpricedUsage _: Bool) -> String {
        return costPrecise(value)
    }

    @MainActor
    static func billingEquivalentTokens(_ breakdown: UsageSpeedBreakdown) -> String {
        compactToken(breakdown.fastBillingEquivalentTokens)
    }

    @MainActor
    static func fastMultiplier(_ breakdown: UsageSpeedBreakdown) -> String {
        guard !breakdown.hasUnpricedFastEquivalent else { return "—" }
        guard let minimum = breakdown.fastMinimumMultiplier,
              let maximum = breakdown.fastMaximumMultiplier else {
            return "—"
        }
        return minimum == maximum
            ? "\(minimum.asPlainString)×"
            : "\(minimum.asPlainString)–\(maximum.asPlainString)×"
    }

    static func token(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 紧凑显示。中文用 万 / 亿,英文用 k / M / B。
    /// zh:  6772.37 万  /  1.23 亿  /  1,234
    /// en:  67.7M  /  248.3k  /  1,234
    @MainActor
    static func compactToken(_ value: Int) -> String {
        let v = Double(value)
        switch L10n.current {
        case .zh:
            if v >= 100_000_000 {
                return "\(trimTrailingZeros(v / 100_000_000)) 亿"
            }
            if v >= 10_000 {
                return "\(trimTrailingZeros(v / 10_000)) 万"
            }
            return token(value)
        case .en:
            if v >= 1_000_000_000 {
                return String(format: "%.2fB", v / 1_000_000_000)
            }
            if v >= 1_000_000 {
                return String(format: "%.2fM", v / 1_000_000)
            }
            if v >= 1_000 {
                return String(format: "%.1fk", v / 1_000)
            }
            return "\(value)"
        }
    }

    @MainActor
    static func compactToken(_ value: Decimal) -> String {
        let rounded = NSDecimalNumber(decimal: value).doubleValue.rounded()
        if rounded >= Double(Int.max) { return "—" }
        return compactToken(Int(rounded))
    }

    /// 保留两位小数,去掉末尾多余的 0(如 6772.30 → 6772.3,1234.00 → 1234)。
    private static func trimTrailingZeros(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        var trimmed = s
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return time(date)
    }

    static func quotaDelta(_ value: Int) -> String {
        if value > 0 { return "+\(value)%" }
        return "\(value)%"
    }
}

// MARK: - Decimal helper

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
