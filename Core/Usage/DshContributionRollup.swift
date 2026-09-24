import Foundation

/// 把逐会话贡献归并成 DSH 的两个主 rollup（草案 §3.3、§4.1）。
///
/// 归并规则：
///   - **日桶**（`UsageBucket`）按 (日, 模型, 速度) 汇总**全部**贡献，与归根结果无关，总量不因归并改变。
///   - **对话桶**（`ConversationUsageBucket`）按**根会话**归并：子代理的用量记到所属根，
///     对话只显示一行并标 `includesSubtasks`。
///   - 父文件缺失时子会话先作为根，不丢用量；父文件后来出现时只要重新调用本函数，
///     已有贡献就会重新归根（不是只给未来条目换 key）。
///   - 父链设环与深度上限保护：异常日志不能把归并拖住。
nonisolated enum DshContributionRollup {
    struct Output: Sendable, Equatable {
        var dayBuckets: [UsageBucket]
        var conversationBuckets: [ConversationUsageBucket]
        var conversationInfos: [ConversationInfo]
    }

    /// 归根的最大层数；超过即按异常处理，停在当前节点。
    static let maxDepth = 64

    static func reduce(_ contributions: [String: DshContribution]) -> Output {
        let conversationKeyPrefix = "dsh:"

        // 1) 解析每个会话的根：父链必须存在且无环。
        /// 成环时取环上字典序最小的 id 作根，保证同一环内所有会话归根一致
        /// （否则互为父子的两个会话会各归各的，对话列表出现重复行）。
        func root(of id: String) -> String {
            var current = id
            var path: [String] = [current]
            var visited: Set<String> = [current]
            var depth = 0
            while depth < maxDepth {
                guard let parent = contributions[current]?.parentSession,
                      !parent.isEmpty,
                      contributions[parent] != nil
                else { break }
                guard visited.insert(parent).inserted else {
                    guard let start = path.firstIndex(of: parent) else { return parent }
                    return path[start...].min() ?? parent
                }
                path.append(parent)
                current = parent
                depth += 1
            }
            return current
        }

        var roots: [String: String] = [:]
        roots.reserveCapacity(contributions.count)
        for id in contributions.keys {
            roots[id] = root(of: id)
        }

        // 2) 日桶：全部贡献按 (日, 模型, 速度) 汇总。
        var dayBuckets: [DayBucketKey: UsageBucket] = [:]
        // 3) 对话桶：按根会话汇总。
        var conversationBuckets: [ConversationBucketKey: ConversationUsageBucket] = [:]

        for (id, contribution) in contributions {
            let rootID = roots[id] ?? id
            let conversationKey = "\(conversationKeyPrefix)\(rootID)"
            for bucket in contribution.usage {
                let dayKey = DayBucketKey(day: bucket.day, model: bucket.model, speed: bucket.speed)
                if var existing = dayBuckets[dayKey] {
                    existing.inputTokens += bucket.inputTokens
                    existing.outputTokens += bucket.outputTokens
                    existing.cacheReadTokens += bucket.cacheReadTokens
                    existing.cacheCreationTokens += bucket.cacheCreationTokens
                    existing.costUSD += bucket.costUSD
                    existing.requestCount += bucket.requestCount
                    existing.hasUnpricedUsage = existing.hasUnpricedUsage || bucket.hasUnpricedUsage
                    dayBuckets[dayKey] = existing
                } else {
                    dayBuckets[dayKey] = UsageBucket(
                        app: .dsh,
                        model: bucket.model,
                        speed: bucket.speed,
                        day: bucket.day,
                        inputTokens: bucket.inputTokens,
                        outputTokens: bucket.outputTokens,
                        cacheReadTokens: bucket.cacheReadTokens,
                        cacheCreationTokens: bucket.cacheCreationTokens,
                        costUSD: bucket.costUSD,
                        requestCount: bucket.requestCount,
                        hasUnpricedUsage: bucket.hasUnpricedUsage
                    )
                }

                let conversationKeyValue = ConversationBucketKey(
                    conversationKey: conversationKey,
                    day: bucket.day,
                    model: bucket.model,
                    speed: bucket.speed
                )
                if var existing = conversationBuckets[conversationKeyValue] {
                    existing.inputTokens += bucket.inputTokens
                    existing.outputTokens += bucket.outputTokens
                    existing.cacheReadTokens += bucket.cacheReadTokens
                    existing.cacheCreationTokens += bucket.cacheCreationTokens
                    existing.requestCount += bucket.requestCount
                    existing.costUSD += bucket.costUSD
                    existing.inputCostUSD += bucket.costInput
                    existing.outputCostUSD += bucket.costOutput
                    existing.cacheReadCostUSD += bucket.costCacheRead
                    existing.cacheCreationCostUSD += bucket.costCacheCreation
                    existing.hasUnpricedUsage = existing.hasUnpricedUsage || bucket.hasUnpricedUsage
                    existing.firstAt = min(existing.firstAt, bucket.firstAt)
                    existing.lastAt = max(existing.lastAt, bucket.lastAt)
                    conversationBuckets[conversationKeyValue] = existing
                } else {
                    conversationBuckets[conversationKeyValue] = ConversationUsageBucket(
                        conversationKey: conversationKey,
                        app: .dsh,
                        day: bucket.day,
                        model: bucket.model,
                        speed: bucket.speed,
                        firstAt: bucket.firstAt,
                        lastAt: bucket.lastAt,
                        inputTokens: bucket.inputTokens,
                        outputTokens: bucket.outputTokens,
                        cacheReadTokens: bucket.cacheReadTokens,
                        cacheCreationTokens: bucket.cacheCreationTokens,
                        requestCount: bucket.requestCount,
                        costUSD: bucket.costUSD,
                        inputCostUSD: bucket.costInput,
                        outputCostUSD: bucket.costOutput,
                        cacheReadCostUSD: bucket.costCacheRead,
                        cacheCreationCostUSD: bucket.costCacheCreation,
                        hasUnpricedUsage: bucket.hasUnpricedUsage
                    )
                }
            }
        }

        // 4) 对话档案：只有真正有用量的会话才出现在对话列表里。
        var membersByRoot: [String: [DshContribution]] = [:]
        for (id, contribution) in contributions where !contribution.usage.isEmpty {
            membersByRoot[roots[id] ?? id, default: []].append(contribution)
        }

        var projectResolver = ConversationProjectResolver()
        var infos: [ConversationInfo] = []
        for (rootID, members) in membersByRoot {
            let sortedMembers = members.sorted { $0.sessionID < $1.sessionID }
            let rootContribution = contributions[rootID]
            let cwd = rootContribution?.cwd ?? sortedMembers.compactMap(\.cwd).first
            let project = projectResolver.resolve(rawPath: cwd ?? "", source: .cwd)
            let firstAt = sortedMembers.flatMap(\.usage).map(\.firstAt).min() ?? Date.distantPast
            let lastAt = sortedMembers.flatMap(\.usage).map(\.lastAt).max() ?? Date.distantPast
            infos.append(ConversationInfo(
                key: "dsh:\(rootID)",
                conversationID: rootID,
                app: .dsh,
                title: rootContribution?.title ?? sortedMembers.compactMap(\.title).first,
                projectKey: project.key,
                projectName: project.name,
                projectPath: project.path,
                projectStatus: project.status,
                projectSource: project.source,
                gitBranch: nil,
                sourcePaths: sortedMembers.map(\.sourcePath).filter { !$0.isEmpty }.sorted(),
                firstAt: firstAt,
                lastAt: lastAt,
                includesSubtasks: sortedMembers.count > 1,
                cacheCreationAvailable: true
            ))
        }

        return Output(
            dayBuckets: dayBuckets.values.sorted { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day < rhs.day }
                if lhs.model != rhs.model { return lhs.model < rhs.model }
                return lhs.speed.rawValue < rhs.speed.rawValue
            },
            conversationBuckets: conversationBuckets.values.sorted { $0.conversationKey < $1.conversationKey },
            conversationInfos: infos.sorted { $0.key < $1.key }
        )
    }

    /// 日桶键：刻意不复用 `UsageAggregator.BucketKey`（那是 MainActor 类的嵌套类型，
    /// 本类型要在非隔离上下文里做归并）。
    private struct DayBucketKey: Hashable {
        let day: Date
        let model: String
        let speed: UsageSpeed
    }

    private struct ConversationBucketKey: Hashable {
        let conversationKey: String
        let day: Date
        let model: String
        let speed: UsageSpeed
    }
}
