import Charts
import SwiftUI

/// 额度页「额度用满预估」：Codex / Claude × 5 小时 / 周的周期卡，宽画布一行四张。
/// 区块自带标题与一句口径说明，便于单独截图分享；卡内不写解释。
/// 进度条显示服务端返回的额度已用比例，条色与「N%」统一按剩余额度着色。
struct QuotaCycleCardsSection: View {
    @Environment(AppState.self) private var appState
    /// 受侧栏服务筛选约束：全部 → Codex + Claude；单选时只含该服务。
    let apps: [UsageApp]
    let isWide: Bool

    /// 只有显示 Codex 卡时才需要交代其他 Agent 的口径。
    private var includesOtherAgents: Bool {
        apps.contains(.codex) && SettingsStore.shared.cycleIncludesOtherAgents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("Full-quota estimate", "额度用满预估"))
                    .font(.system(size: 13, weight: .semibold))
                Text(includesOtherAgents
                    ? tr(
                        "Estimated from local usage (including Codex subscription usage in Pi, OpenCode and DSH) and the official used percentage. For reference only.",
                        "按本机用量（含 Pi、OpenCode、DSH 中的 Codex 订阅用量）和官方已用比例估算，仅供参考。"
                    )
                    : tr(
                        "Estimated from local usage and the official used percentage. For reference only.",
                        "按本机用量和官方已用比例估算，仅供参考。"
                    ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 8)
                if appState.usageService.isCycleRebuilding {
                    ProgressView().controlSize(.small)
                    Text(tr("Rebuilding current cycle data…", "正在补算当前周期数据…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                    count: isWide ? max(1, cards.count) : min(2, max(1, cards.count))
                ),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(cards, id: \.self) { card in
                    currentCycleCard(app: card.app, kind: card.kind)
                }
            }
        }
    }

    private struct CardKey: Hashable {
        let app: UsageApp
        let kind: QuotaLimitKind
    }

    /// 按传入的 `apps` 顺序展开：每服务 5 小时 → 周。
    private var cards: [CardKey] {
        apps.flatMap { app in [CardKey(app: app, kind: .fiveHour), CardKey(app: app, kind: .weekly)] }
    }

