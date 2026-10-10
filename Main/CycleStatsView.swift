import SwiftUI

/// 额度页「额度用满预估」：Codex / Claude × 5 小时 / 周的周期卡，宽画布一行四张。
/// 区块自带标题与一句口径说明，便于单独截图分享；卡内不写解释。
/// 进度条显示服务端返回的额度已用比例，条色与「N%」统一按剩余额度着色。
struct QuotaCycleCardsSection: View {
    @Environment(AppState.self) private var appState
    /// 受侧栏服务筛选约束：全部 → Codex + Claude；单选时只含该服务。
    let apps: [UsageApp]
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("Full-quota estimate", "额度用满预估"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr(
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
                    Text("\(tr("Used", "已用")) \(StatsFormatter.compactToken(summary.totals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage))")
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
                        .help(tr("Quota usage percentage returned by the service.", "服务端返回的额度已用比例。"))
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
        switch app {
        case .codex:
            guard appState.codexAccount != nil else { return nil }
            return QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
        case .claude:
            guard appState.claudeAccount != nil else { return nil }
            return QuotaHistoryAccountKey.claudePrimary(email: appState.claudeAccount?.email)
        case .cursor:
            return nil
        case .pi, .opencode:
            return nil
        case .dsh:
            // DSH 没有额度周期，额度页不出现该服务。
            return nil
        }
    }

    private func hasAccount(_ app: UsageApp) -> Bool {
        accountKey(for: app) != nil
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

/// 周期卡主数字：用满预估 `Tokens · 费用`，Tokens 在前；无依据的一侧显示 `—`。
private func fullUseLine(_ summary: CycleUsageSummary) -> String {
    let tokens = summary.projectedFullCycleTokens
        .map { StatsFormatter.compactToken($0) } ?? "—"
    let cost = summary.projectedFullCycleCostUSD
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
