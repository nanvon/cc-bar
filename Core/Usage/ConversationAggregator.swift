import Foundation
import Observation

/// 与现有按日聚合并行的对话聚合器；列表按范围查询，详情始终聚合完整生命周期。
@MainActor
@Observable
final class ConversationAggregator {
    private var infos: [String: ConversationInfo] = [:]
    private var buckets: [BucketKey: ConversationUsageBucket] = [:]
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private var cachedQuery: (request: ConversationQueryRequest, result: ConversationQueryResult)?
    @ObservationIgnored private var cachedDetail: (revision: UInt64, key: String, detail: ConversationDetail)?

    private struct BucketKey: Hashable {
        let conversationKey: String
        let day: Date
        let model: String
        let speed: UsageSpeed
    }

    private struct ProjectAccumulator {
        var info: ConversationInfo
        var conversationCount: Int
        var lastAt: Date
    }

    var isEmpty: Bool { buckets.isEmpty }

    func load(infos: [ConversationInfo], buckets: [ConversationUsageBucket]) {
        self.infos = Dictionary(uniqueKeysWithValues: infos.map { ($0.key, $0) })
        self.buckets = Dictionary(uniqueKeysWithValues: buckets.map {
            (BucketKey(conversationKey: $0.conversationKey, day: $0.day, model: $0.model, speed: $0.speed), $0)
        })
        markChanged()
    }

    @discardableResult
    func ingest(entries: [UsageEntry], seeds: [ConversationSeed]) -> Bool {
        var changed = false
        var conversationKeysWithUsage = Set(buckets.keys.map(\.conversationKey))
        conversationKeysWithUsage.formUnion(entries.map(\.conversationKey))
        for seed in seeds where conversationKeysWithUsage.contains(seed.key) {
            changed = merge(seed: seed) || changed
        }

        for entry in entries {
            changed = true
            let key = BucketKey(
                conversationKey: entry.conversationKey,
                day: entry.day,
                model: entry.model,
                speed: entry.speed
            )
            let breakdown = entry.costBreakdown
            if var bucket = buckets[key] {
                bucket.inputTokens += entry.inputTokens
                bucket.outputTokens += entry.outputTokens
                bucket.cacheReadTokens += entry.cacheReadTokens
                bucket.cacheCreationTokens += entry.cacheCreationTokens
                bucket.requestCount += entry.requestCount
                bucket.firstAt = min(bucket.firstAt, entry.timestamp)
                bucket.lastAt = max(bucket.lastAt, entry.timestamp)
                bucket.costUSD += breakdown?.total ?? 0
                bucket.inputCostUSD += breakdown?.input ?? 0
                bucket.outputCostUSD += breakdown?.output ?? 0
                bucket.cacheReadCostUSD += breakdown?.cacheRead ?? 0
                bucket.cacheCreationCostUSD += breakdown?.cacheCreation ?? 0
                bucket.hasUnpricedUsage = bucket.hasUnpricedUsage || breakdown == nil
                buckets[key] = bucket
            } else {
                buckets[key] = ConversationUsageBucket(
                    conversationKey: entry.conversationKey,
                    app: entry.app,
                    day: entry.day,
                    model: entry.model,
                    speed: entry.speed,
                    firstAt: entry.timestamp,
                    lastAt: entry.timestamp,
                    inputTokens: entry.inputTokens,
                    outputTokens: entry.outputTokens,
                    cacheReadTokens: entry.cacheReadTokens,
                    cacheCreationTokens: entry.cacheCreationTokens,
                    requestCount: entry.requestCount,
                    costUSD: breakdown?.total ?? 0,
                    inputCostUSD: breakdown?.input ?? 0,
                    outputCostUSD: breakdown?.output ?? 0,
                    cacheReadCostUSD: breakdown?.cacheRead ?? 0,
                    cacheCreationCostUSD: breakdown?.cacheCreation ?? 0,
                    hasUnpricedUsage: breakdown == nil
                )
            }

            if var info = infos[entry.conversationKey] {
                info.firstAt = min(info.firstAt, entry.timestamp)
                info.lastAt = max(info.lastAt, entry.timestamp)
                infos[entry.conversationKey] = info
            }
        }

        conversationKeysWithUsage = Set(buckets.keys.map(\.conversationKey))
        for key in Array(infos.keys) where !conversationKeysWithUsage.contains(key) {
            infos.removeValue(forKey: key)
            changed = true
        }

        if changed { markChanged() }
        return changed
    }

