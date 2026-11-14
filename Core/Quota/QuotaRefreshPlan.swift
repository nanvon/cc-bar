import Foundation

/// 一轮额度刷新计划的声明式描述（草案-性能与功耗等价优化方案 §4.1）。
/// 由当前设置与账号可见性一次性构造，供 `AppState.refreshQuotas` 裁剪链路，
/// 也便于测试矩阵直接验证各开关组合，不把开关判断散落到各 Client。
struct QuotaRefreshPlan: Equatable, Sendable {
    var refreshCodex: Bool
    var refreshClaude: Bool
    var refreshAntigravity: Bool
    var refreshCursor: Bool
    var refreshCommandCode: Bool
    var refreshOpenCodeGo: Bool
    /// 有可见导入 Codex 账号时需要调度导入刷新（是否真正刷新仍按各账号
    /// 自身 `visibleInPopover` 过滤；此处只表达"存在可见项"）。
    var refreshImported: Bool
    /// 主 Codex 启用时，导入账号与主账号同身份可镜像（同一身份只请求一次额度）；
    /// 主 Codex 关闭时即使内存还留有旧身份，可见导入账号也必须用自己的
    /// Keychain 凭据独立刷新，不能复制可能过期的主账号快照。
    var canMirrorPrimary: Bool

    static func make(
        showCodex: Bool,
        showClaude: Bool,
        showAntigravity: Bool = false,
        showCursor: Bool,
        showCommandCode: Bool = false,
        showOpenCodeGo: Bool = false,
        hasVisibleImported: Bool
    ) -> QuotaRefreshPlan {
        QuotaRefreshPlan(
            refreshCodex: showCodex,
            refreshClaude: showClaude,
            refreshAntigravity: showAntigravity,
            refreshCursor: showCursor,
            refreshCommandCode: showCommandCode,
            refreshOpenCodeGo: showOpenCodeGo,
            refreshImported: hasVisibleImported,
            canMirrorPrimary: showCodex
        )
    }
}

/// 单个服务这一轮能否开始请求额度。纯函数，主账号和导入账号共用，便于单测。
/// 判断顺序与原各服务的 `beginXxxRefresh` 一致：请求中 → 退避中 → 定时刷新的最短成功间隔。
/// 手动刷新不受最短间隔限制，但同样遵守 429 退避。
nonisolated enum QuotaRefreshGate {
    enum Decision: Equatable, Sendable {
        case start
        case skip
        /// 仍在 429 退避期内；调用方据此显示「请求过于频繁 · x 后重试」。
        case backingOff(until: Date)
    }

    static func decide(
        state: QuotaRefreshState,
        reason: QuotaRefreshReason,
        now: Date,
        minSuccessInterval: TimeInterval
    ) -> Decision {
        guard !state.inFlight else { return .skip }
        if let backoffUntil = state.backoffUntil, backoffUntil > now {
            return .backingOff(until: backoffUntil)
        }
        if reason == .periodic,
           let lastSuccessAt = state.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return .skip
        }
        return .start
    }
}

/// 各额度服务刷新状态机里真正不同的部分，集中在这里，参数化后的 `AppState` 按 `QuotaApp` 查表。
/// 新增服务时先看这里要不要加分支，不要把差异写回各服务的复制代码里。
nonisolated enum QuotaRefreshPolicy {
    /// 定时刷新的最短成功间隔。导入的 Codex 账号与主 Codex 相同。
    static let defaultMinSuccessInterval: TimeInterval = 60

    static func minSuccessInterval(for app: QuotaApp) -> TimeInterval {
        switch app {
        // agy CLI 取数较重，定时刷新至少隔 2 分钟。
        case .antigravity: return 120
        case .codex, .claude, .cursor, .commandCode, .opencodeGo: return defaultMinSuccessInterval
        }
    }

    /// Claude 只有本轮官方 API 取数成功时清除 429 退避。
    static func clearsBackoffOnSuccess(_ app: QuotaApp, source: QuotaSnapshotSource) -> Bool {
        switch app {
        case .claude: return source == .api
        case .codex, .antigravity, .cursor, .commandCode, .opencodeGo: return true
        }
    }
}
