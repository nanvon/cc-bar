import AppKit
import SwiftUI

// MARK: - Page Header

struct SettingsPageHeader<Accessory: View>: View {
    let category: SettingsCategory
    @ViewBuilder var accessory: () -> Accessory

    init(category: SettingsCategory, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.category = category
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr(category.englishTitle, category.chineseTitle))
                    .font(.system(size: 17, weight: .bold))
                    .kerning(-0.4)
                Text(tr(category.englishSubtitle, category.chineseSubtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
        .padding(.bottom, 8)
    }
}

extension SettingsPageHeader where Accessory == EmptyView {
    init(category: SettingsCategory) {
        self.init(category: category) { EmptyView() }
    }
}

// MARK: - Section Card

struct SettingsCard<HeaderAccessory: View, Content: View>: View {
    let title: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    var isHighlighted: Bool = false
    @ViewBuilder var headerAccessory: () -> HeaderAccessory
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        chinese: String,
        desc: String? = nil,
        chineseDesc: String? = nil,
        isHighlighted: Bool = false,
        @ViewBuilder headerAccessory: @escaping () -> HeaderAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.chinese = chinese
        self.desc = desc
        self.chineseDesc = chineseDesc
        self.isHighlighted = isHighlighted
        self.headerAccessory = headerAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(title, chinese))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .kerning(-0.1)
                    if let desc, let chineseDesc {
                        Text(tr(desc, chineseDesc))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                headerAccessory()
            }
            .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? Color.accentColor.opacity(0.65) : Color.clear,
                        lineWidth: 1.5
                    )
                    .animation(.easeInOut(duration: 0.25), value: isHighlighted)
            )
        }
    }
}

extension SettingsCard where HeaderAccessory == EmptyView {
    init(
        title: String,
        chinese: String,
        desc: String? = nil,
        chineseDesc: String? = nil,
        isHighlighted: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            chinese: chinese,
            desc: desc,
            chineseDesc: chineseDesc,
            isHighlighted: isHighlighted,
            headerAccessory: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Settings Row

struct SettingsRow<Trailing: View>: View {
    let label: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    /// 描述下方的附加行（状态、错误提示、操作链接等），可多行换行。
    var detail: AnyView? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(tr(label, chinese))
                    .font(.system(size: 13))
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    detail
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
    }
}

// MARK: - Inset Divider

struct SettingsDivider: View {
    var leading: CGFloat = SettingsLayout.cardHorizontalPadding
    var trailing: CGFloat = SettingsLayout.cardHorizontalPadding

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
    }
}

// MARK: - Semantic Tone & Callout Banner

enum SettingsSemanticTone {
    case neutral
    case accent
    case success
    case warning
    case danger

    var foreground: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return .accentColor
        case .success: return adaptiveColor(light: (22, 134, 72), dark: (74, 212, 132))
        case .warning: return adaptiveColor(light: (199, 83, 0), dark: (255, 168, 96))
        case .danger: return adaptiveColor(light: (209, 36, 58), dark: (255, 122, 144))
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color.primary.opacity(0.06)
        case .accent: return Color.accentColor.opacity(0.1)
        case .success: return foreground.opacity(0.1)
        case .warning: return foreground.opacity(0.1)
        case .danger: return foreground.opacity(0.1)
        }
    }

    var border: Color {
        switch self {
        case .neutral: return Color.primary.opacity(0.08)
        case .accent: return Color.accentColor.opacity(0.2)
        case .success, .warning, .danger: return foreground.opacity(0.22)
        }
    }
}

struct SettingsCallout<ActionContent: View>: View {
    let tone: SettingsSemanticTone
    let icon: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> ActionContent

    init(
        tone: SettingsSemanticTone,
        icon: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: @escaping () -> ActionContent
    ) {
        self.tone = tone
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.foreground)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 0.6)
        )
    }
}

extension SettingsCallout where ActionContent == EmptyView {
    init(tone: SettingsSemanticTone, icon: String, title: String, message: String? = nil) {
        self.init(tone: tone, icon: icon, title: title, message: message) { EmptyView() }
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
