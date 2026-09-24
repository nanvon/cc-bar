import Foundation
import CoreGraphics

// MARK: - Input

/// 半开日期区间 `[from, to)`，与日桶的 `day >= from && day < to` 过滤口径一致。
struct StatsDateInterval: Equatable {
    let from: Date
    let to: Date

    func contains(_ day: Date) -> Bool {
        day >= from && day < to
    }
}

/// 概览派生结果的全部输入，同时充当缓存键：任一字段变化才重新派生。
///
/// 日期边界都是按「当天 0 点 / 周期起点」取整后的值，同一天内反复求值结果相同，
/// 跨过午夜后边界变化会自然让缓存失效，不需要单独放 `now`。
struct StatsOverviewInput: Equatable {
    /// `UsageAggregator.revision`：聚合数据任何写入都会让它变化。
    let revision: UInt64
    /// KPI、Token 拆分、按服务 / 模型 / 提供商统计的范围。
    let current: StatsDateInterval
    /// 上一个等长区间；`.all` / `.custom` 为 nil，此时所有 delta 不展示。
    let previous: StatsDateInterval?
    /// 用量图表的展示范围；单周期范围下会扩展成近 14 个周期的上下文窗口。
    let chart: StatsDateInterval
    let granularity: StatsGranularity
    /// 侧栏服务过滤；nil = 全部。
    let serviceApp: UsageApp?
    /// 设置里开启且当前可用的统计服务，按固定顺序。
    let visibleApps: [UsageApp]
    /// 上下文窗口模式下唯一全彩的那根柱子的周期起点；非上下文模式为 nil。
    let highlightedPeriodStart: Date?
}

// MARK: - Model

/// 统计页「概览」的全部派生数据。
///
/// 由 `build(buckets:input:)` 对日桶**只遍历一次**得到，各面板只读结果、不再自己过滤聚合。
/// 纯值类型、不依赖 SwiftUI，口径由 `StatsOverviewModelTests` 锁定。
struct StatsOverviewModel {
    let visibleApps: [UsageApp]
    /// 是否存在可对比的上一区间（决定 KPI 卡是否展示 delta）。
    let hasPreviousRange: Bool
    let totalsAll: UsageTotals
    let previousTotalsAll: UsageTotals
    let speedAll: UsageSpeedBreakdown
    /// 图表的周期序列，按周期起点升序。
    let samples: [DailySample]
    /// 固定柱宽：周期很少时避免柱子被自动撑满绘图区，周期多时调窄。
    let barWidth: CGFloat
    let highlightedPeriodStart: Date?
    /// 未排序的提供商分组；排序键在面板里切换，见 `ProviderGroup.sorted(_:by:)`。
    let providerGroups: [ProviderGroup]

    private let totalsByApp: [UsageApp: UsageTotals]
    private let previousTotalsByApp: [UsageApp: UsageTotals]
    private let speedByApp: [UsageApp: UsageSpeedBreakdown]
    private let modelRowsByApp: [UsageApp: [ModelRow]]

    /// 当前范围内某服务的合计；受侧栏服务过滤约束，被过滤掉的服务为 0。
    func totals(_ app: UsageApp) -> UsageTotals {
        totalsByApp[app] ?? .zero
    }

    /// 上一区间某服务的合计；只受可见性约束、不受侧栏服务过滤约束（KPI 卡被过滤时本就不展示 delta）。
    func previousTotals(_ app: UsageApp) -> UsageTotals {
        previousTotalsByApp[app] ?? .zero
    }

    func speed(_ app: UsageApp) -> UsageSpeedBreakdown {
        speedByApp[app] ?? UsageSpeedBreakdown()
    }

    /// 某服务的按模型明细，按费用降序、同值按模型名升序。
    func modelRows(_ app: UsageApp) -> [ModelRow] {
        modelRowsByApp[app] ?? []
    }

    /// 按周期类别键找图表样本（悬停选中用）。
    func sample(forKey key: String) -> DailySample? {
        samples.first { $0.key == key }
    }

