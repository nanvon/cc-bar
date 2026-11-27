import SwiftUI

// MARK: - Services Section View

struct SettingsServicesView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore
    let highlightedSection: String?
    let onOpenDisplaySettings: () -> Void
    let onShowCodexResetCredits: () -> Void
    let onShowCommandCodeSheet: () -> Void
    let onShowOpenCodeGoSheet: () -> Void

    @State private var showUndetected = true

    var body: some View {
        let entries = serviceEntries(settings: settings)
        let inUse = entries.filter(\.isDetected)
        let others = entries.filter { !$0.isDetected }
        let enabledCount = inUse.filter { $0.isEnabled.wrappedValue }.count

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .services) {
                Text(tr("\(enabledCount) of \(inUse.count) active", "已启用 \(enabledCount) / \(inUse.count)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // 已检测 Agent 分组
            ServiceListCard(
                title: tr("Detected on this Mac", "正在使用"),
                subtitle: tr("Drag rows to reorder Menu Bar and Popover display", "拖动行可调整菜单栏与弹出面板顺序"),
                count: inUse.count,
                isHighlighted: highlightedSection == "services-detected",
                showColumnHeader: !inUse.isEmpty
            ) {
                if inUse.isEmpty {
                    emptyDetectedState
                } else {
                    serviceRows(inUse, floatingHUDGloballyEnabled: settings.floatingEnabled)
                }
            }
            .id("services-detected")

            // 未检测服务分组（可折叠）
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showUndetected.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showUndetected ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10)
                                Text(tr("Not Detected", "未检测到"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .kerning(-0.1)
                                Text("\(others.count)")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                Text("· \(tr("Moves up automatically after sign-in or usage", "登录或使用后自动移至上方"))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointingHandCursor()

                        Spacer()
                    }
                    .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
                    .padding(.bottom, showUndetected ? 8 : 0)

                    if showUndetected {
                        VStack(spacing: 0) {
                            serviceRows(others, floatingHUDGloballyEnabled: settings.floatingEnabled)
                        }
                        .ccPanel(cornerRadius: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var emptyDetectedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(tr("No agents detected on this Mac yet", "暂未在这台 Mac 上检测到 Agent"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(tr("Sign in to Codex, Claude Code, Cursor or Antigravity, or start a session in Pi / OpenCode / DSH.",
                    "登录 Codex、Claude Code、Cursor 或 Antigravity，或在 Pi / OpenCode / DSH 中开始对话后会自动显示。"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    // MARK: - Rows & Reorder

    @ViewBuilder
    private func serviceRows(_ entries: [ServiceEntry], floatingHUDGloballyEnabled: Bool) -> some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ReorderableStack(
            ids: entries.map(\.id),
            movableCount: entries.count,
            dividerLeading: ServiceRowMetrics.textLeading,
            onMove: commitServiceMove
        ) { id, reorder in
            if let entry = byID[id] {
                serviceBlock(entry, reorder: reorder, floatingHUDGloballyEnabled: floatingHUDGloballyEnabled)
            }
        }
    }

    private func orderItem(of id: ServiceEntry.ID) -> ServiceOrderItem {
        switch id {
        case .quota(let app): return .quota(app)
        case .usage(let app): return .usage(app)
        }
    }

    private func commitServiceMove(_ moved: ServiceEntry.ID, _ newOrder: [ServiceEntry.ID]) {
        let items = newOrder.map(orderItem(of:))
        let source = orderItem(of: moved)
        guard let index = items.firstIndex(of: source) else { return }
        if index + 1 < items.count {
            SettingsStore.shared.moveService(source, before: items[index + 1])
        } else if index > 0 {
            SettingsStore.shared.moveService(source, after: items[index - 1])
        }
    }

    @ViewBuilder
    private func serviceBlock(
        _ entry: ServiceEntry,
        reorder: ReorderRowState,
        floatingHUDGloballyEnabled: Bool
    ) -> some View {
        VStack(spacing: 0) {
            ServiceRowView(
                entry: entry,
                floatingHUDGloballyEnabled: floatingHUDGloballyEnabled,
                isReorderLifted: reorder.isLifted,
                onOpenDisplaySettings: onOpenDisplaySettings
            )
            .reorderDragSource(reorder)

            if entry.id == .quota(.codex) {
                ImportedCodexAccountsView()
            }
        }
    }

    // MARK: - Bindings

    private func serviceEnabledBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderEnabled(app) },
            set: { newValue in
                settings.setServiceEnabled(newValue, for: app)
                if let usageApp = app.usageApp, usageApp != .cursor {
                    Task { await appState.usageService.localUsageSettingsDidChange(app: usageApp, enabled: newValue) }
                }
                guard newValue, [QuotaApp.antigravity, .cursor, .commandCode, .opencodeGo].contains(app) else { return }
                Task { await appState.refreshQuotas(reason: .userInitiated) }
            }
        )
    }

    private func menuBarBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderShownInMenuBar(app) },
            set: { settings.setProviderShownInMenuBar($0, for: app) }
        )
    }

    private func floatingBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderShownInFloatingHUD(app) },
            set: { newValue in
                settings.setProviderShownInFloatingHUD(newValue, for: app)
                FloatingPanelController.shared.sync()
            }
        )
    }

    private func usageStatsBinding(for usageApp: UsageApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isUsageServiceVisible(usageApp) },
            set: { enabled in
                settings.setUsageServiceVisible(enabled, for: usageApp)
                Task { await appState.usageService.localUsageSettingsDidChange(app: usageApp, enabled: enabled) }
            }
        )
    }

    // MARK: - Service Entry Construction

    private func accountInfo(for app: QuotaApp) -> (email: String?, plan: String?, signedIn: Bool) {
        switch app {
        case .codex:
            return (appState.codexAccount?.email, appState.codexPlanName, appState.codexAccount != nil)
        case .claude:
            return (appState.claudeDisplayEmail, appState.claudePlanName, appState.claudeAccount != nil)
        case .antigravity:
            return (
                appState.antigravityAccount?.email,
                (appState.antigravityAccount?.planType ?? appState.antigravityQuota?.planType)?.capitalized,
                appState.antigravityAccount != nil
            )
        case .cursor:
            return (appState.cursorAccount?.email, appState.cursorQuota?.planType, appState.cursorAccount != nil)
        case .commandCode:
            return (appState.commandCodeAccount?.email, nil, appState.commandCodeAccount != nil)
        case .opencodeGo:
            return (nil, nil, appState.opencodeGoAccount != nil)
        }
    }

    private func localRecordState(for app: UsageApp) -> LocalRecordState {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        func exists(_ path: String) -> Bool {
            fileManager.fileExists(atPath: home.appendingPathComponent(path).path)
        }
        func directoryExists(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: home.appendingPathComponent(path).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        let hasRecords: Bool
        let installed: Bool
        switch app {
        case .codex:
            hasRecords = exists(".codex/sessions") || exists(".codex/archived_sessions")
            installed = exists(".codex")
        case .claude:
            hasRecords = exists(".claude/projects")
            installed = exists(".claude")
        case .pi:
            hasRecords = exists(".pi/agent/sessions")
            installed = exists(".pi")
        case .opencode:
            hasRecords = exists(".local/share/opencode/opencode.db")
            installed = exists(".config/opencode") || exists(".local/share/opencode")
        case .dsh:
            hasRecords = directoryExists(".dsh/sessions") || directoryExists(".ds-bot/sessions")
            installed = exists(".dsh") || exists(".ds-bot")
        case .antigravity:
            let roots = [".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide"]
            hasRecords = roots.contains { directoryExists("\($0)/conversations") }
            installed = roots.contains { exists($0) }
        case .cursor:
            return .missing
        }
        if hasRecords { return .found }
        return installed ? .installedOnly : .missing
    }

    private func serviceEntries(settings: SettingsStore) -> [ServiceEntry] {
        let providers = Dictionary(uniqueKeysWithValues: settings.orderedProviders.map { ($0.app, $0) })
        return settings.orderedServices.compactMap { item -> ServiceEntry? in
            switch item {
            case .quota(let app): return providers[app].map { quotaServiceEntry($0, settings: settings) }
            case .usage(let app): return localUsageServiceEntry(app, settings: settings)
            }
        }
    }

    private func quotaServiceEntry(_ provider: QuotaProviderDescriptor, settings: SettingsStore) -> ServiceEntry {
        let app = provider.app
        let info = accountInfo(for: app)
        let email = PrivacyDisplay.isEnabled ? nil : info.email
        let plan = info.plan.flatMap { $0.isEmpty ? nil : $0 }

        var sourceLines = [quotaSourceHelp(for: app)]
        let claudeDesktopDenied = app == .claude && appState.claudeDesktopAccessDenied
        let authorizeClaudeDesktop = ServiceAction(title: tr("Authorize…", "授权…")) {
            appState.authorizeClaudeDesktopAccess()
        }
        let cursorKeychainRequired = app == .cursor && appState.cursorKeychainAccessRequired
        var isDetected: Bool
        switch app {
        case .codex, .claude:
            let records = localRecordState(for: app == .codex ? .codex : .claude)
            sourceLines.append(app == .codex
                ? tr("Usage: reads conversation records in ~/.codex/sessions and calculates tokens and cost on this Mac.",
                     "用量：读取 ~/.codex/sessions 中的对话记录，在本机计算 Token 和费用。")
                : tr("Usage: reads conversation records in ~/.claude/projects and calculates tokens and cost on this Mac.",
                     "用量：读取 ~/.claude/projects 中的对话记录，在本机计算 Token 和费用。"))
            isDetected = info.signedIn
                || records != .missing
                || (app == .codex && !appState.importedCodexAccounts.isEmpty)
        case .cursor:
            sourceLines.append(tr("Usage: fetches usage records from your Cursor account online.",
                                  "用量：联网读取 Cursor 账号的用量记录。"))
            isDetected = info.signedIn || cursorKeychainRequired
        case .antigravity:
            sourceLines.append(tr(
                "Usage: reads conversation records of the Antigravity app, IDE and CLI in ~/.gemini and calculates tokens and cost on this Mac. Model names in the app's records are partly inferred, so costs are estimates. Quota estimates and popover spend also read the Magpie agy plugin's conversation records in ~/.local/state/magpie-agy-bridge.",
                "用量：读取 ~/.gemini 中 Antigravity App、IDE 和 CLI 的对话记录，在本机计算 Token 和费用。App 记录里的模型名部分靠推断，费用为估算。额度预估和弹出面板花费还读取 ~/.local/state/magpie-agy-bridge 中 Magpie agy 插件的对话记录。"
            ))
            isDetected = info.signedIn || localRecordState(for: .antigravity) != .missing
        case .commandCode:
            sourceLines.append(tr("\(provider.title) does not provide usage data.", "\(provider.title) 不提供用量数据。"))
            isDetected = info.signedIn
        case .opencodeGo:
            sourceLines.append(tr(
                "Usage: conversations that use OpenCode Go models are counted under OpenCode or Pi.",
                "用量：使用 OpenCode Go 模型的对话计入 OpenCode 或 Pi 的统计。"
            ))
            isDetected = info.signedIn
        }
        if let offHint = offHint(for: app), !settings.isProviderEnabled(app) {
            sourceLines.append(offHint)
        }
        if claudeDesktopDenied {
            isDetected = true
            if info.signedIn {
                sourceLines.append(tr(
                    "Not allowed to read Claude Desktop's sign-in. When the Claude Code sign-in expires, quota can't fall back to Claude Desktop.",
                    "未授权读取 Claude 桌面版登录：Claude Code 登录过期后，无法改用桌面版的登录状态查询额度。"
                ))
            }
        }

        let badge: String?
        let subtitle: String
        if claudeDesktopDenied, !info.signedIn {
            badge = nil
            subtitle = tr("Not allowed to read Claude Desktop's sign-in", "未授权读取 Claude 桌面版登录")
        } else if cursorKeychainRequired {
            badge = nil
            subtitle = tr("Not allowed to read Cursor's sign-in", "未授权读取 Cursor 登录")
        } else if !isDetected {
            badge = nil
            subtitle = connectHint(for: app)
        } else if !info.signedIn {
            badge = tr("Usage only", "仅用量")
            subtitle = tr("Not signed in · local records only", "未登录 · 仅统计本机用量")
        } else {
            badge = plan
            if let email {
                subtitle = email
            } else {
                subtitle = tr("Signed in", "已登录")
            }
        }

        let error = settings.isProviderEnabled(app) && info.signedIn ? appState.quotaError(for: app) : nil

        var actions: [ServiceAction] = []
        if app == .codex, info.signedIn {
            actions.append(ServiceAction(title: tr("Reset Credits…", "额度重置次数…"), action: onShowCodexResetCredits))
        }
        if app == .commandCode {
            actions.append(ServiceAction(title: tr("Enter Credentials…", "填写凭据…"), action: onShowCommandCodeSheet))
        }
        if app == .opencodeGo {
            actions.append(ServiceAction(title: tr("Enter Credentials…", "填写凭据…"), action: onShowOpenCodeGoSheet))
        }
        if claudeDesktopDenied, info.signedIn {
            actions.append(authorizeClaudeDesktop)
        }

        let connectAction: ServiceAction?
        if claudeDesktopDenied {
            connectAction = authorizeClaudeDesktop
        } else if cursorKeychainRequired {
            connectAction = ServiceAction(title: tr("Authorize…", "授权…")) {
                appState.authorizeCursorAccess()
            }
        } else if !isDetected, app == .commandCode {
            connectAction = ServiceAction(title: tr("Enter Credentials…", "填写凭据…"), action: onShowCommandCodeSheet)
        } else if !isDetected, app == .opencodeGo {
            connectAction = ServiceAction(title: tr("Enter Credentials…", "填写凭据…"), action: onShowOpenCodeGoSheet)
        } else {
            connectAction = nil
        }

        return ServiceEntry(
            id: .quota(app),
            logoName: provider.logoName,
            fallback: provider.fallback,
            tint: app.tintColor,
            title: provider.title,
            badge: badge,
            subtitle: subtitle,
            errorDetail: error,
            isDetected: isDetected,
            connectAction: connectAction,
            sourceLines: sourceLines,
            actions: actions,
            isEnabled: serviceEnabledBinding(for: app, settings: settings),
            showInMenuBar: provider.supportsMenuBar ? menuBarBinding(for: app, settings: settings) : nil,
            showInFloatingHUD: provider.supportsFloatingHUD ? floatingBinding(for: app, settings: settings) : nil
        )
    }

    private func localUsageServiceEntry(_ app: UsageApp, settings: SettingsStore) -> ServiceEntry {
        let records = localRecordState(for: app)
        let (logoName, fallback, title, source, connectHint): (String, String, String, String, String) = switch app {
        case .pi:
            (
                "pi", "P", "Pi",
                tr("Usage: reads conversation records in ~/.pi/agent/sessions and calculates tokens and cost on this Mac. Pi has no subscription quota.",
                   "用量：读取 ~/.pi/agent/sessions 中的对话记录，在本机计算 Token 和费用。Pi 没有订阅额度。"),
                tr("Start a conversation in Pi to detect it", "用 Pi 产生对话后自动识别")
            )
        case .opencode:
            (
                "opencode", "O", "OpenCode",
                tr("Usage: reads conversation records in ~/.local/share/opencode and calculates tokens and cost on this Mac. OpenCode has no subscription quota.",
                   "用量：读取 ~/.local/share/opencode 中的对话记录，在本机计算 Token 和费用。OpenCode 没有订阅额度。"),
                tr("Start a conversation in OpenCode to detect it", "用 OpenCode 产生对话后自动识别")
            )
        default:
            (
                "dsh", "D", "DSH",
                tr("Usage: reads conversation records in ~/.dsh/sessions and ~/.ds-bot/sessions (DS Bot model Bots) and calculates tokens and cost on this Mac. Only the default locations are checked. DSH has no subscription quota.",
                   "用量：读取 ~/.dsh/sessions 与 ~/.ds-bot/sessions（DS Bot 模型类 Bot）中的对话记录，在本机计算 Token 和费用。只查找这两个默认位置。DSH 没有订阅额度。"),
                tr("Start a conversation in DSH or DS Bot to detect it (only default locations are checked)", "用 DSH 或 DS Bot 产生对话后自动识别，只查找默认位置")
            )
        }

        let subtitle: String = switch records {
        case .found:
            tr("Local records found", "已找到本机记录")
        case .installedOnly where app == .dsh:
            tr("No conversations in the default location", "默认位置没有对话记录")
        case .installedOnly:
            tr("No local records yet", "暂无本机记录")
        case .missing:
            connectHint
        }

        return ServiceEntry(
            id: .usage(app),
            logoName: logoName,
            fallback: fallback,
            tint: app.tintColor,
            title: title,
            badge: records != .missing ? tr("Usage only", "仅用量") : nil,
            subtitle: subtitle,
            errorDetail: nil,
            isDetected: records != .missing,
            connectAction: nil,
            sourceLines: [source],
            actions: [],
            isEnabled: usageStatsBinding(for: app, settings: settings),
            showInMenuBar: nil,
            showInFloatingHUD: nil
        )
    }

    private func quotaSourceHelp(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Quota: reads the sign-in in ~/.codex/auth.json and asks OpenAI for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 ~/.codex/auth.json 的登录状态，向 OpenAI 查询剩余额度。只读取，不改动登录。")
        case .claude:
            tr("Quota: reads the sign-in from Claude Code CLI or Claude Desktop and asks Anthropic for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 Claude Code CLI 或 Claude 桌面版的登录状态，向 Anthropic 查询剩余额度。只读取，不改动登录。")
        case .antigravity:
            tr("Quota: reuses your Antigravity app sign-in to query Google. No agy required. Renewed tokens are saved in CCBar’s own Keychain; the app’s sign-in is read-only. Legacy sign-in files remain supported.",
               "额度：复用 Antigravity 桌面端登录向 Google 查询，无需 agy。续期令牌存 CCBar 自己的钥匙串，不改动桌面端登录；兼容旧凭据文件。")
        case .cursor:
            tr("Quota: reads the sign-in from the Cursor app (decrypted with the Cursor Safe Storage key in Keychain when Cursor encrypts it) and asks Cursor for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 Cursor 应用的登录状态（Cursor 加密保存时，用钥匙串里的 Cursor Safe Storage 密钥解密），向 Cursor 查询剩余额度。只读取，不改动登录。")
        case .commandCode:
            tr("Quota: reads Command Code's local credentials or the ones you entered (stored in Keychain), and asks Command Code for remaining quota.",
               "额度：读取 Command Code 的本机凭据或手动填写的凭据（保存在钥匙串），向 Command Code 查询剩余额度。")
        case .opencodeGo:
            tr("Quota: reads the OpenCode Go API key from OpenCode, Pi, the OPENCODE_API_KEY environment variable, or the one you entered (stored in Keychain), and asks OpenCode for remaining quota.",
               "额度：读取 OpenCode、Pi 中的 OpenCode Go API Key、环境变量 OPENCODE_API_KEY 或手动填写的 Key（保存在钥匙串），向 OpenCode 查询剩余额度。")
        }
    }

    private func connectHint(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Sign in with the Codex CLI to detect it", "用 Codex CLI 登录后自动识别")
        case .claude:
            tr("Sign in to Claude Code CLI or Claude Desktop to detect it", "登录 Claude Code CLI 或 Claude 桌面版后自动识别")
        case .antigravity:
            tr("Sign in to the Antigravity app to detect it", "登录 Antigravity 桌面端后自动识别")
        case .cursor:
            tr("Sign in to the Cursor app to detect it", "登录 Cursor 应用后自动识别")
        case .commandCode:
            tr("Sign in with the Command Code CLI to detect it, or", "登录 Command Code CLI 后自动识别，或")
        case .opencodeGo:
            tr("Connect OpenCode Go in OpenCode or Pi to detect it, or", "在 OpenCode 或 Pi 中连接 OpenCode Go 后自动识别，或")
        }
    }

    private func offHint(for app: QuotaApp) -> String? {
        switch app {
        case .cursor:
            tr("Turning on reads Cursor's sign-in to fetch quota and usage online.",
               "开启后会读取 Cursor 的登录状态，联网查询额度和用量。")
        case .commandCode:
            tr("Turning on fetches Command Code quota online.", "开启后会联网查询 Command Code 额度。")
        case .opencodeGo:
            tr("Turning on fetches OpenCode Go quota online.", "开启后会联网查询 OpenCode Go 额度。")
        default:
            nil
        }
    }
}

