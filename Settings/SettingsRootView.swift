import AppKit
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
    private let updater = AppUpdater.shared
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
    @State private var showQuotaAlertRebuildConfirm = false
    @State private var quotaNotificationSettingsOpened = false

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
        .confirmationDialog(
            tr("Rebuild alert history?", "重建提醒记录？"),
            isPresented: $showQuotaAlertRebuildConfirm, titleVisibility: .visible
        ) {
            Button(tr("Rebuild", "重建")) {
                Task { await appState.quotaNotifications.rebuild(entries: appState.quotaAlertEntries) }
            }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(tr(
                "Current low quotas will be recorded as already alerted. Alerts resume after recovery or reset. The original file is kept as a backup.",
                "当前低额度先记录为已提醒，恢复或重置后再提醒。原记录文件保留为备份。"
            ))
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
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 每个分组各自一个列表，只在组内重排。
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

    /// 组内新顺序换算成全局顺序：插到组内新邻居的前面（落在组尾时插到前一个的后面）。
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

    /// 每一行整行可拖（手柄只做提示）。
    /// Codex 行和它下面的其他 Codex 账号是一块，一起抬起、一起移动。
    @ViewBuilder
    private func serviceBlock(
        _ entry: ServiceEntry,
        reorder: ReorderRowState,
        floatingHUDGloballyEnabled: Bool
    ) -> some View {
        VStack(spacing: 0) {
            ServiceRow(
                entry: entry,
                floatingHUDGloballyEnabled: floatingHUDGloballyEnabled,
                isReorderLifted: reorder.isLifted
            )
            .reorderDragSource(reorder)

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
            InsetDivider()
            PrefsRow(
                label: "Count Codex subscription usage in other agents",
                chinese: "计入其他 Agent 的 Codex 订阅用量",
                desc: "The full-quota estimate and the Codex spend in the popover also count Codex subscription usage from Pi, OpenCode and DSH, all toward the current Codex account. OpenCode API key usage can't be told apart and is included.",
                chineseDesc: "额度用满预估和弹出面板的 Codex 花费同时计入 Pi、OpenCode、DSH 里的 Codex 订阅用量，都算到当前 Codex 账号。OpenCode 分不出 API Key 用量，会一并计入"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.cycleIncludesOtherAgents },
                    set: { settings.cycleIncludesOtherAgents = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
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
                desc: "Past costs are recalculated automatically when prices change.",
                chineseDesc: "价格变化后自动重算历史费用"
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
                desc: "Recompute history with the latest prices and rules. Usage from deleted logs is kept.",
                chineseDesc: "用最新价格表和统计规则重算历史；已删除日志的对话保留用量",
                detail: recalculateOutcomeDetail
            ) {
                // 自动重建进行中同样显示进度并禁用按钮，避免再排一次完整重建。
                let recalculating = isRecalculatingUsage || appState.usageService.isRebuildingHistory
                HStack(spacing: 8) {
                    if appState.usageService.cycleUsageNeedsManualRecalculation, !recalculating {
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
                    if let progress = appState.usageService.scanProgress, recalculating {
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
                        if recalculating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Recalculate", "重新计算"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(recalculating)
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

        quotaAlertGroup(settings: settings)

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
                Button(updateButtonTitle) {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            InsetDivider()
            PrefsRow(label: "Last checked", chinese: "上次检查") {
                if let date = updater.lastCheckedAt {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            InsetDivider()
            PrefsRow(label: "Automatically check for updates", chinese: "自动检查更新") {
                Toggle("", isOn: Binding(
                    get: { updater.automaticChecks },
                    set: { updater.setAutomaticChecks($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }
    }

    // MARK: - Bindings & Actions Helpers

    private func quotaAlertGroup(settings: SettingsStore) -> some View {
        let service = appState.quotaNotifications
        return PrefsGroup(
            title: "Quota alerts", chinese: "额度提醒",
            desc: "Checks enabled quota services and imported Codex accounts after successful refreshes.",
            chineseDesc: "包含已启用的额度服务和导入 Codex 账号，成功刷新后检查"
        ) {
            PrefsRow(label: "Enable quota alerts", chinese: "开启额度提醒", detail: quotaAlertDetail) {
                Toggle(tr("Enable quota alerts", "开启额度提醒"), isOn: Binding(
                    get: { settings.quotaAlertsEnabled },
                    set: { enabled in
                        settings.quotaAlertsEnabled = enabled
                        if enabled { Task { await service.requestPermissionIfNeeded() } }
                    }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.green)
            }
            InsetDivider()
            PrefsRow(label: "Remaining below", chinese: "剩余低于") {
                Picker(tr("Remaining below", "剩余低于"), selection: Binding(
                    get: { settings.quotaAlertThresholdPercent },
                    set: { settings.quotaAlertThresholdPercent = $0; service.settingsChanged() }
                )) {
                    ForEach(Array(stride(from: 5, through: 50, by: 5)), id: \.self) { value in
                        Text("\(value)%").monospacedDigit().tag(value)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(!settings.quotaAlertsEnabled)
            }
            InsetDivider()
            PrefsRow(label: "5-hour / session quota", chinese: "5 小时／会话额度") {
                Toggle(tr("5-hour / session quota", "5 小时／会话额度"), isOn: Binding(
                    get: { settings.quotaAlertFiveHourEnabled },
                    set: { settings.quotaAlertFiveHourEnabled = $0; service.settingsChanged() }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.green)
                .disabled(!settings.quotaAlertsEnabled || (!settings.quotaAlertWeeklyEnabled && !settings.quotaAlertBillingCycleEnabled))
                .help(tr("Keep at least one quota window selected.", "至少保留一个额度窗口"))
            }
            InsetDivider()
            PrefsRow(label: "Weekly quota", chinese: "周额度",
                     desc: "Includes model-specific weekly quotas.", chineseDesc: "包含模型专属周额度") {
                Toggle(tr("Weekly quota", "周额度"), isOn: Binding(
                    get: { settings.quotaAlertWeeklyEnabled },
                    set: { settings.quotaAlertWeeklyEnabled = $0; service.settingsChanged() }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.green)
                .disabled(!settings.quotaAlertsEnabled || (!settings.quotaAlertFiveHourEnabled && !settings.quotaAlertBillingCycleEnabled))
                .help(tr("Keep at least one quota window selected.", "至少保留一个额度窗口"))
            }
            InsetDivider()
            PrefsRow(label: "Billing cycle quota", chinese: "计费周期额度",
                     desc: "Cursor Total / Auto / API and Command Code monthly credits.",
                     chineseDesc: "Cursor Total／Auto／API 和 Command Code 月额度") {
                Toggle(tr("Billing cycle quota", "计费周期额度"), isOn: Binding(
                    get: { settings.quotaAlertBillingCycleEnabled },
                    set: { settings.quotaAlertBillingCycleEnabled = $0; service.settingsChanged() }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.green)
                .disabled(!settings.quotaAlertsEnabled || (!settings.quotaAlertFiveHourEnabled && !settings.quotaAlertWeeklyEnabled))
                .help(tr("Keep at least one quota window selected.", "至少保留一个额度窗口"))
            }
            InsetDivider()
            PrefsRow(label: "Play sound", chinese: "播放声音", detail: quotaAlertSoundDetail) {
                Toggle(tr("Play sound", "播放声音"), isOn: Binding(
                    get: { settings.quotaAlertSoundEnabled },
                    set: { enabled in
                        settings.quotaAlertSoundEnabled = enabled
                        service.settingsChanged()
                        if enabled { Task { await service.requestPermissionIfNeeded() } }
                    }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.green)
                .disabled(!settings.quotaAlertsEnabled)
            }
        }
        .task { _ = await service.refreshPermission() }
    }

    private var quotaAlertDetail: AnyView? {
        let service = appState.quotaNotifications
        guard service.statusText != nil || quotaNotificationSettingsOpened else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            if let status = service.statusText {
                Text(status).foregroundStyle(.orange)
            }
            if SettingsStore.shared.quotaAlertsEnabled {
                if service.permissionState?.canSubmit == false || service.authorizationFailed {
                    Button(tr("Open notification settings", "打开系统通知设置")) {
                        // 只用通知页面入口；不把未公开的 bundle 详情深链视为稳定协议。
                        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                        if !NSWorkspace.shared.open(url) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                        }
                        quotaNotificationSettingsOpened = true
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if service.permissionState?.authorization == .notDetermined || service.authorizationFailed || service.permissionReadFailed {
                    Button(tr("Retry permission request", "重试申请权限")) {
                        Task { await service.requestPermissionIfNeeded() }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(service.isRequestingAuthorization)
                }
            }
            if service.storagePaused {
                Button(tr("Rebuild alert history", "重建提醒记录")) { showQuotaAlertRebuildConfirm = true }
                    .buttonStyle(.bordered).controlSize(.small).disabled(service.isRebuilding)
            }
            if quotaNotificationSettingsOpened {
                Text(tr("Select CCBar in the notification list.", "在通知列表中选择 CCBar"))
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size: 11)))
    }

    private var quotaAlertSoundDetail: AnyView? {
        let settings = SettingsStore.shared
        guard settings.quotaAlertsEnabled, settings.quotaAlertSoundEnabled,
              appState.quotaNotifications.permissionState?.sound == false else { return nil }
        return AnyView(Text(tr("Notification sounds are disabled in System Settings.", "系统设置未允许通知声音"))
            .font(.system(size: 11)).foregroundStyle(.secondary))
    }

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

    /// 按用户自定义 Provider 顺序组装服务行，再接仅有用量的 Pi / OpenCode / DSH。
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
    /// 「原历史保留」与下一步。手动重算只会因来源读取不完整或写盘失败被拒。
    private func rebuildOutcomeHint(_ outcome: UsageRebuildOutcome?) -> String? {
        switch outcome {
        case .rejectedUsageChanged:
            // 只有受限恢复的核对会产生，forceRescan 会把它转成 `.restrictedRecoveryRejected`。
            return tr(
                "Not applied: recalculated usage did not match existing data. Existing data kept.",
                "未生效：重算结果与已有数据不一致，原数据未改动"
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
        case .replaced, .recoveredFromRestrictedHistory, .none:
            // 周期用量与重建前不同是预期结果（以现有日志为准），不再单独提示。
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

    private var updateButtonTitle: String {
        updater.hasUpdate || updater.isWorking
            ? tr("View update", "查看更新")
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
    /// 左侧重排抓手列。
    static let handleWidth: CGFloat = 16
    /// 手柄与服务 tile 的间距。列宽加宽后把间距从 10 收到 6，名称起点仍是 78pt。
    static let handleGap: CGFloat = 6
    static let tileSize: CGFloat = 28
    static let tileGap: CGFloat = 12
    /// 名称文字起点：内边距 + 手柄列 + 手柄间距 + tile + tile 间距。分隔线从这里开始。
    static let textLeading: CGFloat = leadingPadding + handleWidth + handleGap + tileSize + tileGap
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
    /// 左侧重排抓手的抬起态；拖动手势由列表挂在整行上。
    var isReorderLifted = false

    private var isEnabled: Bool { entry.isEnabled.wrappedValue }

    var body: some View {
        HStack(spacing: 0) {
            reorderHandle
                .frame(width: ServiceRowMetrics.handleWidth)
                .padding(.trailing, ServiceRowMetrics.handleGap)

            ServiceTile(
                logoName: entry.logoName,
                fallback: entry.fallback,
                tint: entry.tint,
                size: ServiceRowMetrics.tileSize,
                logoSize: 18,
                cornerRadius: 7.5
            )
            .opacity(entry.isDetected ? 1 : 0.45)
            .padding(.trailing, ServiceRowMetrics.tileGap)

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

    private var reorderHandle: some View {
        ReorderGrip(isLifted: isReorderLifted)
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

// MARK: - Reorder chrome
//
// 列表内拖动重排（Safari 标签页、控制中心那种）：整行起拖，抬起的就是这一行本身，
// 从原位置 1:1 跟手上下移动，越过相邻行中线时相邻行滑开让位，松手后落进空位再写入顺序。
// 拖动中不改布局和数据，只改每行的纵向偏移，位置只按指针算，所以不会闪。

/// 交给行的拖动入口：是否抬起，以及挂在行上的拖动手势（固定行为 nil）。
struct ReorderRowState {
    var isLifted: Bool
    var gesture: AnyGesture<DragGesture.Value>?
}

extension View {
    /// 把行设为拖动起点。行内的按钮、开关、菜单优先响应自己的点击，不触发拖动。
    func reorderDragSource(_ state: ReorderRowState) -> some View {
        contentShape(Rectangle())
            .gesture(
                state.gesture ?? AnyGesture(DragGesture().map { $0 }),
                including: state.gesture == nil ? .subviews : .all
            )
    }
}

private struct ReorderFramesKey: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 可拖动重排的纵向列表。前 `movableCount` 行可拖（需连续排在前面），其后是固定行。
/// 行之间的分隔线由列表画在每行顶部，跟着行一起移动。
struct ReorderableStack<ID: Hashable, Row: View>: View {
    let ids: [ID]
    let movableCount: Int
    var dividerLeading: CGFloat
    /// 第一行顶部也画分隔线（子列表要和上面的主行分开）。
    var dividesFirstRow = false
    /// 松手落位后调用，传入可拖行的新顺序；顺序没变时不调用。
    let onMove: (_ moved: ID, _ newOrder: [ID]) -> Void
    @ViewBuilder let row: (ID, ReorderRowState) -> Row

    private enum Phase { case dragging, settling, cancelling }

    private struct Session {
        var id: ID
        var from: Int
        var order: [ID]
        var frames: [ID: CGRect]
        var phase: Phase
    }

    /// 回到已越过的中线以内 2pt 才换回去，指针停在中线附近不会来回跳。
    private static var hysteresis: CGFloat { 2 }
    /// 松手位置离开列表超过这个距离，视为取消。
    private static var cancelMargin: CGFloat { 40 }

    @State private var space = UUID()
    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var stackSize: CGSize = .zero
    @State private var session: Session?
    @State private var dragOffset: CGFloat = 0
    @State private var target = 0
    @State private var liftedID: ID?
    @State private var ignoresCurrentGesture = false
    @State private var keyMonitor: Any?
    @GestureState private var gestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let movable = index < movableCount
                row(id, ReorderRowState(
                    isLifted: liftedID == id,
                    gesture: movable ? dragGesture(for: id) : nil
                ))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, dividerLeading)
                        .opacity(showsDivider(id, index: index) ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ReorderFramesKey.self,
                            value: [AnyHashable(id): geo.frame(in: .named(space))]
                        )
                    }
                }
                .background { liftedCard.opacity(liftedID == id ? 1 : 0) }
                .offset(y: offset(for: id, index: index))
                .zIndex(session?.id == id ? 1 : 0)
            }
        }
        .coordinateSpace(name: space)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { stackSize = geo.size }
                    .onChange(of: geo.size) { _, size in stackSize = size }
            }
        }
        .onPreferenceChange(ReorderFramesKey.self) { measured in
            // 拖动中用起拖时记下的位置，不跟着偏移刷新。
            if session == nil { frames = measured }
        }
        // 嵌套的子列表把自己的位置留在内部，不往外层列表冒。
        .transformPreference(ReorderFramesKey.self) { $0 = [:] }
        .onChange(of: gestureActive) { _, active in
            guard !active else { return }
            // 手势被系统中途取消时没有 onEnded，下一轮还在拖动就按取消处理。
            DispatchQueue.main.async {
                if session?.phase == .dragging { cancel() }
                ignoresCurrentGesture = false
            }
        }
        .onDisappear {
            removeKeyMonitor()
            if session != nil { ReorderCursor.shared.dragging = false }
        }
    }

    /// 抬起的行：与设置卡片同色的实底、8pt 圆角、很浅的阴影；不缩放、不变色。
    private var liftedCard: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.background)
            .overlay(PanelBackground().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 8, y: 2)
    }

    // MARK: 布局

    private func offset(for id: ID, index: Int) -> CGFloat {
        guard let s = session, index < movableCount, let i = s.order.firstIndex(of: id) else { return 0 }
        if id == s.id { return dragOffset }
        let height = s.frames[s.id]?.height ?? 0
        if s.from < target, i > s.from, i <= target { return -height }
        if s.from > target, i >= target, i < s.from { return height }
        return 0
    }

    /// 分隔线按眼下看到的顺序画：最上面一行不画，抬起的行不画。
    private func showsDivider(_ id: ID, index: Int) -> Bool {
        if liftedID == id { return false }
        if dividesFirstRow { return true }
        guard let s = session, index < movableCount else { return index > 0 }
        var visual = s.order
        visual.remove(at: s.from)
        visual.insert(s.id, at: target)
        return visual.firstIndex(of: id) != 0
    }

    private func clampedOffset(_ raw: CGFloat, _ s: Session) -> CGFloat {
        guard let f = s.frames[s.id],
              let first = s.order.first.flatMap({ s.frames[$0] }),
              let last = s.order.last.flatMap({ s.frames[$0] }) else { return 0 }
        return min(max(raw, first.minY - f.minY), last.maxY - f.maxY)
    }

    /// 被拖行的上沿越过上面某行中线、或下沿越过下面某行中线，就插到那一行的位置。
    private func insertionIndex(for offset: CGFloat, _ s: Session) -> Int {
        guard let f = s.frames[s.id] else { return s.from }
        let top = f.minY + offset
        let bottom = f.maxY + offset
        var result = s.from
        for i in stride(from: s.from - 1, through: 0, by: -1) {
            guard let mid = s.frames[s.order[i]]?.midY else { break }
            let shifted = target <= i
            if top < mid + (shifted ? Self.hysteresis : 0) { result = i } else { break }
        }
        guard result == s.from else { return result }
        for i in (s.from + 1)..<s.order.count {
            guard let mid = s.frames[s.order[i]]?.midY else { break }
            let shifted = target >= i
            if bottom > mid - (shifted ? Self.hysteresis : 0) { result = i } else { break }
        }
        return result
    }

    private func slotOffset(_ s: Session) -> CGFloat {
        guard let f = s.frames[s.id] else { return 0 }
        if target < s.from, let r = s.frames[s.order[target]] { return r.minY - f.minY }
        if target > s.from, let r = s.frames[s.order[target]] { return r.maxY - f.maxY }
        return 0
    }

    // MARK: 手势

    private func dragGesture(for id: ID) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in dragChanged(id, value) }
                .onEnded { value in dragEnded(value) }
        )
    }

    private func dragChanged(_ id: ID, _ value: DragGesture.Value) {
        if ignoresCurrentGesture { return }
        if session == nil, !begin(id) {
            ignoresCurrentGesture = true
            return
        }
        // 上一次还在落位时按下的新拖动，整轮忽略。
        guard let s = session, s.phase == .dragging, s.id == id else {
            ignoresCurrentGesture = true
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { dragOffset = clampedOffset(value.translation.height, s) }
        let next = insertionIndex(for: dragOffset, s)
        if next != target {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { target = next }
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if ignoresCurrentGesture {
            ignoresCurrentGesture = false
            return
        }
        guard session?.phase == .dragging else { return }
        let bounds = CGRect(origin: .zero, size: stackSize)
            .insetBy(dx: -Self.cancelMargin, dy: -Self.cancelMargin)
        if bounds.contains(value.location) {
            settle()
        } else {
            cancel()
        }
    }

    private func begin(_ id: ID) -> Bool {
        let order = Array(ids.prefix(movableCount))
        guard let from = order.firstIndex(of: id) else { return false }
        var snapshot: [ID: CGRect] = [:]
        for item in order {
            guard let rect = frames[AnyHashable(item)] else { return false }
            snapshot[item] = rect
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            session = Session(id: id, from: from, order: order, frames: snapshot, phase: .dragging)
            target = from
            dragOffset = 0
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { liftedID = id }
        ReorderCursor.shared.dragging = true
        installKeyMonitor()
        return true
    }

    /// 松手：从当前位置落进空位，阴影同时淡出；落定后再写入新顺序。
    private func settle() {
        guard var s = session else { return }
        s.phase = .settling
        session = s
        removeKeyMonitor()
        ReorderCursor.shared.dragging = false
        if reduceMotion {
            commit()
            return
        }
        withAnimation(.smooth(duration: 0.2), completionCriteria: .removed) {
            dragOffset = slotOffset(s)
            liftedID = nil
        } completion: {
            commit()
        }
    }

    /// 取消（Esc、列表外松手、手势被打断）：滑回原位，顺序不变。
    private func cancel() {
        guard var s = session else { return }
        s.phase = .cancelling
        session = s
        removeKeyMonitor()
        ReorderCursor.shared.dragging = false
        if reduceMotion {
            reset()
            return
        }
        withAnimation(.smooth(duration: 0.2), completionCriteria: .removed) {
            dragOffset = 0
            target = s.from
            liftedID = nil
        } completion: {
            if session?.phase == .cancelling { reset() }
        }
    }

    /// 写入顺序和清掉偏移放在同一帧、不加动画：数据重排后的位置正好等于落位的位置，画面不跳。
    private func commit() {
        guard let s = session, s.phase == .settling else { return }
        var order = s.order
        order.remove(at: s.from)
        order.insert(s.id, at: target)
        let moved = target != s.from
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if moved { onMove(s.id, order) }
            clearSession()
        }
    }

    private func reset() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { clearSession() }
    }

    private func clearSession() {
        session = nil
        dragOffset = 0
        target = 0
        liftedID = nil
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53, session?.phase == .dragging else { return event }
            ignoresCurrentGesture = true
            cancel()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// 重排抓手：拖动的提示，拖动手势挂在整行上。悬停是张开的手，避免被看成可点击按钮。
struct ReorderGrip: View {
    var isLifted: Bool

    @State private var hovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering || isLifted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                ReorderCursor.shared.hoveringGrip = inside
            }
            .onDisappear {
                if hovering { ReorderCursor.shared.hoveringGrip = false }
            }
            .help(tr("Drag to reorder", "拖动以排序"))
            .accessibilityHidden(true)
    }
}

/// 重排光标：悬停抓手是张开的手，拖动中是抓紧的手。全局只压一层，避免两种手叠在光标栈上。
final class ReorderCursor {
    static let shared = ReorderCursor()

    private enum Kind {
        case open
        case closed
    }

    var hoveringGrip = false {
        didSet { update() }
    }

    var dragging = false {
        didSet {
            // 拖动中收不到抓手的移出事件，松手后先按不在抓手上处理。
            if !dragging { hoveringGrip = false }
            update()
        }
    }

    private var pushed: Kind?

    private func update() {
        let next: Kind? = dragging ? .closed : (hoveringGrip ? .open : nil)
        guard next != pushed else { return }
        if pushed != nil { NSCursor.pop() }
        switch next {
        case .open: NSCursor.openHand.push()
        case .closed: NSCursor.closedHand.push()
        case nil: break
        }
        pushed = next
    }
}
