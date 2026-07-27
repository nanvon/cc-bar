import Foundation
import CryptoKit

/// 模型价格（USD / 百万 token）。命中不到的模型未定价（`Pricing.cost` 返回 nil），token 仍记录。
nonisolated struct ModelPrice: Sendable, Codable, Equatable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal
}

/// 单次调用四类 token 的成本拆分。只有模型已定价时才会生成；未定价继续用 `nil` 表达。
nonisolated struct CostBreakdown: Sendable, Equatable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal

    var total: Decimal { input + output + cacheRead + cacheCreation }
}

/// 同一模型按单次请求完整输入量切换的上下文阶梯价。
/// `shortContext` / `longContext` 均为完整费率，避免值类型递归引用。
nonisolated private struct ContextPriceTiers: Sendable {
    let longContextThreshold: Int
    let shortContext: ModelPrice
    let longContext: ModelPrice

    func rates(for inputTotal: Int) -> ModelPrice {
        inputTotal > longContextThreshold ? longContext : shortContext
    }
}

/// 限时覆盖价：某模型从 `from` 这天（UTC 0 点）起改用 `price`，用于极少数「同一模型中途涨价/降价」
/// 的场景（如 Sonnet 5）。绝大多数模型价格固定，不需要出现在这张表里。
nonisolated private struct PricedPeriod: Sendable {
    let from: Date
    let price: ModelPrice
}

