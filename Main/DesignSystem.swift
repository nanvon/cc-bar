import SwiftUI
import AppKit

// MARK: - Screenshot privacy

/// 仅用于展示，不改写原始数据。匿名编号在本次 App 运行期间跨窗口、排序和筛选保持一致。
@MainActor
enum PrivacyDisplay {
    private static var aliases: [String: [String: Int]] = [:]

    static var isEnabled: Bool { SettingsStore.shared.privacyMode }

    private static func alias(_ key: String, category: String, english: String, chinese: String) -> String {
        let number: Int
        if let existing = aliases[category]?[key] {
            number = existing
        } else {
            number = (aliases[category]?.count ?? 0) + 1
            aliases[category, default: [:]][key] = number
        }
        let suffix = String(format: "%02d", number)
        return tr("\(english) \(suffix)", "\(chinese) \(suffix)")
    }

    static func account(_ key: String) -> String {
        alias(key, category: "account", english: "Account", chinese: "账号")
    }

    static func project(_ key: String) -> String {
        alias(key, category: "project", english: "Project", chinese: "项目")
    }

    static func conversation(_ info: ConversationInfo) -> String {
        isEnabled
            ? alias(info.key, category: "conversation", english: "Conversation", chinese: "对话")
            : (info.title ?? tr("Untitled", "（无标题）"))
    }

    static func help(_ text: String) -> String { isEnabled ? tr("Hidden for privacy", "隐私模式下已隐藏") : text }

    /// 动态错误可能夹带账号或路径；隐私模式只保留失败状态。
    static func error(_ text: String) -> String {
        isEnabled ? tr("Operation failed. Turn off privacy mode to view details.", "操作失败，关闭隐私模式可查看详情。") : text
    }
}

/// 不渲染原文再模糊，避免辅助功能、文本选择或复制仍能拿到原文。
struct PrivacySensitiveText: View {
    enum Kind {
        case path, branch, identifier

        var width: CGFloat {
            switch self {
            case .path: 112
            case .branch: 64
            case .identifier: 88
            }
        }
    }

    let text: String
    var kind: Kind = .path
    var sensitive = true

    var body: some View {
        if PrivacyDisplay.isEnabled && sensitive {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: kind.width, height: 8)
                .frame(height: 14)
                .accessibilityLabel(tr("Hidden for privacy", "隐私模式下已隐藏"))
        } else {
            Text(text)
        }
    }
}

// MARK: - Product accent colors
//
// Provider 识别色定义在 Asset Catalog (*Accent)。
// Xcode 自动从 .xcassets 生成对应 Color,通过 QuotaApp.tintColor 统一访问。
// 见 docs/设计风格.md §4.2。

extension QuotaApp {
    var tintColor: Color {
        switch self {
        case .codex: .codexAccent
        case .claude: .claudeAccent
        case .antigravity: .antigravityAccent
        case .cursor: .cursorAccent
        case .commandCode: Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
        }
    }
}

// MARK: - UsageApp 识别色与名称

extension UsageApp {
    var tintColor: Color {
        switch self {
        case .codex: .codexAccent
        case .claude: .claudeAccent
        case .cursor: .cursorAccent
        case .pi: .piAccent
        case .opencode: .opencodeAccent
        // DSH 识别色取官方主题强调蓝（dsh-client-ui-theme 的 deepseek-500 / 深色 deepseek-400，
        // Asset Catalog : DshAccent），用于图表 / 色块；tile 走官方品牌主色黑底，不用此色。
        case .dsh: .dshAccent
        }
    }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        case .dsh: "DSH"
        }
    }

    /// 对应 Resources/Logos/ 下的 svg 资源名。
    var logoName: String { rawValue }
}

// MARK: - Status color

/// 按剩余百分比解析 3 档状态色:>=20% → normal / <20% → low / <=0 → empty。
///
/// 见 docs/设计风格.md §4.3。Popover / Floating / Stats KPI 全部走这里。
/// `tint`(服务识别色)当前不参与额度着色,保留参数以备将来切回「服务色打底」方案。
func statusColor(remainingPercent: Double?, tint: Color) -> Color {
    guard let value = remainingPercent else { return .secondary }
    if value <= 0 { return quotaEmptyColor }
    if value < 20 { return quotaLowColor }
    return quotaNormalColor
}

