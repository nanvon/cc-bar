import AppKit
import SwiftUI

// MARK: - Refresh & Network View

struct SettingsNetworkView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore
    let highlightedSection: String?

    var body: some View {
        @Bindable var settings = settings
        let claudePaused = settings.proxyMode == .system && settings.claudeProxyMode == .global

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .network) {
                Button {
                    Task { await appState.refreshQuotas(reason: .userInitiated) }
                } label: {
                    HStack(spacing: 5) {
                        if appState.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(tr("Refresh Now", "立即刷新"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.isRefreshing)
            }

            // 精简状态条（替代原三格仪表盘卡片）
            networkStatusBar(settings: settings, claudePaused: claudePaused)

            // 后台刷新频率
            SettingsCard(
                title: "Background Polling",
                chinese: "后台刷新频率",
                isHighlighted: highlightedSection == "network-polling"
            ) {
                SettingsRow(
                    label: "Quota refresh interval",
                    chinese: "额度刷新间隔",
                    desc: "How often CCBar fetches remaining quota from enabled agents.",
                    chineseDesc: "向已启用的 Agent 查询剩余额度的轮询周期"
                ) {
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
                    .frame(width: SettingsLayout.menuPickerWidth)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Log scan interval",
                    chinese: "本机日志扫描间隔",
                    desc: "How often local conversation logs are scanned for token and cost usage.",
                    chineseDesc: "扫描本机对话日志并更新 Token 与费用统计的周期"
                ) {
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
                    .frame(width: SettingsLayout.menuPickerWidth)
                }
            }
            .id("network-polling")

            // 全局网络代理
            SettingsCard(
                title: "Global Proxy",
                chinese: "全局网络代理",
                isHighlighted: highlightedSection == "network-proxy"
            ) {
                SettingsRow(
                    label: "Proxy mode",
                    chinese: "代理方式",
                    desc: settings.proxyMode == .manual
                        ? "If the proxy is unavailable, requests stop instead of falling back to direct connections."
                        : "Uses macOS system network proxy settings.",
                    chineseDesc: settings.proxyMode == .manual
                        ? "代理不可用时停止取数，不会自动回退为直连"
                        : "沿用 macOS 系统网络代理配置"
                ) {
                    Picker(tr("Proxy", "代理"), selection: $settings.proxyMode) {
                        ForEach(ProxyMode.allCases) { mode in
                            Text(mode.bilingualDisplayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                if settings.proxyMode == .manual {
                    proxyFields(type: $settings.proxyType, host: $settings.proxyHost, port: $settings.proxyPort)
                    let resolution = settings.proxyResolution
                    SettingsDivider()
                    ProxyConnectionTestRow(resolution: resolution, forClaude: false)
                        .id(resolution)
                }
            }
            .id("network-proxy")

            // Claude 专用代理
            SettingsCard(
                title: "Claude Proxy Routing",
                chinese: "Claude 独立代理",
                desc: "Protect Claude requests from accidental direct connections.",
                chineseDesc: "单独控制 Claude 请求的网络出口，避免误走直连",
                isHighlighted: highlightedSection == "network-proxy"
            ) {
                SettingsRow(
                    label: "Claude route",
                    chinese: "Claude 代理策略",
                    desc: settings.claudeProxyMode == .direct
                        ? "Claude requests connect directly without using any proxy."
                        : "Prevents direct connections to Anthropic servers.",
                    chineseDesc: settings.claudeProxyMode == .direct
                        ? "Claude 请求将直接连接，不经过任何代理"
                        : "禁止直连 Anthropic 服务"
                ) {
                    Picker(tr("Claude proxy", "Claude 代理"), selection: Binding(
                        get: { settings.claudeProxyMode },
                        set: { mode in
                            if mode == .direct, settings.claudeProxyMode != .direct {
                                guard confirmClaudeDirectConnection() else { return }
                            }
                            settings.claudeProxyMode = mode
                        }
                    )) {
                        Text(tr("Global Manual", "沿用全局")).tag(ClaudeProxyMode.global)
                        Text(tr("Dedicated", "单独配置")).tag(ClaudeProxyMode.dedicated)
                        Text(tr("Direct", "直连")).tag(ClaudeProxyMode.direct)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .focusEffectDisabled()
                }

                if claudePaused {
                    SettingsCallout(
                        tone: .warning,
                        icon: "pause.circle.fill",
                        title: tr("Claude refresh is paused", "Claude 刷新当前已暂停"),
                        message: tr(
                            "Global proxy is set to Follow System. Switch Global Proxy to Manual or configure a Dedicated proxy for Claude.",
                            "当前全局代理为「跟随系统」。请将全局代理改为「手动配置」，或为 Claude 选择「单独配置」。"
                        )
                    )
                    .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
                    .padding(.bottom, 12)
                }

                if settings.claudeProxyMode == .dedicated {
                    proxyFields(
                        type: $settings.claudeProxyType,
                        host: $settings.claudeProxyHost,
                        port: $settings.claudeProxyPort,
                        forClaude: true
                    )
                }

                if settings.claudeProxyMode != .global || settings.proxyMode == .manual {
                    let resolution = settings.claudeProxyResolution
                    SettingsDivider()
                    ProxyConnectionTestRow(resolution: resolution, forClaude: true)
                        .id(resolution)
                }
            }
        }
    }

    // MARK: - Status Bar

    private func networkStatusBar(settings: SettingsStore, claudePaused: Bool) -> some View {
        HStack(spacing: 14) {
            statusCell(
                label: tr("Last Refresh", "上次刷新"),
                value: lastRefreshText,
                tone: appState.isRefreshing ? .accent : .neutral
            )

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5, height: 22)

            statusCell(
                label: tr("Global Proxy", "全局代理"),
                value: settings.proxyMode == .manual
                    ? "\(settings.proxyType == .http ? "HTTP" : "SOCKS5") \(settings.proxyHost.isEmpty ? "—" : settings.proxyHost)"
                    : tr("Follow System", "跟随系统"),
                tone: .neutral
            )

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5, height: 22)

            statusCell(
                label: tr("Claude Route", "Claude 路由"),
                value: claudeRouteLabel(settings: settings, paused: claudePaused),
                tone: claudePaused ? .warning : (settings.claudeProxyMode == .direct ? .danger : .neutral)
            )
        }
        .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
        .padding(.vertical, 12)
        .ccPanel(cornerRadius: 12)
    }

    private func statusCell(label: String, value: String, tone: SettingsSemanticTone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone == .warning || tone == .danger || tone == .accent ? tone.foreground : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func claudeRouteLabel(settings: SettingsStore, paused: Bool) -> String {
        if paused { return tr("Paused (manual needed)", "已暂停（需手动代理）") }
        switch settings.claudeProxyMode {
        case .global: return tr("Global Manual", "沿用全局手动")
        case .dedicated:
            let host = settings.claudeProxyHost.isEmpty ? "—" : settings.claudeProxyHost
            return "\(settings.claudeProxyType == .http ? "HTTP" : "SOCKS5") \(host)"
        case .direct: return tr("Direct (no proxy)", "直连（无代理）")
        }
    }

    // MARK: - Proxy Fields

    @ViewBuilder
    private func proxyFields(
        type: Binding<ProxyType>,
        host: Binding<String>,
        port: Binding<Int>,
        forClaude: Bool = false
    ) -> some View {
        SettingsDivider()
        SettingsRow(
            label: "Endpoint",
            chinese: "代理地址",
            desc: "Protocol, hostname/IP and port.",
            chineseDesc: "选择协议并填写主机名或 IP 与端口"
        ) {
            HStack(spacing: 6) {
                Picker(forClaude ? tr("Claude proxy type", "Claude 代理类型") : tr("Proxy type", "代理类型"),
                       selection: type) {
                    Text("HTTP").tag(ProxyType.http)
                    Text("SOCKS5").tag(ProxyType.socks5)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
                .focusEffectDisabled()

                TextField(tr("Host", "主机"), text: Binding(
                    get: { host.wrappedValue },
                    set: { host.wrappedValue = $0.trimmingCharacters(in: .whitespaces) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 136)

                Text(":")
                    .foregroundStyle(.secondary)

                TextField(tr("Port", "端口"), text: Binding(
                    get: { port.wrappedValue == 0 ? "" : String(port.wrappedValue) },
                    set: { port.wrappedValue = Int(String($0.filter(\.isASCII).filter(\.isNumber).prefix(5))) ?? 0 }
                ))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 66)
            }
        }
    }

    private func confirmClaudeDirectConnection() -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("Set Claude requests to connect directly?", "确定将 Claude 请求设为直连？")
        alert.informativeText = tr(
            "Make sure your network can connect to Claude directly without risk. Claude requests will not use any proxy, including the system proxy.",
            "请确保您的网络支持无风险直连 Claude。直连时 Claude 请求不经过任何代理，也不读取系统代理。"
        )
        alert.alertStyle = .critical
        alert.addButton(withTitle: tr("Connect Directly", "设为直连"))
        alert.addButton(withTitle: tr("Cancel", "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var lastRefreshText: String {
        let latest = QuotaApp.allCases.compactMap {
            appState.refreshState(for: $0).lastSuccessAt
        }.max()
        guard let latest else { return "—" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(timeFormatter.string(from: latest)) · \(PopoverRootView.relativeAge(from: latest))\(tr(" ago", "前"))"
    }
}

// MARK: - Proxy Connection Test Row

private struct ProxyConnectionTestRow: View {
    let resolution: ProxyResolution
    let forClaude: Bool

    @State private var isTesting = false
    @State private var result: Result<Void, QuotaError>?

    var body: some View {
        SettingsRow(
            label: forClaude ? "Claude connection test" : "Connection test",
            chinese: forClaude ? "Claude 连接测试" : "连接测试"
        ) {
            HStack(spacing: 8) {
                switch result {
                case .success:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(forClaude ? tr("Claude API reachable", "Claude API 可达") : tr("Connected", "可连接"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(SettingsSemanticTone.success.foreground)
                case .failure(let error):
                    Text(failureMessage(error))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsSemanticTone.danger.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                case nil:
                    EmptyView()
                }
                Button {
                    result = nil
                    isTesting = true
                    Task {
                        result = await NetworkProxy.testConnection(using: resolution, forClaude: forClaude)
                        isTesting = false
                    }
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(tr("Test", "测试连接"))
                    }
                }
                .buttonStyle(.bordered)
                .focusable(false)
                .disabled(isTesting)
            }
        }
    }

    private func failureMessage(_ error: QuotaError) -> String {
        if forClaude, case .http(let code, _) = error {
            if error.looksLikeInterceptedResponse { return error.userMessage(using: resolution) }
            return tr("Unexpected Claude API response (HTTP \(code))", "Claude API 返回异常响应（HTTP \(code)）")
        }
        if case .network(.tls) = error {
            return tr(
                "Secure connection failed — the proxy's certificate may not be trusted by the system",
                "安全连接失败，代理的证书可能未被系统信任"
            )
        }
        if case .network(.proxyUnavailable) = error {
            switch resolution {
            case .unavailable(.manualIncomplete):
                return tr("Enter the address and port", "请填写地址和端口")
            case .unavailable(.invalidPort):
                return tr("Port must be between 1 and 65535", "端口需在 1–65535 之间")
            case .unavailable(.invalidHost):
                return tr(
                    "Enter only a hostname or IP, without http:// or a port",
                    "地址只填主机名或 IP，不带 http:// 和端口"
                )
            case .unavailable(.claudeManualRequired), .system, .direct, .proxy:
                return tr("Proxy unavailable", "代理不可用")
            }
        }
        return error.userMessage(using: resolution)
    }
}
