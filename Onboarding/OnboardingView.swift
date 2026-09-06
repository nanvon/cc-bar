import SwiftUI
import AppKit

// MARK: - OnboardingView
//
// 见 docs/界面布局.md §5。
// 4 步:Welcome / Detect accounts / Configure / Ready。
// 首次启动时显示;完成后写入 SettingsStore.didCompleteOnboarding = true。

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step: Int = 0

    var body: some View {
        ZStack {
            stepContent
                .transition(.opacity.combined(with: .move(edge: .trailing)))

            VStack {
                Spacer()
                progressDots.padding(.bottom, 16)
            }
        }
        .frame(width: 620, height: 520)
        .background(.regularMaterial)
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: WelcomeStep(onContinue: next)
        case 1: DetectAccountsStep(onBack: prev, onContinue: next)
        case 2: ConfigureStep(onBack: prev, onContinue: next)
        default: ReadyStep(onClose: finish, onOpenStats: openStats)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == step ? 12 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    private func next() { step = min(step + 1, 3) }
    private func prev() { step = max(step - 1, 0) }

    private func finish() {
        SettingsStore.shared.didCompleteOnboarding = true
        dismissWindow(id: "onboarding")
    }

    private func openStats() {
        SettingsStore.shared.didCompleteOnboarding = true
        appState.mainTab = .stats
        openWindow(id: "main")
        dismissWindow(id: "onboarding")
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconBlock()
                .padding(.bottom, 24)

            Text(tr("Welcome to CCBar", "欢迎使用 CCBar"))
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.4)

            Text(tr(
                "Track Codex and Claude Code quota right from your menu bar. We'll detect local providers automatically.",
                "在菜单栏即时查看 Codex 与 Claude Code 的额度,我们将自动检测本机服务。"
            ))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 380)
                .padding(.top, 14)

            VStack(spacing: 8) {
                PrimaryButton(label: tr("Get started", "开始"), action: onContinue)
            }
            .padding(.top, 24)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