// normal 档统一用石墨灰(中性灰),不随服务识别色变化。
private let quotaNormalColor = adaptiveColor(
    light: (red: 108, green: 108, blue: 112), // #6C6C70
    dark: (red: 152, green: 152, blue: 157)   // #98989D
)

private let quotaLowColor = adaptiveColor(
    light: (red: 199, green: 83, blue: 0),    // #C75300
    dark: (red: 255, green: 161, blue: 95)    // #FFA15F
)

private let quotaEmptyColor = adaptiveColor(
    light: (red: 209, green: 36, blue: 58),   // #D1243A
    dark: (red: 255, green: 122, blue: 144)   // #FF7A90
)

/// 按浅 / 深色外观切换的固定色值（0~255）。状态色与统计页色阶共用。
func adaptiveColor(
    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
    dark: (red: CGFloat, green: CGFloat, blue: CGFloat)
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = isDark ? dark : light
        return NSColor(
            calibratedRed: rgb.red / 255,
            green: rgb.green / 255,
            blue: rgb.blue / 255,
            alpha: 1
        )
    })
}

// MARK: - Composition palette（统计页非服务维度）
//
// 见 docs/设计风格.md §4.4。提供商 / 模型 / 项目没有识别色，按排名套紫色顺序色阶（第 1 名最深）。
// 不用蓝色（Antigravity / Pi / DSH 识别色与系统 Accent 都是蓝）；不用灰色（与 Codex 石墨灰、Cursor 近黑混淆）。
// 色阶只表示排名，不表示身份，使用处必须同时显示名称或图例。

enum CompositionPalette {
    private static let ranks: [Color] = [
        adaptiveColor(light: (63, 58, 143), dark: (179, 173, 242)),    // #3F3A8F / #B3ADF2
        adaptiveColor(light: (94, 86, 194), dark: (143, 135, 230)),    // #5E56C2 / #8F87E6
        adaptiveColor(light: (140, 133, 217), dark: (108, 99, 204)),   // #8C85D9 / #6C63CC
        adaptiveColor(light: (189, 184, 236), dark: (77, 70, 158)),    // #BDB8EC / #4D469E
        adaptiveColor(light: (218, 215, 245), dark: (58, 53, 120))     // #DAD7F5 / #3A3578（模型维度第 5 名）
    ]

    /// 第 `index + 1` 名；超出色阶时用最浅一级。
    static func rank(_ index: Int) -> Color {
        ranks[min(max(0, index), ranks.count - 1)]
    }

    /// 「其他 / 其余」。
    static let rest = adaptiveColor(light: (199, 199, 204), dark: (72, 72, 74))           // #C7C7CC / #48484A
    /// 「未归属」斜纹线色。
    static let unattributedStripe = adaptiveColor(light: (199, 199, 204), dark: (99, 99, 102)) // #C7C7CC / #636366
    /// 高消耗对话金额条（中性灰）。
    static let amountBar = Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255)       // #AEAEB2
}

/// 「未归属」的 135° 灰色斜纹，线距 3pt。尺寸由外层决定。
struct UnattributedStripes: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(CompositionPalette.unattributedStripe), lineWidth: 1)
        }
        .overlay(
            Rectangle().strokeBorder(CompositionPalette.unattributedStripe, lineWidth: 0.5)
        )
    }
}

// MARK: - Reset time (hover 切换格式)

/// 重置时间文案,鼠标悬浮时切换显示「相反格式」(相对↔绝对)。
///
/// 菜单栏 App 处于 `.accessory` 非激活态,系统 `.help()` tooltip 不会触发,
/// 因此用 `onHover` 直接切换文案来实现「悬浮看另一种格式」。
/// `font` / `foregroundStyle` 等由调用方在外层指定。
struct ResetTimeText: View {
    let resetsAt: Date?
    @State private var hovering = false

    var body: some View {
        // 相对倒计时是按「距现在还有多久」实时算的,本身没有任何 @Observable 输入,
        // 不会随时间自动重绘(.accessory 非激活态尤甚),否则文案会冻在渲染那一刻、
        // 要鼠标移入才跳。用周期 TimelineView 每分钟推进一次,并把 context.date
        // 作为 now 传入,保证倒计时自己走动。绝对格式不依赖 now,一并重算无副作用。
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(hovering
                 ? formatResetAltCompact(resetsAt, now: context.date)
                 : formatResetCompact(resetsAt, now: context.date))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        }
    }
}

