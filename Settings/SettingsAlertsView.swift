import AppKit
import SwiftUI

// MARK: - Quota Alerts View

struct SettingsAlertsView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore
    let highlightedSection: String?
    @Binding var showRebuildConfirm: Bool
    @Binding var notificationSettingsOpened: Bool

    var body: some View {
        @Bindable var settings = settings
        let service = appState.quotaNotifications

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .alerts)

            // 权限 / 存储异常横幅
            if service.statusText != nil || notificationSettingsOpened {
                permissionCallout(settings: settings)
            }

            // 总开关与阈值
            SettingsCard(
                title: "Low Quota Alert",
                chinese: "低额度提醒",
                desc: "Checks enabled quota services and imported Codex accounts after each successful refresh.",
                chineseDesc: "包含已启用的额度服务和导入的 Codex 账号，每次成功刷新后检查",
                isHighlighted: highlightedSection == "alerts-main"
            ) {
                SettingsRow(
                    label: "Enable quota alerts",
                    chinese: "开启额度提醒",
                    desc: "Send a macOS notification when remaining quota drops below the threshold.",
                    chineseDesc: "剩余额度跌破设定阈值时发送系统通知"
                ) {
                    Toggle(tr("Enable quota alerts", "开启额度提醒"), isOn: Binding(
                        get: { settings.quotaAlertsEnabled },
                        set: { enabled in
                            settings.quotaAlertsEnabled = enabled
                            if enabled { Task { await service.requestPermissionIfNeeded() } }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                }

                SettingsDivider()

                // 阈值滑块
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(tr("Alert threshold", "触发阈值"))
                                .font(.system(size: 13))
                            Text(tr("Notify once when remaining quota falls below this level", "剩余额度低于此百分比时触发一次提醒"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("< \(settings.quotaAlertThresholdPercent)%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                settings.quotaAlertsEnabled
                                    ? (settings.quotaAlertThresholdPercent <= 10 ? SettingsSemanticTone.danger.foreground : .primary)
                                    : .secondary
                            )
                    }

                    HStack(spacing: 12) {
                        Text("5%")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()

                        Slider(
                            value: Binding(
                                get: { Double(settings.quotaAlertThresholdPercent) },
                                set: { newVal in
                                    let snapped = Int((newVal / 5.0).rounded()) * 5
                                    let clamped = min(max(snapped, 5), 50)
                                    if clamped != settings.quotaAlertThresholdPercent {
                                        settings.quotaAlertThresholdPercent = clamped
                                        service.settingsChanged()
                                    }
                                }
                            ),
                            in: 5...50,
                            step: 5
                        )
                        .disabled(!settings.quotaAlertsEnabled)

                        Text("50%")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
                .opacity(settings.quotaAlertsEnabled ? 1 : 0.48)
            }

            // 监听的额度窗口
            SettingsCard(
                title: "Monitored Windows",
                chinese: "提醒范围",
                desc: "Keep at least one quota window selected.",
                chineseDesc: "至少保留一个处于开启状态的额度窗口",
                isHighlighted: highlightedSection == "alerts-windows"
            ) {
                SettingsRow(
                    label: "5-hour / session quota",
                    chinese: "5 小时／会话额度",
                    desc: "Short-term rolling window for Codex, Claude Code and Antigravity.",
                    chineseDesc: "Codex、Claude Code、Antigravity 等短期滚动窗口"
                ) {
                    Toggle(tr("5-hour / session quota", "5 小时／会话额度"), isOn: Binding(
                        get: { settings.quotaAlertFiveHourEnabled },
                        set: { settings.quotaAlertFiveHourEnabled = $0; service.settingsChanged() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.quotaAlertsEnabled || (!settings.quotaAlertWeeklyEnabled && !settings.quotaAlertBillingCycleEnabled))
                    .help(tr("Keep at least one quota window selected.", "至少保留一个额度窗口"))
                }

                SettingsDivider()

                SettingsRow(
                    label: "Weekly quota",
                    chinese: "周额度",
                    desc: "Includes model-specific weekly quotas.",
                    chineseDesc: "包含模型专属周额度"
                ) {
                    Toggle(tr("Weekly quota", "周额度"), isOn: Binding(
                        get: { settings.quotaAlertWeeklyEnabled },
                        set: { settings.quotaAlertWeeklyEnabled = $0; service.settingsChanged() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.quotaAlertsEnabled || (!settings.quotaAlertFiveHourEnabled && !settings.quotaAlertBillingCycleEnabled))
                    .help(tr("Keep at least one quota window selected.", "至少保留一个额度窗口"))
                }

                SettingsDivider()

                SettingsRow(
                    label: "Billing cycle quota",
                    chinese: "计费周期额度",
                    desc: "Cursor Total / Auto / API, and Command Code and OpenCode Go monthly quotas.",
                    chineseDesc: "Cursor Total／Auto／API，以及 Command Code、OpenCode Go 月额度"
                ) {
                    Toggle(tr("Billing cycle quota", "计费周期额度"), isOn: Binding(
                        get: { settings.quotaAlertBillingCycleEnabled },
                        set: { settings.quotaAlertBillingCycleEnabled = $0; service.settingsChanged() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.quotaAlertsEnabled || (!settings.quotaAlertFiveHourEnabled && !settings.quotaAlertWeeklyEnabled))
                    .help(tr("Keep at least one quota window selected.", "至少保留一个额度窗口"))
                }

                SettingsDivider()

                SettingsRow(
                    label: "Play sound",
                    chinese: "播放提示音",
                    detail: soundDisabledDetail(settings: settings)
                ) {
                    Toggle(tr("Play sound", "播放声音"), isOn: Binding(
                        get: { settings.quotaAlertSoundEnabled },
                        set: { enabled in
                            settings.quotaAlertSoundEnabled = enabled
                            service.settingsChanged()
                            if enabled { Task { await service.requestPermissionIfNeeded() } }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.quotaAlertsEnabled)
                }
            }
            .opacity(settings.quotaAlertsEnabled ? 1 : 0.6)
        }
        .task { _ = await service.refreshPermission() }
    }

    @ViewBuilder
    private func permissionCallout(settings: SettingsStore) -> some View {
        let service = appState.quotaNotifications
        SettingsCallout(
            tone: service.statusText != nil ? .warning : .accent,
            icon: service.statusText != nil ? "exclamationmark.triangle.fill" : "info.circle.fill",
            title: service.statusText ?? tr("System notification settings opened", "已打开系统通知设置"),
            message: notificationSettingsOpened
                ? tr("Select CCBar in the notification list to enable banners and sounds.", "请在系统通知列表中选择 CCBar 并开启通知权限。")
                : nil
        ) {
            HStack(spacing: 8) {
                if settings.quotaAlertsEnabled {
                    if service.permissionState?.canSubmit == false || service.authorizationFailed {
                        Button(tr("Open Notification Settings", "打开系统通知设置")) {
                            let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                            if !NSWorkspace.shared.open(url) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                            }
                            notificationSettingsOpened = true
                        }
                        .buttonStyle(.bordered)
                    }
                    if service.permissionState?.authorization == .notDetermined || service.authorizationFailed || service.permissionReadFailed {
                        Button(tr("Retry Permission Request", "重试申请权限")) {
                            Task { await service.requestPermissionIfNeeded() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isRequestingAuthorization)
                    }
                }
                if service.storagePaused {
                    Button(tr("Rebuild Alert History", "重建提醒记录")) {
                        showRebuildConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isRebuilding)
                }
            }
            .padding(.top, 4)
        }
    }

    private func soundDisabledDetail(settings: SettingsStore) -> AnyView? {
        let service = appState.quotaNotifications
        guard settings.quotaAlertsEnabled,
              settings.quotaAlertSoundEnabled,
              service.permissionState?.sound == false
        else { return nil }
        return AnyView(
            Text(tr("Notification sounds are disabled in System Settings.", "系统设置中未允许通知声音"))
                .font(.system(size: 11))
                .foregroundStyle(SettingsSemanticTone.warning.foreground)
        )
    }
}
