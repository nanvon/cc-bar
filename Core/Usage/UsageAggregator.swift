import Foundation
import Observation

/// 按 (day, app, model, speed) 聚合的内存表。
///
/// 本地日志和远端 Dashboard 结果使用独立分区：本地仅追加，远端按完整自然日替换。
/// 标记为 `@Observable`：`snapshot()` / `todayCost(...)` / `totals(...)` 在 SwiftUI
/// body 内访问分区时会自动登记依赖，写回后会驱动所有读这个聚合器的视图自动刷新。
@MainActor
@Observable
final class UsageAggregator {
    private var localBuckets: [BucketKey: UsageBucket] = [:]
    private var remoteBuckets: [BucketKey: UsageBucket] = [:]

    struct BucketKey: Hashable {
        let day: Date
        let app: UsageApp
        let model: String
        let speed: UsageSpeed
    }

    func load(from snapshot: [UsageBucket]) {
        localBuckets.removeAll(keepingCapacity: true)
        for b in snapshot where b.app != .cursor {
            let key = BucketKey(day: b.day, app: b.app, model: b.model, speed: b.speed)
            localBuckets[key] = b
        }
    }

    /// 恢复独立保存的远端日桶；不会影响本地 rollup。
    func loadRemote(from snapshot: [UsageBucket]) {
        remoteBuckets.removeAll(keepingCapacity: true)
        for bucket in snapshot where bucket.app == .cursor {
            let key = BucketKey(day: bucket.day, app: bucket.app, model: bucket.model, speed: bucket.speed)
            remoteBuckets[key] = bucket
        }
    }

    /// 本地扫描器的累计入口。远端数据不得调用此方法，以免重复拉取重复累计。
    func ingestLocal(_ entries: [UsageEntry]) {
        for e in entries where e.app != .cursor {
            let key = BucketKey(day: e.day, app: e.app, model: e.model, speed: e.speed)
            if var b = localBuckets[key] {
                b.inputTokens += e.inputTokens
                b.outputTokens += e.outputTokens
                b.cacheReadTokens += e.cacheReadTokens
                b.cacheCreationTokens += e.cacheCreationTokens
                // 缺少可靠价格（nil）按 0 计入聚合；桶内标记仅保留给诊断，不影响 UI 数值展示。
                b.costUSD += e.costUSD ?? 0
                b.requestCount += e.requestCount
                b.hasUnpricedUsage = b.hasUnpricedUsage || e.costUSD == nil
                localBuckets[key] = b
            } else {
                localBuckets[key] = UsageBucket(
                    app: e.app,
                    model: e.model,
                    speed: e.speed,
                    day: e.day,
                    inputTokens: e.inputTokens,
                    outputTokens: e.outputTokens,
                    cacheReadTokens: e.cacheReadTokens,
                    cacheCreationTokens: e.cacheCreationTokens,
                    costUSD: e.costUSD ?? 0,
                    requestCount: e.requestCount,
                    hasUnpricedUsage: e.costUSD == nil
                )
            }
        }
    }

    /// 兼容既有测试与调用方；新代码应明确使用 `ingestLocal(_:)`。
    func ingest(_ entries: [UsageEntry]) {
        ingestLocal(entries)
    }

    /// 用一段已经完整拉取的远端自然日桶原子替换同一 app 的对应日范围。
    /// 任何 fetch/解析失败都不应调用本方法，因此旧快照会继续保留。
    func replaceRemote(app: UsageApp, dayRange: Range<Date>, buckets: [UsageBucket]) {
        remoteBuckets = remoteBuckets.filter { key, _ in
            key.app != app || key.day < dayRange.lowerBound || key.day >= dayRange.upperBound
        }
        for bucket in buckets where bucket.app == app
            && bucket.day >= dayRange.lowerBound && bucket.day < dayRange.upperBound
        {
            let key = BucketKey(
                day: bucket.day,
                app: bucket.app,
                model: bucket.model,
                speed: bucket.speed
            )
            remoteBuckets[key] = bucket
        }
    }

    /// 用一份**完整重算**过的本地分区替换同一 app 的全部日桶。
    ///
    /// DSH 的日桶每次都从逐会话贡献整体重归并（草案 §3.3），必须走替换而不是增量累加，
    /// 否则 generation 切换或父链变化会把同一段历史加两遍。远端分区不受影响。
    /// 局部增量仍用 `ingestLocal(_:)`。
    func replaceLocal(app: UsageApp, buckets: [UsageBucket]) {
        localBuckets = localBuckets.filter { key, _ in key.app != app }
        for bucket in buckets where bucket.app == app {
            let key = BucketKey(
                day: bucket.day,
                app: bucket.app,
                model: bucket.model,
                speed: bucket.speed
            )
            localBuckets[key] = bucket
        }
    }

    /// 仅本地日志分区；供扫描状态、定价指纹、缺价补全及本地 rollup 持久化使用。
    func snapshotLocal() -> [UsageBucket] {
        Array(localBuckets.values)
    }

    /// 供远端独立缓存持久化使用；不会返回本地分区。
    func snapshotRemote(app: UsageApp) -> [UsageBucket] {
        remoteBuckets.values.filter { $0.app == app }
    }

    /// 本地与远端分区的合并读快照，仅供展示层使用。
    func snapshot() -> [UsageBucket] {
        Array(localBuckets.values) + Array(remoteBuckets.values)
    }

    func todayCost(for app: UsageApp, now: Date = Date()) -> Decimal {
        let today = UsageDay.startOfDay(for: now)
        var sum: Decimal = 0
        for b in localBuckets.values where b.app == app && b.day == today {
            sum += b.costUSD
        }
        for b in remoteBuckets.values where b.app == app && b.day == today {
            sum += b.costUSD
        }
        return sum
    }

    /// 给 M6 复用：按时间范围 / 应用聚合。
    func totals(app: UsageApp, from: Date, to: Date) -> UsageTotals {
        var totals = UsageTotals.zero
        for b in localBuckets.values where b.app == app && b.day >= from && b.day < to {
            totals.add(b)
        }
        for b in remoteBuckets.values where b.app == app && b.day >= from && b.day < to {
            totals.add(b)
        }
        return totals
    }
}
