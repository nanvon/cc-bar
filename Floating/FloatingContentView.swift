import SwiftUI

// MARK: - FloatingContentView
//
// 见 docs/界面布局.md §2。
// 默认变体:Two-row pill。
// 结构:14pt 圆角 HUD 容器 + .hudWindow material 背景 + 两行 pill。
// 每行:18pt ServiceTile + flex 4pt bar + 34pt 百分比(服务色)。

struct FloatingContentView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore

    var body: some View {
        let providers = QuotaProviderDescriptor.floatingProviders.filter {
            settings.effectiveFloatingVisibility(for: $0.app)
        }

        VStack(alignment: .leading, spacing: 7) {
            ForEach(providers) { provider in
                FloatingRow(
                    logoName: provider.logoName,
                    fallback: provider.fallback,
                    tint: provider.app.tintColor,
                    snapshot: appState.quotaSnapshot(for: provider.app)
                )
            }
            if providers.isEmpty {
                Text(tr("No services", "未启用"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 168, alignment: .leading)
        .background {
            // 三层叠加,解决 `.hudWindow` 在彩色桌面下前景被吃掉的问题:
            // 1) 实色窗背景压一层,使桌面像素不再直接透上来
            // 2) `.popover` material 接管毛玻璃质感(比 .hudWindow 厚)
            // 3) hairline 描边,任何背景下都能勾出 HUD 边缘
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        // 阴影交给 NSPanel 的 hasShadow,它按内容 alpha 自动取圆角形状,
        // SwiftUI 这层 shadow 会被 panel 边界裁掉而且和系统阴影叠加,所以移除。
        .fixedSize()
    }
}

private struct FloatingRow: View {
    let logoName: String
    let fallback: String
    let tint: Color
    let snapshot: QuotaSnapshot?

    var body: some View {
        HStack(spacing: 8) {
            ServiceTile(
                logoName: logoName,
                fallback: fallback,
                tint: tint,
                size: 18,
                logoSize: 12,
                cornerRadius: 5
            )

            // Unlimited 没有可填充的比例；留空 bar 位保持各行 tile / 数值三段对齐，
            // 右侧只用一个 ∞ 表达，不再另起一行文字重复同一件事。
            if isUnlimited {
                Spacer(minLength: 56)

                Text("∞")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            } else {
                ProgressBar(value: barValue, tint: barColor, height: 4)
                    .frame(minWidth: 56)

                Text(percentText)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.3)
                    .monospacedDigit()
                    .foregroundStyle(barColor)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
    }

    private var barValue: Double {
        guard let window = snapshot?.primaryWindow else { return 0 }
        return window.remainingPercent / 100
    }

    private var percentText: String {
        guard let window = snapshot?.primaryWindow else { return "--%" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private var barColor: Color {
        statusColor(remainingPercent: snapshot?.primaryWindow?.remainingPercent, tint: tint)
    }

    private var isUnlimited: Bool {
        snapshot?.isUnlimited == true
    }
}
