import AppKit
import SwiftUI

// MARK: - SettingsRootView

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    private let updater = AppUpdater.shared

    private var selectedCategory: SettingsCategory {
        get { appState.mainWindowSession.settingsCategory }
        nonmutating set { appState.mainWindowSession.settingsCategory = newValue }
    }

    @State private var searchQuery = ""
    @State private var highlightedSection: String?
    @State private var highlightClearTask: Task<Void, Never>?

    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginMessageIsError = false
    @State private var isRecalculatingUsage = false
    @State private var pricingCatalogMessage: String?
    @State private var pricingCatalogMessageIsError = false
    @State private var showCodexResetCreditsSheet = false
    @State private var showCommandCodeSheet = false
    @State private var showOpenCodeGoSheet = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?
    @State private var diagnosticsMessageIsError = false
    @State private var showDiagnosticsConfirm = false
    @State private var showQuotaAlertRebuildConfirm = false
    @State private var quotaNotificationSettingsOpened = false

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        HStack(spacing: 0) {
            sidebar(settings: settings)
            // 与侧栏材质一起延伸进标题栏，侧栏右边界从上到下是同一条线。
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            contentArea(settings: settings)
        }
        .sheet(isPresented: $showCommandCodeSheet) {
            CommandCodeCredentialSheet()
        }
        .sheet(isPresented: $showOpenCodeGoSheet) {
            OpenCodeGoCredentialSheet()
        }
        .sheet(isPresented: $showCodexResetCreditsSheet) {
            CodexResetCreditsSheet(
                accountTitle: appState.codexAccount?.email ?? "Codex",
                privacyAccountKey: "primary:codex",
                fetchCredits: { await appState.fetchCodexResetCredits() }
            )
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
        .confirmationDialog(
            tr("Rebuild alert history?", "重建提醒记录？"),
            isPresented: $showQuotaAlertRebuildConfirm,
            titleVisibility: .visible
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
                launchAtLoginMessage = tr(
                    "Approve CCBar in System Settings > General > Login Items & Extensions.",
                    "请在「系统设置 > 通用 > 登录项与扩展」中允许 CCBar。"
                )
                launchAtLoginMessageIsError = false
            } else {
                launchAtLoginMessage = nil
            }
        }
        .onDisappear {
            highlightClearTask?.cancel()
            highlightClearTask = nil
        }
    }

    // MARK: - Sidebar

    private func sidebar(settings: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarSearchField

            VStack(alignment: .leading, spacing: 18) {
                ForEach(SettingsSidebarGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(group.englishTitle, group.chineseTitle).uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.4)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)

                        ForEach(group.categories) { category in
                            sidebarItem(category: category, settings: settings)
                        }
                    }
                }
            }

            Spacer()

            sidebarFooter(settings: settings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: MainWindowLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            TextField(tr("Search settings", "搜索设置…"), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func sidebarItem(category: SettingsCategory, settings: SettingsStore) -> some View {
        let active = !isSearching && selectedCategory == category

        return Button {
            searchQuery = ""
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
                    .lineLimit(1)

                Spacer(minLength: 4)

                sidebarIndicator(for: category, settings: settings, active: active)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
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

    @ViewBuilder
    private func sidebarIndicator(for category: SettingsCategory, settings: SettingsStore, active: Bool) -> some View {
        switch category {
        case .services:
            let enabledQuotaCount = QuotaApp.allCases.filter { settings.isProviderEnabled($0) }.count
            let enabledUsageCount = ServiceOrderItem.usageOnlyApps.filter { settings.isUsageServiceVisible($0) }.count
            let total = enabledQuotaCount + enabledUsageCount
            if total > 0 {
                Text("\(total)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(active ? Color.white.opacity(0.8) : Color.secondary)
            }
        case .alerts:
            if appState.quotaNotifications.statusText != nil {
                Circle()
                    .fill(active ? Color.white : SettingsSemanticTone.warning.foreground)
                    .frame(width: 5.5, height: 5.5)
            }
        case .network:
            if settings.proxyMode == .system && settings.claudeProxyMode == .global {
                Circle()
                    .fill(active ? Color.white : SettingsSemanticTone.warning.foreground)
                    .frame(width: 5.5, height: 5.5)
            }
        case .general:
            if updater.hasUpdate {
                Circle()
                    .fill(active ? Color.white : Color.accentColor)
                    .frame(width: 5.5, height: 5.5)
            }
        case .display, .statistics:
            EmptyView()
        }
    }

    private func sidebarFooter(settings: SettingsStore) -> some View {
        @Bindable var bindable = settings
        return VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Image(systemName: settings.privacyMode ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(settings.privacyMode ? Color.accentColor : Color.secondary)
                Text(tr("Privacy Mode", "隐私模式"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Toggle(tr("Privacy Mode", "隐私模式"), isOn: $bindable.privacyMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .help(tr("Quickly hide account emails, project and conversation names for screenshots",
                     "快速隐藏账号邮箱、项目和对话名称，方便截图分享"))
        }
    }

    // MARK: - Content Area

    private func contentArea(settings: SettingsStore) -> some View {
        ScrollView {
            Group {
                if isSearching {
                    searchResultsView
                } else {
                    categoryView(settings: settings)
                }
            }
            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .id(isSearching ? "search" : selectedCategory.rawValue)
    }

    @ViewBuilder
    private func categoryView(settings: SettingsStore) -> some View {
        switch selectedCategory {
        case .services:
            SettingsServicesView(
                settings: settings,
                highlightedSection: highlightedSection,
                onOpenDisplaySettings: { jump(to: .display, section: "display-floating") },
                onShowCodexResetCredits: { showCodexResetCreditsSheet = true },
                onShowCommandCodeSheet: { showCommandCodeSheet = true },
                onShowOpenCodeGoSheet: { showOpenCodeGoSheet = true }
            )
        case .display:
            SettingsDisplayView(
                settings: settings,
                highlightedSection: highlightedSection,
                onNavigateToServices: { jump(to: .services, section: "services-detected") }
            )
        case .alerts:
            SettingsAlertsView(
                settings: settings,
                highlightedSection: highlightedSection,
                showRebuildConfirm: $showQuotaAlertRebuildConfirm,
                notificationSettingsOpened: $quotaNotificationSettingsOpened
            )
        case .statistics:
            SettingsStatisticsView(
                settings: settings,
                highlightedSection: highlightedSection,
                isRecalculatingUsage: $isRecalculatingUsage,
                pricingCatalogMessage: $pricingCatalogMessage,
                pricingCatalogMessageIsError: $pricingCatalogMessageIsError
            )
        case .network:
            SettingsNetworkView(
                settings: settings,
                highlightedSection: highlightedSection
            )
        case .general:
            SettingsGeneralView(
                settings: settings,
                updater: updater,
                highlightedSection: highlightedSection,
                launchAtLoginMessage: $launchAtLoginMessage,
                launchAtLoginMessageIsError: $launchAtLoginMessageIsError,
                isExportingDiagnostics: $isExportingDiagnostics,
                diagnosticsMessage: $diagnosticsMessage,
                diagnosticsMessageIsError: $diagnosticsMessageIsError,
                showDiagnosticsConfirm: $showDiagnosticsConfirm
            )
        }
    }

    // MARK: - Search Results View

    private var searchResultsView: some View {
        let matches = SettingsSearchCatalog.items.filter { $0.matches(searchQuery) }

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("Search Results", "搜索结果"))
                    .font(.system(size: 17, weight: .bold))
                    .kerning(-0.4)
                Text(tr("\(matches.count) found", "共 \(matches.count) 项"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(tr("Clear", "清除搜索")) {
                    searchQuery = ""
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, SettingsLayout.cardHorizontalPadding)

            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text(tr("No matching settings for \"\(searchQuery)\"", "未找到与「\(searchQuery)」相关的设置项"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(tr("Try keywords like proxy, floating, privacy, alert, pi or language.",
                            "可以尝试搜索：代理、悬浮窗、隐私、提醒、Pi、价格、日志"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .ccPanel(cornerRadius: 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { SettingsDivider() }
                        Button {
                            searchQuery = ""
                            jump(to: item.category, section: item.sectionID)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.category.icon)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, height: 16)

                                VStack(alignment: .leading, spacing: 2.5) {
                                    Text(item.localizedTitle)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary)
                                    Text(item.localizedSummary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(tr(item.category.englishTitle, item.category.chineseTitle))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointingHandCursor()
                    }
                }
                .ccPanel(cornerRadius: 12)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func jump(to category: SettingsCategory, section: String) {
        selectedCategory = category
        highlightedSection = section
        highlightClearTask?.cancel()
        highlightClearTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            highlightedSection = nil
        }
    }

    // MARK: - Diagnostics Export

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
}
