import SwiftUI

struct CycleStatsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if appState.usageService.isCycleRebuilding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Rebuilding current cycle data…", "正在补算当前周期数据…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            currentCyclesSection
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tr("Cycle usage", "周期用量"))
                .font(.system(size: 18, weight: .semibold))
                .kerning(-0.2)
        }
    }

    // MARK: - 当前周期

    /// Codex / Claude × 5 小时 / 周共 4 张 KPI 卡；两行两列，每张占半行宽度。
    private var currentCyclesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Current cycles", "当前周期"))
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    currentCycleKpiCard(app: .codex, kind: .fiveHour)
                    currentCycleKpiCard(app: .codex, kind: .weekly)
                }
                HStack(spacing: 12) {
                    currentCycleKpiCard(app: .claude, kind: .fiveHour)
                    currentCycleKpiCard(app: .claude, kind: .weekly)
                }
            }
        }
    }

    /// KPI 卡：6pt 识别色点 + 服务/周期标签 → 整周期预估 Tokens·费用大字 →
    /// 已用辅助行 → 迷你进度条 → 倒计时。空态只保留标签与一句引导。
    private func currentCycleKpiCard(app: UsageApp, kind: QuotaLimitKind) -> some View {
        Group {
            if let summary = currentSummary(app: app, kind: kind) {
                cycleKpiBody(summary, app: app, kind: kind)
            } else {
                cycleKpiEmptyState(app: app, kind: kind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: 152)
        .ccPanel(cornerRadius: 10)
    }

    /// 卡主体：标签行 → 用满预估大字 → 已用辅助行 → 迷你进度条 → 倒计时。
    private func cycleKpiBody(
        _ summary: CycleUsageSummary,
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> some View {
        let usedPercent = max(0, summary.cycle.latestUsedPercent)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ServiceTile(app: app, size: 12)
                Text("\(app.displayName) · \(cycleKindShort(kind))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let confidence = summary.forecastConfidence {
                    Text(forecastConfidenceText(confidence))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Text(fullUseLine(summary))
                .font(.system(size: 24, weight: .semibold))
                .kerning(-0.5)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 2)

            Text(
                "\(tr("Used", "已用")) \(StatsFormatter.compactToken(summary.totals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage)) · \(String(format: "%.1f%%", usedPercent))"
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            ProgressBar(
                value: usedPercent / 100,
                tint: statusColor(remainingPercent: 100 - usedPercent, tint: app.tintColor),
                height: 4
            )
            .padding(.top, 3)

            Spacer(minLength: 0)

            ResetTimeText(resetsAt: summary.cycle.endAt)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    /// 空态卡：标签行固定在顶部，下方提示内容在剩余空间垂直居中。
    private func cycleKpiEmptyState(app: UsageApp, kind: QuotaLimitKind) -> some View {
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
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
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
            app: app
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
            // DSH 没有额度周期，Cycles 不出现该服务。
            return nil
        }
    }

    private func hasAccount(_ app: UsageApp) -> Bool {
        accountKey(for: app) != nil
    }
}

// MARK: - 周期页共享的纯函数与子视图

/// 周期类型短标签：5 小时 / 周，用于 KPI 卡标签。
private func cycleKindShort(_ kind: QuotaLimitKind) -> String {
    switch kind {
    case .fiveHour: return tr("5-hour", "5 小时")
    case .weekly: return tr("Weekly", "周")
    default: return tr("Cycle", "周期")
    }
}

/// KPI 卡主数字：用满预估 `Tokens · 费用`，无依据的一侧显示 `—`。
private func fullUseLine(_ summary: CycleUsageSummary) -> String {
    let tokens = summary.projectedFullCycleTokens
        .map { StatsFormatter.compactToken($0) } ?? "—"
    let cost = summary.projectedFullCycleCostUSD
        .map { StatsFormatter.tierCostWhole($0, hasUnpricedUsage: false) } ?? "—"
    return "\(tokens) · \(cost)"
}

private func forecastConfidenceText(_ confidence: CycleForecastConfidence) -> String {
    switch confidence {
    case .early: return tr("Early estimate", "早期估算")
    case .rough: return tr("Rough estimate", "粗略估算")
    case .reference: return tr("Reference", "参考")
    case .reliable: return tr("More reliable", "较可靠")
    }
}
