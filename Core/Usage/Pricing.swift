import Foundation
import CryptoKit

/// 单次调用四类 token 的成本拆分。日志有有效总价，或模型已定价时才会生成；未定价继续用 `nil` 表达。
nonisolated struct CostBreakdown: Sendable, Equatable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal

    var total: Decimal { input + output + cacheRead + cacheCreation }
}

nonisolated enum Pricing {
    /// 价格数据在 `Resources/pricing-rules.json`（按各厂商官方定价页核对，起点对齐 cc-switch
    /// `seed_model_pricing` / CodexBar `CostUsagePricing`），由 `PricingRulesStore` 加载，可被签名的远端文件热更新。
    /// 这里只保留取价算法。键为官方型号名；渠道前缀、日期与渠道附加标记由 `ModelIdentity` 解析，
    /// 按 `modelCandidates` 的顺序逐个查价，见 `resolvedPrice`。
    ///
    /// Google Gemini、Cursor / xAI、Z.ai、MiniMax 的价格只能在规则文件里维护：远端价格目录只收
    /// anthropic / openai / deepseek（见 `LiteLLMPricingDecoder` 与 `ModelsDevPricingDecoder` 的
    /// `allowedProviders`），这几家厂商的 key 在远端目录里永远命中不到。

    /// Codex Fast 的长上下文阈值：完整输入严格超过它时改用 Fast 长上下文价（没有则缺价）。
    private static let codexFastLongContextThreshold = 272_000

    /// 当前生效的本地价格规则。同一次计价只取一次，保证各张表来自同一份快照。
    private static var rules: PricingRules {
        PricingRulesStore.shared.current().rules
    }

    /// 取某模型在 `date` 这天应使用的价格。
    /// A 类（`localOverrideKeys`）：走本地阶梯价 / 分段生效价，远端价格目录零参与。
    /// B 类（其余）：远端价格目录优先，命中不到才回落规则文件的基础价；两者都没有 → nil（未定价）。
    private static func standardPrice(
        for key: String,
        app: UsageApp,
        at date: Date,
        inputTotal: Int,
        rules: PricingRules
    ) -> ModelPrice? {
        if var tiers = rules.contextPriceTiers[key] {
            for period in rules.timedContextPriceTiers[key] ?? [] where period.from <= date {
                tiers = period.tiers
            }
            return tiers.rates(for: inputTotal)
        }
        if let overrides = rules.timedOverrides[key] {
            var chosen = rules.table[key]
            for period in overrides where period.from <= date {
                chosen = period.price
            }
            return chosen
        }
        if rules.fixedLocalOverrideKeys.contains(key) {
            return rules.table[key]
        }
        return PricingCatalogStore.shared.rate(for: key, app: app, speed: .standard) ?? rules.table[key]
    }

    /// Codex Fast 的长上下文价。没有收录的模型返回 nil，不用短上下文 Fast 价或 Standard 长上下文价顶上。
    private static func codexFastLongPrice(for key: String, at date: Date, rules: PricingRules) -> ModelPrice? {
        guard var chosen = rules.codexFastLongContextPrices[key] else { return nil }
        for period in rules.timedCodexFastLongPrices[key] ?? [] where period.from <= date {
            chosen = period.price
        }
        return chosen
    }

    private static func price(
        for key: String,
        app: UsageApp,
        speed: UsageSpeed,
        at date: Date,
        inputTotal: Int,
        rules: PricingRules
    ) -> ModelPrice? {
        switch speed {
        case .standard:
            return standardPrice(for: key, app: app, at: date, inputTotal: inputTotal, rules: rules)
        case .unknown:
            return nil
        case .fast:
            // 固定覆盖不能绕过长上下文：GPT-5.5 在这张表里，但它的 Fast 没有长上下文价。
            if app == .codex, inputTotal > codexFastLongContextThreshold {
                return codexFastLongPrice(for: key, at: date, rules: rules)
            }
            if rules.fixedFastLocalOverrideKeys.contains(key) {
                switch app {
                case .codex: return rules.codexFastPrices[key]
                case .claude: return rules.claudeFastPrices[key]
                case .cursor: return nil
                case .pi: return nil
                case .opencode: return nil
                case .dsh: return nil
                case .antigravity: return nil
                }
            }
            switch app {
            case .codex:
                if let periods = rules.timedCodexFastPrices[key] {
                    var chosen = rules.codexFastPrices[key]
                    for period in periods where period.from <= date {
                        chosen = period.price
                    }
                    return chosen
                }
                return PricingCatalogStore.shared.rate(for: key, app: app, speed: .fast)
                    ?? rules.codexFastPrices[key]
            case .claude:
                return PricingCatalogStore.shared.rate(for: key, app: app, speed: .fast)
                    ?? rules.claudeFastPrices[key]
            case .cursor:
                // Cursor 使用服务端 chargedCents，不走本地模型定价。
                return nil
            case .pi:
                // pi 没有 Fast 档位概念。
                return nil
            case .opencode:
                // opencode 没有 Fast 档位概念。
                return nil
            case .dsh:
                // DSH 没有 Fast 档位概念。
                return nil
            case .antigravity:
                // Antigravity 没有 Fast 档位概念。
                return nil
            }
        }
    }

    /// 存储用的模型名归一化：循环去支持的 provider 前缀（含嵌套两层，如 `commandcode/deepseek/...`）；
    /// 剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；兼容 Vertex AI 的 `@日期` 写法。
    /// 该结果同时是 Codex 旧存储身份与 Claude 存储身份（标识迁移按它对账旧快照），前缀表不能改；
    /// 查价不用它，改由 `ModelIdentity` 解析。
    nonisolated static func normalize(model: String) -> String {
        var m = model
        // 循环剥除：Pi / OpenCode 日志里 provider 网关标签可能是 `commandcode/deepseek/...` 双层。
        var removed = true
        while removed {
            removed = false
            for prefix in identityPrefixes where m.hasPrefix(prefix) {
                m.removeFirst(prefix.count)
                removed = true
                break
            }
        }
        // Vertex 风格：`name@YYYYMMDD`
        if let at = m.firstIndex(of: "@") {
            m = String(m[m.startIndex..<at])
        }
        return strippingDateSuffix(m).lowercased()
    }

    /// 查价身份：渠道链与格式差异归一后的模型键，不作为任何存储身份。
    nonisolated static func pricingKey(model: String) -> String {
        ModelIdentity.parse(model).pricingIdentity
    }

    private static let identityPrefixes = [
        "openai-codex/", "openai/", "anthropic/", "deepseek/",
        "opencode-go/", "commandcode/", "command-code/"
    ]

    /// 去掉 Anthropic 风格的 `-YYYYMMDD` 或 `-YYYY-MM-DD` 日期后缀。
    nonisolated static func strippingDateSuffix(_ model: String) -> String {
        var m = model
        for pattern in [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#] {
            if let range = m.range(of: pattern, options: .regularExpression) {
                m.removeSubrange(range)
                break
            }
        }
        return m
    }

    /// 查价候选键，由具体到通用：渠道自有价 → 官方型号候选。
    private static func pricingCandidates(for model: String) -> [String] {
        let identity = ModelIdentity.parse(model)
        let channelKeys = identity.channelPricingKey.map { [$0] } ?? []
        // 标识自带 Fast 档却没有渠道自有价时保持缺价：绝不把 Standard 价当 Fast。
        guard identity.speed != .fast else { return channelKeys }
        return channelKeys + identity.modelCandidates
    }

    /// 按候选顺序取第一个有价的键及其价格；都没有时为 nil（未定价）。
    private static func resolvedPrice(
        model: String,
        app: UsageApp,
        speed: UsageSpeed,
        at date: Date,
        inputTotal: Int,
        rules: PricingRules
    ) -> (key: String, price: ModelPrice)? {
        for key in pricingCandidates(for: model) {
            if let rate = price(for: key, app: app, speed: speed, at: date, inputTotal: inputTotal, rules: rules) {
                return (key, rate)
            }
        }
        return nil
    }

    /// 展示用型号：按查价顺序第一个有 Standard 价的官方型号；都没有时为解析出的模型名。
    /// Fast 档是同一型号的另一种速度，型号名末尾的 `-fast` 在展示时并入该型号。
    nonisolated static func displayModel(for identity: ModelIdentity) -> String {
        let rules = Self.rules
        func official(_ name: String) -> String? {
            // Standard 价不分 App，这里的 app 只为满足签名。
            ModelIdentity.candidates(for: name).first {
                standardPrice(for: $0, app: .codex, at: Date(), inputTotal: 0, rules: rules) != nil
            }
        }
        let name = identity.name
        let speedMerged = name.hasSuffix("-fast") ? official(String(name.dropLast("-fast".count))) : nil
        let matched = speedMerged ?? official(name) ?? name
        return ModelIdentity.aliases[matched] ?? matched
    }

    private static let perMillion: Decimal = 1_000_000

    /// 计算单次调用花费。
    /// - Parameters:
    ///   - app: 用于隐含的 cache_read 语义；Codex 含、Claude 不含（调用方传 input 时已自处理）。
    ///   - at: 该条用量记录实际发生的时间，仅在模型存在分段价时才会影响取价。
    ///   - input/output/cacheRead/cacheCreation: 已拆分的四类 token；Claude 的 `cacheCreation` 表示 5m 写入。
    ///   - cacheCreation1h: Claude 1h 缓存写入；Codex 不使用，缺省为 0。
    ///   - inputTotal: 该请求完整输入 token；GPT-5.6 / GPT-5.5 用它判断长上下文，缺省时由全部输入侧 token 相加。
    /// - Returns: 命中价格返回计算结果（含真实 $0）；命中不到任何价格源时返回 `nil`（未定价，
    ///   区别于真实 $0，调用方不应把 nil 当 0 计入金额汇总——`UsageAggregator.ingest` 已按此处理）。
    static func cost(
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        cacheCreation1h: Int = 0,
        at date: Date,
        inputTotal: Int? = nil
    ) -> Decimal? {
        costBreakdown(
            app: app,
            model: model,
            speed: speed,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            cacheCreation1h: cacheCreation1h,
            at: date,
            inputTotal: inputTotal
        )?.total
    }

    /// 计算单次调用的四项成本；模型未定价时返回 nil，不能折成真实 $0。
    static func costBreakdown(
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        cacheCreation1h: Int = 0,
        at date: Date,
        inputTotal: Int? = nil
    ) -> CostBreakdown? {
        let fullInput = max(0, inputTotal ?? (input + cacheRead + cacheCreation + cacheCreation1h))
        let rules = Self.rules
        guard let p = resolvedPrice(
            model: model, app: app, speed: speed, at: date, inputTotal: fullInput, rules: rules
        )?.price
        else { return nil }
        let i = Decimal(input)     * p.input        / perMillion
        let o = Decimal(output)    * p.output       / perMillion
        let cr = Decimal(cacheRead) * p.cacheRead   / perMillion
        let cc5m = Decimal(cacheCreation) * p.cacheCreation / perMillion
        let oneHourRate = app == .claude
            ? p.input * rules.claudeCacheCreation1hMultiplier
            : p.cacheCreation
        let cc1h = Decimal(cacheCreation1h) * oneHourRate / perMillion
        let cc = cc5m + cc1h
        return CostBreakdown(input: i, output: o, cacheRead: cr, cacheCreation: cc)
    }

    /// 统一解析扫描日志中的最终参考费用。
    ///
    /// 日志提供大于 0 的总价时，总额已经由上游确定，不再被本地或在线价格覆盖。
    /// Pi 的日志分项在浮点尾差范围内会保留并对齐到官方总额；OpenCode 只有总额时，
    /// 价格表只用于估算四项占比，估算结果按官方总额缩放，不改变总费用。
    /// 日志价格缺失或为 0 时，只要存在 Token，就复用当前标准 API 价格链；未命中价格则返回 nil。
    /// 日志分项明显无效、且也无法估算占比时，才用总价作为单项费用；
    /// 所有路径都保证 `UsageEntry.costUSD` 与 `CostBreakdown.total` 一致。
    static func resolveCostBreakdown(
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        cacheCreation1h: Int = 0,
        totalTokens: Int,
        reportedCost: Decimal?,
        reportedBreakdown: CostBreakdown?,
        at date: Date,
        inputTotal: Int? = nil
    ) -> CostBreakdown? {
        if let reportedCost, reportedCost > 0 {
            if let reportedBreakdown {
                if let reconciled = reconcileReportedBreakdown(
                    reportedBreakdown,
                    to: reportedCost,
                    requiresCloseMatch: true
                ) {
                    return reconciled
                }
            } else if let estimated = costBreakdown(
                app: app,
                model: model,
                speed: speed,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation,
                cacheCreation1h: cacheCreation1h,
                at: date,
                inputTotal: inputTotal
            ), estimated.total > 0 {
                let scale = reportedCost / estimated.total
                let scaled = CostBreakdown(
                    input: estimated.input * scale,
                    output: estimated.output * scale,
                    cacheRead: estimated.cacheRead * scale,
                    cacheCreation: estimated.cacheCreation * scale
                )
                if let reconciled = reconcileReportedBreakdown(
                    scaled,
                    to: reportedCost,
                    requiresCloseMatch: false
                ) {
                    return reconciled
                }
            }
            return CostBreakdown(input: 0, output: reportedCost, cacheRead: 0, cacheCreation: 0)
        }

        guard totalTokens > 0 else { return nil }
        return costBreakdown(
            app: app,
            model: model,
            speed: speed,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            cacheCreation1h: cacheCreation1h,
            at: date,
            inputTotal: inputTotal
        )
    }

    /// JSON number 经过 Double 后常带 1e-16 级尾差；这不应让 Pi 的可用分项退化为“全部输出”。
    /// 缩放后也用同一逻辑把最后的 Decimal 舍入差吸收到某个非负分项中。
    private static func reconcileReportedBreakdown(
        _ breakdown: CostBreakdown,
        to reportedCost: Decimal,
        requiresCloseMatch: Bool
    ) -> CostBreakdown? {
        let difference = reportedCost - breakdown.total
        if requiresCloseMatch {
            let absoluteTolerance = Decimal(string: "0.000000000001")!
            let relativeTolerance = abs(reportedCost) * Decimal(string: "0.000000001")!
            guard abs(difference) <= max(absoluteTolerance, relativeTolerance) else { return nil }
        }

        var adjusted = breakdown
        if difference >= 0 || adjusted.output + difference >= 0 {
            adjusted.output += difference
        } else if adjusted.input + difference >= 0 {
            adjusted.input += difference
        } else if adjusted.cacheRead + difference >= 0 {
            adjusted.cacheRead += difference
        } else if adjusted.cacheCreation + difference >= 0 {
            adjusted.cacheCreation += difference
        } else {
            return nil
        }
        return adjusted
    }

    /// 该模型是否已有可用价格（本地表 / 阶梯价 / 远端价格目录任一命中）。唯一权威接口，
    /// 供扫描层区分「已定价（含真实 $0）/ 未定价」。
    static func hasPrice(
        model: String,
        app: UsageApp = .codex,
        speed: UsageSpeed = .standard,
        inputTotal: Int = 0
    ) -> Bool {
        resolvedPrice(model: model, app: app, speed: speed, at: Date(), inputTotal: inputTotal, rules: rules) != nil
    }

    /// 是否应因缺价主动刷新远端目录。明确不计价的内部模型不会触发网络请求。
    static func needsRemotePriceRefresh(model: String, app: UsageApp, speed: UsageSpeed) -> Bool {
        guard speed != .unknown else { return false }
        if app == .codex, pricingKey(model: model) == "codex-auto-review" { return false }
        return resolvedPrice(model: model, app: app, speed: speed, at: Date(), inputTotal: 0, rules: rules) == nil
    }

    /// 原始 Tokens 到 Fast 计费等效 Tokens 的换算倍率；未知或未收录的 Fast 模型返回 nil。
    static func billingEquivalentMultiplier(app: UsageApp, model: String, speed: UsageSpeed) -> Decimal? {
        switch speed {
        case .standard:
            return 1
        case .unknown:
            return nil
        case .fast:
            let rules = Self.rules
            let key = resolvedPrice(model: model, app: app, speed: speed, at: Date(), inputTotal: 0, rules: rules)?.key
                ?? pricingKey(model: model)
            switch app {
            case .codex:
                // ChatGPT credit 倍率不是 API Priority 价格字段，不能从在线价格猜。
                return rules.codexFastMultipliers[key]
            case .claude:
                return rules.claudeFastMultipliers[key] ?? derivedClaudeFastMultiplier(for: key, rules: rules)
            case .cursor:
                return nil
            case .pi:
                // pi 无 Fast 档位概念。
                return nil
            case .opencode:
                // opencode 无 Fast 档位概念。
                return nil
            case .dsh:
                // DSH 无 Fast 档位概念。
                return nil
            case .antigravity:
                // Antigravity 无 Fast 档位概念。
                return nil
            }
        }
    }

    /// Claude 的计费等效倍率定义为 Fast / Standard API 价比。只有四项费率的非零比例完全一致时才推导；
    /// 任一项不一致就返回 nil，让 UI 显示「—」，避免用输入价比例冒充整体倍率。
    private static func derivedClaudeFastMultiplier(for key: String, rules: PricingRules) -> Decimal? {
        guard let standard = standardPrice(for: key, app: .claude, at: Date(), inputTotal: 0, rules: rules),
              let fast = price(for: key, app: .claude, speed: .fast, at: Date(), inputTotal: 0, rules: rules)
        else { return nil }
        let pairs = [
            (standard.input, fast.input),
            (standard.output, fast.output),
            (standard.cacheRead, fast.cacheRead),
            (standard.cacheCreation, fast.cacheCreation)
        ]
        var ratio: Decimal?
        for (base, premium) in pairs {
            if base == 0 {
                guard premium == 0 else { return nil }
                continue
            }
            let current = premium / base
            if let ratio, ratio != current { return nil }
            ratio = current
        }
        return ratio
    }

    /// 价格表内容指纹（SHA-256，确定性），只写进快照作诊断记录，加载时不做比对。
    /// 是否要按新价格重建历史由 `localPricingFingerprint()` 与 `remotePricingSignature(for:)`
    /// 逐项判断（见 `UsageRebuildBasis`）。
    ///
    /// - Parameter knownUsage: 当前用量中实际出现过的 app/model/speed 集合。远端合并价只对
    ///   这个集合算入哈希，避免远端目录里本地未使用模型的变化造成无关的指纹漂移。
    static func fingerprint(knownUsage: Set<PricingUsageKey>) -> String {
        let snapshot = PricingRulesStore.shared.current()
        let fastMultiplierBody = [
            PricingRules.fingerprintBody(snapshot.rules.codexFastMultipliers, prefix: "codex"),
            PricingRules.fingerprintBody(snapshot.rules.claudeFastMultipliers, prefix: "claude")
        ].joined(separator: ";")
        let remoteBody = knownUsage.sorted { $0.persistedKey < $1.persistedKey }.compactMap { usage -> String? in
            remoteRate(for: usage, rules: snapshot.rules).map { rate in
                "\(usage.persistedKey):\(rate.input)/\(rate.output)/\(rate.cacheRead)/\(rate.cacheCreation)"
            }
        }.joined(separator: ";")
        return sha256Hex("\(snapshot.localBody)|\(fastMultiplierBody)|\(remoteBody)")
    }

    /// 本地价格规则（固定价、分段价、阶梯价、Fast 价、缓存规则、模型解析规则）的指纹，不含远端目录与 Fast 倍率。
    /// 规则随 App 更新或远端规则文件改变；与历史计价时的值不同就说明历史费用需要按新价格重建。
    /// 指纹随规则快照计算一次，扫描开始前才会切换快照（`PricingRulesStore.commitPending()`）。
    static func localPricingFingerprint() -> String {
        PricingRulesStore.shared.current().localFingerprint
    }

    /// 某个用量键当前采用的远端价格；本地规则管辖或远端没有收录时为 "-"。
    /// 与历史计价时记下的值不同，说明这个键的历史费用需要按新价格重建。
    static func remotePricingSignature(for usage: PricingUsageKey) -> String {
        guard let rate = remoteRate(for: usage, rules: rules) else { return "-" }
        return "\(rate.input)/\(rate.output)/\(rate.cacheRead)/\(rate.cacheCreation)"
    }

    /// 计价时实际会用到的远端价格。本地规则优先的键返回 nil，与 `price(for:)` 的取价顺序一致。
    private static func remoteRate(for usage: PricingUsageKey, rules: PricingRules) -> ModelPrice? {
        guard let key = resolvedPrice(
            model: usage.model, app: usage.app, speed: usage.speed, at: Date(), inputTotal: 0, rules: rules
        )?.key else { return nil }
        if usage.speed == .standard, rules.localOverrideKeys.contains(key) { return nil }
        if usage.speed == .fast, rules.fixedFastLocalOverrideKeys.contains(key) { return nil }
        if usage.speed == .fast, usage.app == .codex, rules.timedCodexFastPrices[key] != nil { return nil }
        return PricingCatalogStore.shared.rate(for: key, app: usage.app, speed: usage.speed)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
