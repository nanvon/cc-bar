import SwiftUI

// MARK: - SettingsRootView
//
// 见 docs/04-界面布局.md §4。
// 使用 prototype 的 PrefsGroup + PrefsRow 卡片结构,放弃 Form .grouped。

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginMessageIsError = false
    @State private var isRecalculatingUsage = false

    /// 主账号额外重置 credit 的展开状态与懒加载结果(nil = 尚未加载)。
    @State private var codexResetCreditsExpanded = false
    @State private var codexResetCreditsState: CodexResetCreditsState?

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountsGroup(settings: settings)
                menuBarGroup(settings: settings)
                floatingGroup(settings: settings)
                refreshGroup(settings: settings)
                generalGroup(settings: settings)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            settings.syncLaunchAtLoginStatus()
            if settings.launchAtLoginRequiresApproval {
                launchAtLoginMessage = launchAtLoginApprovalMessage
                launchAtLoginMessageIsError = false
            } else {
                launchAtLoginMessage = nil
            }
        }
    }

    // MARK: Accounts

    private func accountsGroup(settings: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // 主账号（自动检测）
            PrefsGroup(
                title: "Accounts",
                chinese: "账号",
                desc: "Auto-detected on your Mac. Toggle which services to display.",
                chineseDesc: "自动检测,自行勾选要显示的"
            ) {
                VStack(spacing: 0) {
                    AccountRow(
                        title: "Codex",
                        subtitle: "OpenAI",
                        tint: .codexAccent,
                        logoName: "codex",
                        fallback: "C",
                        email: appState.codexAccount?.email,
                        plan: appState.codexAccount?.planType,
                        availability: appState.codexAccount == nil ? .notDetected : .connected,
                        canToggle: appState.codexAccount != nil,
                        isOn: Binding(get: { settings.showCodex }, set: { settings.showCodex = $0 }),
                        accessory: appState.codexAccount != nil ? AnyView(codexResetCreditsButton) : nil
                    )
                    if codexResetCreditsExpanded, let state = codexResetCreditsState {
                        CodexResetCreditsDetailView(state: state)
                    }
                }
                AccountRow(
                    title: "Claude Code",
                    subtitle: "Anthropic",
                    tint: .claudeAccent,
                    logoName: "claude",
                    fallback: "K",
                    email: appState.claudeAccount?.email,
                    plan: appState.claudeAccount?.subscriptionType,
                    availability: appState.claudeAccount == nil ? .notDetected : .connected,
                    canToggle: appState.claudeAccount != nil,
                    isOn: Binding(get: { settings.showClaude }, set: { settings.showClaude = $0 })
                )
                AccountRow(
                    title: "Antigravity",
                    subtitle: "Google",
                    tint: .antigravityAccent,
                    logoName: "antigravity",
                    fallback: "A",
                    email: appState.antigravityAccount?.email,
                    plan: appState.antigravityAccount?.planType,
                    availability: antigravityAccountAvailability,
                    canToggle: true,
                    isOn: Binding(
                        get: { settings.showAntigravity },
                        set: { settings.showAntigravity = $0 }
                    )
                )
                AccountRow(
                    title: "Grok",
                    subtitle: "xAI",
                    tint: .grokAccent,
                    logoName: "grok",
                    fallback: "G",
                    email: appState.grokAccount?.email,
                    plan: appState.grokAccount?.planType,
                    availability: appState.grokAccount == nil ? .notDetected : .connected,
                    canToggle: appState.grokAccount != nil,
                    isOn: Binding(get: { settings.showGrok }, set: { settings.showGrok = $0 })
                )
            }

            // 其他 Codex 账号（手动导入）
            PrefsGroup(
                title: "Other Codex Accounts",
                chinese: "其他 Codex 账号",
                desc: "Paste auth.json to monitor additional Codex accounts (view only).",
                chineseDesc: "粘贴 auth.json 添加更多 Codex 账号额度，仅查看，不会切换 CLI 登录状态"
            ) {
                ImportedCodexAccountsView()
            }
        }
    }

    /// 主账号「额外重置次数」入口(🎁),点击展开懒加载明细。
    private var codexResetCreditsButton: some View {
        Button {
            toggleCodexResetCredits()
        } label: {
            Image(systemName: "gift")
                .font(.system(size: 12))
                .foregroundStyle(codexResetCreditsExpanded ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(tr("Extra reset credits", "额外重置次数"))
    }

    private func toggleCodexResetCredits() {
        if codexResetCreditsExpanded {
            codexResetCreditsExpanded = false
            return
        }
        codexResetCreditsExpanded = true
        // 已有成功缓存则直接复用,不重复联网;失败态允许重新展开时重试。
        switch codexResetCreditsState {
        case nil, .failure: break
        default: return
        }
        codexResetCreditsState = .loading
        Task {
            let result = await appState.fetchCodexResetCredits()
            switch result {
            case .success(let fetched): codexResetCreditsState = .success(fetched)
            case .failure(let err): codexResetCreditsState = .failure(err.description)
            }
        }
    }

    // MARK: Menu Bar

    private func menuBarGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Menu Bar",
            chinese: "菜单栏",
            desc: "What appears next to the icon.",
            chineseDesc: "图标旁显示什么"
        ) {
            ForEach(QuotaProviderDescriptor.primaryProviders) { provider in
                PrefsRow(
                    label: "Show \(provider.title)",
                    chinese: "显示 \(provider.title)"
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.isProviderShownInMenuBar(provider.app) },
                        set: { settings.setProviderShownInMenuBar($0, for: provider.app) }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }
            PrefsRow(
                label: "Quota period",
                chinese: "额度周期",
                desc: "Which window to display in the menu bar.",
                chineseDesc: "菜单栏显示哪个窗口"
            ) {
                Picker("", selection: Binding(get: { settings.menuBarWindow }, set: { settings.menuBarWindow = $0 })) {
                    Text(tr("Main", "主要")).tag(MenuBarWindowChoice.primary)
                    Text(tr("Weekly", "周额度")).tag(MenuBarWindowChoice.weekly)
                    Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    // MARK: Floating HUD

    private func floatingGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Floating HUD",
            chinese: "桌面悬浮窗",
            desc: "A small always-on-top window pinned to your desktop.",
            chineseDesc: "桌面常驻的小悬浮窗"
        ) {
            PrefsRow(label: "Show floating window", chinese: "显示悬浮窗") {
                Toggle("", isOn: Binding(
                    get: { settings.floatingEnabled },
                    set: { newValue in
                        settings.floatingEnabled = newValue
                        FloatingPanelController.shared.sync()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
            ForEach(QuotaProviderDescriptor.primaryProviders) { provider in
                PrefsRow(
                    label: "Show \(provider.title) row",
                    chinese: "显示 \(provider.title) 行"
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.isProviderShownInFloatingHUD(provider.app) },
                        set: { newValue in
                            settings.setProviderShownInFloatingHUD(newValue, for: provider.app)
                            FloatingPanelController.shared.sync()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.floatingEnabled)
                }
            }
        }
    }

    // MARK: Refresh

    private func refreshGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Refresh",
            chinese: "刷新",
            desc: "How often the app polls usage in the background.",
            chineseDesc: "后台轮询用量的频率"
        ) {
            PrefsRow(label: "Quota refresh", chinese: "额度刷新") {
                Picker("", selection: Binding(
                    get: { settings.quotaInterval },
                    set: { newValue in
                        settings.quotaInterval = newValue
                        appState.applySettingsChange()
                    }
                )) {
                    ForEach(QuotaIntervalChoice.allCases) { choice in
                        Text(choice.bilingualDisplayName).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(label: "Log scan", chinese: "日志扫描") {
                Picker("", selection: Binding(
                    get: { settings.usageInterval },
                    set: { newValue in
                        settings.usageInterval = newValue
                        appState.applySettingsChange()
                    }
                )) {
                    ForEach(UsageIntervalChoice.allCases) { choice in
                        Text(choice.bilingualDisplayName).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(
                label: "Reset time",
                chinese: "重置时间",
                desc: "How quota reset time is shown.",
                chineseDesc: "额度重置时间的显示方式"
            ) {
                Picker("", selection: Binding(
                    get: { settings.resetTimeDisplay },
                    set: { settings.resetTimeDisplay = $0 }
                )) {
                    Text(tr("Remaining", "剩余时长")).tag(ResetTimeDisplay.relative)
                    Text(tr("Exact time", "具体时间")).tag(ResetTimeDisplay.absolute)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(label: "Last refresh", chinese: "上次刷新") {
                HStack(spacing: 6) {
                    if appState.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Text(lastRefreshText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            PrefsRow(
                label: "Service status dot",
                chinese: "服务状态圆点",
                desc: "Show OpenAI / Anthropic status next to each service in the popover.",
                chineseDesc: "在弹出窗口为每个服务显示官方状态页圆点"
            ) {
                Toggle("", isOn: Binding(get: { settings.showServiceStatus }, set: { settings.showServiceStatus = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            PrefsRow(
                label: "Recalculate usage",
                chinese: "重新计算用量",
                desc: "Rescan local logs and recompute cost with the current pricing table.",
                chineseDesc: "重新扫描本地日志，按当前定价表重新计算费用"
            ) {
                Button {
                    isRecalculatingUsage = true
                    Task {
                        await appState.usageService.forceRescan()
                        isRecalculatingUsage = false
                    }
                } label: {
                    if isRecalculatingUsage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(tr("Recalculate", "重新计算"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRecalculatingUsage)
            }
        }
    }

    // MARK: General

    private func generalGroup(settings: SettingsStore) -> some View {
        PrefsGroup(title: "General", chinese: "通用") {
            PrefsRow(label: "Language", chinese: "语言") {
                Picker("", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.appLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(
                label: "Privacy mode",
                chinese: "隐私模式",
                desc: "Hide provider emails in the popover and names for other Codex accounts.",
                chineseDesc: "弹出窗口中隐藏 Provider 邮箱,并隐藏 Codex 副账号名称"
            ) {
                Toggle("", isOn: Binding(get: { settings.privacyMode }, set: { settings.privacyMode = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            PrefsRow(label: "Launch at login", chinese: "开机自动启动") {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        do {
                            try settings.setLaunchAtLogin(newValue)
                            if settings.launchAtLoginRequiresApproval {
                                launchAtLoginMessage = launchAtLoginApprovalMessage
                                launchAtLoginMessageIsError = false
                            } else {
                                launchAtLoginMessage = nil
                            }
                        } catch {
                            settings.syncLaunchAtLoginStatus()
                            launchAtLoginMessage = launchAtLoginErrorMessage(error)
                            launchAtLoginMessageIsError = true
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
            if let launchAtLoginMessage {
                PrefsRow(
                    label: launchAtLoginMessageIsError ? "Error" : "Status",
                    chinese: launchAtLoginMessageIsError ? "错误" : "状态"
                ) {
                    Text(launchAtLoginMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(launchAtLoginMessageIsError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(4)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            PrefsRow(label: "Version", chinese: "版本") {
                Text(appVersion)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var launchAtLoginApprovalMessage: String {
        tr(
            "Approve CCBar in System Settings > General > Login Items & Extensions.",
            "请在「系统设置 > 通用 > 登录项与扩展」中允许 CCBar。"
        )
    }

    private func launchAtLoginErrorMessage(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
        if description.localizedCaseInsensitiveContains("operation not permitted") {
            return tr(
                "macOS rejected this change. Export a signed CCBar.app, move it to /Applications, launch it there, then try again.",
                "macOS 拒绝了这次更改。请导出签名后的 CCBar.app，拖到 /Applications 后从那里启动，再重试。"
            )
        }
        return description
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(tr("CCBar \(shortVersion) · multi-service quota & local usage stats",
                    "CCBar \(shortVersion) · 多服务额度与本地用量统计"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Helpers

    private var lastRefreshText: String {
        let latest = QuotaApp.allCases.compactMap {
            appState.refreshState(for: $0).lastSuccessAt
        }.max()
        guard let latest else { return "—" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(timeFormatter.string(from: latest)) · \(PopoverRootView.relativeAge(from: latest)) \(tr("ago", "前"))"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var shortVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

private extension SettingsRootView {
    var antigravityAccountAvailability: AccountAvailability {
        switch appState.antigravityAvailability {
        case .running:
            return appState.antigravityAccount == nil ? .running : .connected
        case .installed: return .installed
        case .notInstalled: return .notDetected
        case .unavailable: return .unavailable
        }
    }
}

// MARK: - PrefsGroup

private struct PrefsGroup<Content: View>: View {
    let title: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title, chinese))
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(-0.05)
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - PrefsRow

private struct PrefsRow<Trailing: View>: View {
    let label: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(label, chinese))
                    .font(.system(size: 12.5))
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

// MARK: - AccountRow

private struct AccountRow: View {
    let title: String
    let subtitle: String
    let tint: Color
    let logoName: String
    let fallback: String
    let email: String?
    let plan: String?
    let availability: AccountAvailability
    let canToggle: Bool
    @Binding var isOn: Bool
    /// 可选的额外控件(如 Codex 主账号的重置次数入口),放在状态徽标与开关之间。
    var accessory: AnyView? = nil

    var body: some View {
        HStack(spacing: 11) {
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint, size: 28, logoSize: 16, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("· \(subtitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(detailText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                statusBadge

                if let accessory { accessory }

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!canToggle)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private var detailText: String {
        if let email {
            if let plan, !plan.isEmpty {
                return "\(email) · \(plan)"
            }
            return email
        }
        switch availability {
        case .connected: return plan ?? tr("Connected", "已连接")
        case .running: return tr("Running · waiting for quota", "运行中 · 等待额度")
        case .installed: return tr("Installed · not running", "已安装 · 未运行")
        case .unavailable: return tr("Local service unavailable", "本地服务不可用")
        case .notDetected: return tr("Not detected", "未检测到")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if availability == .connected {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(tr("Connected", "已连接"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(availability == .notDetected ? Color.orange : Color.secondary).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(availability == .notDetected ? Color.orange : Color.secondary)
            }
        }
    }

    private var statusText: String {
        switch availability {
        case .connected: tr("Connected", "已连接")
        case .running: tr("Running", "运行中")
        case .installed: tr("Not running", "未运行")
        case .unavailable: tr("Unavailable", "不可用")
        case .notDetected: tr("Not detected", "未检测到")
        }
    }
}

private enum AccountAvailability: Equatable {
    case connected
    case running
    case installed
    case unavailable
    case notDetected
}

// MARK: - Bilingual display names for existing enums

extension QuotaIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}

extension UsageIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}
