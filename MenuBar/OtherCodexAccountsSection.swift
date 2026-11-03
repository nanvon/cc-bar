import SwiftUI

// MARK: - OtherCodexAccountsSection
//
// Popover 中「其他账号」分区，展示用户手动导入的 Codex 副账号。
// 仅显示 visibleInPopover = true 的条目；visible 数量为 0 时整块隐藏。
// 布局参见 docs/界面布局.md 「Popover 其他账号分区」。

struct OtherCodexAccountsSection: View {
    @Environment(AppState.self) private var appState
    /// 为 true 时,隐藏与当前 CLI 主账号同身份的镜像项(主卡片已经展示了它),避免重复。
    var dedupPrimary: Bool = false

    private var visible: [ImportedCodexAccount] {
        appState.importedCodexAccounts.filter {
            $0.visibleInPopover && !(dedupPrimary && appState.importedCodexAccountMirrorsPrimary($0))
        }
    }

    var body: some View {
        let accounts = visible
        if accounts.isEmpty { EmptyView() } else {
            VStack(spacing: 0) {
                sectionHeader(count: accounts.count)
                ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, account in
                    if idx > 0 {
                        Divider()
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
            Text(tr("OTHER CODEX ACCOUNTS", "其他 Codex 账号"))
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
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
            // 左：名称 + 副标题；隐私模式使用跨页面一致的匿名账号编号。
            VStack(alignment: .leading, spacing: 1) {
                if !displayName.isEmpty {
                    Text(displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                if !displaySubtitle.isEmpty {
                    Text(displaySubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // 与主卡标签列同宽，`codex-work` 这类常见别名不再截断。
            .frame(width: 72, alignment: .leading)

            // 右：服务端主要额度 + 可选次要额度
            if let snap = snapshot {
                VStack(alignment: .leading, spacing: 5) {
                    if let primary = snap.primaryLimit {
                        quotaRow(label: compactLabel(for: primary.kind), window: primary.window)
                    } else {
                        quotaRow(label: "NOW", window: nil)
                    }
                    if let secondary = snap.secondaryLimit,
                       secondary.id != snap.primaryLimit?.id
                    {
                        quotaRow(label: compactLabel(for: secondary.kind), window: secondary.window)
                    }
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
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)

            // 标签 / 条高 / 数值字号与主卡片的次要额度行（compactLimitRow）一致。
            ProgressBar(
                value: (window?.remainingPercent ?? 0) / 100,
                tint: rowColor(window: window),
                height: 2.5
            )

            Text(percentText(window: window))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(rowColor(window: window))
                .frame(width: 30, alignment: .trailing)

            ResetTimeText(resetsAt: window?.resetsAt)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func compactLabel(for kind: QuotaLimitKind) -> String {
        switch kind {
        case .fiveHour: return "5H"
        case .weekly, .modelWeekly: return "WK"
        case .unknown: return "NOW"
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
                        .foregroundStyle(.secondary)
                }
            } else if let err = error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(PrivacyDisplay.error(shortError(err)))
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
            } else {
                Text("—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: Derived

    private var displayName: String {
        if PrivacyDisplay.isEnabled { return PrivacyDisplay.account(account.id) }
        if !account.alias.isEmpty { return account.alias }
        // 关闭「弹出面板显示邮箱」时，邮箱用户名也不显示，名称留空，只剩套餐副标题。
        if !SettingsStore.shared.popoverShowsEmail { return "" }
        return account.email.map { emailUsername($0) } ?? account.id
    }

    private var displaySubtitle: String {
        if SettingsStore.shared.privacyMode {
            // 隐私模式：subtitle 只保留 plan，不显示 email/别名
            if let plan = CodexAccount.planName(account.planType) { return plan }
            return ""
        }
        var parts: [String] = []
        // 有别名时名称不含 email，subtitle 补上 email；无别名时名称已是 email 用户名，不再重复。
        // email 可空（PAT 导入、无 email claim），此时仍保留 plan。
        if SettingsStore.shared.popoverShowsEmail, let email = account.email, !email.isEmpty, !account.alias.isEmpty {
            parts.append(email)
        }
        if let plan = CodexAccount.planName(account.planType) { parts.append(plan) }
        return parts.joined(separator: " · ")
    }

    private func rowColor(window: QuotaWindow?) -> Color {
        guard let window else { return .secondary }
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