    /// 用完整重算过的结果替换同一 app 的对话档案与对话桶，其他 app 的分区原样保留。
    ///
    /// DSH 的对话视图每次都从逐会话贡献重新归根（草案 §3.3、§4.1），走这里而不是
    /// `ingest(entries:seeds:)`——父文件后到、父链改变、generation 切换都会改变归根结果，
    /// 增量合并无法把已经记错 key 的历史迁走。
    @discardableResult
    func replaceLocal(
        app: UsageApp,
        infos newInfos: [ConversationInfo],
        buckets newBuckets: [ConversationUsageBucket]
    ) -> Bool {
        var keptInfos = infos.filter { $0.value.app != app }
        var keptBuckets = buckets.filter { $0.value.app != app }
        var changed = keptInfos.count != infos.count || keptBuckets.count != buckets.count

        for info in newInfos where info.app == app {
            if keptInfos[info.key] != info { changed = true }
            keptInfos[info.key] = info
        }
        for bucket in newBuckets where bucket.app == app {
            let key = BucketKey(
                conversationKey: bucket.conversationKey,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            if keptBuckets[key] != bucket { changed = true }
            keptBuckets[key] = bucket
        }

        infos = keptInfos
        buckets = keptBuckets
        if changed { markChanged() }
        return changed
    }

    func snapshot() -> (infos: [ConversationInfo], buckets: [ConversationUsageBucket]) {
        (Array(infos.values), Array(buckets.values))
    }

    func query(_ rawRequest: ConversationQueryRequest) -> ConversationQueryResult {
        var request = rawRequest
        request.revision = revision
        request.search = request.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cachedQuery, cachedQuery.request == request { return cachedQuery.result }

        var grouped: [String: [ConversationUsageBucket]] = [:]
        for bucket in buckets.values where bucket.day >= request.from && bucket.day < request.to {
            if let app = request.app, bucket.app != app { continue }
            grouped[bucket.conversationKey, default: []].append(bucket)
        }

        var allSummaries: [ConversationSummary] = []
        var projects: [String: ProjectAccumulator] = [:]
        allSummaries.reserveCapacity(grouped.count)
        for (key, values) in grouped {
            guard let info = infos[key] else { continue }
            let item = aggregate(values)
            var rangeLastAt = Date.distantPast
            var modelNames: Set<String> = []
            for value in values {
                rangeLastAt = max(rangeLastAt, value.lastAt)
                modelNames.insert(value.model)
            }
            let summary = ConversationSummary(
                info: info,
                totals: item.totals,
                costs: item.costs,
                speed: item.speed,
                models: modelNames.sorted(),
                rangeLastAt: rangeLastAt
            )
            allSummaries.append(summary)
            if var project = projects[info.projectKey] {
                project.conversationCount += 1
                project.lastAt = max(project.lastAt, rangeLastAt)
                projects[info.projectKey] = project
            } else {
                projects[info.projectKey] = ProjectAccumulator(
                    info: info,
                    conversationCount: 1,
                    lastAt: rangeLastAt
                )
            }
        }

        let projectOptions = projects.values.map {
            ConversationProjectOption(
                key: $0.info.projectKey,
                name: $0.info.projectName,
                path: $0.info.projectPath,
                status: $0.info.projectStatus,
                conversationCount: $0.conversationCount,
                lastAt: $0.lastAt
            )
        }
        let duplicateNames = Dictionary(grouping: projectOptions.filter {
            $0.status.isPathBased
        }, by: \.name)
            .compactMap { $0.value.count > 1 ? $0.key : nil }

        var rows = allSummaries.filter { summary in
            if let projectKey = request.projectKey, summary.info.projectKey != projectKey { return false }
            if !request.search.isEmpty {
                let info = summary.info
                let haystack = [info.title ?? "", info.projectName, info.projectPath, info.conversationID]
                    .joined(separator: " ").lowercased()
                if !haystack.contains(request.search) { return false }
            }
            return true
        }
        rows.sort { lhs, rhs in
            switch request.sort {
            case .recent: return lhs.rangeLastAt > rhs.rangeLastAt
            case .tokens:
                return lhs.totals.totalTokens == rhs.totals.totalTokens
                    ? lhs.rangeLastAt > rhs.rangeLastAt
                    : lhs.totals.totalTokens > rhs.totals.totalTokens
            case .cost:
                return lhs.costs.total == rhs.costs.total
                    ? lhs.rangeLastAt > rhs.rangeLastAt
                    : lhs.costs.total > rhs.costs.total
            }
        }
        let result = ConversationQueryResult(
            rows: rows,
            projectOptions: projectOptions,
            projectConversationCount: allSummaries.count,
            projectKeys: Set(projectOptions.map(\.key)),
            duplicateProjectNames: Set(duplicateNames)
        )
        cachedQuery = (request, result)
        return result
    }

    func detail(key: String) -> ConversationDetail? {
        if let cachedDetail, cachedDetail.revision == revision, cachedDetail.key == key {
            return cachedDetail.detail
        }
        guard let info = infos[key] else { return nil }
        let values = buckets.values.filter { $0.conversationKey == key }
        let overall = aggregate(Array(values))
        var perModel: [String: [ConversationUsageBucket]] = [:]
        for value in values { perModel[value.model, default: []].append(value) }
        var models: [ConversationModelSummary] = []
        for (model, modelBuckets) in perModel {
            let item = aggregate(modelBuckets)
            models.append(ConversationModelSummary(model: model, totals: item.totals, costs: item.costs, speed: item.speed))
        }
        models.sort { lhs, rhs in
            if lhs.costs.total == rhs.costs.total { return lhs.model < rhs.model }
            return lhs.costs.total > rhs.costs.total
        }
        let detail = ConversationDetail(
            info: info,
            totals: overall.totals,
            costs: overall.costs,
            speed: overall.speed,
            models: models
        )
        cachedDetail = (revision, key, detail)
        return detail
    }

    private func merge(seed: ConversationSeed) -> Bool {
        if var info = infos[seed.key] {
            let original = info
            if let title = seed.title, !title.isEmpty { info.title = title }
            let sameProject = info.projectKey == seed.project.key
            let shouldReplaceProject = info.projectStatus == .unassigned
                || seed.project.source.priority > info.projectSource.priority
            if sameProject || (seed.project.status != .unassigned && shouldReplaceProject) {
                info.projectKey = seed.project.key
                info.projectName = seed.project.name
                info.projectPath = seed.project.path
                info.projectStatus = seed.project.status
                info.projectSource = seed.project.source
            }
            if info.gitBranch == nil { info.gitBranch = seed.gitBranch }
            if !info.sourcePaths.contains(seed.sourcePath) { info.sourcePaths.append(seed.sourcePath) }
            info.includesSubtasks = info.includesSubtasks || seed.includesSubtasks
            info.cacheCreationAvailable = info.cacheCreationAvailable || seed.cacheCreationAvailable
            guard info != original else { return false }
            infos[seed.key] = info
            return true
        } else {
            let now = Date.distantFuture
            infos[seed.key] = ConversationInfo(
                key: seed.key,
                conversationID: seed.id,
                app: seed.app,
                title: seed.title,
                projectKey: seed.project.key,
                projectName: seed.project.name,
                projectPath: seed.project.path,
                projectStatus: seed.project.status,
                projectSource: seed.project.source,
                gitBranch: seed.gitBranch,
                sourcePaths: [seed.sourcePath],
                firstAt: now,
                lastAt: .distantPast,
                includesSubtasks: seed.includesSubtasks,
                cacheCreationAvailable: seed.cacheCreationAvailable
            )
            return true
        }
    }

    private func aggregate(_ values: [ConversationUsageBucket]) -> (
        totals: UsageTotals,
        costs: ConversationCostTotals,
        speed: UsageSpeedBreakdown
    ) {
        var totals = UsageTotals.zero
        var costs = ConversationCostTotals()
        var speed = UsageSpeedBreakdown()
        for value in values {
            totals.inputTokens += value.inputTokens
            totals.outputTokens += value.outputTokens
            totals.cacheReadTokens += value.cacheReadTokens
            totals.cacheCreationTokens += value.cacheCreationTokens
            totals.costUSD += value.costUSD
            totals.requestCount += value.requestCount
            totals.hasUnpricedUsage = totals.hasUnpricedUsage || value.hasUnpricedUsage
            costs.input += value.inputCostUSD
            costs.output += value.outputCostUSD
            costs.cacheRead += value.cacheReadCostUSD
            costs.cacheCreation += value.cacheCreationCostUSD
            costs.hasUnpricedUsage = costs.hasUnpricedUsage || value.hasUnpricedUsage

            var bucketTotals = UsageTotals.zero
            bucketTotals.inputTokens = value.inputTokens
            bucketTotals.outputTokens = value.outputTokens
            bucketTotals.cacheReadTokens = value.cacheReadTokens
            bucketTotals.cacheCreationTokens = value.cacheCreationTokens
            bucketTotals.costUSD = value.costUSD
            bucketTotals.requestCount = value.requestCount
            speed.add(
                speed: value.speed,
                totals: bucketTotals,
                app: value.app,
                model: value.model,
                hasUnpricedCost: value.hasUnpricedUsage
            )
        }
        return (totals, costs, speed)
    }

    private func markChanged() {
        revision &+= 1
        cachedQuery = nil
        cachedDetail = nil
    }
}