// MARK: - Panel background / stroke (浅深色对照)
//
// 见 docs/设计风格.md §12.3。
// Stats KPI 卡、Daily usage panel、Settings PrefsGroup body、Onboarding DetectedAccount 全部用这一对。

struct PanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if colorScheme == .dark {
                Color(white: 0.235, opacity: 0.4)
            } else {
                Color.white
            }
        }
    }
}

/// Panel 0.5pt 内描边,做"卡片感"。
struct CCPanelStroke: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }
}

extension View {
    /// 给 Panel / KPI 卡上 0.5pt 内描边。
    func ccPanelStroke(cornerRadius: CGFloat) -> some View {
        modifier(CCPanelStroke(cornerRadius: cornerRadius))
    }

    /// 一步给出 Panel 完整外观:背景 + 圆角 + 0.5pt 描边。
    func ccPanel(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.background)
                    .overlay(PanelBackground().clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
            )
            .ccPanelStroke(cornerRadius: cornerRadius)
    }
}

// MARK: - ServiceMark (色块)
//
// 见 docs/设计风格.md §11.1。
// prototype 用的是 8×8 squircle(圆角 2pt),不是圆。

struct ServiceMark: View {
    let color: Color
    var size: CGFloat = 8
    var cornerRadius: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - ServiceTile (带 logo 的 squircle)
//
// 见 docs/设计风格.md §11.2。
// Popover 服务行左侧、Onboarding 账号列表、设置服务卡片，以及主窗口统计 / 对话 / 周期里
// 标识服务的位置（小号，经 `init(app:size:)`）都用。图表图例与悬停提示仍用 ServiceMark 色块对应图表颜色。

struct ServiceTile: View {
    /// 资源名,对应 Resources/Logos/ 下的 svg。
    let logoName: String
    /// 备用字母(SVG 加载失败时显示)。
    let fallback: String
    /// 背景填充色(服务识别色)。Codex 走 OpenAI 官方观感(白底黑 logo)、DSH / Cursor 走固定深色底,会忽略此值。
    let tint: Color
    /// tile 尺寸,默认 Popover 用 22pt。
    var size: CGFloat = 22
    /// 内 logo 尺寸,默认 14pt。
    var logoSize: CGFloat = 14
    /// 圆角半径,默认 6pt。
    var cornerRadius: CGFloat = 6

    /// Codex 的 tile 还原 OpenAI 官方品牌图标:白底黑 logo + 极细边框。
    /// 其余地方(文字色、环形、图表)的 `Color.codexAccent` 仍是石墨灰,不受影响。
    private var isOpenAIBrand: Bool { logoName == "codex" }

    /// 固定深色底 + 白色 logo,不随外观切换:
    /// - DSH:官方品牌主色(dsh-client-ui-theme `brand-primary` 浅色值 #0F1115),图表里的 `Color.dshAccent` 仍是官方强调蓝;
    /// - Cursor:`CursorAccent` 深色值是近白,直接当底色会吞掉白色 logo,所以 tile 固定用它的浅色值 #2C2C2E。
    private var fixedDarkBackground: Color? {
        switch logoName {
        case "dsh": Color(red: 15 / 255, green: 17 / 255, blue: 21 / 255)
        case "cursor": Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
        default: nil
        }
    }

    private var background: Color {
        if isOpenAIBrand { return .white }
        return fixedDarkBackground ?? tint
    }
    private var foreground: Color { isOpenAIBrand ? .black : .white }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                if isOpenAIBrand {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
            }
            .overlay(logoView)
    }

    @ViewBuilder
    private var logoView: some View {
        if let nsImage = LogoCache.image(named: logoName) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(foreground)
                .frame(width: logoSize, height: logoSize)
        } else {
            Text(fallback)
                .font(.system(size: logoSize * 0.7, weight: .semibold))
                .foregroundStyle(foreground)
        }
    }
}

extension ServiceTile {
    /// 主窗口里标识用量服务的小号 tile（取代原来的 ServiceMark 色块），logo 尺寸与圆角按 tile 尺寸等比缩放。
    init(app: UsageApp, size: CGFloat) {
        self.init(
            logoName: app.logoName,
            fallback: String(app.displayName.prefix(1)),
            tint: app.tintColor,
            size: size,
            logoSize: (size * 0.64).rounded(),
            cornerRadius: size * 0.27
        )
    }
}