    static func build(buckets: [UsageBucket], input: StatsOverviewInput) -> StatsOverviewModel {
        let visible = Set(input.visibleApps)
        let serviceApp = input.serviceApp

        var totalsAll = UsageTotals.zero
        var previousTotalsAll = UsageTotals.zero
        var speedAll = UsageSpeedBreakdown()
        var totalsByApp: [UsageApp: UsageTotals] = [:]
        var previousTotalsByApp: [UsageApp: UsageTotals] = [:]
        var speedByApp: [UsageApp: UsageSpeedBreakdown] = [:]
        var modelsByApp: [UsageApp: [String: (totals: UsageTotals, speed: UsageSpeedBreakdown)]] = [:]
        var groupsByProvider: [ModelProvider: ProviderGroup] = [:]
        var samplesByPeriod: [Date: DailySample] = [:]
        // 同一天 / 同一模型的桶有很多个，周期归并和提供商推导都按键记忆，避免重复做日历与字符串运算。
        var periodStartByDay: [Date: Date] = [:]
        var providerByModel: [ProviderModelKey: ModelProvider] = [:]

        for bucket in buckets where visible.contains(bucket.app) {
            let passesService = serviceApp == nil || bucket.app == serviceApp

            if let previous = input.previous, previous.contains(bucket.day) {
                previousTotalsByApp[bucket.app, default: .zero].add(bucket)
                if passesService { previousTotalsAll.add(bucket) }
            }

            guard passesService else { continue }

            if input.chart.contains(bucket.day) {
                let periodStart: Date
                if let cached = periodStartByDay[bucket.day] {
                    periodStart = cached
                } else {
                    periodStart = input.granularity.bucketStart(for: bucket.day)
                    periodStartByDay[bucket.day] = periodStart
                }
                samplesByPeriod[periodStart, default: DailySample(day: periodStart)].add(bucket)
            }

            guard input.current.contains(bucket.day) else { continue }

            totalsAll.add(bucket)
            speedAll.add(bucket)
            totalsByApp[bucket.app, default: .zero].add(bucket)
            speedByApp[bucket.app, default: UsageSpeedBreakdown()].add(bucket)

            var modelItem = modelsByApp[bucket.app]?[bucket.model]
                ?? (totals: UsageTotals.zero, speed: UsageSpeedBreakdown())
            modelItem.totals.add(bucket)
            modelItem.speed.add(bucket)
            modelsByApp[bucket.app, default: [:]][bucket.model] = modelItem

            let providerKey = ProviderModelKey(app: bucket.app, model: bucket.model)
            let provider: ModelProvider
            if let cached = providerByModel[providerKey] {
                provider = cached
            } else {
                provider = ModelProvider.resolve(app: bucket.app, model: bucket.model)
                providerByModel[providerKey] = provider
            }
            groupsByProvider[provider, default: ProviderGroup(provider: provider)].add(bucket)
        }

        let modelRowsByApp = modelsByApp.mapValues { byModel in
            byModel
                .map { ModelRow(model: $0.key, totals: $0.value.totals, speed: $0.value.speed) }
                .sorted {
                    if $0.totals.costUSD == $1.totals.costUSD {
                        return $0.model < $1.model
                    }
                    return $0.totals.costUSD > $1.totals.costUSD
                }
        }

        var samples = Array(samplesByPeriod.values)
        samples.sort { $0.day < $1.day }
        for index in samples.indices {
            samples[index].key = StatsPeriodKey.key(for: samples[index].day)
        }

        return StatsOverviewModel(
            visibleApps: input.visibleApps,
            hasPreviousRange: input.previous != nil,
            totalsAll: totalsAll,
            previousTotalsAll: previousTotalsAll,
            speedAll: speedAll,
            samples: samples,
            barWidth: barWidth(forSampleCount: samples.count),
            highlightedPeriodStart: input.highlightedPeriodStart,
            providerGroups: Array(groupsByProvider.values),
            totalsByApp: totalsByApp,
            previousTotalsByApp: previousTotalsByApp,
            speedByApp: speedByApp,
            modelRowsByApp: modelRowsByApp
        )
    }

