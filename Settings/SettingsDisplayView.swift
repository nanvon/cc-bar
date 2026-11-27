import SwiftUI

// MARK: - Display & Privacy View

struct SettingsDisplayView: View {
    let settings: SettingsStore
    let highlightedSection: String?
    let onNavigateToServices: () -> Void

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .display)

            // 菜单栏
            SettingsCard(
                title: "Menu Bar",
                chinese: "菜单栏",
                isHighlighted: highlightedSection == "display-menubar"
            ) {
                SettingsRow(
                    label: "Quota period",
                    chinese: "额度周期",
                    desc: "Choose which quota window appears alongside agent icons in the menu bar.",
                    chineseDesc: "选择菜单栏图标旁展示的额度窗口"
                ) {
                    Picker("", selection: $settings.menuBarWindow) {
                        Text(tr("Main", "主额度")).tag(MenuBarWindowChoice.primary)
                        Text(tr("Weekly", "周额度")).tag(MenuBarWindowChoice.weekly)
                        Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            // 弹出面板
            SettingsCard(
                title: "Popover",
                chinese: "弹出面板",
                isHighlighted: highlightedSection == "display-popover"
            ) {
                SettingsRow(
                    label: "Official status dot",
                    chinese: "官方状态圆点",
                    desc: "Show live operational status indicators next to agent names.",
                    chineseDesc: "在 Agent 名称旁显示官方运行状态圆点"
                ) {
                    Toggle("", isOn: $settings.showServiceStatus)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Recent conversations",
                    chinese: "最近对话",
                    desc: "Conversations active today, sorted by most recent activity.",
                    chineseDesc: "今天有活动的对话，按最近活动时间排序"
                ) {
                    HStack(spacing: 10) {
                        if settings.showRecentConversations {
                            Picker("", selection: $settings.recentConversationLimit) {
                                ForEach(Array(SettingsStore.recentConversationLimitRange), id: \.self) { count in
                                    Text(tr("\(count)", "\(count) 条")).tag(count)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: SettingsLayout.compactMenuPickerWidth)
                            .help(tr("Maximum shown", "最多显示条数"))
                        }
                        Toggle("", isOn: $settings.showRecentConversations)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    label: "Show email in popover",
                    chinese: "弹出面板显示邮箱",
                    desc: "Always hidden while privacy mode is enabled.",
                    chineseDesc: "开启隐私模式时始终隐藏"
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.popoverShowsEmail && !settings.privacyMode },
                        set: { settings.popoverShowsEmail = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(settings.privacyMode)
                }
            }

            // 桌面悬浮窗
            SettingsCard(
                title: "Floating HUD",
                chinese: "桌面悬浮窗",
                isHighlighted: highlightedSection == "display-floating"
            ) {
                SettingsRow(
                    label: "Show floating window",
                    chinese: "显示桌面悬浮窗",
                    desc: "Keep an always-on-top mini quota bar visible on your desktop.",
                    chineseDesc: "在桌面置顶显示精简额度条，具体显示哪些 Agent 可在「Agent 与账号」中勾选"
                ) {
                    HStack(spacing: 10) {
                        Button(tr("Manage Agents", "管理 Agent")) {
                            onNavigateToServices()
                        }
                        .buttonStyle(.bordered)
                        .focusEffectDisabled()

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
            }

            // 时间与隐私
            SettingsCard(
                title: "Time & Privacy",
                chinese: "时间与隐私",
                isHighlighted: highlightedSection == "display-privacy"
            ) {
                SettingsRow(
                    label: "Reset time format",
                    chinese: "重置时间格式",
                    desc: "Hovering any reset label still reveals the alternate format.",
                    chineseDesc: "悬停任意重置时间标签时仍可查看另一种格式"
                ) {
                    Picker("", selection: $settings.resetTimeDisplay) {
                        Text(tr("Remaining", "剩余时长")).tag(ResetTimeDisplay.relative)
                        Text(tr("Exact time", "具体时间")).tag(ResetTimeDisplay.absolute)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(
                    label: "Privacy mode",
                    chinese: "隐私模式",
                    desc: "Hide account emails, project names and conversation titles for screenshots. Usage numbers remain visible.",
                    chineseDesc: "隐藏账号邮箱、项目名和对话标题，用量数字照常显示，方便截图分享"
                ) {
                    Toggle("", isOn: $settings.privacyMode)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }
        }
    }
}