    private func currentCycleCard(app: UsageApp, kind: QuotaLimitKind) -> some View {
        Group {
            if let summary = currentSummary(app: app, kind: kind) {
                cycleCardBody(summary, app: app, kind: kind)
            } else {
                cycleCardEmptyState(app: app, kind: kind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: 132)
        .ccPanel(cornerRadius: 10)
    }

    /// 卡主体：标签行 → 用满预估主数字 + 说明 → 额度进度条 → 已用行。
    /// 间距两档：外边距与分组间 14pt，组内 8pt（主数字与说明 2pt 视为一体）。
    private func cycleCardBody(
        _ summary: CycleUsageSummary,
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> some View {
        let usedPercent = max(0, min(100, summary.cycle.latestUsedPercent))
        let color = officialColor(remaining: 100 - usedPercent)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ServiceTile(app: app, size: 12)
                    Text("\(app.displayName) · \(cycleKindShort(kind))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    ResetTimeText(resetsAt: summary.cycle.endAt)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(fullUseLine(summary))
                        .font(.system(size: 22, weight: .semibold))
                        .kerning(-0.5)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(fullUseCaption(summary))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 14)

            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(value: usedPercent / 100, tint: color, height: 6)

                HStack(alignment: .firstTextBaseline) {
                    // 只算当前额度段：Claude 周内重置不换周期，重置前的用量不再计入，与进度条对应。
                    Text("\(tr("Used", "已用")) \(StatsFormatter.compactToken(summary.currentAllowanceTotals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.currentAllowanceTotals.costUSD, hasUnpricedUsage: summary.currentAllowanceTotals.hasUnpricedUsage))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    // 剩余状态由数字和进度条颜色表达：≥20% 石墨灰、<20% 橙、=0 红（统一走 statusColor）。
                    Text(String(format: "%.0f%%", usedPercent))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .help(tr("Quota usage percentage reported officially.", "官方返回的额度已用比例。"))
                }
            }
        }
        .padding(14)
    }

    private func officialColor(remaining: Double) -> Color {
        statusColor(remainingPercent: remaining, tint: .primary)
    }

    /// 空态卡：标签行固定在顶部，下方提示内容在剩余空间垂直居中。
    private func cycleCardEmptyState(app: UsageApp, kind: QuotaLimitKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ServiceTile(app: app, size: 12)
                Text("\(app.displayName) · \(cycleKindShort(kind))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(hasAccount(app)
                     ? tr("Waiting for the current cycle", "等待当前周期")
                     : tr("Account not detected", "未检测到账号"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(hasAccount(app)
                 ? tr(
                    "A successful quota refresh will establish this reset cycle.",
                    "额度刷新成功后会建立该重置周期。"
                 )
                 : tr(
                    "Connect this service and refresh quota to start recording cycles.",
                    "连接该服务并刷新额度后开始记录周期。"
                 ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: - 数据

    private func currentSummary(
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> CycleUsageSummary? {
        guard let accountKey = accountKey(for: app) else { return nil }
        return summaries(kind: kind, app: app)
            .filter { $0.cycle.isCurrent() && $0.cycle.accountKey == accountKey }
            .sorted { lhs, rhs in
                let lhsLastSample = lhs.cycle.lastSampleAt ?? .distantPast
                let rhsLastSample = rhs.cycle.lastSampleAt ?? .distantPast
                if lhsLastSample != rhsLastSample { return lhsLastSample > rhsLastSample }
                if lhs.cycle.boundaryQuality != rhs.cycle.boundaryQuality {
                    return lhs.cycle.boundaryQuality == .observed
                }
                return lhs.cycle.endAt > rhs.cycle.endAt
            }
            .first
    }

    private func summaries(
        kind: QuotaLimitKind,
        app: UsageApp?
    ) -> [CycleUsageSummary] {
        appState.usageService.cycleAggregator.summaries(
            cycles: appState.quotaCycles.records,
            kind: kind,
            app: app,
            includeOtherAgents: SettingsStore.shared.cycleIncludesOtherAgents
        )
    }

    private func accountKey(for app: UsageApp) -> String? {
        appState.cycleAccountKey(for: app)
    }

    private func hasAccount(_ app: UsageApp) -> Bool {
        accountKey(for: app) != nil
    }
}

private extension AppState {
    /// 额度周期归属的主账号；未登录或该服务没有额度周期时为 nil。周期卡与历史周期共用。
    func cycleAccountKey(for app: UsageApp) -> String? {
        switch app {
        case .codex:
            guard codexAccount != nil else { return nil }
            return QuotaHistoryAccountKey.codexPrimary(accountId: codexAccount?.accountId)
        case .claude:
            guard claudeAccount != nil else { return nil }
            return QuotaHistoryAccountKey.claudePrimary(
                email: claudeAccount?.email,
                accountUuid: claudeAccount?.accountUuid
            )
        case .cursor:
            return nil
        case .pi, .opencode:
            return nil
        case .dsh:
            // DSH 没有额度周期，额度页不出现该服务。
            return nil
        case .antigravity:
            // Antigravity 用量不进周期统计。
            return nil
        }
    }
}

// MARK: - 历史周期

/// 额度页「历史周期」：每服务一个面板，柱状图看各已结束周期的用满预估费用（深色为实际费用），
/// 下方列最近 4 个周期的预估与实际 Tokens · 费用。5 小时 / 周在区块标题行切换。
struct QuotaCycleHistorySection: View {
    @Environment(AppState.self) private var appState
    /// 受侧栏服务筛选约束，规则同周期卡。
    let apps: [UsageApp]
    let isWide: Bool

    @State private var kind: QuotaLimitKind = .weekly

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("Past cycles", "历史周期"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Picker(tr("Cycle", "周期"), selection: $kind) {
                    Text(tr("5-hour", "5 小时")).tag(QuotaLimitKind.fiveHour)
                    Text(tr("Weekly", "周")).tag(QuotaLimitKind.weekly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                    count: isWide ? min(2, max(1, apps.count)) : 1
                ),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(apps, id: \.self) { app in
                    QuotaCycleHistoryPanel(app: app, kind: kind, summaries: completedSummaries(app: app))
                }
            }
        }
    }

    /// 当前主账号已结束、有本机用量的周期，按结束时间升序，只取最近 `maxCycles` 个。
    private func completedSummaries(app: UsageApp) -> [CycleUsageSummary] {
        guard let accountKey = appState.cycleAccountKey(for: app) else { return [] }
        let now = Date()
        let summaries = appState.usageService.cycleAggregator.summaries(
            cycles: appState.quotaCycles.records,
            kind: kind,
            app: app,
            includeOtherAgents: SettingsStore.shared.cycleIncludesOtherAgents,
            now: now
        )
        return Array(
            summaries
                .filter { $0.cycle.accountKey == accountKey && $0.cycle.isComplete(at: now) && $0.hasLocalUsage }
                .sorted { $0.cycle.endAt < $1.cycle.endAt }
                .suffix(Self.maxCycles)
        )
    }

    static let maxCycles = 12
}

private struct QuotaCycleHistoryPanel: View {
    let app: UsageApp
    let kind: QuotaLimitKind
    let summaries: [CycleUsageSummary]

    @State private var selectedID: String?

    /// 官方已用比例低于此值时预估偏差大，柱子与明细降为弱化显示。
    private static let lowObservationPercent = 10.0
    private static let chartHeight: CGFloat = 140
    private static let recentRowCount = 4
    private static let axisLabelCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ServiceTile(app: app, size: 12)
                Text(app.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                legendItem(color: estimateColor, label: tr("Full-use estimate", "用满预估"))
                legendItem(color: app.tintColor, label: tr("Actual", "实际"))
            }

            if summaries.isEmpty {
                Text(tr("No completed cycles yet", "暂无已结束周期"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.chartHeight + 96)
            } else {
                chart
                    .frame(height: Self.chartHeight)
                recentTable
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .ccPanel(cornerRadius: 12)
        .onChange(of: kind) { _, _ in selectedID = nil }
    }

    private var estimateColor: Color { app.tintColor.opacity(0.3) }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            ServiceMark(color: color, size: 9)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: 图表

    /// 同一类别上叠两根不堆叠的柱：浅色为用满预估费用，深色为实际费用；无预估依据时只画实际。
    private var chart: some View {
        let barWidth = StatsOverviewModel.barWidth(forSampleCount: summaries.count)
        let selected = selectedID.flatMap { id in summaries.first { $0.id == id } }
        return Chart {
            ForEach(summaries) { summary in
                let opacity = barOpacity(summary, selected: selected)
                if let estimate = summary.cycleEstimatedFullAllowanceCostUSD {
                    BarMark(
                        x: .value("Cycle", summary.id),
                        y: .value("Cost", Self.double(estimate)),
                        width: .fixed(barWidth),
                        stacking: .unstacked
                    )
                    .foregroundStyle(estimateColor)
                    .opacity(opacity)
                    .cornerRadius(2)
                }
                BarMark(
                    x: .value("Cycle", summary.id),
                    y: .value("Cost", Self.double(summary.totals.costUSD)),
                    width: .fixed(barWidth),
                    stacking: .unstacked
                )
                .foregroundStyle(app.tintColor)
                .opacity(opacity)
                .cornerRadius(2)
            }

            if let selected {
                RuleMark(x: .value("Cycle", selected.id))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXSelection(value: $selectedID)
        .chartXScale(domain: summaries.map(\.id))
        .chartXAxis {
            AxisMarks(values: StatsOverviewModel.axisKeys(from: summaries.map(\.id), maxCount: Self.axisLabelCount)) { value in
                AxisValueLabel {
                    if let id = value.as(String.self), let summary = summaries.first(where: { $0.id == id }) {
                        Text(axisLabel(summary))
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
                    if let cost = value.as(Double.self) {
                        Text(StatsFormatter.axisCost(Decimal(cost)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartOverlay(alignment: .topLeading) { proxy in
            GeometryReader { geo in
                if let selected, let plotFrame = proxy.plotFrame,
                   let x = proxy.position(forX: selected.id) {
                    let plot = geo[plotFrame]
                    let gap = barWidth / 2 + 10
                    let centerX = plot.minX + x
                    let fitsRight = centerX + gap + QuotaCycleHistoryTooltip.width <= plot.maxX
                    let left = fitsRight ? centerX + gap : max(0, centerX - gap - QuotaCycleHistoryTooltip.width)
                    QuotaCycleHistoryTooltip(summary: selected, kind: kind, lowObservation: isLowObservation(selected))
                        .offset(x: left)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 悬浮时非选中柱降透明；无悬浮时，已用比例过低的周期降透明。
    private func barOpacity(_ summary: CycleUsageSummary, selected: CycleUsageSummary?) -> Double {
        if let selected { return selected.id == summary.id ? 1 : 0.35 }
        return isLowObservation(summary) ? 0.35 : 1
    }

    private func isLowObservation(_ summary: CycleUsageSummary) -> Bool {
        summary.cycleObservedPercent < Self.lowObservationPercent
    }

    private func axisLabel(_ summary: CycleUsageSummary) -> String {
        kind == .fiveHour
            ? CycleHistoryFormat.dayTime(summary.cycle.startAt)
            : CycleHistoryFormat.monthDay(summary.cycle.startAt)
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    // MARK: 明细

    /// 最近 4 个周期，新的在上：周期 | 用满预估 | 实际。
    private var recentTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                headerCell(tr("Cycle", "周期"))
                headerCell(tr("Full-use estimate", "用满预估"))
                headerCell(tr("Actual", "实际"))
            }

            Divider()

            ForEach(Array(summaries.suffix(Self.recentRowCount).reversed())) { summary in
                let low = isLowObservation(summary)
                GridRow {
                    valueCell(CycleHistoryFormat.period(summary.cycle, kind: kind), weight: .regular, style: .secondary)
                    valueCell(
                        CycleHistoryFormat.estimateLine(summary),
                        weight: low ? .regular : .semibold,
                        style: low ? .secondary : .primary
                    )
                    valueCell(CycleHistoryFormat.actualLine(summary), weight: .regular, style: .secondary)
                }
            }
        }
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func valueCell(_ text: String, weight: Font.Weight, style: HierarchicalShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: weight))
            .monospacedDigit()
            .foregroundStyle(style)
            .lineLimit(1)
    }
}

/// 历史周期柱的悬浮明细：周期 → 用满预估 / 实际 → 官方已用比例与数据提示。样式同用量柱状图浮层。
private struct QuotaCycleHistoryTooltip: View {
    static let width: CGFloat = 200

    let summary: CycleUsageSummary
    let kind: QuotaLimitKind
    let lowObservation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CycleHistoryFormat.period(summary.cycle, kind: kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            row(label: tr("Full-use estimate", "用满预估"), value: CycleHistoryFormat.estimateLine(summary), emphasized: true)
            row(label: tr("Actual", "实际"), value: CycleHistoryFormat.actualLine(summary), emphasized: true)

            Divider()

            row(
                label: tr("Officially used", "官方已用"),
                value: CycleHistoryFormat.percent(summary.cycleObservedPercent),
                emphasized: false
            )
            if summary.cycle.extraResetCount > 0 {
                row(
                    label: tr("Mid-cycle resets", "周期内重置"),
                    value: "\(summary.cycle.extraResetCount)",
                    emphasized: false
                )
            }
            if lowObservation {
                note(tr("Low usage, estimate is rough.", "已用比例低，预估偏差大。"))
            }
            if summary.quality == .incomplete {
                note(tr("Some of this cycle wasn't recorded.", "该周期有部分时段未记录。"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .ccPanelStroke(cornerRadius: 8)
    }

    private func row(label: String, value: String, emphasized: Bool) -> some View {
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 历史周期的文字格式：`Tokens · 费用`（Tokens 在前），周期起止按本地时间。
@MainActor
private enum CycleHistoryFormat {
    static func estimateLine(_ summary: CycleUsageSummary) -> String {
        let tokens = summary.cycleEstimatedFullAllowanceTokens.map { StatsFormatter.compactToken($0) } ?? "—"
        let cost = summary.cycleEstimatedFullAllowanceCostUSD
            .map { StatsFormatter.tierCostWhole($0, hasUnpricedUsage: false) } ?? "—"
        return "\(tokens) · \(cost)"
    }

    static func actualLine(_ summary: CycleUsageSummary) -> String {
        "\(StatsFormatter.compactToken(summary.totals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage))"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// 周：`10-26 – 11-02`；5 小时：`11-03 06:29 – 11:29`，跨天时结束端也带日期。
    static func period(_ cycle: QuotaCycleRecord, kind: QuotaLimitKind) -> String {
        guard kind == .fiveHour else {
            return "\(monthDay(cycle.startAt)) – \(monthDay(cycle.endAt))"
        }
        let sameDay = Calendar.current.isDate(cycle.startAt, inSameDayAs: cycle.endAt)
        return "\(dayTime(cycle.startAt)) – \(sameDay ? time(cycle.endAt) : dayTime(cycle.endAt))"
    }

    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }
    static func dayTime(_ date: Date) -> String { dayTimeFormatter.string(from: date) }
    static func time(_ date: Date) -> String { StatsFormatter.time(date) }

    private static let monthDayFormatter = formatter("MM-dd")
    private static let dayTimeFormatter = formatter("MM-dd HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

// MARK: - 周期卡共享的纯函数

/// 周期类型短标签：5 小时 / 周，用于周期卡标签。
private func cycleKindShort(_ kind: QuotaLimitKind) -> String {
    switch kind {
    case .fiveHour: return tr("5-hour", "5 小时")
    case .weekly: return tr("Weekly", "周")
    default: return tr("Cycle", "周期")
    }
}

/// 周期卡主数字：当前额度段的用满预估 `Tokens · 费用`，Tokens 在前；无依据的一侧显示 `—`。
private func fullUseLine(_ summary: CycleUsageSummary) -> String {
    let tokens = summary.estimatedFullAllowanceTokens
        .map { StatsFormatter.compactToken($0) } ?? "—"
    let cost = summary.estimatedFullAllowanceCostUSD
        .map { StatsFormatter.tierCostWhole($0, hasUnpricedUsage: false) } ?? "—"
    return "\(tokens) · \(cost)"
}

/// 主数字下方说明：`用满预估`，有可信度时追加 `· 粗略估算` 等。
private func fullUseCaption(_ summary: CycleUsageSummary) -> String {
    let title = tr("Full-use estimate", "用满预估")
    guard let confidence = summary.forecastConfidence else { return title }
    return "\(title) · \(forecastConfidenceText(confidence))"
}

private func forecastConfidenceText(_ confidence: CycleForecastConfidence) -> String {
    switch confidence {
    case .early: return tr("Early estimate", "早期估算")
    case .rough: return tr("Rough estimate", "粗略估算")
    case .reference: return tr("Reference", "参考")
    case .reliable: return tr("More reliable", "较可靠")
    }
}