nonisolated enum Pricing {
    /// 价格表与 cc-switch `seed_model_pricing` / CodexBar `CostUsagePricing` 对齐（2026 上半年价位）。
    /// 命中不到时返回 nil。键为归一化后的模型名（剥 `openai/` 前缀和末尾 `-YYYYMMDD` / `-YYYY-MM-DD` 日期段）。
    static let table: [String: ModelPrice] = [
        // —— Claude 4.x 系（input 已不含 cache_read）——
        "claude-fable-5":    .init(input: 10,  output: 50,  cacheRead: 1.00, cacheCreation: 12.50),
        "claude-opus-5":     .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-8":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-7":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-6":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-5":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-1":   .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        "claude-opus-4":     .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        // Sonnet 5 是当前生效价（2026-09-01 起的新价见下方 timedOverrides）。
        "claude-sonnet-5":   .init(input: 2,   output: 10,  cacheRead: 0.20, cacheCreation: 2.50),
        "claude-sonnet-4-7": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-6": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-5": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4":   .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-haiku-4-5":  .init(input: 1,   output: 5,   cacheRead: 0.10, cacheCreation: 1.25),
        "claude-haiku-4":    .init(input: 0.8, output: 4,   cacheRead: 0.08, cacheCreation: 1.0),

        // —— Codex / GPT-5 系（input 含 cache_read，调用侧已扣 billable）。
        "gpt-5":             .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5-mini":        .init(input: 0.25, output: 2,   cacheRead: 0.025, cacheCreation: 0),
        "gpt-5-nano":        .init(input: 0.05, output: 0.40, cacheRead: 0.005, cacheCreation: 0),
        "gpt-5-codex":       .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1-codex":     .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.2":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.3":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.4":           .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.4-codex":     .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.5":           .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-codex":     .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-pro":       .init(input: 30,   output: 180, cacheRead: 30,    cacheCreation: 0),
        "codex-mini-latest": .init(input: 1.50, output: 6,   cacheRead: 0.375, cacheCreation: 0),

        // —— DeepSeek 系列（与 cc-switch seed_model_pricing 对齐）——
        // 缓存语义：通过 Anthropic 兼容端点使用时 input 不含 cache_read，直接乘价。
        // V4 系列官方 CNY 按 1 USD ≈ 7.14 折算。
        "deepseek-v4-pro":    .init(input: 0.435, output: 0.87,  cacheRead: 0.003625, cacheCreation: 0),
        "deepseek-v4-flash":  .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v3.2":      .init(input: 0.28,  output: 0.42,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-v3.1":      .init(input: 0.55,  output: 1.67,  cacheRead: 0.055,    cacheCreation: 0),
        "deepseek-v3":        .init(input: 0.28,  output: 1.11,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-chat":      .init(input: 0.27,  output: 1.10,  cacheRead: 0.07,     cacheCreation: 0),
        "deepseek-reasoner":  .init(input: 0.55,  output: 2.19,  cacheRead: 0.14,     cacheCreation: 0),
        // codex-auto-review 内部 review，官方未公开计费；不入表 → cost=0，token 仍记录

        // —— Grok / xAI 系（USD / 百万 token；Grok 扫描优先用 costUsdTicks，表仅作回退）——
        // 价位对齐 2026 公开 API 量级；精确计费以 CLI 写入的 ticks 为准。
        "grok-4.5":        .init(input: 3,    output: 15,  cacheRead: 0.75,  cacheCreation: 0),
        "grok-4.5-build":  .init(input: 3,    output: 15,  cacheRead: 0.75,  cacheCreation: 0),
        "grok-build":      .init(input: 3,    output: 15,  cacheRead: 0.75,  cacheCreation: 0),
        "grok-build-0.1":  .init(input: 2,    output: 10,  cacheRead: 0.40,  cacheCreation: 0),
        "grok-code-fast":  .init(input: 0.20, output: 1.50, cacheRead: 0.05, cacheCreation: 0),
        "grok-code-fast-1":.init(input: 0.20, output: 1.50, cacheRead: 0.05, cacheCreation: 0),
        "grok-4":          .init(input: 3,    output: 15,  cacheRead: 0.75,  cacheCreation: 0),
        "grok-3":          .init(input: 3,    output: 15,  cacheRead: 0.75,  cacheCreation: 0),
        "grok-3-mini":     .init(input: 0.30, output: 0.50, cacheRead: 0.07, cacheCreation: 0),
    ]

    /// Fast / Priority 的显式价格表。远端 LiteLLM / models.dev 目录没有服务档位维度，不能用于覆盖这些价格。
    private static let codexFastPrices: [String: ModelPrice] = [
        "gpt-5.6":       .init(input: 10,   output: 60,  cacheRead: 1,    cacheCreation: 12.5),
        "gpt-5.6-sol":   .init(input: 10,   output: 60,  cacheRead: 1,    cacheCreation: 12.5),
        "gpt-5.6-terra": .init(input: 5,    output: 30,  cacheRead: 0.5,  cacheCreation: 6.25),
        "gpt-5.6-luna":  .init(input: 2,    output: 12,  cacheRead: 0.2,  cacheCreation: 2.5),
        "gpt-5.5":       .init(input: 12.5, output: 75,  cacheRead: 1.25, cacheCreation: 0),
        "gpt-5.5-codex": .init(input: 12.5, output: 75,  cacheRead: 1.25, cacheCreation: 0),
        "gpt-5.4":       .init(input: 5,    output: 30,  cacheRead: 0.5,  cacheCreation: 0),
        "gpt-5.4-codex": .init(input: 5,    output: 30,  cacheRead: 0.5,  cacheCreation: 0)
    ]

    private static let claudeFastPrices: [String: ModelPrice] = [
        "claude-opus-5":   .init(input: 10, output: 50,  cacheRead: 1, cacheCreation: 12.5),
        "claude-opus-4-8": .init(input: 10, output: 50,  cacheRead: 1, cacheCreation: 12.5),
        // 仅用于 2026-07-24 移除 Fast 前产生的历史日志计价。
        "claude-opus-4-7": .init(input: 30, output: 150, cacheRead: 3, cacheCreation: 37.5),
        // 仅用于 2026-06-29 停止支持 Fast 前产生的历史日志计价。
        "claude-opus-4-6": .init(input: 30, output: 150, cacheRead: 3, cacheCreation: 37.5)
    ]

    /// Fast 的计费等效 Token 倍率。Codex 使用 ChatGPT credit 倍率；Claude 使用 Fast/Standard API 价比。
    private static let codexFastMultipliers: [String: Decimal] = [
        "gpt-5.6": 2.5,
        "gpt-5.6-sol": 2.5,
        "gpt-5.6-terra": 2.5,
        "gpt-5.6-luna": 2.5,
        "gpt-5.5": 2.5,
        "gpt-5.5-codex": 2.5,
        "gpt-5.4": 2,
        "gpt-5.4-codex": 2
    ]

    private static let claudeFastMultipliers: [String: Decimal] = [
        "claude-opus-5": 2,
        "claude-opus-4-8": 2,
        "claude-opus-4-7": 6,
        "claude-opus-4-6": 6
    ]

    /// Anthropic 1 小时 prompt cache 写入按当前档位基础输入价的 2 倍计费。
    /// 5 分钟写入继续使用各模型 `ModelPrice.cacheCreation`（基础输入价的 1.25 倍）。
    private static let claudeCacheCreation1hMultiplier: Decimal = 2

    /// OpenAI Standard API 的 GPT-5.6 / GPT-5.5 上下文阶梯价（USD / 百万 token）。
    /// 完整输入严格超过 272K 时，该次请求的输入、缓存读写和输出全部使用长上下文费率。
    /// `gpt-5.6` 是 Sol 的别名；Pro 是 reasoning.mode，不是独立 model slug。
    private static let contextPriceTiers: [String: ContextPriceTiers] = [
        "gpt-5.6": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 5, output: 30, cacheRead: 0.50, cacheCreation: 6.25),
            longContext: .init(input: 10, output: 45, cacheRead: 1, cacheCreation: 12.5)
        ),
        "gpt-5.6-sol": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 5, output: 30, cacheRead: 0.50, cacheCreation: 6.25),
            longContext: .init(input: 10, output: 45, cacheRead: 1, cacheCreation: 12.5)
        ),
        "gpt-5.6-terra": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 2.5, output: 15, cacheRead: 0.25, cacheCreation: 3.125),
            longContext: .init(input: 5, output: 22.5, cacheRead: 0.5, cacheCreation: 6.25)
        ),
        "gpt-5.6-luna": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 1, output: 6, cacheRead: 0.1, cacheCreation: 1.25),
            longContext: .init(input: 2, output: 9, cacheRead: 0.2, cacheCreation: 2.5)
        ),
        "gpt-5.5": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 5, output: 30, cacheRead: 0.50, cacheCreation: 0),
            longContext: .init(input: 10, output: 45, cacheRead: 1, cacheCreation: 0)
        ),
        "gpt-5.5-codex": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 5, output: 30, cacheRead: 0.50, cacheCreation: 0),
            longContext: .init(input: 10, output: 45, cacheRead: 1, cacheCreation: 0)
        )
    ]

    /// 已审计的固定本地价；即使远端目录返回同名模型，也不能覆盖。
    private static let fixedLocalOverrideKeys: Set<String> = [
        "gpt-5.5-pro"
    ]

    /// 少数模型中途涨价/降价的时间点覆盖；这里的每个 key 必须同时在 `table` 提供最早
    /// 时段的基础价，不在这里出现的模型永远用 `table` 里的固定价。
    /// 键为归一化后的模型名，每条按 `from` 升序排列；只要用量记录的日期 ≥ `from` 就换成对应新价，
    /// 取满足条件里最晚的一档（早于所有 `from` 时退回 `table` 的基准价）。
    private static let timedOverrides: [String: [PricedPeriod]] = [
        "claude-sonnet-5": [
            PricedPeriod(from: utcDate(2026, 9, 1), price: .init(input: 3, output: 15, cacheRead: 0.30, cacheCreation: 3.75))
        ]
    ]

    private static func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A 类模型：受本地特殊规则（阶梯价 / 分段生效价 / 固定价）管辖的 key。远端价格目录对这些 key 零参与——
    /// 一旦让远端「今天的单一价」覆盖进来，272K 阶梯和分段计价会被破坏、历史计价错乱。
    private static let localOverrideKeys: Set<String> = {
        precondition(
            timedOverrides.keys.allSatisfy { table[$0] != nil },
            "timedOverrides 中的模型必须在 Pricing.table 中提供基础价"
        )
        precondition(
            fixedLocalOverrideKeys.allSatisfy { table[$0] != nil },
            "fixedLocalOverrideKeys 中的模型必须在 Pricing.table 中提供固定价"
        )
        return Set(contextPriceTiers.keys)
            .union(timedOverrides.keys)
            .union(fixedLocalOverrideKeys)
    }()

    /// 取某模型在 `date` 这天应使用的价格。
    /// A 类（`localOverrideKeys`）：走本地阶梯价 / 分段生效价，远端价格目录零参与。
    /// B 类（其余）：远端价格目录优先，命中不到才回落内置 `table`；两者都没有 → nil（未定价）。
    private static func standardPrice(for key: String, at date: Date, inputTotal: Int) -> ModelPrice? {
        if let tiers = contextPriceTiers[key] {
            return tiers.rates(for: inputTotal)
        }
        if let overrides = timedOverrides[key] {
            var chosen = table[key]
            for period in overrides where period.from <= date {
                chosen = period.price
            }
            return chosen
        }
        if fixedLocalOverrideKeys.contains(key) {
            return table[key]
        }
        return PricingCatalogStore.shared.rate(for: key) ?? table[key]
    }

    private static func price(
        for key: String,
        app: UsageApp,
        speed: UsageSpeed,
        at date: Date,
        inputTotal: Int
    ) -> ModelPrice? {
        switch speed {
        case .standard:
            return standardPrice(for: key, at: date, inputTotal: inputTotal)
        case .unknown:
            return nil
        case .fast:
            switch app {
            case .codex:
                // OpenAI Priority 官方价格明确排除 >272K 长上下文；不能用 Standard 长上下文价猜测。
                guard inputTotal <= 272_000 else { return nil }
                return codexFastPrices[key]
            case .claude:
                return claudeFastPrices[key]
            case .grok:
                // Grok Build 无独立 Fast 价表；未收录时返回 nil。
                return nil
            }
        }
    }

    /// 归一化模型名：去 `openai/` 前缀；剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；
    /// 兼容 Vertex AI 的 `@日期` 写法。
    nonisolated static func normalize(model: String) -> String {
        var m = model
        if m.hasPrefix("openai/") {
            m.removeFirst("openai/".count)
        }
        if m.hasPrefix("deepseek/") {
            m.removeFirst("deepseek/".count)
        }
        if m.hasPrefix("xai/") {
            m.removeFirst("xai/".count)
        }
        // Vertex 风格：`name@YYYYMMDD`
        if let at = m.firstIndex(of: "@") {
            m = String(m[m.startIndex..<at])
        }
        // Anthropic 风格：`-YYYYMMDD` 或 `-YYYY-MM-DD`
        let patterns = [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#]
        for pat in patterns {
            if let range = m.range(of: pat, options: .regularExpression) {
                m.removeSubrange(range)
                break
            }
        }
        return m.lowercased()
    }

    private static let perMillion: Decimal = 1_000_000

    /// 计算单次调用花费。
    /// - Parameters:
    ///   - app: 用于隐含的 cache_read 语义；Codex 含、Claude 不含（调用方传 input 时已自处理）。
    ///   - at: 该条用量记录实际发生的时间，仅在模型存在 `timedOverrides` 时才会影响取价（如 Sonnet 5）。
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
        let key = normalize(model: model)
        let fullInput = max(0, inputTotal ?? (input + cacheRead + cacheCreation + cacheCreation1h))
        guard let p = price(for: key, app: app, speed: speed, at: date, inputTotal: fullInput) else { return nil }
        let i = Decimal(input)     * p.input        / perMillion
        let o = Decimal(output)    * p.output       / perMillion
        let cr = Decimal(cacheRead) * p.cacheRead   / perMillion
        let cc5m = Decimal(cacheCreation) * p.cacheCreation / perMillion
        let oneHourRate = app == .claude
            ? p.input * claudeCacheCreation1hMultiplier
            : p.cacheCreation
        let cc1h = Decimal(cacheCreation1h) * oneHourRate / perMillion
        let cc = cc5m + cc1h
        return CostBreakdown(input: i, output: o, cacheRead: cr, cacheCreation: cc)
    }

    /// 该模型是否已有可用价格（本地表 / 阶梯价 / 远端价格目录任一命中）。唯一权威接口，
    /// 供 UI 层区分「已定价（含真实 $0）/ 未定价」（目前尚无调用点，供后续统计 UI 使用）。
    static func hasPrice(
        model: String,
        app: UsageApp = .codex,
        speed: UsageSpeed = .standard,
        inputTotal: Int = 0
    ) -> Bool {
        let key = normalize(model: model)
        if speed != .standard {
            return price(for: key, app: app, speed: speed, at: Date(), inputTotal: inputTotal) != nil
        }
        if localOverrideKeys.contains(key) { return true }
        if table[key] != nil { return true }
        return PricingCatalogStore.shared.rate(for: key) != nil
    }

    /// 原始 Tokens 到 Fast 计费等效 Tokens 的换算倍率；未知或未收录的 Fast 模型返回 nil。
    static func billingEquivalentMultiplier(app: UsageApp, model: String, speed: UsageSpeed) -> Decimal? {
        switch speed {
        case .standard:
            return 1
        case .unknown:
            return nil
        case .fast:
            let key = normalize(model: model)
            switch app {
            case .codex: return codexFastMultipliers[key]
            case .claude: return claudeFastMultipliers[key]
            case .grok: return nil
            }
        }
    }

    /// 价格表内容指纹（SHA-256，确定性）。
    /// 扫描状态 / 汇总缓存持久化它；内容一变（新增模型、改价、修正数值、调整限时覆盖，或 B 类模型
    /// 的远端合并价变化）→ 指纹变 → 缓存自动失效并全量重扫重算历史桶，无需手动 bump 版本号。
    ///
    /// - Parameter knownModels: 当前用量中实际出现过的（归一化后）模型名集合。B 类远端合并价只对
    ///   这个集合里的模型算入哈希——而不是把整个 LiteLLM/models.dev 目录塞进去，否则远端新增的、
    ///   本地用户根本没用过的模型也会触发全量重扫。调用方通常传 `Set(aggregator.snapshot().map(\.model))`
    ///   或从磁盘缓存自带的 buckets 推导（`UsageRollupCache.load()` 即如此，见该文件）。
    static func fingerprint(knownModels: Set<String>) -> String {
        let baseBody = table.keys.sorted().map { key -> String in
            let p = table[key]!
            return "\(key):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
        }.joined(separator: ";")
        let tierBody = contextPriceTiers.keys.sorted().map { key -> String in
            let tiers = contextPriceTiers[key]!
            let short = tiers.shortContext
            let long = tiers.longContext
            return "\(key):\(tiers.longContextThreshold):\(short.input)/\(short.output)/\(short.cacheRead)/\(short.cacheCreation):\(long.input)/\(long.output)/\(long.cacheRead)/\(long.cacheCreation)"
        }.joined(separator: ";")
        let overrideBody = timedOverrides.keys.sorted().map { key -> String in
            let parts = timedOverrides[key]!.sorted { $0.from < $1.from }.map { period -> String in
                let p = period.price
                return "\(period.from.timeIntervalSince1970)=\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
            }.joined(separator: ",")
            return "\(key)@\(parts)"
        }.joined(separator: ";")
        let fastPriceBody = [
            fingerprintBody(codexFastPrices, prefix: "codex"),
            fingerprintBody(claudeFastPrices, prefix: "claude")
        ].joined(separator: ";")
        let fastMultiplierBody = [
            fingerprintBody(codexFastMultipliers, prefix: "codex"),
            fingerprintBody(claudeFastMultipliers, prefix: "claude")
        ].joined(separator: ";")
        let cacheRuleBody = "claude-cache-creation-1h:\(claudeCacheCreation1hMultiplier)"
        let fixedOverrideBody = fixedLocalOverrideKeys.sorted().joined(separator: ";")
        let remoteBody = knownModels.subtracting(localOverrideKeys).sorted().compactMap { key -> String? in
            guard let rate = PricingCatalogStore.shared.rate(for: key) else { return nil }
            return "\(key):\(rate.input)/\(rate.output)/\(rate.cacheRead)/\(rate.cacheCreation)"
        }.joined(separator: ";")
        let digest = SHA256.hash(data: Data("\(baseBody)|\(tierBody)|\(overrideBody)|\(fixedOverrideBody)|\(fastPriceBody)|\(fastMultiplierBody)|\(cacheRuleBody)|\(remoteBody)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprintBody(_ values: [String: ModelPrice], prefix: String) -> String {
        values.keys.sorted().map { key in
            let p = values[key]!
            return "\(prefix):\(key):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
        }.joined(separator: ";")
    }

    private static func fingerprintBody(_ values: [String: Decimal], prefix: String) -> String {
        values.keys.sorted().map { "\(prefix):\($0):\(values[$0]!)" }.joined(separator: ";")
    }
}