    /// X 轴刻度取自桶自己的类别键，不按日历 stride 推算；超过 `maxCount` 时从第一个起
    /// 每隔 step 个取一个，保证刻度落在某根柱子上且总数不超过 `maxCount`。
    /// `maxCount` 由图表按绘图区宽度算出，见 `OverviewUsageChartPanel`。
    static func axisKeys(from keys: [String], maxCount: Int) -> [String] {
        let limit = max(1, maxCount)
        guard keys.count > limit else { return keys }
        let step = (keys.count + limit - 1) / limit
        return stride(from: 0, to: keys.count, by: step).map { keys[$0] }
    }

    /// 柱宽用固定值而非交给 Swift Charts 自动计算——天数很少(极端情况只有 1 天)时,
    /// 自动宽度会把柱子撑到接近整个绘图区;天数越多则相应调窄,避免拥挤。
    private static func barWidth(forSampleCount count: Int) -> CGFloat {
        switch count {
        case 0...3: return 28
        case 4...14: return 18
        case 15...45: return 10
        default: return 5
        }
    }

    private struct ProviderModelKey: Hashable {
        let app: UsageApp
        let model: String
    }
}

// MARK: - Cache

/// 概览派生结果的同步记忆缓存。
///
/// 放在视图的 `@State` 里；它本身不是 `@Observable`，body 内读写不会触发额外刷新。
/// 依赖登记由调用方读取 `aggregator.revision` 与各项设置完成，输入不变就直接复用上次结果，
/// 悬停、展开、排序等不改变输入的刷新都不会重新派生。
final class StatsOverviewCache {
    private var input: StatsOverviewInput?
    private var model: StatsOverviewModel?

    func model(
        for input: StatsOverviewInput,
        buckets: () -> [UsageBucket]
    ) -> StatsOverviewModel {
        if let model, self.input == input { return model }
        let built = StatsOverviewModel.build(buckets: buckets(), input: input)
        self.input = input
        self.model = built
        return built
    }
}

// MARK: - Row models

/// 用量图表的 X 轴不用日期轴，改用「每个周期一个类别」的离散轴：日期轴上 Swift Charts
/// 会按自己推断(或指定)的 unit 给柱子分箱、把柱心挪到箱中点，刻度却落在箱起点，日 / 周 /
/// 月三种粒度都对不齐；周粒度还会按 `Calendar.current` 的周起点(可能是周日)算箱边界，
/// 和本项目的周一口径再差一天。类别轴下柱心与刻度共用同一个 band 中心，天然对齐。
enum StatsPeriodKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for day: Date) -> String { formatter.string(from: day) }
    static func date(from key: String) -> Date? { formatter.date(from: key) }
}

/// 图表的一根柱。`day` 是该柱所属周期的起点(日粒度即当天,周粒度为周一,月粒度为 1 号),
/// 命名沿用历史,不随粒度改名。
struct DailySample: Identifiable {
    var id: Date { day }
    let day: Date
    /// 用量图表 X 轴用的离散类别键，见 `StatsPeriodKey`。
    var key: String = ""
    var codex = UsageTotals.zero
    var claude = UsageTotals.zero
    var cursor = UsageTotals.zero
    var pi = UsageTotals.zero
    var opencode = UsageTotals.zero
    var dsh = UsageTotals.zero

    init(day: Date) {
        self.day = day
    }

    var totalCost: Decimal { totalUsage.costUSD }
    var totalTokens: Int { totalUsage.totalTokens }

    mutating func add(_ bucket: UsageBucket) {
        switch bucket.app {
        case .codex: codex.add(bucket)
        case .claude: claude.add(bucket)
        case .cursor: cursor.add(bucket)
        case .pi: pi.add(bucket)
        case .opencode: opencode.add(bucket)
        case .dsh: dsh.add(bucket)
        }
    }

    func totals(for app: UsageApp) -> UsageTotals {
        switch app {
        case .codex: return codex
        case .claude: return claude
        case .cursor: return cursor
        case .pi: return pi
        case .opencode: return opencode
        case .dsh: return dsh
        }
    }

    func cost(for app: UsageApp) -> Decimal {
        totals(for: app).costUSD
    }