// MARK: - Service List Card

private struct ServiceListCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let count: Int
    var isHighlighted: Bool = false
    var showColumnHeader: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .kerning(-0.1)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    if let subtitle {
                        Text("· \(subtitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if showColumnHeader {
                    Text(tr("Display in", "展示位置"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: ServiceRowMetrics.destination * 2, alignment: .center)
                    Color.clear.frame(width: ServiceRowMetrics.info, height: 1)
                    Text(tr("Active", "启用"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: ServiceRowMetrics.toggle, alignment: .center)
                }
            }
            .padding(.leading, SettingsLayout.cardHorizontalPadding)
            .padding(.trailing, ServiceRowMetrics.trailingPadding)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? Color.accentColor.opacity(0.65) : Color.clear,
                        lineWidth: 1.5
                    )
                    .animation(.easeInOut(duration: 0.25), value: isHighlighted)
            )
        }
    }
}

// MARK: - Service Entry Models

private struct ServiceEntry: Identifiable {
    enum ID: Hashable {
        case quota(QuotaApp)
        case usage(UsageApp)
    }

    let id: ID
    let logoName: String
    let fallback: String
    let tint: Color
    let title: String
    let badge: String?
    let subtitle: String
    let errorDetail: String?
    let isDetected: Bool
    let connectAction: ServiceAction?
    let sourceLines: [String]
    let actions: [ServiceAction]
    let isEnabled: Binding<Bool>
    let showInMenuBar: Binding<Bool>?
    let showInFloatingHUD: Binding<Bool>?
}