private struct AppIconBlock: View {
    var body: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                fallback
            }
        }
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(
                colors: [
                    Color(red: 0.29, green: 0.29, blue: 0.31),
                    Color.codexAccent,
                    Color.claudeAccent
                ],
                startPoint: UnitPoint(x: 0, y: 0),
                endPoint: UnitPoint(x: 1, y: 1)
            ))
            .overlay(
                Image(systemName: "gauge.medium")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

// MARK: - Step 2: Detect accounts

private struct DetectAccountsStep: View {
    @Environment(AppState.self) private var appState
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(anyDetected
                 ? tr("We found these accounts", "检测到以下账号")
                 : tr("No accounts detected yet", "未检测到账号,可稍后在设置中查看"))
                .font(.system(size: 18, weight: .bold))
                .kerning(-0.3)

            VStack(spacing: 10) {
                DetectedAccountRow(
                    title: "Codex",
                    subtitle: "OpenAI",
                    plan: appState.codexAccount?.planType,
                    email: appState.codexAccount?.email,
                    source: codexSource,
                    tint: .codexAccent,
                    logoName: "codex",
                    fallback: "C",
                    isDetected: appState.codexAccount != nil
                )
                DetectedAccountRow(
                    title: "Claude Code",
                    subtitle: "Anthropic",
                    plan: appState.claudeAccount?.subscriptionType,
                    email: appState.claudeAccount?.email,
                    source: claudeSource,
                    tint: .claudeAccent,
                    logoName: "claude",
                    fallback: "K",
                    isDetected: appState.claudeAccount != nil
                )
                DetectedAccountRow(
                    title: "Antigravity",
                    subtitle: "Google",
                    plan: appState.antigravityQuota?.planType ?? appState.antigravityAccount?.planType,
                    email: appState.antigravityAccount?.email,
                    source: "~/.gemini/jetski-standalone-oauth-token",
                    tint: .antigravityAccent,
                    logoName: "antigravity",
                    fallback: "A",
                    isDetected: appState.antigravityAccount != nil
                )
                DetectedAccountRow(
                    title: "Cursor",
                    subtitle: "Cursor",
                    plan: appState.cursorQuota?.planType,
                    email: appState.cursorAccount?.email,
                    source: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                    tint: .gray,
                    logoName: "cursor",
                    fallback: "C",
                    isDetected: appState.cursorAccount != nil
                )
                DetectedAccountRow(
                    title: "Command Code",
                    subtitle: "Command Code",
                    plan: appState.commandCodeQuota?.planType ?? appState.commandCodeAccount?.planType,
                    email: appState.commandCodeAccount?.login ?? appState.commandCodeAccount?.email,
                    source: commandCodeSource,
                    tint: QuotaApp.commandCode.tintColor,
                    logoName: "commandcode",
                    fallback: "⌘",
                    isDetected: appState.commandCodeAccount != nil
                )
            }
            .padding(.top, 18)

            ReadOnlyInfoCard()
                .padding(.top, 18)

            Spacer()

            HStack(spacing: 8) {
                SecondaryButton(label: tr("Back", "上一步"), action: onBack)
                Spacer()
                PrimaryButton(label: tr("Continue", "继续"), action: onContinue)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    private var codexSource: String {
        "~/.codex/auth.json"
    }

    private var claudeSource: String {
        switch appState.claudeAccount?.source {
        case .file: return "~/.claude/.credentials.json"
        case .keychain: return "Keychain · claude-code"
        case .none: return "—"
        }
    }

    private var commandCodeSource: String {
        switch appState.commandCodeAccount?.source {
        case .commandCodeCLI: return "~/.commandcode/auth.json"
        case .pi: return "~/.pi/agent/auth.json"
        case .opencode: return "~/.local/share/opencode/auth.json"
        case .environment: return "ENV · COMMAND_CODE_API_KEY"
        case .manualKeychain: return "Keychain · command-code"
        case .none: return "—"
        }
    }

    private var anyDetected: Bool {
        appState.codexAccount != nil
            || appState.claudeAccount != nil
            || appState.antigravityAccount != nil
            || appState.cursorAccount != nil
            || appState.commandCodeAccount != nil
    }
}

private struct DetectedAccountRow: View {
    let title: String
    let subtitle: String
    let plan: String?
    let email: String?
    let source: String
    let tint: Color
    let logoName: String
    let fallback: String
    let isDetected: Bool

    var body: some View {
        HStack(spacing: 13) {
            CheckmarkBox(checked: isDetected)
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint, size: 34, logoSize: 16, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("· \(subtitleText)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(email ?? tr("Not detected", "未检测到"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .ccPanel(cornerRadius: 12)
        .opacity(isDetected ? 1 : 0.6)
    }

    private var subtitleText: String {
        if let plan, !plan.isEmpty { return "\(subtitle) · \(plan)" }
        return subtitle
    }
}

private struct CheckmarkBox: View {
    let checked: Bool

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.35))
    }
}

private struct ReadOnlyInfoCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Read-only access", "仅读取"))
                    .font(.system(size: 11.5, weight: .medium))
                Text(tr(
                    "CCBar reads quota status locally. It never sends your credentials anywhere.",
                    "CCBar 仅本地读取额度,不会向任何地方发送你的凭据。"
                ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Step 3: Configure menu bar + HUD

private struct ConfigureStep: View {
    @Environment(AppState.self) private var appState
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Choose your view", "选择你想看到的方式"))
                .font(.system(size: 18, weight: .bold))
                .kerning(-0.3)

            VStack(spacing: 14) {
                ConfigureRow(title: "Show in menu bar",
                             chineseTitle: "菜单栏",
                             subtitle: "Show enabled providers next to the menu bar icon.",
                             chineseSubtitle: "在菜单栏图标旁显示百分比") {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 12) {
                            Toggle("Codex", isOn: Binding(get: { settings.menuBarShowCodex }, set: { settings.menuBarShowCodex = $0 }))
                                .toggleStyle(.switch)
                                .tint(.green)
                            Toggle("Claude Code", isOn: Binding(get: { settings.menuBarShowClaude }, set: { settings.menuBarShowClaude = $0 }))
                                .toggleStyle(.switch)
                                .tint(.green)
                        }
                        HStack(spacing: 12) {
                            Toggle("Cursor", isOn: Binding(
                                get: { settings.isProviderShownInMenuBar(.cursor) },
                                set: { shown in
                                    settings.setProviderShownInMenuBar(shown, for: .cursor)
                                    if shown {
                                        settings.setProviderEnabled(true, for: .cursor)
                                        Task {
                                            await appState.refreshQuotas(reason: .userInitiated)
                                        }
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .tint(.green)
                            Toggle("Command Code", isOn: Binding(
                                get: { settings.isProviderShownInMenuBar(.commandCode) },
                                set: { shown in
                                    settings.setProviderShownInMenuBar(shown, for: .commandCode)
                                    if shown {
                                        settings.setProviderEnabled(true, for: .commandCode)
                                        Task {
                                            await appState.refreshQuotas(reason: .userInitiated)
                                        }
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .tint(.green)
                        }
                    }
                }

                ConfigureRow(title: "Floating HUD",
                             chineseTitle: "桌面悬浮窗",
                             subtitle: "Pin a small percentage HUD to your desktop.",
                             chineseSubtitle: "在桌面常驻一个小悬浮窗") {
                    Toggle(tr("Enabled", "启用"), isOn: Binding(
                        get: { settings.floatingEnabled },
                        set: { v in
                            settings.floatingEnabled = v
                            FloatingPanelController.shared.sync()
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(.green)
                }
            }
            .padding(.top, 18)

            Spacer()

            HStack(spacing: 8) {
                SecondaryButton(label: tr("Back", "上一步"), action: onBack)
                Spacer()
                PrimaryButton(label: tr("Continue", "继续"), action: onContinue)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }
}

private struct ConfigureRow<Trailing: View>: View {
    let title: String
    let chineseTitle: String
    let subtitle: String
    let chineseSubtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title, chineseTitle))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr(subtitle, chineseSubtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .ccPanel(cornerRadius: 12)
    }
}

// MARK: - Step 4: Ready

private struct ReadyStep: View {
    let onClose: () -> Void
    let onOpenStats: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                AppIconBlock()
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 36, y: 36)
            }
            .padding(.bottom, 24)

            Text(tr("You're all set", "一切就绪"))
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.4)

            Text(tr(
                "Open Statistics now, or just keep an eye on the menu bar.",
                "现在打开统计,或者直接在菜单栏盯着看。"
            ))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 14)

            HStack(spacing: 8) {
                SecondaryButton(label: tr("Close", "关闭"), action: onClose)
                PrimaryButton(label: tr("Open Statistics", "打开统计"), action: onOpenStats)
            }
            .padding(.top, 24)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Buttons

private struct PrimaryButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(height: 26)
                .background(
                    Capsule().fill(Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

private struct SecondaryButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(height: 26)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.15))
                )
                .overlay(
                    Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
