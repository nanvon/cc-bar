import AppKit
import SwiftUI

// MARK: - ImportedCodexAccountsView
//
// 设置页「其他 Codex 账号」：作为缩进子行挂在 Codex 服务行下方，右侧列与服务行对齐
// （菜单栏 / 悬浮窗两列留空，⋯ 菜单在数据来源列，开关在启用列）。
// 用户在此处粘贴 auth.json → 解析预览 → 填写别名 → 保存。
// 增删后调 AppState.reloadImportedCodexAccounts() 通知运行时。

struct ImportedCodexAccountsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddSheet = false
    @State private var deleteTarget: ImportedCodexAccount?

    @State private var selectedResetAccount: ImportedCodexAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let accounts = appState.importedCodexAccounts
            let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // 子行之间整行拖动排序，只在其他账号内移动；第一行顶部的分隔线把它和 Codex 主行分开。
            ReorderableStack(
                ids: accounts.map(\.id),
                movableCount: accounts.count,
                dividerLeading: ServiceRowMetrics.textLeading,
                dividesFirstRow: true,
                onMove: { _, newOrder in appState.reorderImportedCodexAccounts(orderedIds: newOrder) }
            ) { id, reorder in
                if let account = byID[id] {
                    importedAccountRow(account: account, reorder: reorder)
                }
            }

            subRowDivider

            // 添加按钮：与子行名称左对齐
            Button {
                showAddSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(tr("Add Codex Account…", "添加 Codex 账号…"))
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 9)
                .padding(.leading, ServiceRowMetrics.textLeading)
                .padding(.trailing, ServiceRowMetrics.trailingPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointingHandCursor()
            .help(tr("Paste another account's auth.json to view its quota. Quota only; your Codex CLI sign-in is not changed.",
                     "粘贴其他账号的 auth.json 查看它的额度。只查看额度，不会切换 Codex CLI 的登录账号"))
        }
        .background(Color.primary.opacity(0.02))
        .sheet(isPresented: $showAddSheet) {
            AddImportedCodexAccountSheet { appState.reloadImportedCodexAccounts() }
        }
        .sheet(item: $selectedResetAccount) { account in
            CodexResetCreditsSheet(
                accountTitle: rowTitle(account, respectsPrivacy: false),
                privacyAccountKey: account.id,
                fetchCredits: { await appState.fetchImportedCodexResetCredits(account: account) }
            )
        }
        .confirmationDialog(
            tr("Remove account?", "删除此账号？"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                Button(tr("Remove", "删除"), role: .destructive) {
                    appState.removeImportedCodexAccount(id: target.id)
                    deleteTarget = nil
                }
                Button(tr("Cancel", "取消"), role: .cancel) {
                    deleteTarget = nil
                }
            }
        } message: {
            if let target = deleteTarget {
                let name = rowTitle(target)
                Text(tr("\u{201C}\(name)\u{201D} will be removed from CCBar. The account itself is not affected.",
                        "\u{201C}\(name)\u{201D} 将从 CCBar 中移除，账号本身不受影响。"))
            }
        }
    }

    /// 子行分隔线：从名称起点开始，同服务行之间的分隔线。
    private var subRowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, ServiceRowMetrics.textLeading)
    }

    // MARK: 账号行

    private func importedAccountRow(account: ImportedCodexAccount, reorder: ReorderRowState) -> some View {
        let error = appState.importedCodexError(for: account)

        return HStack(spacing: 0) {
            ReorderGrip(isLifted: reorder.isLifted)
                .frame(width: ServiceRowMetrics.handleWidth)

            Color.clear
                .frame(width: ServiceRowMetrics.textLeading - ServiceRowMetrics.leadingPadding - ServiceRowMetrics.handleWidth)

            ServiceTile(
                logoName: "codex",
                fallback: "C",
                tint: QuotaApp.codex.tintColor,
                size: 20,
                logoSize: 13,
                cornerRadius: 5.5
            )
            .padding(.trailing, 10)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(rowTitle(account))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                let detail = importedAccountDetail(account)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let error {
                    Text("· \(tr("Refresh failed", "刷新失败"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .help(error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // 菜单栏 / 悬浮窗两列：导入账号只在 Popover 显示，留空保持对齐。
            Color.clear
                .frame(width: ServiceRowMetrics.destination * 2, height: 1)

            Menu {
                Button(tr("Reset Credits…", "额度重置次数…")) {
                    selectedResetAccount = account
                }
                Divider()
                Button(tr("Remove…", "删除…"), role: .destructive) {
                    deleteTarget = account
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("More", "更多操作"))
            .frame(width: ServiceRowMetrics.info)

            Toggle(rowTitle(account), isOn: Binding(
                get: { account.visibleInPopover },
                set: { newValue in
                    appState.updateImportedCodexMetadata(id: account.id) { $0.visibleInPopover = newValue }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.green)
            .help(tr("Show this account's quota in the Popover", "在 Popover 显示这个账号的额度"))
            .frame(width: ServiceRowMetrics.toggle)
        }
        .padding(.leading, ServiceRowMetrics.leadingPadding)
        .padding(.trailing, ServiceRowMetrics.trailingPadding)
        .padding(.vertical, 8)
        .reorderDragSource(reorder)
    }

    private func rowTitle(_ account: ImportedCodexAccount, respectsPrivacy: Bool = true) -> String {
        if respectsPrivacy && PrivacyDisplay.isEnabled { return PrivacyDisplay.account(account.id) }
        if !account.alias.isEmpty { return account.alias }
        if let email = account.email, !email.isEmpty {
            return email.components(separatedBy: "@").first ?? email
        }
        return account.id
    }

    private func importedAccountDetail(_ account: ImportedCodexAccount) -> String {
        var parts: [String] = []
        if !PrivacyDisplay.isEnabled, let email = account.email, !email.isEmpty { parts.append(email) }
        if let plan = account.planType, !plan.isEmpty { parts.append(plan.capitalized) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AddImportedCodexAccountSheet

struct AddImportedCodexAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onSuccess: () -> Void

    @State private var jsonText = ""
    @State private var visibleInPopover = true

    @State private var parseResult: Result<[ImportedCodexPaste.Parsed], ImportedCodexPaste.Failure>?
    @State private var saveError: String?
    @State private var isSaving = false
    /// 识别到的 personal access token（不透明令牌，身份在保存时联网解析）。
    @State private var patToken: String?

    private var parsedBatch: [ImportedCodexPaste.Parsed]? {
        if case .success(let list) = parseResult { return list }
        return nil
    }
    private var parsed: ImportedCodexPaste.Parsed? { parsedBatch?.first }
    private var isBatch: Bool { (parsedBatch?.count ?? 0) > 1 }
    private var parseError: String? {
        if case .failure(let f) = parseResult { return f.description }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text(tr("Add Codex Account", "添加 Codex 账号"))
                    .font(.system(size: 14, weight: .semibold))
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
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // JSON 粘贴区
                    jsonSection
                    // 预览
                    if let pat = patToken {
                        patPreviewSection(pat)
                    } else if isBatch, let batch = parsedBatch {
                        batchPreviewSection(batch)
                    } else if let p = parsed {
                        previewSection(p)
                    }
                    // 表单(显示开关,单账号 / 批量通用)
                    if parsedBatch != nil || patToken != nil { formSection }
                    // 错误
                    if let err = parseError ?? saveError {
                        Text(PrivacyDisplay.error(err))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // 按钮栏
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Button(isBatch ? tr("Import All", "批量导入") : tr("Save", "保存")) { save() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled((parsedBatch == nil && patToken == nil) || isSaving)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 460)
        .onChange(of: jsonText) { _, _ in reParse() }
    }

    // MARK: JSON 粘贴区

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Paste auth.json content", "粘贴 auth.json 内容"))
                .font(.system(size: 12, weight: .semibold))
            Text(tr(
                "Supports a single auth.json, a JSON array of accounts (e.g. cc-switch export), or {\"personal_access_token\": \"at-...\"}.",
                "支持单个 auth.json、多账号 JSON 数组（如 cc-switch 导出）或 {\"personal_access_token\": \"at-...\"}。"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Group {
                if PrivacyDisplay.isEnabled {
                    VStack(spacing: 10) {
                        Text(jsonText.isEmpty
                             ? tr("Credentials stay hidden in privacy mode", "隐私模式下不显示凭据内容")
                             : tr("Pasted credentials are hidden", "已粘贴的凭据内容已隐藏"))
                            .foregroundStyle(.secondary)
                        Button(tr("Paste credentials", "粘贴凭据")) {
                            jsonText = NSPasteboard.general.string(forType: .string) ?? ""
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $jsonText)
                }
            }
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 120)
                .padding(6)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            parseError != nil ? Color.red.opacity(0.6) :
                            ((parsed != nil || patToken != nil) ? Color.green.opacity(0.5) : Color.secondary.opacity(0.25)),
                            lineWidth: 1
                        )
                )
        }
    }

    // MARK: 解析预览

    private func previewSection(_ p: ImportedCodexPaste.Parsed) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let email = p.email {
                        Text(PrivacyDisplay.isEnabled ? PrivacyDisplay.account(p.id) : email)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    if let plan = p.planType {
                        Text(plan.capitalized)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text("ID:")
                    PrivacySensitiveText(text: p.chatgptAccountId, kind: .identifier)
                }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(10)
        .background(.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: PAT 预览

    private func patPreviewSection(_ token: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Personal access token", "个人访问令牌"))
                    .font(.system(size: 12, weight: .semibold))
                Text(tr(
                    "Identity is verified online on save.",
                    "身份将在保存时联网验证。"
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 批量预览

    private func batchPreviewSection(_ batch: [ImportedCodexPaste.Parsed]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))
                Text(tr("Found \(batch.count) accounts", "找到 \(batch.count) 个账号"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(batch.enumerated()), id: \.element.id) { idx, p in
                    HStack(spacing: 8) {
                        if let email = p.email {
                            Text(PrivacyDisplay.isEnabled ? PrivacyDisplay.account(p.id) : email)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                        }
                        if let plan = p.planType {
                            Text(plan.capitalized)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        PrivacySensitiveText(text: p.chatgptAccountId, kind: .identifier)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)

                    if idx < batch.count - 1 {
                        Divider().padding(.leading, 10)
                    }
                }
            }
            .background(.green.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: 表单

    private var formSection: some View {
        // 显示开关(单账号 / 批量通用,默认开启)
        Toggle(isOn: $visibleInPopover) {
            Text(tr("Show in popover", "在弹出面板中显示"))
                .font(.system(size: 12.5))
        }
        .toggleStyle(.switch)
        .tint(.green)
    }

    // MARK: 操作

    private func reParse() {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parseResult = nil
            patToken = nil
            saveError = nil
            return
        }
        // 先认 personal access token 形态；命中则走 PAT 路径，不再按 OAuth 解析。
        if let pat = ImportedCodexPaste.personalAccessToken(in: trimmed) {
            patToken = pat
            parseResult = nil
            saveError = nil
            return
        }
        patToken = nil
        parseResult = ImportedCodexPaste.parseAny(trimmed)
        saveError = nil
    }

    private func save() {
        if let pat = patToken {
            savePersonalAccessToken(pat)
            return
        }
        guard let batch = parsedBatch, !batch.isEmpty else { return }
        isSaving = true
        var firstError: String?
        // 别名一律留空,显示名由 email @ 前部分自动派生;
        // visibleInPopover 单账号 / 批量都遵循当前开关。
        for p in batch {
            do {
                try appState.upsertImportedCodexAccount(
                    from: p,
                    alias: "",
                    visibleInPopover: visibleInPopover
                )
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        isSaving = false
        if let err = firstError {
            saveError = err
        } else {
            onSuccess()
            dismiss()
        }
    }

    /// PAT 不透明、本地拿不到 account_id，保存时联网发一次 usage 验证并解析身份。
    private func savePersonalAccessToken(_ token: String) {
        isSaving = true
        saveError = nil
        Task {
            do {
                try await appState.importCodexPersonalAccessToken(
                    token: token,
                    visibleInPopover: visibleInPopover
                )
                isSaving = false
                onSuccess()
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
