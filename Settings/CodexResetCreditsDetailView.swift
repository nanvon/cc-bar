import SwiftUI

// MARK: - CodexResetCreditsSheet
//
// 显示某个 Codex 账号的「使用限额重置」(rate-limit-reset-credits)明细弹窗。
// 参考 ChatGPT 官方样式：标题栏、绿色可用次数胶囊标签、卡片式记录列表。
// 主账号行(SettingsRootView)和导入账号行(ImportedCodexAccountsView)共用此 Sheet。
// 数据均为按需拉取,不持久化。

/// 重置 credit 的加载状态。
enum CodexResetCreditsState {
    case loading
    case success(CodexResetCreditsClient.Fetched)
    case failure(String)
}

struct CodexResetCreditsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let accountTitle: String
    let fetchCredits: () async -> Result<CodexResetCreditsClient.Fetched, QuotaError>

    @State private var state: CodexResetCreditsState = .loading
    @State private var listContentHeight: CGFloat = 0

    /// 列表区最大高度：约可容纳 5 条卡片完全展开不滚动，超过时内部滚动。
    private let maxListHeight: CGFloat = 330

    private var resolvedListHeight: CGFloat {
        if listContentHeight > 0 {
            return min(listContentHeight, maxListHeight)
        }
        if case .success(let fetched) = state, !fetched.credits.isEmpty {
            let count = CGFloat(fetched.credits.count)
            return min(max(count * 64 - 8, 56), maxListHeight)
        }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            headerView

            Divider()

            // 内容区
            contentView
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            Divider()

            // 底部操作栏
            footerView
        }
        .frame(width: 440)
        .fixedSize(horizontal: true, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: listContentHeight)
        .onPreferenceChange(ResetCreditsListHeightKey.self) { measured in
            if measured > 0 {
                listContentHeight = measured
            }
        }
        .task {
            await loadData()
        }
    }

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Reset Credits", "使用限额重置"))
                    .font(.system(size: 14, weight: .semibold))
                if !accountTitle.isEmpty {
                    Text(accountTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(tr("Loading reset credits…", "正在查询使用限额重置…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)

        case .failure(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button(tr("Retry", "重试")) {
                    Task { await loadData() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)

        case .success(let fetched):
            VStack(alignment: .leading, spacing: 12) {
                // 总览行：可用次数胶囊标签
                HStack {
                    Text(tr("Total Available", "总可用额度"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(tr("\(fetched.availableCount) available", "可用 \(fetched.availableCount) 次"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(fetched.availableCount > 0 ? Color.green : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(fetched.availableCount > 0 ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12))
                        )
                }

                // 记录列表
                if fetched.credits.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "gift")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text(tr("No reset credits available", "暂无可用重置记录"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(fetched.credits) { credit in
                                creditCard(credit)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ResetCreditsListHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                    }
                    .frame(height: resolvedListHeight > 0 ? resolvedListHeight : nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func creditCard(_ credit: CodexResetCreditsClient.Credit) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle(for: credit))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)

                if let expiresAt = credit.expiresAt {
                    Text(tr(
                        "Expires \(Self.dateFormatter.string(from: expiresAt))",
                        "将于 \(Self.dateFormatter.string(from: expiresAt)) 到期"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !credit.status.isEmpty && credit.status.lowercased() != "active" {
                Text(credit.status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var footerView: some View {
        HStack {
            Spacer()
            Button(tr("Done", "完成")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func loadData() async {
        state = .loading
        let result = await fetchCredits()
        switch result {
        case .success(let fetched):
            state = .success(fetched)
        case .failure(let err):
            state = .failure(err.userMessage)
        }
    }

    private func displayTitle(for credit: CodexResetCreditsClient.Credit) -> String {
        let raw = credit.title.isEmpty ? credit.status : credit.title
        if raw == "Full reset" || raw == "full_reset" {
            return tr("Full reset (weekly + 5-hour)", "完全重置（每周 + 5 小时）")
        }
        return raw
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - PreferenceKey

private struct ResetCreditsListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

