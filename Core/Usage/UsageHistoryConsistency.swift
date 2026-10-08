import Foundation

/// 用于对账的用量向量：完整键 + 四类 Tokens + 请求数。金额刻意不参与相等门槛
/// （价格目录变化正是重算要处理的情况），也不做总量兜底（总量相等不能证明覆盖完整）。
nonisolated struct UsageVectorCounts: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int

    static let zero = UsageVectorCounts(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        requestCount: 0
    )
}

nonisolated struct UsageVectorKey: Sendable, Hashable {
    var app: UsageApp
    var day: Date
    var model: String
    var speed: UsageSpeed
}

nonisolated struct ConversationVectorKey: Sendable, Hashable {
    var conversationKey: String
    var day: Date
    var model: String
    var speed: UsageSpeed
}

nonisolated struct CycleVectorKey: Sendable, Hashable {
    var cycleID: String
    var allowanceSegmentID: String?
    var app: UsageApp
    var model: String
    var speed: UsageSpeed
    var quality: CycleUsageQuality
}

/// 候选与基准的差异摘要。只保留数量级信息，不含路径、标题或任何正文。
nonisolated struct UsageRebuildMismatch: Sendable, Equatable {
    var usageKeysBaseline = 0
    var usageKeysCandidate = 0
    var usageKeysMissing = 0
    var usageKeysAdded = 0
    var usageKeysChanged = 0
    var conversationKeysBaseline = 0
    var conversationKeysCandidate = 0
    var conversationKeysMissing = 0
    var conversationKeysAdded = 0
    var conversationKeysChanged = 0
    var conversationsRemoved = 0
    var conversationsAdded = 0
    var conversationAttributionChanged = 0
    var cycleKeysBaseline = 0
    var cycleKeysCandidate = 0
    var cycleKeysMissing = 0
    var cycleKeysAdded = 0
    var cycleKeysChanged = 0

    var hasUsageDifference: Bool {
        usageKeysMissing > 0 || usageKeysAdded > 0 || usageKeysChanged > 0
            || conversationKeysMissing > 0 || conversationKeysAdded > 0 || conversationKeysChanged > 0
            || conversationsRemoved > 0 || conversationsAdded > 0 || conversationAttributionChanged > 0
    }

    var hasCycleDifference: Bool {
        cycleKeysMissing > 0 || cycleKeysAdded > 0 || cycleKeysChanged > 0
    }

    /// 脱敏摘要，写日志与 UI 提示用。
    var summary: String {
        var parts: [String] = []
        if usageKeysMissing > 0 { parts.append("day_keys_missing=\(usageKeysMissing)") }
        if usageKeysAdded > 0 { parts.append("day_keys_added=\(usageKeysAdded)") }
        if usageKeysChanged > 0 { parts.append("day_keys_changed=\(usageKeysChanged)") }
        if conversationKeysMissing > 0 { parts.append("conversation_keys_missing=\(conversationKeysMissing)") }
        if conversationKeysAdded > 0 { parts.append("conversation_keys_added=\(conversationKeysAdded)") }
        if conversationKeysChanged > 0 { parts.append("conversation_keys_changed=\(conversationKeysChanged)") }
        if conversationsRemoved > 0 { parts.append("conversations_removed=\(conversationsRemoved)") }
        if conversationsAdded > 0 { parts.append("conversations_added=\(conversationsAdded)") }
        if conversationAttributionChanged > 0 {
            parts.append("conversation_attribution_changed=\(conversationAttributionChanged)")
        }
        if cycleKeysMissing > 0 { parts.append("cycle_keys_missing=\(cycleKeysMissing)") }
        if cycleKeysAdded > 0 { parts.append("cycle_keys_added=\(cycleKeysAdded)") }
        if cycleKeysChanged > 0 { parts.append("cycle_keys_changed=\(cycleKeysChanged)") }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}

/// 受限恢复的核对：候选的完整用量向量必须与基准逐一相等才算通过。
/// 手动重建不走这道门槛（见 `UsageRebuildMerge`），比较结果只作诊断记录。
/// 不接受「总量不减少」「键集合是超集」「没有报错」这类弱证明。
nonisolated enum UsageHistoryConsistency {
    nonisolated static func dayVector(_ buckets: [UsageBucket]) -> [UsageVectorKey: UsageVectorCounts] {
        var result: [UsageVectorKey: UsageVectorCounts] = [:]
        for bucket in buckets where bucket.app != .cursor {
            let key = UsageVectorKey(
                app: bucket.app,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            var counts = result[key] ?? .zero
            counts.inputTokens += bucket.inputTokens
            counts.outputTokens += bucket.outputTokens
            counts.cacheReadTokens += bucket.cacheReadTokens
            counts.cacheCreationTokens += bucket.cacheCreationTokens
            counts.requestCount += bucket.requestCount
            result[key] = counts
        }
        return result
    }

    nonisolated static func conversationVector(
        _ buckets: [ConversationUsageBucket]
    ) -> [ConversationVectorKey: UsageVectorCounts] {
        var result: [ConversationVectorKey: UsageVectorCounts] = [:]
        for bucket in buckets where bucket.app != .cursor {
            let key = ConversationVectorKey(
                conversationKey: bucket.conversationKey,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            var counts = result[key] ?? .zero
            counts.inputTokens += bucket.inputTokens
            counts.outputTokens += bucket.outputTokens
            counts.cacheReadTokens += bucket.cacheReadTokens
            counts.cacheCreationTokens += bucket.cacheCreationTokens
            counts.requestCount += bucket.requestCount
            result[key] = counts
        }
        return result
    }

    nonisolated static func cycleVector(
        _ buckets: [CycleUsageBucket]
    ) -> [CycleVectorKey: UsageVectorCounts] {
        var result: [CycleVectorKey: UsageVectorCounts] = [:]
        for bucket in buckets {
            let key = CycleVectorKey(
                cycleID: bucket.cycleID,
                allowanceSegmentID: bucket.allowanceSegmentID,
                app: bucket.app,
                model: bucket.model,
                speed: bucket.speed,
                quality: bucket.quality
            )
            var counts = result[key] ?? .zero
            counts.inputTokens += bucket.inputTokens
            counts.outputTokens += bucket.outputTokens
            counts.cacheReadTokens += bucket.cacheReadTokens
            counts.cacheCreationTokens += bucket.cacheCreationTokens
            counts.requestCount += bucket.requestCount
            result[key] = counts
        }
        return result
    }

    nonisolated static func compare<V: Hashable>(
        baseline: [V: UsageVectorCounts],
        candidate: [V: UsageVectorCounts],
        into mismatch: inout UsageRebuildMismatch,
        missing: WritableKeyPath<UsageRebuildMismatch, Int>,
        added: WritableKeyPath<UsageRebuildMismatch, Int>,
        changed: WritableKeyPath<UsageRebuildMismatch, Int>
    ) {
        mismatch[keyPath: missing] = baseline.keys.filter { candidate[$0] == nil }.count
        mismatch[keyPath: added] = candidate.keys.filter { baseline[$0] == nil }.count
        mismatch[keyPath: changed] = baseline.reduce(into: 0) { count, pair in
            guard let candidateCounts = candidate[pair.key], candidateCounts != pair.value else { return }
            count += 1
        }
    }

    /// 用量对账：日桶 + 对话桶 + 会话归属。基准里没有的投影（例如对话历史在迁移时被丢弃）
    /// 不纳入比较，但必须由 `degradeReasons` 说明。
    nonisolated static func compareUsage(
        baseline: [UsageBucket],
        candidateDay: [UsageBucket],
        baselineConversation: [ConversationUsageBucket],
        candidateConversation: [ConversationUsageBucket],
        baselineInfos: [ConversationInfo],
        candidateInfos: [ConversationInfo]
    ) -> UsageRebuildMismatch {
        var mismatch = UsageRebuildMismatch()
        let baselineDay = dayVector(baseline)
        let candidateDayVector = dayVector(candidateDay)
        mismatch.usageKeysBaseline = baselineDay.count
        mismatch.usageKeysCandidate = candidateDayVector.count
        if !baselineDay.isEmpty {
            compare(
                baseline: baselineDay,
                candidate: candidateDayVector,
                into: &mismatch,
                missing: \.usageKeysMissing,
                added: \.usageKeysAdded,
                changed: \.usageKeysChanged
            )
        }

        if !baselineConversation.isEmpty || !baselineInfos.isEmpty {
            let baselineVector = conversationVector(baselineConversation)
            let candidateVector = conversationVector(candidateConversation)
            mismatch.conversationKeysBaseline = baselineVector.count
            mismatch.conversationKeysCandidate = candidateVector.count
            compare(
                baseline: baselineVector,
                candidate: candidateVector,
                into: &mismatch,
                missing: \.conversationKeysMissing,
                added: \.conversationKeysAdded,
                changed: \.conversationKeysChanged
            )

            // 会话归属：键集合与 app / 项目归组必须一致，标题之类的展示字段不参与。
            let baselineKeys = Set(baselineInfos.map(\.key))
            let candidateKeys = Set(candidateInfos.map(\.key))
            mismatch.conversationsRemoved = baselineKeys.subtracting(candidateKeys).count
            mismatch.conversationsAdded = candidateKeys.subtracting(baselineKeys).count
            var baselineByKey: [String: ConversationInfo] = [:]
            for info in baselineInfos { baselineByKey[info.key] = info }
            mismatch.conversationAttributionChanged = candidateInfos.reduce(into: 0) { count, info in
                guard let old = baselineByKey[info.key] else { return }
                if old.app != info.app || old.projectKey != info.projectKey { count += 1 }
            }
        }
        return mismatch
    }

    /// 周期对账。上下文变化时调用方按已有规则独立处理，不在这里放宽。
    nonisolated static func compareCycle(
        baseline: [CycleUsageBucket],
        candidate: [CycleUsageBucket],
        into mismatch: inout UsageRebuildMismatch
    ) {
        let baselineVector = cycleVector(baseline)
        let candidateVector = cycleVector(candidate)
        mismatch.cycleKeysBaseline = baselineVector.count
        mismatch.cycleKeysCandidate = candidateVector.count
        compare(
            baseline: baselineVector,
            candidate: candidateVector,
            into: &mismatch,
            missing: \.cycleKeysMissing,
            added: \.cycleKeysAdded,
            changed: \.cycleKeysChanged
        )
    }
}

/// 手动重建的合并规则：日志还在的对话以重扫结果为准（新解析规则、新价格都生效）；
/// 日志已全部删除的对话保留原用量，只按当前价格表重新计算金额。
/// 只处理 Claude / Codex / Pi：OpenCode、DSH 本来就按会话保留源库中已删除的历史，候选里已带着这部分。
nonisolated enum UsageRebuildMerge {
    struct Result: Sendable {
        var dayBuckets: [UsageBucket]
        var conversationInfos: [ConversationInfo]
        var conversationBuckets: [ConversationUsageBucket]
        var cycleBuckets: [CycleUsageBucket]
        /// 保留下来的已删除对话数。
        var preservedConversations = 0
        /// 重扫结果在同一键上已不少于历史、因此没有叠加的对话桶 / 周期桶数。
        var skippedBuckets = 0
    }

    static let preservedApps: Set<UsageApp> = [.claude, .codex, .pi]

    /// - Parameters:
    ///   - cycleStartByID: 周期起点，用作被保留周期桶的取价时间；找不到的周期桶保留原金额。
    ///   - sourceExists: 判断对话档案里记录的日志路径是否仍在。
    static func preserveDeletedConversations(
        baselineDay: [UsageBucket],
        baselineInfos: [ConversationInfo],
        baselineConversation: [ConversationUsageBucket],
        baselineCycles: [CycleUsageBucket],
        candidateDay: [UsageBucket],
        candidateInfos: [ConversationInfo],
        candidateConversation: [ConversationUsageBucket],
        candidateCycles: [CycleUsageBucket],
        cycleStartByID: [String: Date],
        sourceExists: (String) -> Bool
    ) -> Result {
        var result = Result(
            dayBuckets: candidateDay,
            conversationInfos: candidateInfos,
            conversationBuckets: candidateConversation,
            cycleBuckets: candidateCycles
        )
        let candidateKeys = Set(candidateInfos.map(\.key))
            .union(candidateConversation.map(\.conversationKey))
        // 重扫里没有、且记录的日志路径都已不存在，才算日志已删除。
        // 文件还在却没有重扫出用量的对话（归属改变、解析规则变化）以重扫结果为准，不保留。
        let deleted = baselineInfos.filter { info in
            preservedApps.contains(info.app)
                && !candidateKeys.contains(info.key)
                && !info.sourcePaths.contains(where: sourceExists)
        }
        guard !deleted.isEmpty else { return result }
        let deletedKeys = Set(deleted.map(\.key))

        // 防重复计入：原对话日志被删、续接对话还在时，续接对话会在重扫里重新计入复制过去的消息。
        // 某个键上重扫结果已不少于历史，说明被删对话的用量已经算在别处，不再叠加。
        let baselineDayVector = UsageHistoryConsistency.dayVector(baselineDay)
        let candidateDayVector = UsageHistoryConsistency.dayVector(candidateDay)
        var dayBuckets: [UsageVectorKey: UsageBucket] = [:]
        for bucket in candidateDay {
            dayBuckets[UsageVectorKey(app: bucket.app, day: bucket.day, model: bucket.model, speed: bucket.speed)] = bucket
        }
        var keptKeys: Set<String> = []
        for bucket in baselineConversation where deletedKeys.contains(bucket.conversationKey) {
            let key = UsageVectorKey(app: bucket.app, day: bucket.day, model: bucket.model, speed: bucket.speed)
            if covers(candidateDayVector[key], baselineDayVector[key]) {
                result.skippedBuckets += 1
                continue
            }
            let kept = repriced(bucket)
            result.conversationBuckets.append(kept)
            keptKeys.insert(kept.conversationKey)
            if var day = dayBuckets[key] {
                day.inputTokens += kept.inputTokens
                day.outputTokens += kept.outputTokens
                day.cacheReadTokens += kept.cacheReadTokens
                day.cacheCreationTokens += kept.cacheCreationTokens
                day.costUSD += kept.costUSD
                day.requestCount += kept.requestCount
                day.hasUnpricedUsage = day.hasUnpricedUsage || kept.hasUnpricedUsage
                dayBuckets[key] = day
            } else {
                dayBuckets[key] = UsageBucket(
                    app: kept.app, model: kept.model, speed: kept.speed, day: kept.day,
                    inputTokens: kept.inputTokens, outputTokens: kept.outputTokens,
                    cacheReadTokens: kept.cacheReadTokens, cacheCreationTokens: kept.cacheCreationTokens,
                    costUSD: kept.costUSD, requestCount: kept.requestCount,
                    hasUnpricedUsage: kept.hasUnpricedUsage
                )
            }
        }
        result.dayBuckets = Array(dayBuckets.values)
        result.conversationInfos += deleted.filter { keptKeys.contains($0.key) }
        result.preservedConversations = keptKeys.count

        let baselineCycleVector = UsageHistoryConsistency.cycleVector(baselineCycles)
        let candidateCycleVector = UsageHistoryConsistency.cycleVector(candidateCycles)
        for bucket in baselineCycles {
            guard let conversationKey = bucket.conversationKey, deletedKeys.contains(conversationKey) else { continue }
            let key = CycleVectorKey(
                cycleID: bucket.cycleID,
                allowanceSegmentID: bucket.allowanceSegmentID,
                app: bucket.app,
                model: bucket.model,
                speed: bucket.speed,
                quality: bucket.quality
            )
            if covers(candidateCycleVector[key], baselineCycleVector[key]) {
                result.skippedBuckets += 1
                continue
            }
            var kept = bucket
            if let at = cycleStartByID[bucket.cycleID], let cost = cost(
                app: bucket.app, model: bucket.model, speed: bucket.speed,
                input: bucket.inputTokens, output: bucket.outputTokens,
                cacheRead: bucket.cacheReadTokens, cacheCreation: bucket.cacheCreationTokens,
                requestCount: bucket.requestCount, at: at
            ) {
                kept.costUSD = cost.total
                kept.hasUnpricedUsage = false
            }
            result.cycleBuckets.append(kept)
        }
        return result
    }

    private static func covers(_ candidate: UsageVectorCounts?, _ baseline: UsageVectorCounts?) -> Bool {
        guard let baseline else { return true }
        let candidate = candidate ?? .zero
        return candidate.inputTokens >= baseline.inputTokens
            && candidate.outputTokens >= baseline.outputTokens
            && candidate.cacheReadTokens >= baseline.cacheReadTokens
            && candidate.cacheCreationTokens >= baseline.cacheCreationTokens
            && candidate.requestCount >= baseline.requestCount
    }

    private static func repriced(_ bucket: ConversationUsageBucket) -> ConversationUsageBucket {
        guard let cost = cost(
            app: bucket.app, model: bucket.model, speed: bucket.speed,
            input: bucket.inputTokens, output: bucket.outputTokens,
            cacheRead: bucket.cacheReadTokens, cacheCreation: bucket.cacheCreationTokens,
            requestCount: bucket.requestCount, at: bucket.firstAt
        ) else { return bucket }
        var kept = bucket
        kept.costUSD = cost.total
        kept.inputCostUSD = cost.input
        kept.outputCostUSD = cost.output
        kept.cacheReadCostUSD = cost.cacheRead
        kept.cacheCreationCostUSD = cost.cacheCreation
        kept.hasUnpricedUsage = false
        return kept
    }

    /// 汇总桶的估算计价。逐条明细已随日志删除：Claude 缓存写入全部按 5 分钟价，
    /// 长上下文档位按桶内平均每次请求的输入量判断，取价时间用桶内最早一条的时间。
    /// Pi 日志自带上游结算金额，按价格表重算会覆盖官方金额，保留原值（返回 nil）；
    /// 当前价格表也查不到的模型同样保留原金额。
    private static func cost(
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        requestCount: Int,
        at date: Date
    ) -> CostBreakdown? {
        guard app == .claude || app == .codex else { return nil }
        let fullInput = input + cacheRead + cacheCreation
        return Pricing.costBreakdown(
            app: app,
            model: model,
            speed: speed,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            at: date,
            inputTotal: requestCount > 0 ? fullInput / requestCount : fullInput
        )
    }
}

/// 一次运行的结果状态。UI 与日志据此区分「成功」「保留旧历史的拒绝」「提交失败」「恢复受限」，
/// 不靠字符串前缀判断。
nonisolated enum UsageRebuildOutcome: Sendable, Equatable {
    /// 候选已提交。`cycleVerified` 表示周期用量与重建前是否一致，只作诊断。
    case replaced(cycleVerified: Bool)
    /// 受限恢复核对时用量向量不一致，原历史原样保留。
    case rejectedUsageChanged
    /// 来源读取 / 解码不完整或 DSH 冲突，本轮不作为。
    case rejectedIncompleteSources(String)
    /// 候选持久化失败，基准仍未改变。
    case commitFailed(String)
    /// 第一轮已经提交，缺价第二轮被拒 / 失败：保留第一轮有效结果，不宣称整轮完整成功。
    case partiallyCommitted(String)
    /// 受限恢复的一次核对：向量一致，已据此采纳进度。
    case recoveredFromRestrictedHistory
    /// 受限恢复的核对无法确认，保留历史、停止自动全量重扫。
    case restrictedRecoveryRejected
}

/// 受限恢复（历史可用但没有可信进度）的状态。
nonisolated enum UsageHistoryRecoveryState: Sendable, Equatable {
    /// 正常：历史与进度同代。
    case complete
    /// 历史可用但进度不可信；尚未做核对。
    case pendingVerification
    /// 核对未通过：保留历史展示，不再自动全量重扫。
    case verificationRejected
    /// 没有可展示的有效历史，不能自动当成首装。
    case unavailable
}

/// 仅供 Codex 标识迁移使用；普通重算仍按原始完整模型键严格对账。
/// 金额和时间范围也按旧键比较，不能用全局总额相等替代逐桶守恒。
nonisolated extension UsageHistoryConsistency {
    struct MigrationBalance: Equatable {
        var cost: Decimal = 0
        var input: Decimal = 0
        var output: Decimal = 0
        var read: Decimal = 0
        var creation: Decimal = 0
        var unpriced = false
        var incomplete = false
        var firstAt: Date?
        var lastAt: Date?
    }

    struct MigrationCycleKey: Hashable {
        var key: CycleVectorKey
        var conversationKey: String?
    }

    static func migrationDayBalances(_ buckets: [UsageBucket]) -> [UsageVectorKey: MigrationBalance] {
        var result: [UsageVectorKey: MigrationBalance] = [:]
        for b in buckets {
            let key = UsageVectorKey(app: b.app, day: b.day, model: b.model, speed: b.speed)
            var balance = result[key] ?? MigrationBalance()
            balance.cost += b.costUSD
            balance.unpriced = balance.unpriced || b.hasUnpricedUsage
            balance.incomplete = balance.incomplete || b.costIncomplete
            result[key] = balance
        }
        return result
    }

    private static func migrationConversationBalances(
        _ buckets: [ConversationUsageBucket]
    ) -> [ConversationVectorKey: MigrationBalance] {
        var result: [ConversationVectorKey: MigrationBalance] = [:]
        for b in buckets {
            let key = ConversationVectorKey(conversationKey: b.conversationKey, day: b.day, model: b.model, speed: b.speed)
            var balance = result[key] ?? MigrationBalance()
            balance.cost += b.costUSD
            balance.input += b.inputCostUSD
            balance.output += b.outputCostUSD
            balance.read += b.cacheReadCostUSD
            balance.creation += b.cacheCreationCostUSD
            balance.unpriced = balance.unpriced || b.hasUnpricedUsage
            balance.firstAt = min(balance.firstAt ?? b.firstAt, b.firstAt)
            balance.lastAt = max(balance.lastAt ?? b.lastAt, b.lastAt)
            result[key] = balance
        }
        return result
    }

    private static func migrationCycleVectors(
        _ buckets: [CycleUsageBucket]
    ) -> [MigrationCycleKey: UsageVectorCounts] {
        var result: [MigrationCycleKey: UsageVectorCounts] = [:]
        for b in buckets {
            let key = migrationCycleKey(b)
            var counts = result[key] ?? .zero
            counts.inputTokens += b.inputTokens
            counts.outputTokens += b.outputTokens
            counts.cacheReadTokens += b.cacheReadTokens
            counts.cacheCreationTokens += b.cacheCreationTokens
            counts.requestCount += b.requestCount
            result[key] = counts
        }
        return result
    }

    private static func migrationCycleKey(_ b: CycleUsageBucket) -> MigrationCycleKey {
        MigrationCycleKey(key: CycleVectorKey(cycleID: b.cycleID, allowanceSegmentID: b.allowanceSegmentID,
                                              app: b.app, model: b.model, speed: b.speed, quality: b.quality),
                          conversationKey: b.conversationKey)
    }

    private static func migrationCycleBalances(_ buckets: [CycleUsageBucket]) -> [MigrationCycleKey: MigrationBalance] {
        var result: [MigrationCycleKey: MigrationBalance] = [:]
        for b in buckets {
            let key = migrationCycleKey(b)
            var balance = result[key] ?? MigrationBalance()
            balance.cost += b.costUSD
            balance.unpriced = balance.unpriced || b.hasUnpricedUsage
            result[key] = balance
        }
        return result
    }

    /// origins 仅由迁移器根据原始调用产生，不能由裸模型名推测。
    static func validateCodexIdentityMigration(
        baseline: UsageSnapshot, candidate: UsageSnapshot, origins: [String: String]
    ) -> Bool {
        guard origins.allSatisfy({ Pricing.normalize(model: $0.key) == $0.value }),
              baseline.scanState == candidate.scanState,
              baseline.conversationRollup.infos == candidate.conversationRollup.infos,
              baseline.usageRollup.buckets.filter({ $0.app != .codex }) == candidate.usageRollup.buckets.filter({ $0.app != .codex }),
              baseline.conversationRollup.buckets.filter({ $0.app != .codex }) == candidate.conversationRollup.buckets.filter({ $0.app != .codex }),
              baseline.cycleRollup.buckets.filter({ $0.app != .codex }) == candidate.cycleRollup.buckets.filter({ $0.app != .codex })
        else { return false }
        let day = candidate.usageRollup.buckets.map { bucket -> UsageBucket in
            var b = bucket
            if b.app == .codex { b.model = origins[b.model] ?? b.model }
            return b
        }
        let conversation = candidate.conversationRollup.buckets.map { bucket -> ConversationUsageBucket in
            var b = bucket
            if b.app == .codex { b.model = origins[b.model] ?? b.model }
            return b
        }
        let cycle = candidate.cycleRollup.buckets.map { bucket -> CycleUsageBucket in
            var b = bucket
            if b.app == .codex { b.model = origins[b.model] ?? b.model }
            return b
        }
        return dayVector(baseline.usageRollup.buckets) == dayVector(day)
            && conversationVector(baseline.conversationRollup.buckets) == conversationVector(conversation)
            && migrationCycleVectors(baseline.cycleRollup.buckets) == migrationCycleVectors(cycle)
            && migrationDayBalances(baseline.usageRollup.buckets) == migrationDayBalances(day)
            && migrationConversationBalances(baseline.conversationRollup.buckets) == migrationConversationBalances(conversation)
            && migrationCycleBalances(baseline.cycleRollup.buckets) == migrationCycleBalances(cycle)
    }
}
