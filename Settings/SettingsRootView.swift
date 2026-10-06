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
    @State private var showOtherServices = false
    @State private var showMoreCodexAccounts = false
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
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(selectedCategory)
    }

    // MARK: - Section 1: Services & Accounts

    @ViewBuilder
    private func servicesSection(settings: SettingsStore) -> some View {
        let entries = serviceEntries(settings: settings)
        let inUse = entries.filter(\.isDetected)
        let others = entries.filter { !$0.isDetected }

        VStack(alignment: .leading, spacing: 12) {
            servicesIntro

            // 正在使用：这台 Mac 上检测到的服务，每个服务一行，列为额度与用量 / 开启 / 菜单栏 / 悬浮窗 / 专属操作
            PrefsGroup(
                title: "In Use",
                chinese: "正在使用",
                desc: "Services found on this Mac. Turning one off hides its quota and usage; existing records are kept.",
                chineseDesc: "这台 Mac 上检测到的服务。关闭后不再显示它的额度和用量，已有记录会保留。"
            ) {
                if inUse.isEmpty {
                    Text(tr(
                        "No services found on this Mac yet. See Other Supported Services below.",
                        "暂未检测到任何服务，见下方「其他支持的服务」"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ServiceMatrixHeader()
                    ForEach(Array(inUse.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            InsetDivider()
                        }
                        ServiceSettingsRow(entry: entry, floatingHUDGloballyEnabled: settings.floatingEnabled)
                        if entry.id == .quota(.codex) {
                            moreCodexAccounts
                        }
                    }
                }
            }
        }

        // 其他支持的服务：未检测到的服务默认折叠，只给接入提示。
        // 保留开启开关：额度服务即使未检测到，开着也会在 Popover 里占一张卡片，用户需要能在这里关掉。
        if !others.isEmpty {
            CollapsiblePrefsGroup(
                title: "Other Supported Services (\(others.count))",
                chinese: "其他支持的服务（\(others.count)）",
                desc: "Not found on this Mac yet. Sign in or use one as described, and it will appear above.",
                chineseDesc: "暂未在这台 Mac 上检测到。按提示登录或使用后，会自动出现在上方。",
                isExpanded: $showOtherServices
            ) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        InsetDivider()
                    }
                    OtherServiceRow(entry: entry)
                    if entry.id == .quota(.codex) {
                        moreCodexAccounts
                    }
                }
            }
        }
    }

    /// 页面顶部说明：先讲清额度和用量是两类信息，再看下面每个服务支持哪类。
    private var servicesIntro: some View {
        let markdown = tr(
            "CCBar shows two kinds of info for each service: **Quota**, how much of your plan is left, and **Usage**, how many tokens you've used and what they cost. Support varies by service.",
            "CCBar 为每个服务提供两类信息：**额度**，即套餐还剩多少；**用量**，即用了多少 Token、折合多少钱。不同服务支持的不一样。"
        )
        let text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        return Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// 更多 Codex 账号：缩进挂在 Codex 行下方，与服务名左对齐（16 行内边距 + 22 tile + 10 间距）。
    /// 默认折叠，只显示标题和已导入数量；点标题展开说明和账号列表。
    private var moreCodexAccounts: some View {
        let count = appState.importedCodexAccounts.count
        let title = count > 0
            ? tr("More Codex Accounts (\(count))", "更多 Codex 账号（\(count)）")
            : tr("More Codex Accounts", "更多 Codex 账号")

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showMoreCodexAccounts.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showMoreCodexAccounts ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointingHandCursor()
            .accessibilityValue(showMoreCodexAccounts ? tr("Expanded", "已展开") : tr("Collapsed", "已收起"))

            if showMoreCodexAccounts {
                Text(tr(
                    "Paste another account's auth.json to view its quota. Quota only, no usage, and your Codex CLI sign-in is not affected.",
                    "粘贴其他账号的 auth.json，在 CCBar 里查看它们的额度。只看额度、不统计用量，也不影响 Codex CLI 当前登录的账号。"
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -6)

                moreCodexAccountsList
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private var moreCodexAccountsList: some View {
        ImportedCodexAccountsView()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    /// 设置页「开启」开关：一个服务一个开关，同时管额度和用量（见 `SettingsStore.setServiceEnabled`）。
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

    /// 仅有用量的服务（Pi / OpenCode / DSH）的「开启」开关，直接对应统计服务可见性。
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
        let subtitle: String? = switch (email, plan) {
        case (let email?, let plan?): "\(email) · \(plan)"
        case (let email?, nil): email
        case (nil, let plan?): plan
        case (nil, nil): nil
        }

        let quota = ServiceCapabilityStatus(
            text: info.signedIn ? tr("Signed in", "已登录") : tr("Not signed in", "未登录"),
            isWarning: !info.signedIn,
            help: quotaSourceHelp(for: app)
        )

        let usage: ServiceCapabilityStatus?
        let isDetected: Bool
        switch app {
        case .codex, .claude:
            let usageApp: UsageApp = app == .codex ? .codex : .claude
            let records = localRecordState(for: usageApp)
            usage = ServiceCapabilityStatus(
                text: records == .found
                    ? tr("Local records found", "已找到本机记录")
                    : tr("No local records yet", "暂无本机记录"),
                isWarning: false,
                help: app == .codex
                    ? tr("Reads conversation records in ~/.codex/sessions and calculates tokens and cost on this Mac.",
                         "读取 ~/.codex/sessions 中的对话记录，在本机计算 Token 和费用。")
                    : tr("Reads conversation records in ~/.claude/projects and calculates tokens and cost on this Mac.",
                         "读取 ~/.claude/projects 中的对话记录，在本机计算 Token 和费用。")
            )
            // 只导入了其他 Codex 账号、本机没登录 Codex 时也算在用，让「更多 Codex 账号」留在上方。
            isDetected = info.signedIn
                || records != .missing
                || (app == .codex && !appState.importedCodexAccounts.isEmpty)
        case .cursor:
            usage = ServiceCapabilityStatus(
                text: tr("From your Cursor account", "来自 Cursor 账号"),
                isWarning: false,
                help: tr("Fetches usage records from your Cursor account online.", "联网读取 Cursor 账号的用量记录。")
            )
            isDetected = info.signedIn
        case .antigravity, .commandCode:
            usage = nil
            isDetected = info.signedIn
        }

        return ServiceEntry(
            id: .quota(app),
            logoName: provider.logoName,
            fallback: provider.fallback,
            tint: app.tintColor,
            title: provider.title,
            vendor: provider.vendor,
            subtitle: subtitle,
            quota: quota,
            usage: usage,
            isDetected: isDetected,
            connectHint: connectHint(for: app),
            connectAccessory: app == .commandCode ? commandCodeManualCredentialButton : nil,
            offHint: offHint(for: app),
            isEnabled: serviceEnabledBinding(for: app, settings: settings),
            showInMenuBar: provider.supportsMenuBar ? menuBarBinding(for: app, settings: settings) : nil,
            showInFloatingHUD: provider.supportsFloatingHUD ? floatingBinding(for: app, settings: settings) : nil,
            accessory: accessoryView(for: app)
        )
    }

    private func localUsageServiceEntry(_ app: UsageApp, settings: SettingsStore) -> ServiceEntry {
        let records = localRecordState(for: app)
        let (logoName, fallback, title, vendor, help, connectHint): (String, String, String, String, String, String) = switch app {
        case .pi:
            (
                "pi", "P", "Pi", "pi.dev",
                tr("Reads conversation records in ~/.pi/agent/sessions and calculates tokens and cost on this Mac.",
                   "读取 ~/.pi/agent/sessions 中的对话记录，在本机计算 Token 和费用。"),
                tr("Start a conversation in Pi to detect it", "使用 Pi 产生对话后自动识别")
            )
        case .opencode:
            (
                "opencode", "O", "OpenCode", "opencode.ai",
                tr("Reads conversation records in ~/.local/share/opencode and calculates tokens and cost on this Mac.",
                   "读取 ~/.local/share/opencode 中的对话记录，在本机计算 Token 和费用。"),
                tr("Start a conversation in OpenCode to detect it", "使用 OpenCode 产生对话后自动识别")
            )
        default:
            (
                "dsh", "D", "DSH", "DeepSeek Harness",
                tr("Reads session records in ~/.dsh/sessions and calculates tokens and cost on this Mac. Only the default location is checked.",
                   "读取 ~/.dsh/sessions 中的会话记录，在本机计算 Token 和费用。只查找这个默认位置。"),
                tr("Start a session in DSH to detect it (default location only)", "使用 DSH 产生会话后自动识别，只查找默认位置")
            )
        }

        let usageText: String = switch records {
        case .found:
            tr("Local records found", "已找到本机记录")
        case .installedOnly where app == .dsh:
            tr("DSH found, but no sessions in the default location", "已找到 DSH，默认位置没有会话记录")
        case .installedOnly, .missing:
            tr("No local records yet", "暂无本机记录")
        }

        return ServiceEntry(
            id: .usage(app),
            logoName: logoName,
            fallback: fallback,
            tint: app.tintColor,
            title: title,
            vendor: vendor,
            subtitle: nil,
            quota: nil,
            usage: ServiceCapabilityStatus(text: usageText, isWarning: false, help: help),
            isDetected: records != .missing,
            connectHint: connectHint,
            connectAccessory: nil,
            offHint: nil,
            isEnabled: usageStatsBinding(for: app, settings: settings),
            showInMenuBar: nil,
            showInFloatingHUD: nil,
            accessory: nil
        )
    }

    /// 额度的数据来源说明（hover），排查问题时用。
    private func quotaSourceHelp(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Reads the sign-in in ~/.codex/auth.json and asks OpenAI for remaining quota. Read-only; your sign-in is not changed.",
               "读取 ~/.codex/auth.json 的登录状态，向 OpenAI 查询剩余额度。只读取，不改动登录。")
        case .claude:
            tr("Reads the sign-in from Claude Code CLI or Claude Desktop and asks Anthropic for remaining quota. Read-only; your sign-in is not changed.",
               "读取 Claude Code CLI 或 Claude 桌面版的登录状态，向 Anthropic 查询剩余额度。只读取，不改动登录。")
        case .antigravity:
            tr("Reads the sign-in in ~/.gemini (agy CLI / IDE plugin) and asks Google for remaining quota. Read-only; your sign-in is not changed.",
               "读取 ~/.gemini 中的登录状态（agy CLI / IDE 插件登录），向 Google 查询剩余额度。只读取，不改动登录。")
        case .cursor:
            tr("Reads the sign-in from the Cursor app and asks Cursor for remaining quota. Read-only; your sign-in is not changed.",
               "读取 Cursor 应用的登录状态，向 Cursor 查询剩余额度。只读取，不改动登录。")
        case .commandCode:
            tr("Reads Command Code's local credentials or the ones you entered, and asks Command Code for remaining quota. Read-only; your sign-in is not changed.",
               "读取 Command Code 的本机凭据或手动填写的凭据，向 Command Code 查询剩余额度。只读取，不改动登录。")
        }
    }

    /// 「其他支持的服务」里的接入提示。
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

    /// 检测到但默认关闭的服务，关闭态说明开启后会发生什么（两者开启后才联网请求）。
    private func offHint(for app: QuotaApp) -> String? {
        switch app {
        case .cursor:
            tr("Turning on reads Cursor's sign-in to fetch quota and usage online",
               "开启后会读取 Cursor 的登录状态，联网查询额度和用量")
        case .commandCode:
            tr("Turning on fetches Command Code quota online", "开启后会联网查询 Command Code 额度")
        default:
            nil
        }
    }

    private func accessoryView(for app: QuotaApp) -> AnyView? {
        switch app {
        case .codex:
            return appState.codexAccount != nil ? AnyView(codexResetCreditsButton) : nil
        case .commandCode:
            return AnyView(commandCodeCredentialButton)
        default:
            return nil
        }
    }

    private var commandCodeManualCredentialButton: AnyView {
        AnyView(
            Button(tr("Enter credentials", "手动填写凭据")) {
                showCommandCodeSheet = true
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .focusEffectDisabled()
        )
    }

    private var commandCodeCredentialButton: some View {
        Button {
            showCommandCodeSheet = true
        } label: {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(tr("Enter Command Code credentials", "填写 Command Code 凭据"))
    }

    private var codexResetCreditsButton: some View {
        Button {
            showCodexResetCreditsSheet = true
        } label: {
            Image(systemName: "gift")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(tr("Reset credits", "额度重置次数"))
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

// MARK: - CollapsiblePrefsGroup

/// 可折叠的设置分组，标题样式同 `PrefsGroup`，点标题展开 / 收起。
private struct CollapsiblePrefsGroup<Content: View>: View {
    let title: String
    let chinese: String
    let desc: String
    let chineseDesc: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(tr(title, chinese))
                            .font(.system(size: 13, weight: .semibold))
                            .kerning(-0.05)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointingHandCursor()
            .accessibilityValue(isExpanded ? tr("Expanded", "已展开") : tr("Collapsed", "已收起"))
            .padding(.horizontal, 4)
            .padding(.bottom, isExpanded ? 8 : 0)

            if isExpanded {
                VStack(spacing: 0) {
                    content()
                }
                .ccPanel(cornerRadius: 10)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

// MARK: - Service matrix

/// 「正在使用」矩阵列宽。服务列占剩余宽度；主窗口最小宽 1040 时服务列约 285pt。
private enum ServiceMatrixColumn {
    static let status: CGFloat = 220
    static let toggle: CGFloat = 56
    static let destination: CGFloat = 64
    static let accessory: CGFloat = 40
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
    let vendor: String
    /// 账号 · 套餐；没有账号概念的服务为 nil。
    let subtitle: String?
    let quota: ServiceCapabilityStatus?
    let usage: ServiceCapabilityStatus?
    /// 这台 Mac 上检测到了（登录态或本机记录），决定放在「正在使用」还是「其他支持的服务」。
    let isDetected: Bool
    let connectHint: String
    let connectAccessory: AnyView?
    /// 关闭态的专属说明；nil 时按支持的能力给通用文案。
    let offHint: String?
    let isEnabled: Binding<Bool>
    /// 菜单栏 / 悬浮窗只跟额度有关；仅有用量的服务为 nil。
    let showInMenuBar: Binding<Bool>?
    let showInFloatingHUD: Binding<Bool>?
    let accessory: AnyView?
}

private struct ServiceCapabilityStatus {
    let text: String
    let isWarning: Bool
    /// 数据来源说明（hover），排查问题时用。
    let help: String
}

private enum LocalRecordState: Equatable {
    case found
    case installedOnly
    case missing
}

private struct ServiceMatrixHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(tr("Service", "服务"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("Quota & Usage", "额度与用量"))
                .frame(width: ServiceMatrixColumn.status, alignment: .leading)
            centered(tr("On", "开启"), width: ServiceMatrixColumn.toggle)
            centered(tr("Menu Bar", "菜单栏"), width: ServiceMatrixColumn.destination)
            centered(tr("Floating HUD", "悬浮窗"), width: ServiceMatrixColumn.destination)
            Color.clear
                .frame(width: ServiceMatrixColumn.accessory, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    /// 英文列头（如 Floating HUD）可能略宽于列，按自然宽度居中，允许轻微越出列边界。
    private func centered(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width)
    }
}

/// 服务 tile + 名称 · 厂商，下面一行由调用方给出（账号副标题或接入提示）。
private struct ServiceNameBlock<Detail: View>: View {
    let entry: ServiceEntry
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 10) {
            ServiceTile(logoName: entry.logoName, fallback: entry.fallback, tint: entry.tint)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("· \(entry.vendor)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                detail()
            }
        }
    }
}

private struct ServiceEnabledToggle: View {
    let entry: ServiceEntry

    var body: some View {
        // 小号开关：表格行更紧凑，接近设计稿 32×20。
        Toggle(entry.title, isOn: entry.isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.green)
            .help(tr(
                "Turning off hides this service's quota and usage. Records are kept.",
                "关闭后不再显示这个服务的额度和用量，已有记录保留，重新开启即可看到"
            ))
    }
}

/// 「额度与用量」列里的一行：`额度  已登录`。
private struct CapabilityStatusLine: View {
    let label: String
    let status: ServiceCapabilityStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .leading)
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(status.isWarning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(status.help)
    }
}

/// 「正在使用」里的服务行。
private struct ServiceSettingsRow: View {
    let entry: ServiceEntry
    let floatingHUDGloballyEnabled: Bool

    private var isEnabled: Bool { entry.isEnabled.wrappedValue }

    var body: some View {
        HStack(spacing: 0) {
            ServiceNameBlock(entry: entry) {
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            statusColumn
                .frame(width: ServiceMatrixColumn.status, alignment: .leading)

            ServiceEnabledToggle(entry: entry)
                .frame(width: ServiceMatrixColumn.toggle)

            // 菜单栏 / 悬浮窗只跟额度有关：仅有用量的服务留空占位，保持列对齐。
            // 服务关闭时整组置灰且不可点，不隐藏。
            HStack(spacing: 0) {
                destinationCell(
                    entry.showInMenuBar,
                    title: tr("Menu Bar", "菜单栏"),
                    unavailable: false,
                    help: nil
                )
                destinationCell(
                    entry.showInFloatingHUD,
                    title: tr("Floating HUD", "悬浮窗"),
                    unavailable: !floatingHUDGloballyEnabled,
                    help: floatingDisabledHelp
                )
            }
            .opacity(isEnabled ? 1 : 0.4)

            // 用固定宽的占位撑住操作列：没有专属操作的行也要占 40pt，否则整行各列右移、与列头错位。
            ZStack {
                Color.clear
                    .frame(width: ServiceMatrixColumn.accessory, height: 1)
                if let accessory = entry.accessory { accessory }
            }
            .frame(width: ServiceMatrixColumn.accessory)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var statusColumn: some View {
        if isEnabled {
            VStack(alignment: .leading, spacing: 2) {
                if let quota = entry.quota {
                    CapabilityStatusLine(label: tr("Quota", "额度"), status: quota)
                }
                if let usage = entry.usage {
                    CapabilityStatusLine(label: tr("Usage", "用量"), status: usage)
                }
            }
        } else {
            Text(offText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var offText: String {
        if let offHint = entry.offHint { return offHint }
        switch (entry.quota != nil, entry.usage != nil) {
        case (true, true): return tr("Off, quota and usage hidden", "已关闭，不显示额度和用量")
        case (true, false): return tr("Off, quota hidden", "已关闭，不显示额度")
        default: return tr("Off, usage hidden", "已关闭，不显示用量")
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
        .frame(width: ServiceMatrixColumn.destination)
    }
}

/// 「其他支持的服务」里的行：只给接入提示和开启开关。
private struct OtherServiceRow: View {
    let entry: ServiceEntry

    var body: some View {
        HStack(spacing: 0) {
            ServiceNameBlock(entry: entry) {
                HStack(spacing: 4) {
                    Text(entry.connectHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.connectHint)
                    if let connectAccessory = entry.connectAccessory {
                        connectAccessory
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            ServiceEnabledToggle(entry: entry)
                .frame(width: ServiceMatrixColumn.toggle)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
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