private enum LogoCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

// MARK: - ProgressRing (进度环)
//
// 见 docs/设计风格.md §11.3(已废弃)。
// 组件保留,但当前界面没有调用点:Popover 主额度改用大字 + 横条,Stats 的
// Current limits 面板已移除。value 取 0...1,值越大环越满。颜色由调用方传入(通常用 statusColor)。

struct ProgressRing<Center: View>: View {
    let value: Double
    let tint: Color
    var diameter: CGFloat = 56
    var stroke: CGFloat = 5.5
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: stroke))

            Circle()
                .trim(from: 0, to: clampedValue)
                .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: clampedValue)

            center()
        }
        .frame(width: diameter, height: diameter)
    }

    private var clampedValue: CGFloat {
        max(0, min(1, CGFloat(value)))
    }
}

extension ProgressRing where Center == EmptyView {
    init(value: Double, tint: Color, diameter: CGFloat = 56, stroke: CGFloat = 5.5) {
        self.init(value: value, tint: tint, diameter: diameter, stroke: stroke) {
            EmptyView()
        }
    }
}

// MARK: - ProgressBar (横条)
//
// 见 docs/设计风格.md §11.4。
// Popover weekly 5/2.5、HUD 4/2、Dense compact 3/1.5、BigStat 6/3。

struct ProgressBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                Capsule()
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * clampedValue))
                    .animation(.easeOut(duration: 0.25), value: clampedValue)
            }
        }
        .frame(height: height)
    }

    private var clampedValue: CGFloat {
        max(0, min(1, CGFloat(value)))
    }
}

// MARK: - Bilingual label helpers
//
// 见 docs/设计风格.md §5。
// 单语切换 · 由 SettingsStore.shared.resolvedLanguage 决定渲染中文还是英文。
// 调用方保留 `english` + `chinese` 两个字段,组件内自动选词,无需迁移调用点。

/// 行内单语显示 · zh 渲染 chinese,en 渲染 english。
struct BilingualInline: View {
    let english: String
    let chinese: String
    /// 保留参数以兼容历史调用,运行时不再拼接。
    var separator: String = " · "

    var body: some View {
        switch SettingsStore.shared.resolvedLanguage {
        case .zh: Text(chinese)
        case .en: Text(english)
        }
    }
}

/// 节标题 / KPI label · 单语模式下退化为单行 Text,保留主字体。
struct BilingualStack: View {
    let english: String
    let chinese: String
    var englishFont: Font = .headline
    var chineseFont: Font = .caption

    var body: some View {
        switch SettingsStore.shared.resolvedLanguage {
        case .zh: Text(chinese).font(englishFont)
        case .en: Text(english).font(englishFont)
        }
    }
}

// MARK: - Spacing tokens (4pt 基线)
//
// 见 docs/设计风格.md §10。

enum CCSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s2: CGFloat = 6
    static let s: CGFloat = 8
    static let m2: CGFloat = 10
    static let m: CGFloat = 12
    static let l2: CGFloat = 14
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 28
    static let huge: CGFloat = 32
}

// MARK: - VisualEffectBackground
//
// SwiftUI 包 NSVisualEffectView,用于把指定 material(.hudWindow / .popover / .sidebar 等)
// 接到 SwiftUI 视图层级里。悬浮窗 HUD 用它叠「实色压底 + .popover material + hairline」
// 三层(见 FloatingContentView 与 docs/设计风格.md §12.3),不用 .hudWindow,
// 因为 .hudWindow 在彩色桌面下前景对比不足。

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

// MARK: - Refresh state badge
//
// Popover header 状态点;Live / Stale / Offline。

enum CCRefreshState {
    case live, stale, offline

    var color: Color {
        switch self {
        case .live: return .green
        case .stale: return .orange
        case .offline: return .red
        }
    }

    @MainActor
    var tooltip: String {
        switch self {
        case .live: return tr("Live", "在线")
        case .stale: return tr("Stale", "数据陈旧")
        case .offline: return tr("Offline", "离线")
        }
    }
}

