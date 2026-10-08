import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Image(nsImage: MenuBarBadgeImage.make(
            providers: visibleProviders,
            snapshots: snapshots,
            window: SettingsStore.shared.menuBarWindow
        ))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(MenuBarBadgeImage.accessibilityLabel(
            providers: visibleProviders,
            snapshots: snapshots,
            window: SettingsStore.shared.menuBarWindow
        ))
    }

    private var visibleProviders: [QuotaProviderDescriptor] {
        SettingsStore.shared.orderedMenuBarProviders.filter {
            SettingsStore.shared.effectiveMenuBarVisibility(for: $0.app)
        }
    }

    private var snapshots: [QuotaApp: QuotaSnapshot] {
        Dictionary(uniqueKeysWithValues: QuotaApp.allCases.compactMap { app in
            appState.quotaSnapshot(for: app).map { (app, $0) }
        })
    }
}

enum MenuBarLogo {
    private static let cache = NSCache<NSString, NSImage>()
    private static let size = NSSize(width: 18, height: 18)

    static func rawImage(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = size
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

enum MenuBarBadgeImage {
    private static let iconSize: CGFloat = 18
    private static let height: CGFloat = 22
    private static let iconTextGap: CGFloat = 3
    private static let segmentGap: CGFloat = 9
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    static func make(
        providers: [QuotaProviderDescriptor],
        snapshots: [QuotaApp: QuotaSnapshot],
        window: MenuBarWindowChoice
    ) -> NSImage {
        let items = providers.map { provider in
            BadgeItem(
                logo: provider.logoName,
                fallback: provider.fallback,
                text: pctText(snapshots[provider.app], window: window)
            )
        }

        let attrs = textAttributes
        let textWidths = items.map { $0.text.size(withAttributes: attrs).width }
        let width = items.enumerated().reduce(CGFloat.zero) { partial, entry in
            let gap = entry.offset == 0 ? CGFloat.zero : segmentGap
            let textPart = entry.element.text.isEmpty ? 0 : iconTextGap + ceil(textWidths[entry.offset])
            return partial + gap + iconSize + textPart
        }

        // 没有任何 item 时仍要返回一个最小图像（至少留一个 logo 占位以免菜单栏图标完全消失）
        if items.isEmpty {
            return placeholderImage()
        }

        let image = NSImage(size: NSSize(width: max(ceil(width), iconSize), height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        var x: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { x += segmentGap }
            drawIcon(item, x: x)
            x += iconSize
            if !item.text.isEmpty {
                x += iconTextGap
                let textSize = item.text.size(withAttributes: attrs)
                item.text.draw(at: NSPoint(x: x, y: floor((height - textSize.height) / 2)),
                               withAttributes: attrs)
                x += ceil(textSize.width)
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func accessibilityLabel(
        providers: [QuotaProviderDescriptor],
        snapshots: [QuotaApp: QuotaSnapshot],
        window: MenuBarWindowChoice
    ) -> String {
        let parts = providers.map { provider in
            if snapshots[provider.app]?.isUnlimited == true {
                return "\(provider.title) Unlimited"
            }
            return "\(provider.title) \(pctText(snapshots[provider.app], window: window))"
        }
        return parts.isEmpty ? "CCBar" : parts.joined(separator: ", ")
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }

    private static func pctText(_ snap: QuotaSnapshot?, window: MenuBarWindowChoice) -> String {
        guard let snap else { return "--" }
        if snap.isUnlimited == true { return "∞" }
        let limits = MenuBarQuotaSelection.limits(in: snap, choice: window)
        guard !limits.isEmpty else { return "--" }
        return limits.map { pctOrPlaceholder($0.window) }.joined(separator: "/")
    }

    private static func pctOrPlaceholder(_ window: QuotaWindow?) -> String {
        guard let window else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private static func placeholderImage() -> NSImage {
        let image = NSImage(size: NSSize(width: iconSize, height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        if let img = MenuBarLogo.rawImage(named: "codex") {
            img.draw(in: NSRect(x: 0, y: floor((height - iconSize) / 2),
                                width: iconSize, height: iconSize))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawIcon(_ item: BadgeItem, x: CGFloat) {
        let rect = NSRect(x: x, y: floor((height - iconSize) / 2), width: iconSize, height: iconSize)
        if let img = MenuBarLogo.rawImage(named: item.logo) {
            img.draw(in: rect)
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let size = item.fallback.size(withAttributes: attrs)
        item.fallback.draw(at: NSPoint(x: x + floor((iconSize - size.width) / 2),
                                       y: floor((height - size.height) / 2)),
                           withAttributes: attrs)
    }

    private struct BadgeItem {
        let logo: String
        let fallback: String
        let text: String
    }
}

enum MenuBarQuotaSelection {
    static func limits(
        in snapshot: QuotaSnapshot,
        choice: MenuBarWindowChoice
    ) -> [QuotaLimit] {
        // Cursor 的 Total / Auto / API 是同一计费周期下的不同额度维度，
        // 不是主 / 周窗口。菜单栏只显示 Total，避免把 Auto 伪装成 Weekly，
        // 也避免三段数字挤占菜单栏空间；明细始终在 Popover 展示。
        if snapshot.app == .cursor {
            return [snapshot.primaryLimit].compactMap { $0 }
        }
        switch choice {
        case .primary:
            return [snapshot.primaryLimit].compactMap { $0 }
        case .weekly:
            return [snapshot.weeklyLimit].compactMap { $0 }
        case .both:
            return [snapshot.primaryLimit, snapshot.secondaryLimit]
                .compactMap { $0 }
                .reduce(into: [QuotaLimit]()) { result, limit in
                    if !result.contains(where: { $0.id == limit.id }) { result.append(limit) }
                }
        }
    }
}
