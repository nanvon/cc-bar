import Foundation

/// 只消费真实 API 窗口；展示层继承的 reset 不进入周期判断。
nonisolated enum QuotaAlertPolicy {
    static let resetTolerance: TimeInterval = 30 * 60
    static let recoveryInterval: TimeInterval = 60
    static let retryInterval: TimeInterval = 10 * 60
    static let freshnessInterval: TimeInterval = 5 * 60

    struct Result: Sendable {
        var record: QuotaAlertRecord
        var shouldAlert: Bool
    }

    /// 只选择各 client 已解析且可识别的额度，不把未知 Codex 窗口当成标准周期。
    static func limits(in snapshot: QuotaSnapshot, preferences: QuotaAlertPreferences) -> [QuotaLimit] {
        var limits = snapshot.allLimits
        if snapshot.app == .antigravity {
            // 非分组响应仍把 Gemini 放在独立字段；第三方窗口与分组响应共用 ID。
            limits = limits.map { limit in
                var limit = limit
                if limit.id == "five-hour" { limit.id = "claude-5h" }
                if limit.id == "weekly" { limit.id = "claude-weekly" }
                return limit
            }
            if let window = snapshot.geminiWindow {
                limits.append(QuotaLimit(id: "gemini-5h", kind: .fiveHour, window: window))
            }
            if let window = snapshot.geminiWeekly {
                limits.append(QuotaLimit(id: "gemini-weekly", kind: .weekly, window: window))
            }
        }
        var seen: Set<String> = []
        return limits.filter { limit in
            guard limit.isActive != false, preferences.includes(limit.kind) else { return false }
            let supported: Bool
            switch snapshot.app {
            case .codex:
                supported = [.fiveHour, .weekly].contains(limit.kind)
            case .claude:
                supported = [.fiveHour, .weekly, .modelWeekly].contains(limit.kind)
            case .antigravity:
                supported = [.fiveHour, .weekly].contains(limit.kind)
            case .cursor:
                supported = ["cursor-total", "cursor-auto", "cursor-api"].contains(limit.id)
            case .commandCode:
                supported = ["command-code-five-hour", "command-code-weekly", "command-code-monthly"].contains(limit.id)
            }
            return supported && seen.insert(windowKey(limit, app: snapshot.app)).inserted
        }
    }

    static func windowKey(_ limit: QuotaLimit, app: QuotaApp) -> String {
        // Codex 保留 v1 的键；其他服务必须区分同 kind 下的模型 / 分组 / 计费额度。
        app == .codex ? limit.kind.rawValue : "limit:" + QuotaAlertIdentity.digest([app.rawValue, limit.id])
    }

    static func evaluate(
        previous: QuotaAlertRecord?, window: QuotaWindow, kind: QuotaLimitKind,
        threshold: Int, observationID: UUID, now: Date, baseline: Bool = false, allowBillingCycle: Bool = false
    ) -> Result? {
        guard kind != .unknown || allowBillingCycle, window.usedPercent.isFinite,
              window.usedPercent >= 0 else { return nil }
        // Cursor 可返回超过套餐上限的用量；按剩余 0% 处理。其他窗口仍拒绝越界值。
        guard window.usedPercent <= 100 || allowBillingCycle else { return nil }
        let remaining = max(0, 100 - window.usedPercent)
        let reset = reliableReset(window, kind: kind, now: now)
        var record = previous ?? QuotaAlertRecord(anchor: reset, windowSeconds: window.windowSeconds, lastSeenAt: now)
        // 自然月长度可以变化；计费窗口仍以固定锚点和恢复证据判断是否换周期。
        let sameLength = kind == .unknown || record.windowSeconds == nil || window.windowSeconds == nil
            || record.windowSeconds == window.windowSeconds

        if let previous, sameLength {
            if let anchor = previous.anchor, let reset,
               now >= anchor, reset.timeIntervalSince(anchor) > resetTolerance {
                record = QuotaAlertRecord(anchor: reset, windowSeconds: window.windowSeconds, lastSeenAt: now)
            } else {
                // 时间未知，或重置时间提前后移：都需要两次独立的恢复证据。
                let timeUnknown = previous.anchor.map { $0 <= now } ?? true
                let earlyReset = previous.anchor.flatMap { anchor in
                    reset.map { $0.timeIntervalSince(anchor) > resetTolerance }
                } ?? false
                let recoveryThreshold = max(previous.alertedThreshold ?? threshold, threshold) + 5
                if previous.occupied, (timeUnknown || earlyReset), remaining >= Double(recoveryThreshold) {
                    if let evidence = previous.recovery,
                       evidence.threshold == threshold,
                       evidence.observationID != observationID,
                       resetsAgree(evidence.reset, reset),
                       now.timeIntervalSince(evidence.observedAt) >= recoveryInterval {
                        record = QuotaAlertRecord(anchor: reset, windowSeconds: window.windowSeconds, lastSeenAt: now)
                    } else if previous.recovery == nil || previous.recovery?.threshold != threshold
                                || !resetsAgree(previous.recovery?.reset, reset) {
                        record.recovery = QuotaAlertRecovery(
                            observationID: observationID, observedAt: now, reset: reset, threshold: threshold
                        )
                    }
                } else {
                    record.recovery = nil
                }
                // 无时间的身份补上首次可靠时间时，保留已经占用的机会。
                if record.anchor == nil, record.recovery == nil, let reset { record.anchor = reset }
                if record.windowSeconds == nil { record.windowSeconds = window.windowSeconds }
            }
        } else if !sameLength {
            record.recovery = nil
        }
        if now.timeIntervalSince(record.lastSeenAt) >= 24 * 60 * 60 { record.lastSeenAt = now }
        if previous == nil, baseline, remaining < Double(threshold) {
            record.alertedThreshold = threshold
            record.submission = QuotaAlertSubmission(id: UUID(), status: .accepted, submittedAt: now)
        }
        let due = record.retryAfter.map { now >= $0 } ?? true
        return Result(record: record, shouldAlert: remaining < Double(threshold) && !record.occupied && due)
    }

    static func reliableReset(_ window: QuotaWindow, kind: QuotaLimitKind, now: Date) -> Date? {
        let expected: Int
        switch kind {
        case .fiveHour: expected = 5 * 60 * 60
        case .weekly, .modelWeekly: expected = 7 * 24 * 60 * 60
        case .unknown:
            // 计费周期按返回的长度判断；长度缺失时只接受一年内的未来日期。
            guard window.windowSeconds.map({ $0 > 0 && $0 <= 366 * 86_400 }) ?? true else { return nil }
            expected = window.windowSeconds.map { max($0, 32 * 86_400) } ?? 366 * 86_400
        }
        guard kind == .unknown || window.windowSeconds == nil || window.windowSeconds == expected,
              let reset = window.resetsAt, reset.timeIntervalSince1970.isFinite,
              reset > now, reset.timeIntervalSince(now) <= Double(expected) + resetTolerance else { return nil }
        return reset
    }

    private static func resetsAgree(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) <= resetTolerance
        default: false
        }
    }

    /// 只在同 account 没有多个已知 user 时补全弱身份；弱身份不能连接两个强身份。
    static func resolve(
        _ identity: QuotaAlertIdentity, active: [QuotaAlertIdentity], payload: inout QuotaAlertPayload
    ) -> QuotaAlertIdentity? {
        let known = Set([identity] + active + payload.accounts.values.map(\.identity)).filter {
            $0.app == identity.app && $0.accountDigest == identity.accountDigest && $0.userDigest != nil
        }
        if identity.userDigest == nil, known.count > 1 { return nil }
        let resolved = identity.userDigest == nil ? (known.first ?? identity) : identity
        if known.count <= 1, resolved.userDigest != nil {
            let weakKeys = payload.accounts.filter {
                $0.value.identity.app == resolved.app && $0.value.identity.accountDigest == resolved.accountDigest
                    && $0.value.identity.userDigest == nil
            }.map(\.key)
            var destination = payload.accounts[resolved.key] ?? QuotaAlertAccountState(identity: resolved)
            for key in weakKeys {
                guard let weak = payload.accounts.removeValue(forKey: key) else { continue }
                for (kind, incoming) in weak.windows {
                    guard let existing = destination.windows[kind] else {
                        destination.windows[kind] = incoming
                        continue
                    }
                    // 身份补全本身不解锁；不确定周期是否相同时也保守继承占用状态。
                    if incoming.occupied && !existing.occupied { destination.windows[kind] = incoming }
                }
            }
            if !weakKeys.isEmpty { payload.accounts[resolved.key] = destination }
        }
        return resolved
    }
}