// MARK: - Pointing-hand cursor
//
// 全局统一的 hover 手型光标 ViewModifier。用在所有 `.borderless` / `.plain`
// 自定义按钮上,弥补 SwiftUI 默认按钮在 macOS 上无光标提示的问题。

private struct PointingHandCursor: ViewModifier {
    /// 记录本视图是否已 push，保证 push / pop 严格配对：视图在悬停中被移除
    /// （Popover 关闭、分段控件按 id 重建）时收不到 onHover(false)，由 onDisappear 补 pop，
    /// 否则光标栈残留一层手型，移到别处仍是手型。
    @State private var didPush = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !didPush {
                    NSCursor.pointingHand.push()
                    didPush = true
                } else if !hovering, didPush {
                    NSCursor.pop()
                    didPush = false
                }
            }
            .onDisappear {
                guard didPush else { return }
                NSCursor.pop()
                didPush = false
            }
    }
}

extension View {
    /// 鼠标进入时切换为手型光标,离开时还原。
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

// MARK: - PopoverIconButtonStyle
//
// Popover 顶部 26×22 圆角 5pt borderless 图标按钮。
// hover 浅灰背景 + 手型光标,匹配 docs/界面布局.md §1.3。

struct PopoverIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 26, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointingHandCursor()
    }
}

// MARK: - Stats selectable list（对话 / 项目列表）
//
// 统计页对话、项目两个主从列表共用：自绘选中态，不使用系统 List 的强调色整行高亮。
// 选中 = 圆角 8pt 中性浅底 `primary.opacity(0.08)`，悬停 `0.04`。

/// 可选中列表行：整行可点，选中 / 悬停背景统一在这里。
struct StatsSelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.08 : (isHovered ? 0.04 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointingHandCursor()
    }
}

/// 主从列表容器：`ScrollView` + `LazyVStack`，↑ / ↓ 切换选中，选中变化时滚动到可见。
struct StatsSelectionList<Item: Identifiable, Row: View, Trailing: View>: View where Item.ID == String {
    let items: [Item]
    @Binding var selection: String?
    @ViewBuilder var row: (Item) -> Row
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        StatsSelectableRow(isSelected: selection == item.id) {
                            selection = item.id
                        } content: {
                            row(item)
                        }
                        .id(item.id)
                    }
                    trailing()
                }
                .padding(8)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let index = items.firstIndex(where: { $0.id == selection }) else { return .ignored }
        let target = index + offset
        if items.indices.contains(target) { selection = items[target].id }
        return .handled
    }
}

extension StatsSelectionList where Trailing == EmptyView {
    init(items: [Item], selection: Binding<String?>, @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items: items, selection: selection, row: row, trailing: { EmptyView() })
    }
}

/// 对话 / 项目两个主从页共用的分栏尺寸，两页切换时分隔线不跳。
/// 最小窗口 1040 宽时：1040 − 侧栏 200 − 列表 360 = 详情 480。
enum StatsSplitMetrics {
    static let listMinWidth: CGFloat = 360
    /// 列表默认宽，也是上限：多出的宽度都给详情。
    static let listWidth: CGFloat = 400
    static let detailMinWidth: CGFloat = 480
    /// 详情区宽度达到该值时面板两列并排。默认窗口（1440 宽）下详情区约 840pt。
    static let wideDetailWidth: CGFloat = 760
}

/// 列表栏首次整理（聚合器为空且正在扫描）：进度 + 骨架行。
struct StatsOrganizingState: View {
    let progress: ScanProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tr("Organizing conversation history…", "正在整理历史对话"))
                    .font(.system(size: 12.5, weight: .medium))
            }
            if let progress {
                if progress.filesTotal > 0 {
                    ProgressView(value: Double(progress.filesCompleted), total: Double(max(1, progress.filesTotal)))
                }
                Text(tr(
                    "\(progress.filesCompleted) session files processed",
                    "已处理 \(progress.filesCompleted) 个会话文件"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.14)).frame(width: 160, height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)).frame(height: 8)
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 列表栏空状态（所选范围内没有数据）：图标 + 标题 + 说明，可选「查看近 30 天」。
struct StatsListEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    /// 为 nil 时不显示「查看近 30 天」（当前已是近 30 天或全部时间）。
    var showLast30Days: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if let showLast30Days {
                Button(tr("View last 30 days", "查看近 30 天"), action: showLast30Days)
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}