    /// 所有统计服务合并后的口径，供每日悬浮明细展示 token 拆分 + 命中率。
    var totalUsage: UsageTotals {
        var t = UsageTotals.zero
        for totals in [codex, claude, cursor, pi, opencode, dsh] {
            t.add(totals)
        }
        return t
    }
}

struct ModelRow: Identifiable {
    var id: String { model }
    let model: String
    let totals: UsageTotals
    let speed: UsageSpeedBreakdown
}

/// 「按提供商」面板的提供商级聚合：跨服务归并 totals / 速度拆分，保留来源服务与模型子明细。
struct ProviderGroup: Identifiable {
    var id: ModelProvider { provider }
    let provider: ModelProvider
    var totals = UsageTotals.zero
    var speed = UsageSpeedBreakdown()
    var sources: Set<UsageApp> = []
    var models: [ProviderModelRow] = []

    mutating func add(_ bucket: UsageBucket) {
        totals.add(bucket)
        speed.add(bucket)
        sources.insert(bucket.app)
        if let idx = models.firstIndex(where: { $0.app == bucket.app && $0.model == bucket.model }) {
            models[idx].totals.add(bucket)
            models[idx].speed.add(bucket)
        } else {
            var totals = UsageTotals.zero
            totals.add(bucket)
            var speed = UsageSpeedBreakdown()
            speed.add(bucket)
            models.append(ProviderModelRow(model: bucket.model, app: bucket.app, totals: totals, speed: speed))
        }
    }

    /// 按排序键排列提供商及其模型明细；`other` 组在任何排序下都固定排最后，
    /// 数值键相等时按提供商名 / 模型名升序，保证跨渲染顺序稳定（分组来自字典遍历，本身无序）。
    static func sorted(_ groups: [ProviderGroup], by sort: ProviderSort) -> [ProviderGroup] {
        groups
            .map { group in
                var g = group
                g.models = sortedModels(g.models, by: sort)
                return g
            }
            .sorted { lhs, rhs in
                let lOther = lhs.provider == .other
                let rOther = rhs.provider == .other
                if lOther != rOther { return !lOther }
                switch sort {
                case .cost:
                    if lhs.totals.costUSD == rhs.totals.costUSD { return compareByName(lhs, rhs) }
                    return lhs.totals.costUSD > rhs.totals.costUSD
                case .tokens:
                    if lhs.totals.totalTokens == rhs.totals.totalTokens { return compareByName(lhs, rhs) }
                    return lhs.totals.totalTokens > rhs.totals.totalTokens
                case .requests:
                    if lhs.totals.requestCount == rhs.totals.requestCount { return compareByName(lhs, rhs) }
                    return lhs.totals.requestCount > rhs.totals.requestCount
                case .name:
                    return compareByName(lhs, rhs)
                }
            }
    }

    private static func compareByName(_ lhs: ProviderGroup, _ rhs: ProviderGroup) -> Bool {
        lhs.provider.displayName.localizedCaseInsensitiveCompare(
            rhs.provider.displayName
        ) == .orderedAscending
    }

    /// 提供商展开区模型明细行：跟随面板排序键，数值大的在前，同值按模型名升序稳定。
    private static func sortedModels(_ models: [ProviderModelRow], by sort: ProviderSort) -> [ProviderModelRow] {
        models.sorted { lhs, rhs in
            switch sort {
            case .cost:
                if lhs.totals.costUSD == rhs.totals.costUSD { return lhs.model < rhs.model }
                return lhs.totals.costUSD > rhs.totals.costUSD
            case .tokens:
                if lhs.totals.totalTokens == rhs.totals.totalTokens { return lhs.model < rhs.model }
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            case .requests:
                if lhs.totals.requestCount == rhs.totals.requestCount { return lhs.model < rhs.model }
                return lhs.totals.requestCount > rhs.totals.requestCount
            case .name:
                return lhs.model < rhs.model
            }
        }
    }
}

/// 提供商展开区内的模型明细行（模型 + 来源服务）。
struct ProviderModelRow: Identifiable {
    var id: String { "\(app.rawValue)/\(model)" }
    let model: String
    let app: UsageApp
    var totals: UsageTotals
    var speed: UsageSpeedBreakdown
}
