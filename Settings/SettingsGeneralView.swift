import AppKit
import SwiftUI

// MARK: - General & About View

struct SettingsGeneralView: View {
    let settings: SettingsStore
    let updater: AppUpdater
    let highlightedSection: String?
    @Binding var launchAtLoginMessage: String?
    @Binding var launchAtLoginMessageIsError: Bool
    @Binding var isExportingDiagnostics: Bool
    @Binding var diagnosticsMessage: String?
    @Binding var diagnosticsMessageIsError: Bool
    @Binding var showDiagnosticsConfirm: Bool

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .general)

            // 版本与更新
            aboutHeroCard

            // 系统偏好
            SettingsCard(
                title: "System",
                chinese: "系统偏好",
                isHighlighted: highlightedSection == "general-system"
            ) {
                SettingsRow(
                    label: "Language",
                    chinese: "界面语言",
                    desc: "Choose the display language for menus, statistics and settings.",
                    chineseDesc: "切换菜单栏、统计与设置界面的显示语言"
                ) {
                    Picker("", selection: $settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: SettingsLayout.languagePickerWidth)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Launch at login",
                    chinese: "开机自动启动",
                    desc: "Start CCBar automatically when you log in to your Mac.",
                    chineseDesc: "登录 macOS 时自动在后台启动 CCBar",
                    detail: launchAtLoginDetail
                ) {
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

            // 诊断与日志
            SettingsCard(
                title: "Diagnostics",
                chinese: "诊断与日志",
                isHighlighted: highlightedSection == "general-diagnostics"
            ) {
                SettingsRow(
                    label: "Export diagnostics",
                    chinese: "导出诊断日志",
                    desc: "Creates a local redacted zip archive for reporting issues. Nothing is uploaded automatically.",
                    chineseDesc: "在本机生成脱敏的 zip 诊断包用于反馈问题，不会自动上传"
                ) {
                    HStack(spacing: 8) {
                        if let diagnosticsMessage {
                            Text(diagnosticsMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    diagnosticsMessageIsError
                                        ? SettingsSemanticTone.danger.foreground
                                        : SettingsSemanticTone.success.foreground
                                )
                        }
                        Button {
                            showDiagnosticsConfirm = true
                        } label: {
                            if isExportingDiagnostics {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(tr("Export…", "导出…"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExportingDiagnostics)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    label: "Reveal log folder",
                    chinese: "打开日志目录",
                    desc: "~/Library/Logs/CCBar",
                    chineseDesc: "~/Library/Logs/CCBar"
                ) {
                    Button(tr("Open in Finder", "在 Finder 中打开")) {
                        DiagnosticsBundle.revealLogDirectory()
                    }
                    .buttonStyle(.bordered)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Verbose logging",
                    chinese: "详细日志",
                    desc: "Turn on while troubleshooting an issue, then turn off to keep logs compact.",
                    chineseDesc: "排查问题时开启，排查完成后建议关闭"
                ) {
                    Toggle("", isOn: $settings.verboseLogging)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }
        }
    }

    // MARK: - About Hero & Updates Card

    private var aboutHeroCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9.5, style: .continuous))

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("CCBar")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("v\(appVersion)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if updater.hasUpdate {
                            Text("· \(tr("Update available", "有新版本"))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(tr("Last checked:", "上次检查："))
                            .foregroundStyle(.secondary)
                        if let date = updater.lastCheckedAt {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }

                Spacer()

                if updater.hasUpdate {
                    Button(updateButtonTitle) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(updateButtonTitle) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
            .padding(.vertical, 15)

            SettingsDivider()

            SettingsRow(
                label: "Automatically check for updates",
                chinese: "自动检查更新",
                desc: "Periodically check GitHub releases for newer CCBar builds.",
                chineseDesc: "定期在后台检查 CCBar 新版本"
            ) {
                Toggle("", isOn: Binding(
                    get: { updater.automaticChecks },
                    set: { updater.setAutomaticChecks($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }
        .ccPanel(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(highlightedSection == "general-updates" ? 0.65 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.25), value: highlightedSection)
        )
    }

    // MARK: - Helpers

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var updateButtonTitle: String {
        updater.hasUpdate || updater.isWorking
            ? tr("View Update", "查看更新")
            : tr("Check for Updates", "检查更新")
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

    private var launchAtLoginDetail: AnyView? {
        guard let launchAtLoginMessage else { return nil }
        return AnyView(
            Text(launchAtLoginMessageIsError ? PrivacyDisplay.error(launchAtLoginMessage) : launchAtLoginMessage)
                .font(.system(size: 11))
                .foregroundStyle(launchAtLoginMessageIsError ? SettingsSemanticTone.danger.foreground : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        )
    }
}
