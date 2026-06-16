import SwiftUI

// MARK: - OtherCodexAccountsSection
//
// Popover 中「其他账号」分区，展示用户手动导入的 Codex 副账号。
// 仅显示 visibleInPopover = true 的条目；visible 数量为 0 时整块隐藏。
// 布局参见 docs/界面布局.md 「Popover 其他账号分区」。

struct OtherCodexAccountsSection: View {
    @Environment(AppState.self) private var appState

    private var visible: [ImportedCodexAccount] {
        appState.importedCodexAccounts.filter(\.visibleInPopover)
    }

    var body: some View {
        let accounts = visible
        if accounts.isEmpty { EmptyView() } else {
            VStack(spacing: 0) {
                sectionHeader(count: accounts.count)
                ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, account in
                    if idx > 0 {
                        Divider()
                            .overlay(CCPopoverPalette.separator)
                            .padding(.leading, 16)
                            .padding(.trailing, 16)
                    }
                    ImportedCodexRow(account: account)
                }
            }
        }
    }

    private func sectionHeader(count: Int) -> some View {
        HStack {
            Text(tr("OTHER CODEX ACCOUNTS", "其他账号"))
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(CCPopoverPalette.weakText)

            Spacer()

            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(CCPopoverPalette.weakText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

// MARK: - ImportedCodexRow

private struct ImportedCodexRow: View {
    @Environment(AppState.self) private var appState
    let account: ImportedCodexAccount

    private var snapshot: QuotaSnapshot? { appState.importedCodexQuota(for: account) }
    private var error: String? { appState.importedCodexError(for: account) }
    private var refreshState: QuotaRefreshState {
        appState.importedCodexRefreshState(for: account)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左：别名 + 副标题（隐私模式下名称为空,VStack 只剩 subtitle,
            // 由外层 HStack(.center) 自动垂直居中）
            VStack(alignment: .leading, spacing: 1) {
                if !displayName.isEmpty {
                    Text(displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(CCPopoverPalette.primaryText)
                        .lineLimit(1)
                }
                if !displaySubtitle.isEmpty {
                    Text(displaySubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(CCPopoverPalette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: 52, alignment: .leading)

            // 右：5H + WK 两行进度
            if let snap = snapshot {
                VStack(alignment: .leading, spacing: 5) {
                    quotaRow(label: "5H", window: snap.fiveHour)
                    quotaRow(label: "WK", window: snap.weekly)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                loadingOrError
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: 进度行

    private func quotaRow(label: String, window: QuotaWindow?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(CCPopoverPalette.weakText)
                .frame(width: 18, alignment: .leading)

            ProgressBar(
                value: (window?.remainingPercent ?? 0) / 100,
                tint: rowColor(window: window),
                height: 2,
                track: CCPopoverPalette.progressTrack
            )

            Text(percentText(window: window))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(rowColor(window: window))
                .frame(width: 30, alignment: .trailing)

            ResetTimeText(resetsAt: window?.resetsAt)
                .font(.system(size: 10))
                .foregroundStyle(CCPopoverPalette.weakText)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var loadingOrError: some View {
        Group {
            if refreshState.inFlight {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(tr("Loading…", "加载中…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(CCPopoverPalette.secondaryText)
                }
            } else if let err = error {
                Text(shortError(err))
                    .font(.system(size: 10.5))
                    .foregroundStyle(CCPopoverPalette.secondaryText)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CCPopoverPalette.weakText)
            }
        }
    }

    // MARK: Derived

    private var displayName: String {
        if SettingsStore.shared.privacyMode { return "" }
        return account.alias.isEmpty ? (account.email.map { emailUsername($0) } ?? account.id) : account.alias
    }

    private var displaySubtitle: String {
        if SettingsStore.shared.privacyMode {
            // 隐私模式：subtitle 只保留 plan，不显示 email/别名
            if let plan = account.planType, !plan.isEmpty { return plan.capitalized }
            return ""
        }
        var parts: [String] = []
        if let email = account.email, !email.isEmpty { parts.append(email) }
        if let plan = account.planType, !plan.isEmpty { parts.append(plan.capitalized) }
        if let email = account.email, !email.isEmpty, !account.alias.isEmpty {
            // 有别名时 subtitle 只显示 email · plan
            return parts.joined(separator: " · ")
        }
        return parts.dropFirst().joined(separator: " · ")
    }

    private func rowColor(window: QuotaWindow?) -> Color {
        guard let window else { return CCPopoverPalette.secondaryText }
        return statusColor(remainingPercent: window.remainingPercent, tint: .codexAccent)
    }

    private func percentText(window: QuotaWindow?) -> String {
        guard let window else { return "--%"}
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private func emailUsername(_ email: String) -> String {
        email.components(separatedBy: "@").first ?? email
    }

    private func shortError(_ s: String) -> String {
        let line = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }
}
