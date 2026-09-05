import SwiftUI
import AppKit
import Charts

// MARK: - StatsRange

/// 时间范围。从属于 `StatsGranularity`：每个粒度只暴露自己那一组范围
/// （当前 / 上一个 / 近 N 个 / 全部 / 自定义），`.all` 与 `.custom` 三个粒度共用；
/// 日粒度额外保留 `.thisWeek` / `.thisMonth` / `.thisYear`，用于「按天看、但只统计本周 / 本月 / 本年」。
enum StatsRange: Hashable, CaseIterable {
    case today
    case yesterday
    case last7
    case last30
    case thisWeek
    case lastWeek
    case last4Weeks
    case last12Weeks
    case thisMonth
    case lastMonth
    case last6Months
    case thisYear
    case all
    case custom

    var englishLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7: return "7d"
        case .last30: return "30d"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .last4Weeks: return "4w"
        case .last12Weeks: return "12w"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last6Months: return "6m"
        case .thisYear: return "Year"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    var chineseLabel: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .last7: return "7 天"
        case .last30: return "30 天"
        case .thisWeek: return "本周"
        case .lastWeek: return "上周"
        case .last4Weeks: return "4 周"
        case .last12Weeks: return "12 周"
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .last6Months: return "6 个月"
        case .thisYear: return "本年"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    /// 周一为一周起点的公历；`StatsGranularity` 的周桶起点与 `weekRange` 文案共用同一份，
    /// 避免「本周」和周粒度出现两个周起点真相。
    static var weekStartMondayCalendar: Calendar {
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
            return (Self.weekStart(now, cal: cal, fallback: startOfToday), startOfTomorrow)
        case .lastWeek:
            let weekStart = Self.weekStart(now, cal: cal, fallback: startOfToday)
            let previous = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
            return (previous, weekStart)
        case .last4Weeks:
            let weekStart = Self.weekStart(now, cal: cal, fallback: startOfToday)
            let from = cal.date(byAdding: .weekOfYear, value: -3, to: weekStart) ?? weekStart
            return (from, startOfTomorrow)
        case .last12Weeks:
            let weekStart = Self.weekStart(now, cal: cal, fallback: startOfToday)
            let from = cal.date(byAdding: .weekOfYear, value: -11, to: weekStart) ?? weekStart
            return (from, startOfTomorrow)
        case .thisMonth:
            return (Self.monthStart(now, cal: cal, fallback: startOfToday), startOfTomorrow)
        case .lastMonth:
            let monthStart = Self.monthStart(now, cal: cal, fallback: startOfToday)
            let previous = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
            return (previous, monthStart)
        case .last6Months:
            let monthStart = Self.monthStart(now, cal: cal, fallback: startOfToday)
            let from = cal.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart
            return (from, startOfTomorrow)
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

    private static func weekStart(_ date: Date, cal: Calendar, fallback: Date) -> Date {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? fallback
    }

    private static func monthStart(_ date: Date, cal: Calendar, fallback: Date) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? fallback
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

// MARK: - StatsGranularity

/// 统计粒度，Overview / Conversations 的**上级**控件：它决定「一个统计单元」是一天、
/// 一周还是一个月，下级的 `StatsRange` 只能在该粒度自己那组范围里选。
/// 底层用量桶始终是日桶，周 / 月只在读取时把日桶归并到周期起点。
enum StatsGranularity: Hashable, CaseIterable {
    case day
    case week
    case month

    var englishLabel: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    var chineseLabel: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var panelTitleEnglish: String {
        switch self {
        case .day: return "Daily usage"
        case .week: return "Weekly usage"
        case .month: return "Monthly usage"
        }
    }

    var panelTitleChinese: String {
        switch self {
        case .day: return "每日用量"
        case .week: return "每周用量"
        case .month: return "每月用量"
        }
    }

    /// 该粒度下可选的时间范围：当前 / 上一个 / 近 N 个 / 全部 / 自定义。
    /// `.all` 与 `.custom` 三个粒度共用，切换粒度时不会被重置。
    /// 日粒度另外保留本周 / 本月 / 本年三档自然周期，按天分桶但只统计该周期。
    var ranges: [StatsRange] {
        switch self {
        case .day: return [.today, .yesterday, .last7, .last30, .thisWeek, .thisMonth, .thisYear, .all, .custom]
        case .week: return [.thisWeek, .lastWeek, .last4Weeks, .last12Weeks, .all, .custom]
        case .month: return [.thisMonth, .lastMonth, .last6Months, .thisYear, .all, .custom]
        }
    }

    /// 把日桶的本地 0 点日期归并到所属周期起点。周起点为周一，月起点为自然月 1 号；
    /// range 边界处的不完整周 / 月不补全，直接落进对应桶。
    func bucketStart(for day: Date) -> Date {
        let cal = StatsRange.weekStartMondayCalendar
        switch self {
        case .day:
            return day
        case .week:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
            return cal.date(from: comps) ?? day
        case .month:
            let comps = cal.dateComponents([.year, .month], from: day)
            return cal.date(from: comps) ?? day
        }
    }

    /// X 轴刻度文案：日 / 周显示月日(周为该周起始日),月显示年月。
    var axisDateFormat: Date.FormatStyle {
        switch self {
        case .day, .week:
            return Date.FormatStyle.dateTime.month(.abbreviated).day()
        case .month:
            return Date.FormatStyle.dateTime.year().month(.abbreviated)
        }
    }

    /// 单周期上下文窗口显示多少个周期（含所选那个）。三种粒度共用同一个值，
    /// 柱数落在 `dailyBarWidth` 的 4~14 根档位里，粒度切换时柱宽不跳变。
    static let contextWindowPeriods = 14

    /// 上下文窗口按该单位往前推：日 → 天，周 → 周，月 → 月。
    var contextWindowComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    var contextWindowHintEnglish: String {
        switch self {
        case .day: return "Last 14 days · highlighted = selected"
        case .week: return "Last 14 weeks · highlighted = selected"
        case .month: return "Last 14 months · highlighted = selected"
        }
    }

    var contextWindowHintChinese: String {
        switch self {
        case .day: return "近 14 天 · 高亮为所选范围"
        case .week: return "近 14 周 · 高亮为所选范围"
        case .month: return "近 14 个月 · 高亮为所选范围"
        }
    }

    /// 悬浮明细的标题：日 `2026-09-03`,周 `2026-09-01 – 09-07`,月 `2026-09`。
    func periodLabel(_ start: Date) -> String {
        switch self {
        case .day: return StatsFormatter.day(start)
        case .week: return StatsFormatter.weekRange(start)
        case .month: return StatsFormatter.month(start)
        }
    }
}

// MARK: - Service filter (sidebar)

enum StatsServiceFilter: Hashable, CaseIterable {
    case all
    case codex
    case claude
    case cursor
    case pi
    case opencode

    var englishLabel: String {
        switch self {
        case .all: return "All"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        }
    }

    var chineseLabel: String {
        switch self {
        case .all: return "全部"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        }
    }

    var tint: Color? {
        switch self {
        case .all: return nil
        case .codex: return .codexAccent
        case .claude: return .claudeAccent
        case .cursor: return .gray
        case .pi: return .piAccent
        case .opencode: return .opencodeAccent
        }
    }

    var usageApp: UsageApp? {
        switch self {
        case .all: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .cursor: return .cursor
        case .pi: return .pi
        case .opencode: return .opencode
        }
    }
}

enum StatsViewMode: Hashable {
    case overview
    case conversations
    case cycles
    case timeline
}

private struct CursorHistoryRequest: Hashable {
    let accountID: String
    let from: Date
    let to: Date

    var range: Range<Date> { from..<to }
}

/// 「按提供商」面板的排序键；`other` 组在任何排序下都固定排最后。
enum ProviderSort: CaseIterable, Identifiable {
    case cost
    case tokens
    case requests
    case name

    var id: Self { self }

    @MainActor
    var label: String {
        switch self {
        case .cost: return tr("Cost", "费用")
        case .tokens: return tr("Tokens", "Tokens")
        case .requests: return tr("Requests", "请求数")
        case .name: return tr("Name", "名称")
        }
    }
}

// MARK: - StatsView

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var range: StatsRange = .today
    @State private var serviceFilter: StatsServiceFilter = .all
    @State private var viewMode: StatsViewMode = .overview
    @State private var selectedPeriodKey: String?
    @State private var customFrom: Date = Calendar.current.startOfDay(
        for: Date().addingTimeInterval(-7 * 86400)
    )
    @State private var customTo: Date = Calendar.current.startOfDay(for: Date())
    @State private var granularity: StatsGranularity = .day
    @State private var providerSort: ProviderSort = .cost
    @State private var expandedProvider: ModelProvider?
    /// 时间线窗口视角全局统一，避免 Codex 与 Claude 默认落在不同口径。
    @State private var timelineWindow: QuotaLimitKind = .fiveHour

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            VStack(spacing: 0) {
                if let error = appState.usageService.lastError {
                    usageErrorBanner(error)
                }

                if viewMode == .conversations {
                    ConversationStatsView(
                        granularity: $granularity,
                        range: $range,
                        customFrom: $customFrom,
                        customTo: $customTo,
                        serviceFilter: serviceFilter
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    GeometryReader { proxy in
                        ScrollView {
                            mainContent(canvasWidth: proxy.size.width, viewportHeight: proxy.size.height)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { reconcileServiceFilter() }
        .onChange(of: SettingsStore.shared.usageServiceVisibility) { _, _ in
            reconcileServiceFilter()
        }
        .onChange(of: viewMode) { _, _ in
            reconcileServiceFilter()
        }
        .onChange(of: granularity) { _, _ in
            reconcileRange()
            expandedProvider = nil
        }
        .onChange(of: range) { _, _ in expandedProvider = nil }
        .onChange(of: serviceFilter) { _, _ in expandedProvider = nil }
        .task(id: cursorHistoryRequest) {
            guard let request = cursorHistoryRequest else { return }
            await appState.loadCursorUsageHistory(for: request.range)
        }
    }

    /// 本地日志读取或聚合持久化失败时必须在统计页可见，并给出直接恢复入口。
    /// 具体技术错误保留在 hover help，主文案只说明数据状态与安全行为。
    private func usageErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(tr(
                "Usage statistics may be incomplete. Available data is preserved; retry or recalculate in Settings.",
                "用量统计可能不完整。可用的已有数据会保留，请稍后重试或前往设置重新计算。"
            ))
            .font(.system(size: 11.5))
            .lineLimit(2)
            Spacer(minLength: 8)
            Button(tr("Open Settings", "打开设置")) {
                appState.mainTab = .settings
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .help(error)
    }

    /// 宽度断点:主画布达到该宽度时,时间线的折线图与表格改为左右并排;
    /// 更窄(如最小窗口)时回落单列堆叠,避免内容挤压截断。
    private static let wideCanvasWidth: CGFloat = 880

    @ViewBuilder
    private func mainContent(canvasWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        let isWide = canvasWidth >= Self.wideCanvasWidth
        switch viewMode {
        case .overview:
            overviewContent
        case .conversations:
            EmptyView()
        case .cycles:
            CycleStatsView()
        case .timeline:
            timelineContent(isWide: isWide, viewportHeight: viewportHeight)
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
            byProviderPanel
        }
        .padding(20)
    }

    /// 时间线面板均分视口剩余高度:每个账号分区 `.maxHeight(.infinity)` 等分,
    /// 面板内图表吃掉剩余、宽画布下表格拉满与图等高;内容最小高度总和超过视口时,
    /// 由外层 ScrollView 兜底滚动(见 `viewportHeight` 只作 minHeight 的撑满技巧)。
    private func timelineContent(isWide: Bool, viewportHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            timelineHeader
            if timelineSections.isEmpty {
                placeholderHeight(220, message: tr("No accounts", "暂无账号"))
                    .ccPanel(cornerRadius: 12)
            } else {
                ForEach(timelineSections) { section in
                    QuotaTimelineAccountPanel(
                        section: section,
                        selectedKind: timelineWindow,
                        isWide: isWide
                    )
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .frame(minHeight: max(0, viewportHeight - 40), alignment: .top)
    }

    // MARK: Sidebar

    private var visibleUsageApps: [UsageApp] {
        SettingsStore.shared.visibleUsageApps
    }

    private var visibleServiceFilters: [StatsServiceFilter] {
        [.all] + visibleUsageApps.map { filter(for: $0) }
    }

    private func filter(for app: UsageApp) -> StatsServiceFilter {
        switch app {
        case .codex: return .codex
        case .claude: return .claude
        case .cursor: return .cursor
        case .pi: return .pi
        case .opencode: return .opencode
        }
    }

    /// 设置里被关闭的服务,其 sidebar 项不再显示;若当前选中了被关闭的服务则回退到全部。
    private func reconcileServiceFilter() {
        // Cursor Dashboard 没有本机会话 ID；对话页不能伪造或查询 Cursor 对话。
        if viewMode == .conversations, serviceFilter == .cursor {
            serviceFilter = .all
            return
        }
        if case .all = serviceFilter { return }
        if let app = serviceFilter.usageApp, !SettingsStore.shared.isUsageServiceEffectivelyVisible(app) {
            serviceFilter = .all
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: "Service", chinese: "服务") {
                ForEach(visibleServiceFilters, id: \.self) { item in
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
                sidebarItem(
                    english: "Cycles",
                    chinese: "周期",
                    icon: "arrow.triangle.2.circlepath",
                    active: viewMode == .cycles
                ) {
                    viewMode = .cycles
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
        .focusEffectDisabled()
        .pointingHandCursor()
    }

    // MARK: Top bar (segmented + custom)

    private var topBar: some View {
        HStack(spacing: 12) {
            // 扫描提示由后台扫描自行出现 / 消失。它不能当成 HStack 的普通成员夹在
            // Spacer 和两个 Picker 之间——那样每次出现都凭空插入约 170pt,把右对齐的
            // 控件整体推着左右平移。改成让它独占左侧剩余空间并在其中右对齐:视觉上仍
            // 紧贴控件左边,但剩余空间由它自己吃掉,控件位置只由自身宽度决定,不再被推动。
            HStack(spacing: 6) {
                if appState.usageService.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(tr("Recalculating usage…", "正在重新计算用量…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            SegmentedBar(items: StatsGranularity.allCases,
                         label: { tr($0.englishLabel, $0.chineseLabel) },
                         selection: $granularity)

            rangePicker
        }
    }

    /// 范围分段控件。三个粒度的段数不一样(日 9 段,周 / 月各 6 段):若让每组按自己的内容
    /// 取宽,切换粒度时控件会忽宽忽窄,并把左边的粒度控件推得左右跳;若只取最宽一组而不
    /// 拉伸,周 / 月又会在两个控件之间空出约 3 个段的空隙。
    ///
    /// 这里用段数最多的日粒度那组按自然宽度撑出总宽(`.hidden()`,只参与布局不显示),
    /// 当前粒度的控件叠在上面等分填满。于是三个粒度总宽一致、右边缘齐平、与粒度控件之间
    /// 没有空隙,代价是周 / 月的 6 段各自更宽——段内都是 2~3 个字,拉宽后仍是正常观感。
    /// 宽度由布局系统算,不写死数值,改文案或换语言时自动跟着变。
    private var rangePicker: some View {
        SegmentedBar(items: StatsGranularity.day.ranges,
                     label: { tr($0.englishLabel, $0.chineseLabel) },
                     selection: .constant(StatsRange.today),
                     uniformSegments: true)
            .hidden()
            .overlay {
                SegmentedBar(items: granularity.ranges,
                             label: { tr($0.englishLabel, $0.chineseLabel) },
                             selection: $range,
                             stretch: true)
                    .frame(maxWidth: .infinity)
                    // 段数随粒度变(9 / 6),不按粒度重建的话 SwiftUI 会跨粒度复用同一批段视图,
                    // 把上一个粒度的段宽残留下来,切几次就宽度不一、控件也撑不满而居中留白。
                    .id(granularity)
            }
    }

    /// 切换粒度后，把不属于新粒度的范围收敛到该粒度的第一档；
    /// `.all` / `.custom` 在三个粒度里都在，切换时会原样保留。
    private func reconcileRange() {
        guard !granularity.ranges.contains(range) else { return }
        range = granularity.ranges.first ?? .all
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
            totalTokensCard
            totalSpendCard
            ForEach(visibleUsageApps, id: \.self) { app in
                serviceCard(for: app)
            }
        }
    }

    private var totalTokensCard: some View {
        KPICard(
            english: "Total tokens",
            chinese: "总 Tokens",
            value: StatsFormatter.compactToken(currentTotalsAll.totalTokens),
            delta: deltaPercent(current: Double(currentTotalsAll.totalTokens),
                                previous: Double(previousTotalsAll.totalTokens)),
            tint: nil,
            dimmed: false
        )
    }

    private var totalSpendCard: some View {
        KPICard(
            english: "Total spend",
            chinese: "总花费",
            value: StatsFormatter.tierCost(
                currentTotalsAll.costUSD,
                hasUnpricedUsage: currentTotalsAll.hasUnpricedUsage,
                costIncomplete: currentTotalsAll.costIncomplete
            ),
            delta: costDelta(current: currentTotalsAll, previous: previousTotalsAll),
            tint: nil,
            dimmed: false
        )
    }

    private func serviceCard(for app: UsageApp) -> some View {
        let isDimmed = serviceFilter.usageApp != nil && serviceFilter.usageApp != app
        return KPICard(
            english: app.displayName,
            chinese: app.displayName,
            value: isDimmed
                ? "—"
                : StatsFormatter.tierCost(
                    currentTotals(app).costUSD,
                    hasUnpricedUsage: currentTotals(app).hasUnpricedUsage,
                    costIncomplete: currentTotals(app).costIncomplete
                ),
            delta: isDimmed ? nil : costDelta(current: currentTotals(app), previous: previousTotals(app)),
            tint: app.tintColor,
            dimmed: isDimmed
        )
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
        Panel(
            title: granularity.panelTitleEnglish,
            chinese: granularity.panelTitleChinese,
            right: AnyView(
                HStack(spacing: 8) {
                    if chartUsesContextWindow {
                        Text(tr(granularity.contextWindowHintEnglish, granularity.contextWindowHintChinese))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(visibleUsageApps, id: \.self) { app in
                        LegendChip(color: app.tintColor, label: app.displayName)
                    }
                }
            )
        ) {
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
                            ForEach(visibleUsageApps, id: \.self) { app in
                                BarMark(
                                    x: .value("Period", sample.key),
                                    y: .value("Tokens", Double(sample.totals(for: app).totalTokens)),
                                    width: .fixed(dailyBarWidth),
                                    stacking: .standard
                                )
                                .foregroundStyle(app.tintColor)
                                .opacity(barOpacity(for: sample))
                                .cornerRadius(2)
                            }
                        }

                        if let selected = selectedSample {
                            RuleMark(x: .value("Period", selected.key))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                                .annotation(
                                    position: .top,
                                    spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                                ) {
                                    DailyTooltip(
                                        sample: selected,
                                        visibleApps: visibleUsageApps,
                                        granularity: granularity
                                    )
                                }
                        }
                    }
                    .chartXSelection(value: $selectedPeriodKey)
                    .chartXScale(domain: dailySamples.map(\.key))
                    .chartXAxis {
                        AxisMarks(values: chartAxisKeys) { value in
                            AxisValueLabel {
                                if let key = value.as(String.self),
                                   let date = StatsPeriodKey.date(from: key) {
                                    Text(date, format: granularity.axisDateFormat)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 160)
                    .animation(.easeOut(duration: 0.12), value: selectedPeriodKey)
                    .onChange(of: range) { _, _ in selectedPeriodKey = nil }
                    .onChange(of: serviceFilter) { _, _ in selectedPeriodKey = nil }
                    .onChange(of: granularity) { _, _ in selectedPeriodKey = nil }
                }
            }
        }
    }

    // MARK: By service panel

    /// 服务数 ≤ 3 时单行排列;超过 3 个(全开时 4 个)改两列网格,
    /// 每列占半行宽、两两对齐铺满。
    @ViewBuilder
    private var byServicePanel: some View {
        Panel(title: "By service", chinese: "按服务") {
            if visibleUsageApps.isEmpty {
                placeholderHeight(
                    60,
                    message: tr("No services selected · enable in Settings → Stats services", "未选择任何服务 · 到「设置 → 统计服务」开启")
                )
            } else if visibleUsageApps.count > 3 {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(visibleUsageApps, id: \.self) { app in
                        serviceRow(for: app)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(visibleUsageApps, id: \.self) { app in
                        serviceRow(for: app)
                    }
                }
            }
        }
    }

    private func serviceRow(for app: UsageApp) -> some View {
        ByServiceRow(
            title: app.displayName,
            subtitle: serviceSubtitle(app),
            tint: app.tintColor,
            value: Decimal(currentTotals(app).totalTokens),
            totalValue: Decimal(currentTotalsAll.totalTokens),
            totals: currentTotals(app),
            speed: currentSpeedBreakdown(app)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serviceSubtitle(_ app: UsageApp) -> String {
        switch app {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        case .cursor: return "Cursor"
        case .pi: return "pi.dev"
        case .opencode: return "opencode.ai"
        }
    }

    // MARK: By provider panel(按模型提供商,跨服务归并)

    /// 按提供商查看 token 与费用：所有有数据的提供商平铺一行一眼可见；
    /// 右上角四档排序（费用 / Tokens / 请求数 / 名称，`other` 恒排最后）；
    /// 点击行就地展开该提供商全部数据（Token 拆分 + 来源服务 + 按模型明细）。
    private var byProviderPanel: some View {
        Panel(title: "By provider", chinese: "按提供商", right: AnyView(
            Picker("", selection: $providerSort) {
                ForEach(ProviderSort.allCases) { item in Text(item.label).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(tr("Sort by cost / tokens / requests / name", "按费用 / Tokens / 请求数 / 名称排序"))
        )) {
            let groups = providerGroups()
            if groups.isEmpty {
                placeholderHeight(60, message: tr("No data", "无数据"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        providerRow(group)
                        if group.id != groups.last?.id {
                            Divider().padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    private func providerRow(_ group: ProviderGroup) -> some View {
        let isExpanded = expandedProvider == group.provider
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    expandedProvider = isExpanded ? nil : group.provider
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(group.provider.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(StatsFormatter.compactToken(group.totals.totalTokens)) Tokens")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(StatsFormatter.tierCost(
                        group.totals.costUSD,
                        hasUnpricedUsage: group.totals.hasUnpricedUsage,
                        costIncomplete: group.totals.costIncomplete
                    ))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isExpanded {
                providerDetail(group)
                    .padding(.leading, 16)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 7)
    }

    /// 展开后的提供商全部数据：整体 Token 拆分 + 来源服务 + 按模型明细。
    private func providerDetail(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TokenBreakdownView(totals: group.totals, showsHero: false)

            if group.sources.count > 1 || !group.models.isEmpty {
                HStack(spacing: 6) {
                    Text(tr("Sources", "来源"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(UsageApp.allCases.filter { group.sources.contains($0) }, id: \.self) { app in
                        HStack(spacing: 4) {
                            ServiceMark(color: app.tintColor, size: 6, cornerRadius: 1.5)
                            Text(app.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if group.sources.count > 1 {
                        Text("· \(group.totals.requestCount) \(tr("requests", "次请求"))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !group.models.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.models) { row in
                        providerModelRow(row)
                    }
                }
            }
        }
    }

    private func providerModelRow(_ row: ProviderModelRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ServiceMark(color: row.app.tintColor, size: 6, cornerRadius: 1.5)
                Text(row.model)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(StatsFormatter.compactToken(row.totals.totalTokens)) Tokens")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                Text(StatsFormatter.tierCost(
                    row.totals.costUSD,
                    hasUnpricedUsage: row.totals.hasUnpricedUsage,
                    costIncomplete: row.totals.costIncomplete
                ))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            TokenBreakdownInlineRow(totals: row.totals)
                .padding(.leading, 12)
            if row.speed.fast.requestCount > 0 {
                FastUsageInlineRow(breakdown: row.speed)
                    .padding(.leading, 12)
            }
        }
    }

    /// 跨服务按 `ModelProvider` 归并（totals + 速度拆分 + 来源服务 + 模型子明细），按排序键排列。
    private func providerGroups() -> [ProviderGroup] {
        var byProvider: [ModelProvider: ProviderGroup] = [:]
        for b in filteredBuckets {
            let provider = ModelProvider.resolve(app: b.app, model: b.model)
            var group = byProvider[provider] ?? ProviderGroup(provider: provider)
            group.totals.add(b)
            group.speed.add(b)
            group.sources.insert(b.app)
            if let idx = group.models.firstIndex(where: { $0.app == b.app && $0.model == b.model }) {
                var row = group.models[idx]
                row.totals.add(b)
                row.speed.add(b)
                group.models[idx] = row
            } else {
                var totals = UsageTotals.zero
                totals.add(b)
                var speed = UsageSpeedBreakdown()
                speed.add(b)
                group.models.append(ProviderModelRow(model: b.model, app: b.app, totals: totals, speed: speed))
            }
            byProvider[provider] = group
        }
        return byProvider.values
            .map { group in
                var g = group
                g.models = sortedModels(g.models)
                return g
            }
            .sorted { lhs, rhs in
                let lOther = lhs.provider == .other
                let rOther = rhs.provider == .other
                if lOther != rOther { return !lOther }
                switch providerSort {
                case .cost:
                    if lhs.totals.costUSD == rhs.totals.costUSD { return compareProvidersByName(lhs, rhs) }
                    return lhs.totals.costUSD > rhs.totals.costUSD
                case .tokens:
                    if lhs.totals.totalTokens == rhs.totals.totalTokens { return compareProvidersByName(lhs, rhs) }
                    return lhs.totals.totalTokens > rhs.totals.totalTokens
                case .requests:
                    if lhs.totals.requestCount == rhs.totals.requestCount { return compareProvidersByName(lhs, rhs) }
                    return lhs.totals.requestCount > rhs.totals.requestCount
                case .name:
                    return compareProvidersByName(lhs, rhs)
                }
            }
    }

    /// 排序 tie-breaker：数值键相等时按提供商名升序，保证跨渲染顺序稳定（`byProvider.values` 字典遍历无序）。
    private func compareProvidersByName(_ lhs: ProviderGroup, _ rhs: ProviderGroup) -> Bool {
        lhs.provider.displayName.localizedCaseInsensitiveCompare(
            rhs.provider.displayName
        ) == .orderedAscending
    }

    /// 提供商展开区模型明细行：跟随面板排序键，数值大的在前，同值按模型名升序稳定。
    private func sortedModels(_ models: [ProviderModelRow]) -> [ProviderModelRow] {
        models.sorted { lhs, rhs in
            switch providerSort {
            case .cost:
                if lhs.totals.costUSD == rhs.totals.costUSD { return lhs.model < rhs.model }
                return lhs.totals.costUSD > rhs.totals.costUSD
            case .tokens:
                if lhs.totals.totalTokens == rhs.totals.totalTokens { return lhs.model < rhs.model }
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            case .requests:
                if lhs.totals.requestCount == rhs.totals.requestCount { return lhs.model < rhs.model }
                return lhs.totals.requestCount > rhs.totals.requestCount
            case .name:
                return lhs.model < rhs.model
            }
        }
    }

    // MARK: By model panel(保留旧的按模型聚合)

    private var byModelPanel: some View {
        Panel(title: "By model", chinese: "按模型") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(visibleUsageApps.enumerated()), id: \.element) { index, app in
                    if index > 0 {
                        Divider()
                    }
                    if showsModelGroup(app) {
                        modelGroup(title: app.displayName, tint: app.tintColor, rows: modelRows(for: app))
                    }
                }
            }
        }
    }

    /// 单服务过滤时只显示该服务的模型组;「全部」时显示所有可见服务。
    private func showsModelGroup(_ app: UsageApp) -> Bool {
        guard let filter = serviceFilter.usageApp else { return true }
        return filter == app
    }

    // MARK: Timeline

    private var timelineHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Quota Timeline", "额度时间线"))
                    .font(.system(size: 18, weight: .semibold))
                Text(tr(
                    "5H shows today. Weekly shows the current and previous quota cycles.",
                    "5小时展示今天；周视图展示当前和上一额度周期。"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(tr("Quota window", "额度窗口"), selection: $timelineWindow) {
                ForEach(QuotaTimelineWindowKind.pickable, id: \.self) { item in
                    Text(item.label).tag(item.kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 128)
            Text(StatsFormatter.day(Date()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var timelineSections: [QuotaTimelineSection] {
        // Cursor / Pi / OpenCode 没有本地可绘制的额度时间线。
        guard serviceFilter != .cursor, serviceFilter != .pi, serviceFilter != .opencode else { return [] }
        var sections: [QuotaTimelineSection] = []

        if serviceFilter != .claude {
            let key = QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
            var addedPrimaryCodex = false
            if shouldShowTimelineSection(accountKey: key, snapshot: appState.codexQuota, accountExists: appState.codexAccount != nil) {
                sections.append(timelineSection(
                    accountKey: key,
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
                    accountKey: key,
                    title: importedCodexTimelineTitle(account, index: idx),
                    tint: .codexAccent,
                    snapshot: appState.importedCodexQuota(for: account),
                    isLoading: appState.importedCodexRefreshState(for: account).inFlight
                ))
            }
        }

        if serviceFilter != .codex {
            let key = QuotaHistoryAccountKey.claudePrimary(email: appState.claudeAccount?.email)
            if shouldShowTimelineSection(accountKey: key, snapshot: appState.claudeQuota, accountExists: appState.claudeAccount != nil) {
                sections.append(timelineSection(
                    accountKey: key,
                    title: "Claude Code",
                    tint: .claudeAccent,
                    snapshot: appState.claudeQuota,
                    isLoading: appState.refreshState(for: .claude).inFlight
                ))
            }
        }

        return sections
    }

    private func timelineSection(
        accountKey: String,
        title: String,
        tint: Color,
        snapshot: QuotaSnapshot?,
        isLoading: Bool
    ) -> QuotaTimelineSection {
        let windows: [QuotaTimelineWindow] = [.fiveHour, .weekly].compactMap { kind in
            timelineWindowSection(accountKey: accountKey, kind: kind, snapshot: snapshot)
        }
        return QuotaTimelineSection(
            accountKey: accountKey,
            title: title,
            tint: tint,
            windows: windows,
            isLoading: isLoading
        )
    }

    /// 每个标准窗口（5H / 每周）在「快照当前持有该窗口」或「历史留有该系列数据」时展示。
    private func timelineWindowSection(
        accountKey: String,
        kind: QuotaLimitKind,
        snapshot: QuotaSnapshot?
    ) -> QuotaTimelineWindow? {
        let events = timelineEvents(for: accountKey, kind: kind)
        let sample = appState.quotaHistory.lastSamples[
            QuotaHistoryStore.seriesKey(accountKey: accountKey, limitKind: kind)
        ]
        let snapshotWindow = window(of: kind, in: snapshot)
        guard sample != nil || !events.isEmpty || snapshotWindow != nil else { return nil }

        return QuotaTimelineWindow(
            kind: kind,
            currentRemaining: sample?.remainingPercent ?? roundedRemaining(snapshotWindow),
            latestSampleAt: sample?.sampledAt,
            periods: QuotaHistoryStore.timelinePeriods(
                payload: appState.quotaHistory,
                accountKey: accountKey,
                limitKind: kind
            )
        )
    }

    private func roundedRemaining(_ window: QuotaWindow?) -> Int? {
        guard let remaining = window?.remainingPercent else { return nil }
        return max(0, min(100, Int(remaining.rounded())))
    }

    private func window(of kind: QuotaLimitKind, in snapshot: QuotaSnapshot?) -> QuotaWindow? {
        guard let snapshot else { return nil }
        switch kind {
        case .fiveHour: return snapshot.fiveHourLimit?.window
        case .weekly: return snapshot.weeklyLimit?.window
        case .modelWeekly, .unknown: return nil
        }
    }

    private func shouldShowTimelineSection(accountKey: String, snapshot: QuotaSnapshot?, accountExists: Bool) -> Bool {
        let history = appState.quotaHistory
        let hasSeries = history.lastSamples.keys.contains {
            $0.hasPrefix("\(accountKey)|")
        }
        return accountExists || snapshot != nil || hasSeries
            || history.events.contains { $0.accountKey == accountKey }
    }

    private func timelineEvents(for accountKey: String, kind: QuotaLimitKind) -> [QuotaChangeEvent] {
        appState.quotaHistory.events
            .filter { $0.accountKey == accountKey && $0.limitKind == kind }
            .sorted { $0.sampledAt < $1.sampledAt }
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
                                hasUnpricedUsage: row.totals.hasUnpricedUsage,
                                costIncomplete: row.totals.costIncomplete
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
            .filter { SettingsStore.shared.isUsageServiceEffectivelyVisible($0.app) }
        switch serviceFilter {
        case .all:
            return buckets
        case .codex:
            return buckets.filter { $0.app == .codex }
        case .claude:
            return buckets.filter { $0.app == .claude }
        case .cursor:
            return buckets.filter { $0.app == .cursor }
        case .pi:
            return buckets.filter { $0.app == .pi }
        case .opencode:
            return buckets.filter { $0.app == .opencode }
        }
    }

    /// 所选范围只落在**一个当前粒度周期**内(日:今天 / 昨天 / 单日自定义;周:本周 / 上周;
    /// 月:本月 / 上月;以及不跨周期的自定义)时,用量图表扩展为近 14 个周期的上下文,
    /// 范围内柱子高亮、范围外降透明;KPI 与其他面板口径不变。
    private var chartUsesContextWindow: Bool {
        guard range != .all else { return false }
        let (from, to) = rangeBounds
        guard to > from else { return false }
        // 按桶归属判断而非按时长,夏令时的 23/25 小时和月份天数差都不会影响结果。
        return selectedPeriodStart == granularity.bucketStart(for: lastDayInRange)
    }

    /// 所选范围首日所属的周期起点——上下文窗口里唯一全彩的那根柱子。
    private var selectedPeriodStart: Date {
        let cal = StatsRange.weekStartMondayCalendar
        return granularity.bucketStart(for: cal.startOfDay(for: rangeBounds.from))
    }

    /// 所选范围末日(右开区间往回退一秒再取当天 0 点)。
    private var lastDayInRange: Date {
        let cal = StatsRange.weekStartMondayCalendar
        return cal.startOfDay(for: rangeBounds.to.addingTimeInterval(-1))
    }

    /// 图表展示窗口:上下文模式取「所选周期起点往前 13 个周期」,连所选那个共 14 个。
    /// 从周期起点往前推而不是从范围结束时刻往前推,首柱才是完整的周 / 月,不会天然偏矮。
    private var chartBounds: (from: Date, to: Date) {
        let bounds = rangeBounds
        guard chartUsesContextWindow else { return bounds }
        let cal = StatsRange.weekStartMondayCalendar
        let from = cal.date(byAdding: granularity.contextWindowComponent,
                            value: -(StatsGranularity.contextWindowPeriods - 1),
                            to: selectedPeriodStart) ?? bounds.from
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
            .filter { SettingsStore.shared.isUsageServiceEffectivelyVisible($0.app) }
        var t = UsageTotals.zero
        for b in buckets {
            if serviceFilter == .codex && b.app != .codex { continue }
            if serviceFilter == .claude && b.app != .claude { continue }
            if serviceFilter == .cursor && b.app != .cursor { continue }
            if serviceFilter == .pi && b.app != .pi { continue }
            if serviceFilter == .opencode && b.app != .opencode { continue }
            t.add(b)
        }
        return t
    }

    private func previousTotals(_ app: UsageApp) -> UsageTotals {
        guard SettingsStore.shared.isUsageServiceEffectivelyVisible(app) else { return .zero }
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
        // 当前值为 0 时固定是 ↓100%,对没有用量的服务没有信息量,直接不渲染。
        guard current > 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    private func costDelta(current: UsageTotals, previous: UsageTotals) -> Double? {
        return deltaPercent(current: current.costUSD.doubleValue, previous: previous.costUSD.doubleValue)
    }

    /// 底层永远是日桶,这里按 `granularity` 把日桶再归并到周期起点。
    /// 周 / 月桶在 range 边界被截断时不补全、不标注,首尾柱天然偏矮。
    private var dailySamples: [DailySample] {
        let (from, to) = chartBounds
        var byDay: [Date: (codex: UsageTotals, claude: UsageTotals, cursor: UsageTotals, pi: UsageTotals, opencode: UsageTotals)] = [:]
        for b in filteredBuckets(from: from, to: to) {
            let bucketDay = granularity.bucketStart(for: b.day)
            var pair = byDay[bucketDay] ?? (.zero, .zero, .zero, .zero, .zero)
            switch b.app {
            case .codex: pair.codex.add(b)
            case .claude: pair.claude.add(b)
            case .cursor: pair.cursor.add(b)
            case .pi: pair.pi.add(b)
            case .opencode: pair.opencode.add(b)
            }
            byDay[bucketDay] = pair
        }
        return byDay
            .map {
                DailySample(
                    day: $0.key,
                    key: StatsPeriodKey.key(for: $0.key),
                    codex: $0.value.codex,
                    claude: $0.value.claude,
                    cursor: $0.value.cursor,
                    pi: $0.value.pi,
                    opencode: $0.value.opencode
                )
            }
            .sorted { $0.day < $1.day }
    }

    /// X 轴刻度取自桶自己的类别键,不按日历 stride 推算;周期多时每隔 step 个取一个,
    /// 保证刻度永远落在某根柱子的 band 上。
    private var chartAxisKeys: [String] {
        let keys = dailySamples.map(\.key)
        guard keys.count > 5 else { return keys }
        let step = max(1, keys.count / 5)
        return stride(from: 0, to: keys.count, by: step).map { keys[$0] }
    }

    private var selectedSample: DailySample? {
        guard let selectedPeriodKey else { return nil }
        return dailySamples.first { $0.key == selectedPeriodKey }
    }

    /// 悬浮选中某个周期时,非选中柱降透明以聚焦;无悬浮时,上下文窗口内
    /// 只有所选周期那根柱子全彩,前面的上下文柱降透明。
    /// 上下文窗口本身已保证范围只覆盖一个周期,所以直接和该周期起点比,
    /// 自定义范围从周中 / 月中开始时也不会把自己那根柱判成范围外。
    private func barOpacity(for sample: DailySample) -> Double {
        if let selected = selectedSample {
            return selected.id == sample.id ? 1 : 0.35
        }
        guard chartUsesContextWindow else { return 1 }
        return sample.day == selectedPeriodStart ? 1 : 0.35
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

    private var cursorUsageIsInCurrentScope: Bool {
        SettingsStore.shared.isUsageServiceEffectivelyVisible(.cursor)
            && (serviceFilter == .all || serviceFilter == .cursor)
    }

    /// 当前范围外的历史由 Stats 选择时按月静默补拉；All 没有可靠的远端起点，
    /// 所以只使用现有缓存，绝不偷偷发起无界回溯。
    private var cursorHistoryRequest: CursorHistoryRequest? {
        guard viewMode == .overview,
              cursorUsageIsInCurrentScope,
              range != .all,
              let accountID = appState.cursorAccount?.userID
        else { return nil }

        let current = rangeBounds
        let requested = previousRangeBounds.map { $0.from..<current.to } ?? current.from..<current.to
        guard !appState.usageService.isCursorRemoteUsageCovered(requested) else { return nil }
        return CursorHistoryRequest(accountID: accountID, from: requested.lowerBound, to: requested.upperBound)
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

// MARK: - Segmented bar

/// 自绘分段控件。系统 `Picker(.segmented)` 的段宽只按各自文案自适应,SwiftUI 也没有暴露
/// `NSSegmentedControl.distribution`,所以它既不会拉伸去填满给定宽度,段与段之间也不会等宽。
/// 而 Stats 顶栏要求三个粒度(日 9 段、周 / 月各 6 段)下范围控件总宽一致、和粒度控件之间
/// 不留空隙,系统控件做不到,只能自绘:`stretch` 打开时各段等分容器宽度。
/// 粒度控件一并换成同一组件,避免两个并排的控件一个系统一个自绘、圆角底色对不上。
/// 样式见 设计风格「Segmented control」。
private struct SegmentedBar<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    /// 各段等分容器宽度(让周 / 月那 6 段撑满日粒度 9 段的宽度);
    /// 关闭时按文案自然宽度,用于撑出宽度骨架。
    var stretch: Bool = false
    /// 骨架专用:每段都按**所有段里最长的那个文案**取宽,于是总宽 = 段数 × 最宽段宽。
    /// 若骨架只取各段自然宽之和,等分后每段拿到的是平均宽,比平均宽的那几段
    /// (中文「30 天」「自定义」)就会被挤到缩字。
    var uniformSegments: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // 身份用 item 自身而不是位置索引:段数随粒度变化,按索引复用会让不同粒度的段
            // 共用同一个视图身份,布局残留在切换后表现为段宽不一。
            ForEach(items, id: \.self) { item in
                segment(item,
                        isFirst: item == items.first,
                        precededBySelected: precedingItem(of: item) == selection)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        )
    }

    /// 段内文案。骨架模式下把所有段的文案叠在一起,宽度取其中最长的那个。
    @ViewBuilder
    private func segmentLabel(_ item: Item, isActive: Bool) -> some View {
        if uniformSegments {
            ZStack {
                ForEach(items, id: \.self) { other in
                    segmentText(label(other), isActive: false)
                }
            }
        } else {
            segmentText(label(item), isActive: isActive)
        }
    }

    private func segmentText(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(1)
            // 骨架已保证每段不窄于最长文案,这里只是兜底,防止窗口被压到极窄时截成省略号。
            .minimumScaleFactor(0.85)
            .foregroundStyle(isActive ? Color.white : Color.primary)
    }

    /// 左邻的那一段,首段返回 nil。段数最多 9 个,线性查找足够。
    private func precedingItem(of item: Item) -> Item? {
        guard let index = items.firstIndex(of: item), index > 0 else { return nil }
        return items[index - 1]
    }

    private func segment(_ item: Item, isFirst: Bool, precededBySelected: Bool) -> some View {
        let isActive = item == selection
        return Button {
            selection = item
        } label: {
            segmentLabel(item, isActive: isActive)
                .padding(.horizontal, 10)
                .frame(maxWidth: stretch ? .infinity : nil)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        // 段间分隔线:与系统 segmented 一致,只在自己和左邻都未选中时出现。
        .overlay(alignment: .leading) {
            if !isFirst, !isActive, !precededBySelected {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 12)
            }
        }
    }
}

// MARK: - Daily usage tooltip

/// 用量柱状图的悬浮浮层:展示该周期内各服务花费、合计花费与合计 tokens。
private struct DailyTooltip: View {
    let sample: DailySample
    let visibleApps: [UsageApp]
    let granularity: StatsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(granularity.periodLabel(sample.day))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(visibleApps, id: \.self) { app in
                serviceRow(color: app.tintColor, label: app.displayName, value: StatsFormatter.tierCost(
                    sample.cost(for: app),
                    hasUnpricedUsage: sample.totals(for: app).hasUnpricedUsage,
                    costIncomplete: sample.totals(for: app).costIncomplete
                ))
            }

            Divider()

            totalRow(label: tr("Total", "合计"), value: StatsFormatter.tierCost(
                sample.totalCost,
                hasUnpricedUsage: sample.totalUsage.hasUnpricedUsage,
                costIncomplete: sample.totalUsage.costIncomplete
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
            // delta 放在 Label 行右侧：利用标题行原有留白，让 22pt 主值独占整行，
            // 服务变多、卡片被压窄时主值不再被 delta 挤掉。
            HStack(spacing: 4) {
                if let tint {
                    ServiceMark(color: tint, size: 6, cornerRadius: 1.5)
                }
                Text(tr(english, chinese))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let delta, delta != 0 {
                    Text(formatDelta(delta))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(delta >= 0 ? Color.red : Color.green)
                        .lineLimit(1)
                }
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.5)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
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
        return "\(arrow)\(String(format: "%.1f", abs))%"
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
                hasUnpricedUsage: breakdown.fastHasUnpricedCost,
                costIncomplete: breakdown.fast.costIncomplete
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
                hasUnpricedUsage: breakdown.fastHasUnpricedCost,
                costIncomplete: breakdown.fast.costIncomplete
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
        // 花费金额不再展示:与 KPI 行的 Codex / Claude Code 卡完全重复,此处保留 Token 占比 + 量。
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
                Text(tr("of tokens", "Token 占比"))
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
    /// 全局选定的窗口视角，所有账号使用同一口径。
    let selectedKind: QuotaLimitKind
    var isWide: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let window = activeWindow {
                windowContent(window)
            } else {
                loadingOrEmpty(message: tr("No data for this window", "该窗口暂无数据"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }

    /// 当前 Picker 是全局语义；无对应数据时保留空态，不能悄悄回退到另一种窗口。
    private var activeWindow: QuotaTimelineWindow? {
        section.windows.first { $0.kind == selectedKind }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 7) {
                ServiceMark(color: section.tint, size: 8)
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                if let kind = activeWindow?.kind {
                    Text(limitKindLabel(kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            Spacer()
            if let window = activeWindow {
                timelineMetric(label: tr("Current", "当前"), value: currentText(window))
                timelineMetric(
                    label: deltaLabel(window.kind),
                    value: StatsFormatter.quotaDelta(window.periods.first?.totalDelta ?? 0)
                )
                timelineMetric(label: tr("Updated", "更新"), value: latestText(window))
            }
        }
    }

    private func limitKindLabel(_ kind: QuotaLimitKind) -> String {
        switch kind {
        case .fiveHour: return "5H"
        case .weekly: return "WK"
        case .modelWeekly: return tr("MODEL", "模型")
        case .unknown: return tr("CURRENT", "当前")
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

    private func currentText(_ window: QuotaTimelineWindow) -> String {
        guard let value = window.currentRemaining else { return "--" }
        return "\(value)%"
    }

    private func deltaLabel(_ kind: QuotaLimitKind) -> String {
        switch kind {
        case .fiveHour: return tr("Today", "今天")
        case .weekly: return tr("Current cycle", "当前周期")
        case .modelWeekly, .unknown: return tr("Change", "变动")
        }
    }

    /// 5H 视图只画今天，但最新采样可能停在昨天（今天还没刷新成功）；这时必须带日期，
    /// 否则纯 `HH:mm` 会被读成今天的时间。
    private func latestText(_ window: QuotaTimelineWindow) -> String {
        guard let date = window.latestSampleAt else { return "--" }
        let spansDays = window.kind == .weekly || !Calendar.current.isDateInToday(date)
        return StatsFormatter.timelineTime(date, spansDays: spansDays)
    }

    @ViewBuilder
    private func windowContent(_ window: QuotaTimelineWindow) -> some View {
        let entries = mergedEntries(in: window)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(window.periods) { period in
                periodSummary(period, window: window)
            }
        }

        if entries.isEmpty {
            loadingOrEmpty(message: tr("No data for this window", "该窗口暂无数据"))
                .frame(height: 80)
        } else if isWide {
            HStack(alignment: .top, spacing: 14) {
                timelineChart(entries, window: window)
                    .frame(minHeight: 140, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                QuotaTimelineTable(entries: entries, spansDays: window.kind == .weekly)
                    .frame(width: 384)
                    .frame(maxHeight: .infinity)
            }
        } else {
            timelineChart(entries, window: window)
                .frame(minHeight: 140, maxHeight: .infinity)
            QuotaTimelineTable(entries: entries, spansDays: window.kind == .weekly)
        }
    }

    /// 周视图的当前/上一周期共用一张图和一张表；合并时给每个周期的窗口序号加偏移，
    /// 保留跨额度窗口断线语义，不把不同周期的最后一点和第一点连成假回升。
    private func mergedEntries(in window: QuotaTimelineWindow) -> [QuotaTimelineEntry] {
        var result: [QuotaTimelineEntry] = []
        var windowIndexOffset = 0

        for period in window.periods {
            let periodEntries = period.entries
            result.append(contentsOf: periodEntries.map { entry in
                var merged = entry
                merged.windowIndex += windowIndexOffset
                return merged
            })

            let periodWindowCount = (periodEntries.map(\.windowIndex).max() ?? -1) + 1
            windowIndexOffset += periodWindowCount
        }

        return result.sorted { $0.sampledAt < $1.sampledAt }
    }

    private func periodSummary(_ period: QuotaTimelinePeriod, window: QuotaTimelineWindow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(periodLabel(period.kind))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(StatsFormatter.timelineTime(period.start, spansDays: window.kind == .weekly)) → \(StatsFormatter.timelineTime(period.end, spansDays: window.kind == .weekly))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(StatsFormatter.quotaDelta(period.totalDelta))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func timelineChart(
        _ entries: [QuotaTimelineEntry],
        window: QuotaTimelineWindow
    ) -> some View {
        QuotaTimelineChart(
            entries: entries,
            tint: section.tint,
            spansDays: window.kind == .weekly,
            domain: timelineDomain(for: window)
        )
    }

    private func timelineDomain(for window: QuotaTimelineWindow) -> ClosedRange<Date> {
        guard let start = window.periods.map(\.start).min(),
              let end = window.periods.map(\.end).max()
        else {
            let now = Date()
            return now...now.addingTimeInterval(1_800)
        }
        return start...max(start, end)
    }

    private func periodLabel(_ kind: QuotaTimelinePeriodKind) -> String {
        switch kind {
        case .today: return tr("Today", "今天")
        case .currentCycle: return tr("Current cycle", "当前周期")
        case .previousCycle: return tr("Previous cycle", "上一周期")
        }
    }

    @ViewBuilder
    private func loadingOrEmpty(message: String) -> some View {
        if section.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Loading…", "加载中…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 窗口切换分段的可选项；固定 5H → 每周顺序。
@MainActor
private enum QuotaTimelineWindowKind: Hashable {
    case fiveHour
    case weekly

    var kind: QuotaLimitKind {
        switch self {
        case .fiveHour: return .fiveHour
        case .weekly: return .weekly
        }
    }

    var label: String {
        switch self {
        case .fiveHour: return tr("5H", "5小时")
        case .weekly: return tr("WK", "本周")
        }
    }

    static let pickable: [QuotaTimelineWindowKind] = [.fiveHour, .weekly]
}

private struct QuotaTimelineChart: View {
    let entries: [QuotaTimelineEntry]
    let tint: Color
    var spansDays: Bool = false
    let domain: ClosedRange<Date>

    /// X 轴按实际数据范围自适应，不再固定成整段周期：一天/一周里只有少数几次变动时，
    /// 固定域会把所有点挤在很窄的一段。两端各留一点余量，避免首尾点贴着轴；
    /// 单点或零跨度时退回固定余量，防止退化成零宽度域。
    private var xDomain: ClosedRange<Date> {
        let times = entries.map(\.sampledAt)
        guard let first = times.min(), let last = times.max() else { return domain }
        let span = last.timeIntervalSince(first)
        let padding = span > 0 ? span * 0.04 : (spansDays ? 1_800 : 900)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    var body: some View {
        Chart(entries) { entry in
            // series 按额度窗口分段：跨窗重置不产生变动事件，不分段会把上一窗口的低点
            // 和新窗口的高点直连成一条「额度自己涨回去」的假斜线。
            LineMark(
                x: .value("Time", entry.sampledAt),
                y: .value("Remaining", entry.remainingPercent),
                series: .value("Window", entry.windowIndex)
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            PointMark(
                x: .value("Time", entry.sampledAt),
                y: .value("Remaining", entry.remainingPercent)
            )
            .foregroundStyle(chartPointColor(remainingPercent: Double(entry.remainingPercent)))
            .symbolSize(40)
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                if spansDays {
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // 左:Y 轴刻度不贴面板内容左缘;右:末尾数据点 / X 轴标签不贴相邻表格。
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    /// 图表内数据点 4 档色:warning / low / empty 沿用全局 `statusColor`;
    /// normal(>50%)档在图表内比全局中性灰加深一档,保证浅色模式下点的可读性。
    /// 全局 `statusColor` 与 Popover / HUD 等处的中性灰不受影响。
    private func chartPointColor(remainingPercent: Double) -> Color {
        guard remainingPercent > 50 else {
            return statusColor(remainingPercent: remainingPercent, tint: .secondary)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb: (red: CGFloat, green: CGFloat, blue: CGFloat) = isDark
                ? (174, 174, 180)  // #AEAEB4
                : (86, 86, 90)     // #56565A
            return NSColor(
                calibratedRed: rgb.red / 255,
                green: rgb.green / 255,
                blue: rgb.blue / 255,
                alpha: 1
            )
        })
    }
}

private struct QuotaTimelineTable: View {
    let entries: [QuotaTimelineEntry]
    var spansDays: Bool = false

    /// 行数超过该值时,表体固定高度内部滚动(表头固定),保证面板高度稳定。
    private static let maxVisibleRows = 8
    /// 单行高度估算:11.5pt 行文本(~14pt)+ 上下 7pt padding + Divider。
    private static let rowHeight: CGFloat = 29

    private var rows: [QuotaTimelineEntry] {
        entries.sorted { $0.sampledAt > $1.sampledAt }
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
        ForEach(rows) { entry in
            Divider()
            row(entry)
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

    private func row(_ entry: QuotaTimelineEntry) -> some View {
        HStack {
            tableText(StatsFormatter.timelineTime(entry.sampledAt, spansDays: spansDays), width: 82, alignment: .leading)
            tableText(entry.deltaPercent.map { StatsFormatter.quotaDelta($0) } ?? "—", width: 82, alignment: .trailing)
                .foregroundStyle(deltaColor(entry.deltaPercent))
            tableText("\(entry.remainingPercent)%", width: 104, alignment: .trailing)
                .foregroundStyle(statusColor(remainingPercent: Double(entry.remainingPercent), tint: .secondary))
            tableText(StatsFormatter.resetTime(entry.resetsAt, spansDays: spansDays), width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func deltaColor(_ value: Int?) -> Color {
        guard let value else { return .secondary }
        return value < 0 ? .red : .green
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

/// 用量图表的 X 轴不用日期轴，改用「每个周期一个类别」的离散轴：日期轴上 Swift Charts
/// 会按自己推断(或指定)的 unit 给柱子分箱、把柱心挪到箱中点，刻度却落在箱起点，日 / 周 /
/// 月三种粒度都对不齐；周粒度还会按 `Calendar.current` 的周起点(可能是周日)算箱边界，
/// 和本项目的周一口径再差一天。类别轴下柱心与刻度共用同一个 band 中心，天然对齐。
private enum StatsPeriodKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for day: Date) -> String { formatter.string(from: day) }
    static func date(from key: String) -> Date? { formatter.date(from: key) }
}

/// 图表的一根柱。`day` 是该柱所属周期的起点(日粒度即当天,周粒度为周一,月粒度为 1 号),
/// 命名沿用历史,不随粒度改名。
private struct DailySample: Identifiable {
    var id: Date { day }
    let day: Date
    /// 用量图表 X 轴用的离散类别键，见 `StatsPeriodKey`。
    let key: String
    let codex: UsageTotals
    let claude: UsageTotals
    let cursor: UsageTotals
    let pi: UsageTotals
    let opencode: UsageTotals

    var codexCost: Decimal { codex.costUSD }
    var claudeCost: Decimal { claude.costUSD }
    var cursorCost: Decimal { cursor.costUSD }
    var piCost: Decimal { pi.costUSD }
    var opencodeCost: Decimal { opencode.costUSD }
    var totalCost: Decimal { totalUsage.costUSD }
    var totalTokens: Int { totalUsage.totalTokens }

    func totals(for app: UsageApp) -> UsageTotals {
        switch app {
        case .codex: return codex
        case .claude: return claude
        case .cursor: return cursor
        case .pi: return pi
        case .opencode: return opencode
        }
    }

    func cost(for app: UsageApp) -> Decimal {
        switch app {
        case .codex: return codexCost
        case .claude: return claudeCost
        case .cursor: return cursorCost
        case .pi: return piCost
        case .opencode: return opencodeCost
        }
    }

    /// 所有统计服务合并后的口径，供每日悬浮明细展示 token 拆分 + 命中率。
    var totalUsage: UsageTotals {
        var t = UsageTotals.zero
        for totals in [codex, claude, cursor, pi, opencode] {
            t.add(totals)
        }
        return t
    }
}

private struct ModelRow: Identifiable {
    var id: String { model }
    let model: String
    let totals: UsageTotals
    let speed: UsageSpeedBreakdown
}

/// 「按提供商」面板的提供商级聚合：跨服务归并 totals / 速度拆分，保留来源服务与模型子明细。
private struct ProviderGroup: Identifiable {
    var id: ModelProvider { provider }
    let provider: ModelProvider
    var totals = UsageTotals.zero
    var speed = UsageSpeedBreakdown()
    var sources: Set<UsageApp> = []
    var models: [ProviderModelRow] = []
}

/// 提供商展开区内的模型明细行（模型 + 来源服务）。
private struct ProviderModelRow: Identifiable {
    var id: String { "\(app.rawValue)/\(model)" }
    let model: String
    let app: UsageApp
    var totals: UsageTotals
    var speed: UsageSpeedBreakdown
}

private struct QuotaTimelineSection: Identifiable {
    var id: String { accountKey }
    let accountKey: String
    let title: String
    let tint: Color
    let windows: [QuotaTimelineWindow]
    var isLoading: Bool = false
}

/// 单个标准窗口（5H / 每周）的时间线数据。5H 仅含今天；周窗口含当前和上一额度周期。
private struct QuotaTimelineWindow: Identifiable {
    var id: QuotaLimitKind { kind }
    let kind: QuotaLimitKind
    let currentRemaining: Int?
    let latestSampleAt: Date?
    let periods: [QuotaTimelinePeriod]
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

    /// 美元显示取整（四舍五入到整数），仅周期页面使用，存储仍用原始 Decimal。
    static func costWhole(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
            .rounding(accordingToBehavior: nil)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return "$\(f.string(from: ns) ?? "0")"
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

    /// 图表 Y 轴专用：正常金额保持紧凑，小额刻度保留足够小数避免全部显示为 $0。
    static func axisCost(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        let magnitude = abs(ns.doubleValue)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        if magnitude >= 10 {
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 0
        } else if magnitude >= 1 {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
        } else {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 3
        }
        return "$\(f.string(from: ns) ?? "0.00")"
    }

    @MainActor
    static func tierCost(
        _ value: Decimal,
        hasUnpricedUsage _: Bool,
        costIncomplete _: Bool = false
    ) -> String {
        return cost(value)
    }

    /// 取整版 tierCost：仅周期页面使用。
    @MainActor
    static func tierCostWhole(_ value: Decimal, hasUnpricedUsage _: Bool) -> String {
        return costWhole(value)
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

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    /// 周桶标题:起始日全写、结束日省年份,控制在 200pt 浮层宽度内(如 `2026-09-01 – 09-07`)。
    static func weekRange(_ start: Date) -> String {
        let end = StatsRange.weekStartMondayCalendar.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(day(start)) – \(monthDayFormatter.string(from: end))"
    }

    /// 月桶标题(如 `2026-09`)。
    static func month(_ start: Date) -> String {
        monthFormatter.string(from: start)
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

    private static let resetTimeWithDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return time(date)
    }

    static func resetTime(_ date: Date?, spansDays: Bool) -> String {
        guard let date else { return "--" }
        return timelineTime(date, spansDays: spansDays)
    }

    /// 时间线使用的时刻格式：同一窗口跨天（滚动周窗口 / 跨午夜 5H）时带 MM-dd 前缀。
    static func timelineTime(_ date: Date, spansDays: Bool) -> String {
        spansDays ? resetTimeWithDayFormatter.string(from: date) : time(date)
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