private struct ServiceAction {
    let title: String
    let action: () -> Void
}

private enum LocalRecordState: Equatable {
    case found
    case installedOnly
    case missing
}

// MARK: - Service Row View

private struct ServiceRowView: View {
    let entry: ServiceEntry
    let floatingHUDGloballyEnabled: Bool
    var isReorderLifted = false
    let onOpenDisplaySettings: () -> Void

    @State private var showInfoPopover = false

    private var isEnabled: Bool { entry.isEnabled.wrappedValue }

    var body: some View {
        HStack(spacing: 0) {
            ReorderGrip(isLifted: isReorderLifted)
                .frame(width: ServiceRowMetrics.handleWidth)
                .padding(.trailing, ServiceRowMetrics.handleGap)

            ServiceTile(
                logoName: entry.logoName,
                fallback: entry.fallback,
                tint: entry.tint,
                size: ServiceRowMetrics.tileSize,
                logoSize: 19,
                cornerRadius: 8.5
            )
            .opacity(entry.isDetected ? (isEnabled ? 1 : 0.6) : 0.42)
            .padding(.trailing, ServiceRowMetrics.tileGap)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(entry.isDetected ? Color.primary : Color.secondary)
                        .lineLimit(1)

                    if let badge = entry.badge {
                        Text(badge)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }

                    if let errorDetail = entry.errorDetail {
                        Button {
                            showInfoPopover = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9.5))
                                Text(tr("Failed", "刷新失败"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(SettingsSemanticTone.warning.foreground)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointingHandCursor()
                        .help(errorDetail)
                    }
                }

                HStack(alignment: .center, spacing: 6) {
                    Text(entry.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.subtitle)

                    if let connectAction = entry.connectAction {
                        Button(connectAction.title, action: connectAction.action)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .focusEffectDisabled()
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // 菜单栏与悬浮窗展示位按钮（等宽对齐列头）
            HStack(spacing: ServiceRowMetrics.destinationItemGap) {
                destinationToggle(
                    binding: entry.showInMenuBar,
                    label: tr("Menu Bar", "菜单栏"),
                    accessibilityName: tr("Menu Bar", "菜单栏"),
                    unavailable: false,
                    unavailableMessage: nil
                )
                destinationToggle(
                    binding: entry.showInFloatingHUD,
                    label: tr("HUD", "悬浮窗"),
                    accessibilityName: tr("Floating HUD", "悬浮窗"),
                    unavailable: !floatingHUDGloballyEnabled,
                    unavailableMessage: floatingDisabledHelp
                )
            }
            .frame(width: ServiceRowMetrics.destination * 2, alignment: .center)
            .opacity(isEnabled ? 1 : 0.38)

            ServiceInfoButton(entry: entry, isPresented: $showInfoPopover)
                .frame(width: ServiceRowMetrics.info, alignment: .center)

            Toggle(entry.title, isOn: entry.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .fixedSize()
                .help(tr(
                    "Turning off stops updates and hides this agent's data. Saved usage is kept.",
                    "关闭后停止更新并隐藏该 Agent 的数据，已保存的用量会保留"
                ))
                .frame(width: ServiceRowMetrics.toggle, alignment: .center)
        }
        .padding(.leading, ServiceRowMetrics.leadingPadding)
        .padding(.trailing, ServiceRowMetrics.trailingPadding)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
    }

    private var floatingDisabledHelp: String? {
        guard isEnabled, !floatingHUDGloballyEnabled else { return nil }
        return tr("Floating HUD is currently turned off in Display & Privacy.", "桌面悬浮窗当前处于关闭状态，需先在「显示与隐私」中开启。")
    }

    @ViewBuilder
    private func destinationToggle(
        binding: Binding<Bool>?,
        label: String,
        accessibilityName: String,
        unavailable: Bool,
        unavailableMessage: String?
    ) -> some View {
        if let binding {
            DestinationChipToggle(
                label: label,
                accessibilityTitle: "\(entry.title) \(accessibilityName)",
                isOn: binding,
                disabled: !isEnabled || unavailable,
                unavailableMessage: unavailableMessage,
                onOpenDisplaySettings: unavailable && isEnabled ? onOpenDisplaySettings : nil
            )
        } else {
            Color.clear
                .frame(width: ServiceRowMetrics.destinationItemWidth, height: 22)
        }
    }
}

// MARK: - Destination Chip Toggle

private struct DestinationChipToggle: View {
    let label: String
    let accessibilityTitle: String
    @Binding var isOn: Bool
    var disabled: Bool
    var unavailableMessage: String?
    var onOpenDisplaySettings: (() -> Void)?

    @State private var showHintPopover = false

    var body: some View {
        let active = isOn && !disabled
        let fontWeight: Font.Weight = active ? .medium : .regular
        let foreground: Color = active ? .accentColor : .secondary.opacity(disabled ? 0.5 : 0.85)
        let fill: Color = active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)
        let border: Color = active ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.08)

        let btn = Button {
            if disabled {
                if unavailableMessage != nil {
                    showHintPopover = true
                }
            } else {
                isOn.toggle()
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: fontWeight))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .frame(width: ServiceRowMetrics.destinationItemWidth, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(border, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(isOn ? tr("On", "已开启") : tr("Off", "已关闭"))
        .help(disabled ? (unavailableMessage ?? "") : accessibilityTitle)
        .popover(isPresented: $showHintPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if let unavailableMessage {
                    Text(unavailableMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onOpenDisplaySettings {
                    Button(tr("Go to Display & Privacy →", "前往「显示与隐私」开启 →")) {
                        showHintPopover = false
                        onOpenDisplaySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 240, alignment: .leading)
        }

        if disabled && unavailableMessage == nil {
            btn
        } else {
            btn.pointingHandCursor()
        }
    }
}

// MARK: - Service Info Button

private struct ServiceInfoButton: View {
    let entry: ServiceEntry
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: entry.errorDetail == nil ? "info.circle" : "exclamationmark.circle.fill")
                .font(.system(size: 13.5))
                .foregroundStyle(entry.errorDetail == nil ? Color.secondary : SettingsSemanticTone.warning.foreground)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .help(tr("Data sources & actions", "数据来源与操作"))
        .accessibilityLabel(tr("\(entry.title) data sources", "\(entry.title) 数据来源"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ServiceTile(
                        logoName: entry.logoName,
                        fallback: entry.fallback,
                        tint: entry.tint,
                        size: 22,
                        logoSize: 13,
                        cornerRadius: 6
                    )
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                }

                ForEach(entry.sourceLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorDetail = entry.errorDetail {
                    SettingsCallout(
                        tone: .warning,
                        icon: "exclamationmark.triangle.fill",
                        title: tr("Last refresh failed", "最近一次刷新失败"),
                        message: errorDetail
                    )
                }

                if !entry.actions.isEmpty {
                    Divider()
                    HStack(spacing: 8) {
                        ForEach(entry.actions, id: \.title) { item in
                            Button(item.title) {
                                isPresented = false
                                item.action()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }
}
