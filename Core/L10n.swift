import Foundation

// MARK: - Language model
//
// 见 docs/设计风格.md §5。
// 应用界面只显示一种语言:跟随系统(根据 Locale.current 解析为 zh / en)、中文、English。
// 调用方使用全局 `tr(en, zh)` 选词,由 SettingsStore.shared.resolvedLanguage 决定渲染哪一种。

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zh
    case en

    var id: String { rawValue }

    /// Picker 中始终双语显示,任意档位用户都需要看懂。
    var displayName: String {
        switch self {
        case .system: return "Follow System · 跟随系统"
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

enum ResolvedLanguage {
    case zh
    case en
}

@MainActor
enum L10n {
    static var current: ResolvedLanguage { SettingsStore.shared.resolvedLanguage }

    static func tr(_ english: String, _ chinese: String) -> String {
        switch current {
        case .zh: return chinese
        case .en: return english
        }
    }
}

/// SwiftUI view body 内的便捷选词函数。等同于 `L10n.tr(en, zh)`。
@MainActor
func tr(_ english: String, _ chinese: String) -> String {
    L10n.tr(english, chinese)
}

/// 根据用户设置把额度重置时间格式化为「剩余时长」或「绝对时间(MM-dd HH:mm)」。
@MainActor
func formatResetHint(_ resetsAt: Date?, now: Date = Date()) -> String {
    guard let resetsAt else { return tr("reset unknown", "时间未知") }

    switch SettingsStore.shared.resetTimeDisplay {
    case .absolute:
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        let stamp = formatter.string(from: resetsAt)
        return tr("resets at \(stamp)", "\(stamp) 重置")
    case .relative:
        return relativeResetHint(resetsAt, now: now)
    }
}

/// Popover 等紧凑场景使用:仅返回 `4h37m` / `5d3h` / `<1m` 这种无空格无后缀的形式。
@MainActor
func formatResetCompact(_ resetsAt: Date?, now: Date = Date()) -> String {
    guard let resetsAt else { return "—" }

    switch SettingsStore.shared.resetTimeDisplay {
    case .absolute:
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: resetsAt)
    case .relative:
        return compactRelativeReset(resetsAt, now: now)
    }
}

/// 鼠标悬浮重置时间时显示的「相反格式」(紧凑形式,用于行内切换显示)。
/// 当前设置 relative → 绝对时刻(当天 HH:mm,跨天 MM-dd HH:mm);
/// 当前设置 absolute → 相对时长(如 "4h37m")。
@MainActor
func formatResetAltCompact(_ resetsAt: Date?, now: Date = Date()) -> String {
    guard let resetsAt else { return "—" }
    switch SettingsStore.shared.resetTimeDisplay {
    case .relative:
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDate(resetsAt, inSameDayAs: now)
            ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: resetsAt)
    case .absolute:
        return compactRelativeReset(resetsAt, now: now)
    }
}

/// 紧凑相对时长,如 "4h37m" / "5d3h" / "<1m"(无空格无后缀)。
/// 供 formatResetCompact 与 formatResetAltCompact 共享。
@MainActor
private func compactRelativeReset(_ resetsAt: Date, now: Date) -> String {
    let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
    if seconds < 60 { return "<1m" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 {
        return remainingMinutes > 0 ? "\(hours)h\(remainingMinutes)m" : "\(hours)h"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return remainingHours > 0 ? "\(days)d\(remainingHours)h" : "\(days)d"
}

/// 相对时长文案,如 "4h 37m 后重置" / "resets in 4h 37m"。供 formatResetHint 使用。
@MainActor
private func relativeResetHint(_ resetsAt: Date, now: Date) -> String {
    let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
    if seconds < 60 { return tr("resets in <1m", "<1m 后重置") }
    let minutes = seconds / 60
    if minutes < 60 { return tr("resets in \(minutes)m", "\(minutes)m 后重置") }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 {
        return remainingMinutes > 0
            ? tr("resets in \(hours)h \(remainingMinutes)m", "\(hours)h \(remainingMinutes)m 后重置")
            : tr("resets in \(hours)h", "\(hours)h 后重置")
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return remainingHours > 0
        ? tr("resets in \(days)d \(remainingHours)h", "\(days)d \(remainingHours)h 后重置")
        : tr("resets in \(days)d", "\(days)d 后重置")
}
