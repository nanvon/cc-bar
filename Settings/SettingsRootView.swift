import SwiftUI

// MARK: - SettingsCategory

enum SettingsCategory: String, CaseIterable, Identifiable {
    case services
    case appearance
    case data
    case general

    var id: String { rawValue }

    var englishTitle: String {
        switch self {
        case .services: return "Services & Accounts"
        case .appearance: return "Appearance & Display"
        case .data: return "Data & Refresh"
        case .general: return "General"
        }
    }

    var chineseTitle: String {
        switch self {
        case .services: return "服务与账号"
        case .appearance: return "外观与显示"
        case .data: return "数据与刷新"
        case .general: return "通用"
        }
    }

    var icon: String {
        switch self {
        case .services: return "server.rack"
        case .appearance: return "macwindow"
        case .data: return "arrow.triangle.2.circlepath"
        case .general: return "gearshape"
        }
    }
}

// MARK: - SettingsRootView

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedCategory: SettingsCategory = .services
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginMessageIsError = false
    @State private var isRecalculatingUsage = false
    @State private var pricingCatalogMessage: String?
    @State private var pricingCatalogMessageIsError = false
    @State private var showCodexResetCreditsSheet = false
    @State private var showCommandCodeSheet = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?
    @State private var diagnosticsMessageIsError = false
    @State private var showDiagnosticsConfirm = false

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        HStack(spacing: 0) {
            sidebar
            // 与侧栏材质一起延伸进标题栏，侧栏右边界从上到下是同一条线。
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            contentArea(settings: settings)
        }
        .sheet(isPresented: $showCommandCodeSheet) {
            CommandCodeCredentialSheet()
        }
        .confirmationDialog(
            tr("Export diagnostics?", "导出诊断日志？"),
            isPresented: $showDiagnosticsConfirm,
            titleVisibility: .visible
        ) {
            Button(tr("Export", "导出")) { exportDiagnostics() }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(diagnosticsDisclosure)
        }
        .sheet(isPresented: $showCodexResetCreditsSheet) {
            CodexResetCreditsSheet(
                accountTitle: appState.codexAccount?.email ?? "Codex",
                privacyAccountKey: "primary:codex",
                fetchCredits: { await appState.fetchCodexResetCredits() }
            )
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: "Preferences", chinese: "偏好设置") {
                ForEach(SettingsCategory.allCases) { category in
                    sidebarItem(category: category)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: MainWindowLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func sidebarGroup<Content: View>(
        title: String,
        chinese: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr(title, chinese).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            content()
        }
    }

    private func sidebarItem(category: SettingsCategory) -> some View {
        let active = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(active ? Color.white : Color.secondary)

                Text(tr(category.englishTitle, category.chineseTitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: - Content Area

    private func contentArea(settings: SettingsStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch selectedCategory {
                case .services:
                    servicesSection(settings: settings)
                case .appearance:
                    appearanceSection(settings: settings)
                case .data:
                    dataSection(settings: settings)
                case .general:
                    generalSection(settings: settings)
                }
            }
            // 内容栏居中、限宽，同系统设置；四个分类共用，切换时宽度不跳。
            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .id(selectedCategory)
    }

    // MARK: - Section 1: Services & Accounts

    /// 一层设置完：每个服务一行，右侧固定为 菜单栏 / 悬浮窗 / 数据来源 / 启用 四列。
    /// 检测到的服务在「正在使用」，其余在「未检测到」；其他 Codex 账号作为子行挂在 Codex 下面。
    @ViewBuilder
    private func servicesSection(settings: SettingsStore) -> some View {
        let entries = serviceEntries(settings: settings)
        let inUse = entries.filter(\.isDetected)
        let others = entries.filter { !$0.isDetected }

        ServiceGroup(title: tr("In Use", "正在使用"), desc: nil) {
            if inUse.isEmpty {
                Text(tr("No services found on this Mac yet", "暂未在这台 Mac 上检测到服务"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                serviceRows(inUse, floatingHUDGloballyEnabled: settings.floatingEnabled)
            }
        }

        if !others.isEmpty {
            ServiceGroup(
                title: tr("Not Detected", "未检测到"),
                desc: tr("Moves up once you sign in or use it", "登录或使用后会移到上方")
            ) {
                serviceRows(others, floatingHUDGloballyEnabled: settings.floatingEnabled)
            }
        }
    }

    @ViewBuilder
    private func serviceRows(_ entries: [ServiceEntry], floatingHUDGloballyEnabled: Bool) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 {
                InsetDivider(leading: ServiceRowMetrics.textLeading, trailing: 0)
            }
            ServiceRow(entry: entry, floatingHUDGloballyEnabled: floatingHUDGloballyEnabled)
            if entry.id == .quota(.codex) {
                ImportedCodexAccountsView()
            }
        }
    }

    // MARK: - Section 2: Appearance & Display

    @ViewBuilder
    private func appearanceSection(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Menu Bar",
            chinese: "菜单栏"
        ) {
            PrefsRow(
                label: "Quota period",
                chinese: "额度周期"
            ) {
                Picker("", selection: Binding(get: { settings.menuBarWindow }, set: { settings.menuBarWindow = $0 })) {
                    Text(tr("Main", "主额度")).tag(MenuBarWindowChoice.primary)
                    Text(tr("Weekly", "周额度")).tag(MenuBarWindowChoice.weekly)
                    Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }

        PrefsGroup(
            title: "Floating HUD",
            chinese: "桌面悬浮窗"
        ) {
            PrefsRow(
                label: "Show floating window",
                chinese: "显示悬浮窗",
                desc: "Choose services in Services & Accounts.",
                chineseDesc: "显示哪些服务在「服务与账号」中设置"
            ) {
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
        }

        PrefsGroup(
            title: "Display Details",
            chinese: "显示细节"
        ) {
            PrefsRow(
                label: "Reset time",
                chinese: "重置时间"
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
            InsetDivider()
            PrefsRow(
                label: "Service status dot",
                chinese: "服务状态圆点"
            ) {
                Toggle("", isOn: Binding(get: { settings.showServiceStatus }, set: { settings.showServiceStatus = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            InsetDivider()
            PrefsRow(
                label: "Privacy mode",
                chinese: "隐私模式",
                desc: "Hide account, project, and conversation names for screenshots. Usage numbers stay visible.",
                chineseDesc: "隐藏账号、项目和对话名称，用量数据照常显示，便于截图分享"
            ) {
                Toggle("", isOn: Binding(get: { settings.privacyMode }, set: { settings.privacyMode = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
        }

        PrefsGroup(
            title: "Statistics",
            chinese: "统计"
        ) {
            PrefsRow(
                label: "Ranking metric",
                chinese: "排行口径",
                desc: "Used for sorting and shares in Overview and Projects.",
                chineseDesc: "用于概览和项目页的排序与占比"
            ) {
                Picker("", selection: Binding(
                    get: { settings.statsRankMetric },
                    set: { settings.statsRankMetric = $0 }
                )) {
                    Text("Tokens").tag(StatsRankMetric.tokens)
                    Text(tr("Cost", "费用")).tag(StatsRankMetric.cost)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    // MARK: - Section 3: Data & Refresh

    @ViewBuilder
    private func dataSection(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Polling Intervals",
            chinese: "后台刷新"
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
            InsetDivider()
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
            InsetDivider()
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
        }

        PrefsGroup(
            title: "Data Maintenance",
            chinese: "数据维护"
        ) {
            PrefsRow(
                label: "Price catalog",
                chinese: "价格目录",
                desc: "Applies to new usage only. Use Recalculate to update past costs.",
                chineseDesc: "只影响新记录；历史费用需「重新计算」"
            ) {
                HStack(spacing: 8) {
                    if let pricingCatalogMessage {
                        Text(pricingCatalogMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(pricingCatalogMessageIsError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        pricingCatalogMessage = nil
                        Task {
                            let succeeded = await appState.usageService.refreshPricingCatalog()
                            pricingCatalogMessageIsError = !succeeded
                            pricingCatalogMessage = succeeded
                                ? tr("Updated", "已更新")
                                : tr("Update failed", "更新失败")
                        }
                    } label: {
                        if appState.usageService.isRefreshingPricingCatalog {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Update", "更新"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.usageService.isRefreshingPricingCatalog)
                }
            }
            InsetDivider()
            PrefsRow(
                label: "Recalculate usage",
                chinese: "重新计算用量",
                desc: "Recompute all past costs with current prices.",
                chineseDesc: "按当前价格重算全部历史费用",
                detail: recalculateOutcomeDetail
            ) {
                HStack(spacing: 8) {
                    if appState.usageService.cycleUsageNeedsManualRecalculation, !isRecalculatingUsage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(tr("Cycle usage incomplete", "周期用量不完整"))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help(tr(
                            "Some past cycles are missing usage data. Recalculate to fill it in.",
                            "部分历史周期缺少用量数据，点「重新计算」补齐"
                        ))
                    }
                    if let progress = appState.usageService.scanProgress, isRecalculatingUsage {
                        Text(scanProgressText(progress))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
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
    }

    // MARK: - Section 4: General

    @ViewBuilder
    private func generalSection(settings: SettingsStore) -> some View {
        PrefsGroup(title: "System", chinese: "系统") {
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
            InsetDivider()
            PrefsRow(label: "Launch at login", chinese: "开机自动启动", detail: launchAtLoginDetail) {
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
        }

        PrefsGroup(title: "Diagnostics", chinese: "诊断") {
            PrefsRow(
                label: "Export diagnostics",
                chinese: "导出诊断日志",
                desc: "A redacted zip for reporting issues.",
                chineseDesc: "生成脱敏的 zip，用于反馈问题"
            ) {
                HStack(spacing: 8) {
                    if let diagnosticsMessage {
                        Text(diagnosticsMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(diagnosticsMessageIsError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300, alignment: .trailing)
                    }
                    Button {
                        showDiagnosticsConfirm = true
                    } label: {
                        if isExportingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Export", "导出"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExportingDiagnostics)
                }
            }
            InsetDivider()
            PrefsRow(
                label: "Reveal log folder",
                chinese: "打开日志目录",
                desc: "~/Library/Logs/CCBar",
                chineseDesc: "~/Library/Logs/CCBar"
            ) {
                Button(tr("Open", "打开")) {
                    DiagnosticsBundle.revealLogDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            InsetDivider()
            PrefsRow(
                label: "Verbose logging",
                chinese: "详细日志",
                desc: "Turn on while troubleshooting, then turn it off.",
                chineseDesc: "排查问题时开启，用完建议关闭"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.verboseLogging },
                    set: { settings.verboseLogging = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }

        PrefsGroup(title: "Updates & About", chinese: "更新与关于") {
            PrefsRow(label: "Version", chinese: "版本") {
                Text(appVersion)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            InsetDivider()
            PrefsRow(
                label: "Check for updates",
                chinese: "检查更新"
            ) {
                HStack(spacing: 8) {
                    if let updateStatusText {
                        Text(updateStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(updateStatusIsError ? Color.red : (updateStatusHasNewVersion ? Color.accentColor : Color.secondary))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        if updateStatusHasNewVersion {
                            appState.openReleasePage()
                        } else {
                            Task { await appState.checkForUpdates() }
                        }
                    } label: {
                        if isUpdateCheckInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(updateButtonTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isUpdateCheckInProgress)
                }
            }
            InsetDivider()
            PrefsRow(label: "Check at launch", chinese: "启动时自动检查") {
                Toggle("", isOn: Binding(
                    get: { settings.autoCheckForUpdates },
                    set: { settings.autoCheckForUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }
    }

    // MARK: - Bindings & Actions Helpers

    /// 设置页「启用」开关：一个服务一个开关，同时管额度和用量（见 `SettingsStore.setServiceEnabled`）。
    private func serviceEnabledBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderEnabled(app) },
            set: { newValue in
                settings.setServiceEnabled(newValue, for: app)
                // Antigravity / Cursor / Command Code 开启后立即取一次额度，不等下一轮调度。
                guard newValue, [QuotaApp.antigravity, .cursor, .commandCode].contains(app) else { return }
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

    /// 仅有用量的服务（Pi / OpenCode / DSH）的「启用」开关，直接对应统计服务可见性。
    private func usageStatsBinding(for usageApp: UsageApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isUsageServiceVisible(usageApp) },
            set: { settings.setUsageServiceVisible($0, for: usageApp) }
        )
    }

    private func accountInfo(for app: QuotaApp) -> (email: String?, plan: String?, signedIn: Bool) {
        switch app {
        case .codex:
            return (
                email: appState.codexAccount?.email,
                plan: appState.codexAccount?.planType?.capitalized,
                signedIn: appState.codexAccount != nil
            )
        case .claude:
            return (
                email: appState.claudeAccount?.email,
                plan: appState.claudeAccount?.subscriptionType?.capitalized,
                signedIn: appState.claudeAccount != nil
            )
        case .antigravity:
            return (
                email: appState.antigravityAccount?.email,
                plan: (appState.antigravityAccount?.planType ?? appState.antigravityQuota?.planType)?.capitalized,
                signedIn: appState.antigravityAccount != nil
            )
        case .cursor:
            return (
                email: appState.cursorAccount?.email,
                plan: appState.cursorQuota?.planType,
                signedIn: appState.cursorAccount != nil
            )
        case .commandCode:
            return (
                email: appState.commandCodeAccount?.email ?? appState.commandCodeAccount?.login,
                plan: appState.commandCodeQuota?.planType ?? appState.commandCodeAccount?.planType,
                signedIn: appState.commandCodeAccount != nil
            )
        }
    }

    /// 本机记录探测：只看默认位置是否存在，不扫描内容。
    /// `installedOnly` 表示找到了工具的数据目录，但默认位置还没有对话记录。
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
            // 只探测默认根：不做 Desktop 自定义数据目录、显式 DSH_HOME、Beta home 的自动发现。
            // 没有默认日志不能据此断定用户未安装 DSH。
            hasRecords = directoryExists(".dsh/sessions")
            installed = exists(".dsh")
        case .cursor:
            // Cursor 没有本机记录，用量来自账号远端计量。
            return .missing
        }
        if hasRecords { return .found }
        return installed ? .installedOnly : .missing
    }

    /// 按固定顺序组装服务行：先 5 个额度服务（`allProviders` 顺序），再仅有用量的 Pi / OpenCode / DSH。
    private func serviceEntries(settings: SettingsStore) -> [ServiceEntry] {
        QuotaProviderDescriptor.allProviders.map { quotaServiceEntry($0, settings: settings) }
            + [UsageApp.pi, .opencode, .dsh].map { localUsageServiceEntry($0, settings: settings) }
    }

    private func quotaServiceEntry(_ provider: QuotaProviderDescriptor, settings: SettingsStore) -> ServiceEntry {
        let app = provider.app
        let info = accountInfo(for: app)
        let email = info.email.map {
            PrivacyDisplay.isEnabled ? PrivacyDisplay.account("primary:\(app.rawValue)") : $0
        }
        let plan = info.plan.flatMap { $0.isEmpty ? nil : $0 }

        var sourceLines = [quotaSourceHelp(for: app)]
        let isDetected: Bool
        switch app {
        case .codex, .claude:
            let records = localRecordState(for: app == .codex ? .codex : .claude)
            sourceLines.append(app == .codex
                ? tr("Usage: reads conversation records in ~/.codex/sessions and calculates tokens and cost on this Mac.",
                     "用量：读取 ~/.codex/sessions 中的对话记录，在本机计算 Token 和费用。")
                : tr("Usage: reads conversation records in ~/.claude/projects and calculates tokens and cost on this Mac.",
                     "用量：读取 ~/.claude/projects 中的对话记录，在本机计算 Token 和费用。"))
            // 只导入了其他 Codex 账号、本机没登录 Codex 时也算在用，让子账号留在上方。
            isDetected = info.signedIn
                || records != .missing
                || (app == .codex && !appState.importedCodexAccounts.isEmpty)
        case .cursor:
            sourceLines.append(tr("Usage: fetches usage records from your Cursor account online.",
                                  "用量：联网读取 Cursor 账号的用量记录。"))
            isDetected = info.signedIn
        case .antigravity, .commandCode:
            sourceLines.append(tr("\(provider.title) does not provide usage data.", "\(provider.title) 不提供用量数据。"))
            isDetected = info.signedIn
        }
        if let offHint = offHint(for: app), !settings.isProviderEnabled(app) {
            sourceLines.append(offHint)
        }

        let subtitle: String
        if !isDetected {
            subtitle = connectHint(for: app)
        } else if !info.signedIn {
            subtitle = tr("Not signed in · usage only", "未登录 · 只统计用量")
        } else {
            switch (email, plan) {
            case (let email?, let plan?): subtitle = "\(email) · \(plan)"
            case (let email?, nil): subtitle = email
            case (nil, let plan?): subtitle = plan
            case (nil, nil): subtitle = tr("Signed in", "已登录")
            }
        }

        // 只对开着、已登录的服务报刷新失败；文案是 `QuotaError.userMessage`，原因放进数据来源弹窗。
        let error = settings.isProviderEnabled(app) && info.signedIn ? appState.quotaError(for: app) : nil

        var actions: [ServiceAction] = []
        if app == .codex, info.signedIn {
            actions.append(ServiceAction(title: tr("Reset Credits…", "额度重置次数…")) { showCodexResetCreditsSheet = true })
        }
        if app == .commandCode {
            actions.append(ServiceAction(title: tr("Enter Credentials…", "填写凭据…")) { showCommandCodeSheet = true })
        }

        return ServiceEntry(
            id: .quota(app),
            logoName: provider.logoName,
            fallback: provider.fallback,
            tint: app.tintColor,
            title: provider.title,
            subtitle: subtitle,
            errorDetail: error,
            isDetected: isDetected,
            connectAction: !isDetected && app == .commandCode
                ? ServiceAction(title: tr("Enter Credentials…", "填写凭据…")) { showCommandCodeSheet = true }
                : nil,
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
                tr("Usage: reads session records in ~/.dsh/sessions and calculates tokens and cost on this Mac. Only the default location is checked. DSH has no subscription quota.",
                   "用量：读取 ~/.dsh/sessions 中的会话记录，在本机计算 Token 和费用。只查找这个默认位置。DSH 没有订阅额度。"),
                tr("Start a session in DSH to detect it (only ~/.dsh is checked)", "用 DSH 产生会话后自动识别，只查找 ~/.dsh")
            )
        }

        let subtitle: String = switch records {
        case .found:
            tr("Usage only · local records found", "仅用量 · 已找到本机记录")
        case .installedOnly where app == .dsh:
            tr("Usage only · no sessions in the default location", "仅用量 · 默认位置没有会话记录")
        case .installedOnly:
            tr("Usage only · no local records yet", "仅用量 · 暂无本机记录")
        case .missing:
            connectHint
        }

        return ServiceEntry(
            id: .usage(app),
            logoName: logoName,
            fallback: fallback,
            tint: app.tintColor,
            title: title,
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

    /// 额度的数据来源说明，放在行尾数据来源弹窗里。
    private func quotaSourceHelp(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Quota: reads the sign-in in ~/.codex/auth.json and asks OpenAI for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 ~/.codex/auth.json 的登录状态，向 OpenAI 查询剩余额度。只读取，不改动登录。")
        case .claude:
            tr("Quota: reads the sign-in from Claude Code CLI or Claude Desktop and asks Anthropic for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 Claude Code CLI 或 Claude 桌面版的登录状态，向 Anthropic 查询剩余额度。只读取，不改动登录。")
        case .antigravity:
            tr("Quota: reads the sign-in in ~/.gemini (agy CLI / IDE plugin) and asks Google for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 ~/.gemini 中的登录状态（agy CLI / IDE 插件登录），向 Google 查询剩余额度。只读取，不改动登录。")
        case .cursor:
            tr("Quota: reads the sign-in from the Cursor app and asks Cursor for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 Cursor 应用的登录状态，向 Cursor 查询剩余额度。只读取，不改动登录。")
        case .commandCode:
            tr("Quota: reads Command Code's local credentials or the ones you entered (stored in Keychain), and asks Command Code for remaining quota.",
               "额度：读取 Command Code 的本机凭据或手动填写的凭据（保存在钥匙串），向 Command Code 查询剩余额度。")
        }
    }

    /// 「未检测到」行的接入提示。
    private func connectHint(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Sign in with the Codex CLI to detect it", "用 Codex CLI 登录后自动识别")
        case .claude:
            tr("Sign in to Claude Code CLI or Claude Desktop to detect it", "登录 Claude Code CLI 或 Claude 桌面版后自动识别")
        case .antigravity:
            tr("Sign in to Antigravity (agy CLI or IDE plugin) to detect it", "登录 Antigravity（agy CLI 或 IDE 插件）后自动识别")
        case .cursor:
            tr("Sign in to the Cursor app to detect it", "登录 Cursor 应用后自动识别")
        case .commandCode:
            tr("Sign in with the Command Code CLI to detect it, or", "登录 Command Code CLI 后自动识别，或")
        }
    }

    /// 默认关闭的服务，关闭态说明开启后会发生什么（两者开启后才联网请求）。
    private func offHint(for app: QuotaApp) -> String? {
        switch app {
        case .cursor:
            tr("Turning on reads Cursor's sign-in to fetch quota and usage online.",
               "开启后会读取 Cursor 的登录状态，联网查询额度和用量。")
        case .commandCode:
            tr("Turning on fetches Command Code quota online.", "开启后会联网查询 Command Code 额度。")
        default:
            nil
        }
    }

    /// 手动重算的结果提示。成功不提示（费用已在统计页可见）；被拒 / 失败必须说明
    /// 「原历史保留」与下一步，和技术实现里的拒绝阈值一致。
    private func rebuildOutcomeHint(_ outcome: UsageRebuildOutcome?) -> String? {
        switch outcome {
        case .rejectedUsageChanged:
            return tr(
                "Not applied: logs changed during recalculation. Existing data kept.",
                "未生效：重算期间日志有变化，原数据未改动"
            )
        case .rejectedIncompleteSources:
            return tr(
                "Not applied: some logs could not be read. Existing data kept.",
                "未生效：部分日志读取失败，原数据未改动"
            )
        case .commitFailed:
            return tr(
                "Could not save the result. Existing data kept.",
                "结果保存失败，原数据未改动"
            )
        case .partiallyCommitted:
            return tr(
                "Partly applied: costs for models with newly fetched prices were not updated.",
                "部分生效：新获取价格的模型费用未更新"
            )
        case .restrictedRecoveryRejected:
            return tr(
                "Verification failed. Existing data kept; new usage is paused. Restore the logs or fix disk read/write errors, then retry.",
                "校验未通过：原数据保留，已暂停统计新用量。恢复日志或解决磁盘读写问题后再试"
            )
        case .replaced(cycleVerified: false):
            return tr(
                "Costs updated; some usage could not be matched to its quota cycle.",
                "费用已更新；部分用量未能确认所属额度周期"
            )
        case .replaced(cycleVerified: true), .recoveredFromRestrictedHistory, .none:
            return nil
        }
    }

    private func scanProgressText(_ progress: ScanProgress) -> String {
        let appName: String
        switch progress.app {
        case .codex: appName = "Codex"
        case .claude: appName = "Claude Code"
        case .cursor: appName = "Cursor"
        case .pi: appName = "Pi"
        case .opencode: appName = "OpenCode"
        case .dsh: appName = "DSH"
        }
        if progress.filesTotal > 0 {
            return tr(
                "Scanning \(appName): \(progress.filesCompleted)/\(progress.filesTotal) files",
                "正在扫描 \(appName)：\(progress.filesCompleted)/\(progress.filesTotal) 个文件"
            )
        }
        return tr(
            "Scanning \(appName): \(progress.linesParsed) items",
            "正在扫描 \(appName)：已处理 \(progress.linesParsed) 条"
        )
    }

    // MARK: Diagnostics helpers

    /// 导出前必须把"包含什么 / 不包含什么"说清楚。用户对"把日志发给开发者"的顾虑
    /// 只能靠明确告知消解，不能靠一句"已脱敏"带过。
    private var diagnosticsDisclosure: String {
        tr(
            """
            The zip contains the app version, macOS version, your settings, each service's \
            status and last error, and local log scan statistics.

            It does not contain sign-in tokens, plain-text email addresses, conversation \
            content, file contents, or project names. Nothing is uploaded — the file is \
            saved locally and it is up to you whether to send it.
            """,
            """
            压缩包内含：App 版本、macOS 版本、你的设置项、各服务的状态与最后一次错误、\
            本地日志扫描统计。

            不含：登录令牌、明文邮箱、对话内容、文件内容、项目名。App 不会上传任何内容，\
            文件只保存在本机，发不发由你决定。
            """
        )
    }

    private func exportDiagnostics() {
        isExportingDiagnostics = true
        diagnosticsMessage = nil
        diagnosticsMessageIsError = false
        Task {
            do {
                let url = try await DiagnosticsBundle.export(appState: appState)
                DiagnosticsBundle.revealInFinder(url)
                diagnosticsMessage = tr("Revealed in Finder", "已在 Finder 中显示")
            } catch {
                diagnosticsMessage = tr("Export failed", "导出失败")
                diagnosticsMessageIsError = true
                AppLog.error(.app, "diagnostics export failed: \(Redact.error(error))")
            }
            isExportingDiagnostics = false
        }
    }

    // MARK: Update check helpers

    private var isUpdateCheckInProgress: Bool {
        appState.updateStatus == .checking
    }

    private var updateStatusHasNewVersion: Bool {
        if case .updateAvailable = appState.updateStatus { return true }
        return false
    }

    private var updateStatusIsError: Bool {
        appState.updateStatus == .failed || appState.updateStatus == .rateLimited
    }

    private var updateStatusText: String? {
        switch appState.updateStatus {
        case .idle, .checking:
            return nil
        case .upToDate(let latest):
            return tr("Up to date (\(latest))", "已是最新（\(latest)）")
        case .updateAvailable(let version):
            return tr("Version \(version) is available", "发现新版本 \(version)")
        case .failed:
            return tr("Check failed", "检查失败")
        case .rateLimited:
            return tr("GitHub rate limit reached, try again later", "GitHub 暂时限流，请稍后再试")
        }
    }

    private var updateButtonTitle: String {
        updateStatusHasNewVersion
            ? tr("Download", "前往下载")
            : tr("Check", "检查")
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

    /// 「重新计算用量」上一次的核对结果提示，放在描述下方，长文案换行显示。
    private var recalculateOutcomeDetail: AnyView? {
        guard !isRecalculatingUsage,
              let hint = rebuildOutcomeHint(appState.usageService.lastRebuildOutcome)
        else { return nil }
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text(hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.top, 2)
            .help(PrivacyDisplay.help(appState.usageService.lastRebuildDiagnostic ?? ""))
        )
    }

    /// 开机启动的状态 / 错误说明，作为「开机自动启动」的描述行。
    private var launchAtLoginDetail: AnyView? {
        guard let launchAtLoginMessage else { return nil }
        return AnyView(
            Text(launchAtLoginMessageIsError ? PrivacyDisplay.error(launchAtLoginMessage) : launchAtLoginMessage)
                .font(.system(size: 11))
                .foregroundStyle(launchAtLoginMessageIsError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        )
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
                // 13 semibold：不小于行标签（13 regular），组标题层级在行之上。
                Text(tr(title, chinese))
                    .font(.system(size: 13, weight: .semibold))
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
    var leading: AnyView? = nil
    var desc: String? = nil
    var chineseDesc: String? = nil
    /// 描述下方的附加行（状态、错误提示等），可多行换行，不占右侧控件区。
    var detail: AnyView? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // 右侧控件与左侧文字块垂直居中：描述有两行或带附加行时，控件不再贴着首行基线。
        HStack(alignment: .center, spacing: 12) {
            if let leading { leading }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(label, chinese))
                    .font(.system(size: 13))
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if let detail {
                    detail
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}

// MARK: - InsetDivider

private struct InsetDivider: View {
    var leading: CGFloat = 16
    var trailing: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
    }
}

// MARK: - Layout

enum SettingsLayout {
    /// 内容栏最大宽度，同系统设置；四个分类共用，居中显示。
    static let contentMaxWidth: CGFloat = 680
}

/// 服务行的缩进与右侧固定列宽。`ImportedCodexAccountsView` 的子行按同一套列对齐。
enum ServiceRowMetrics {
    static let leadingPadding: CGFloat = 16
    static let trailingPadding: CGFloat = 14
    static let tileSize: CGFloat = 28
    /// 名称文字起点：16 内边距 + 28 tile + 12 间距。行间分隔线和子行都从这里开始。
    static let textLeading: CGFloat = 56
    /// 英文列头 Floating HUD 约 70pt，按自然宽度居中会略越出 64pt 列宽，但不会压到相邻列头。
    static let destination: CGFloat = 64
    static let info: CGFloat = 28
    static let toggle: CGFloat = 44
}

// MARK: - Service rows

/// 服务分组：标题行右侧写一次列名（菜单栏 / 悬浮窗 / 启用），与下面每行的控件对齐。
private struct ServiceGroup<Content: View>: View {
    let title: String
    let desc: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(-0.05)
                    if let desc {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                columnTitle(tr("Menu Bar", "菜单栏"), width: ServiceRowMetrics.destination)
                columnTitle(tr("Floating HUD", "悬浮窗"), width: ServiceRowMetrics.destination)
                Color.clear
                    .frame(width: ServiceRowMetrics.info, height: 1)
                columnTitle(tr("Enabled", "启用"), width: ServiceRowMetrics.toggle)
            }
            .padding(.leading, 4)
            .padding(.trailing, ServiceRowMetrics.trailingPadding)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func columnTitle(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width)
    }
}

/// 设置页一行服务的展示数据。额度服务和仅有用量的服务共用，不支持的能力为 nil、不显示。
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
    /// 账号 · 套餐、本机记录状态，或未检测到时的接入提示。
    let subtitle: String
    /// 最近一次刷新失败的原因（`QuotaError.userMessage`）；行内只写「刷新失败」，原因放进数据来源弹窗。
    let errorDetail: String?
    /// 这台 Mac 上检测到了（登录态或本机记录），决定放在「正在使用」还是「未检测到」。
    let isDetected: Bool
    /// 未检测到时副标题后的按钮（Command Code 手动填写凭据）。
    let connectAction: ServiceAction?
    let sourceLines: [String]
    /// 数据来源弹窗底部的操作（Codex 额度重置次数、Command Code 凭据）。
    let actions: [ServiceAction]
    let isEnabled: Binding<Bool>
    /// 菜单栏 / 悬浮窗只跟额度有关；仅有用量的服务为 nil，单元格留空。
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

private struct ServiceRow: View {
    let entry: ServiceEntry
    let floatingHUDGloballyEnabled: Bool

    private var isEnabled: Bool { entry.isEnabled.wrappedValue }

    var body: some View {
        HStack(spacing: 0) {
            ServiceTile(
                logoName: entry.logoName,
                fallback: entry.fallback,
                tint: entry.tint,
                size: ServiceRowMetrics.tileSize,
                logoSize: 18,
                cornerRadius: 7.5
            )
            .opacity(entry.isDetected ? 1 : 0.45)
            .padding(.trailing, ServiceRowMetrics.textLeading - ServiceRowMetrics.leadingPadding - ServiceRowMetrics.tileSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(entry.isDetected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                subtitleLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // 服务关闭时两列置灰且不可点，不隐藏，保持列对齐。
            HStack(spacing: 0) {
                destinationCell(entry.showInMenuBar, title: tr("Menu Bar", "菜单栏"), unavailable: false, help: nil)
                destinationCell(
                    entry.showInFloatingHUD,
                    title: tr("Floating HUD", "悬浮窗"),
                    unavailable: !floatingHUDGloballyEnabled,
                    help: floatingDisabledHelp
                )
            }
            .opacity(isEnabled ? 1 : 0.4)

            ServiceInfoButton(entry: entry)
                .frame(width: ServiceRowMetrics.info)

            Toggle(entry.title, isOn: entry.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .help(tr(
                    "Turning off hides this service's quota and usage. Records are kept.",
                    "关闭后不再显示这个服务的额度和用量，已有记录保留，重新开启即可看到"
                ))
                .frame(width: ServiceRowMetrics.toggle)
        }
        .padding(.leading, ServiceRowMetrics.leadingPadding)
        .padding(.trailing, ServiceRowMetrics.trailingPadding)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
    }

    private var subtitleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.subtitle)
            if let errorDetail = entry.errorDetail {
                Text("· \(tr("Refresh failed", "刷新失败"))")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .help(errorDetail)
            }
            if let connectAction = entry.connectAction {
                Button(connectAction.title, action: connectAction.action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .focusEffectDisabled()
                    .fixedSize()
            }
        }
    }

    /// 悬浮窗列不可勾选的原因：服务关闭时不提示；其余是全局悬浮窗未开启。
    private var floatingDisabledHelp: String? {
        guard isEnabled, !floatingHUDGloballyEnabled else { return nil }
        return tr("Enable Floating HUD in Appearance & Display first", "需先在「外观与显示」中开启桌面悬浮窗")
    }

    @ViewBuilder
    private func destinationCell(
        _ binding: Binding<Bool>?,
        title: String,
        unavailable: Bool,
        help: String?
    ) -> some View {
        Group {
            if let binding {
                DisplayDestinationCheckbox(
                    title: "\(entry.title) \(title)",
                    isOn: binding,
                    disabled: !isEnabled || unavailable,
                    disabledHelp: help
                )
            } else {
                Color.clear
                    .frame(height: 22)
            }
        }
        .frame(width: ServiceRowMetrics.destination)
    }
}

/// 行尾数据来源按钮：悬停提示，点击弹出说明（读哪里、向谁查询、最近一次失败原因）和专属操作。
/// 刷新失败时图标换成橙色感叹号。
private struct ServiceInfoButton: View {
    let entry: ServiceEntry
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: entry.errorDetail == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(entry.errorDetail == nil ? Color.secondary : Color.orange)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .help(tr("Data sources", "数据来源"))
        .accessibilityLabel(tr("\(entry.title) data sources", "\(entry.title) 数据来源"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                ForEach(entry.sourceLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorDetail = entry.errorDetail {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorDetail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                }
                if !entry.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(entry.actions, id: \.title) { item in
                            Button(item.title) {
                                isPresented = false
                                item.action()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}


// MARK: - DisplayDestinationCheckbox

/// 矩阵单元格里的 13pt 复选框，没有文字标签（列头说明含义），`title` 只作无障碍标签。
/// 整个单元格可点，不只是 13pt 的框。
private struct DisplayDestinationCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var disabledHelp: String? = nil

    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        let button = Button {
            if disabled {
                if disabledHelp != nil {
                    showTooltip = true
                }
            } else {
                isOn.toggle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(isOn ? Color.primary.opacity(disabled ? 0.04 : 0.08) : Color.clear)

                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.8)

                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.secondary)
                }
            }
            .frame(width: 13, height: 13)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? tr("On", "已开启") : tr("Off", "已关闭"))
        .onHover { hovering in
            guard disabled, let disabledHelp, !disabledHelp.isEmpty else { return }
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    showTooltip = true
                }
            } else {
                showTooltip = false
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
        }
        .popover(isPresented: $showTooltip, arrowEdge: .top) {
            if let disabledHelp, !disabledHelp.isEmpty {
                Text(disabledHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fixedSize()
            }
        }
        .help(disabled ? (disabledHelp ?? "") : "")

        if disabled {
            button
        } else {
            button.pointingHandCursor()
        }
    }

    private var borderColor: Color {
        if disabled { return Color.primary.opacity(isOn ? 0.12 : 0.06) }
        return Color.primary.opacity(isOn ? 0.28 : 0.12)
    }
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
