import Foundation
import CryptoKit

/// 模型价格（USD / 百万 token）。命中不到的模型未定价（`Pricing.cost` 返回 nil），token 仍记录。
nonisolated struct ModelPrice: Sendable, Codable, Equatable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal
}

/// 单次调用四类 token 的成本拆分。日志有有效总价，或模型已定价时才会生成；未定价继续用 `nil` 表达。
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

/// 阶梯价模型的限时覆盖：从 `from` 这天（UTC 0 点）起整套短/长上下文价改为 `tiers`。
nonisolated private struct TieredPricedPeriod: Sendable {
    let from: Date
    let tiers: ContextPriceTiers
}

nonisolated enum Pricing {
    /// 价格表与 cc-switch `seed_model_pricing` / CodexBar `CostUsagePricing` 对齐（2026 上半年价位）。
    /// 命中不到时返回 nil。键为归一化后的模型名（循环剥 provider 前缀 `openai-codex/` / `openai/` /
    /// `anthropic/` / `deepseek/` / `opencode-go/` / `commandcode/` / `command-code/`
    /// 和末尾 `-YYYYMMDD` / `-YYYY-MM-DD` 日期段）。
    static let table: [String: ModelPrice] = [
        // —— Claude 4.x / 5.x 系（input 已不含 cache_read）——
        // Fable 5.1 自发布起缓存读取即为 0.025x 基础输入价（$0.25）；Fable 5 仍为 0.1x。
        "claude-fable-5.1":  .init(input: 10,  output: 50,  cacheRead: 0.25, cacheCreation: 12.50),
        "claude-fable-5-1":  .init(input: 10,  output: 50,  cacheRead: 0.25, cacheCreation: 12.50),
        "claude-fable-5":    .init(input: 10,  output: 50,  cacheRead: 1.00, cacheCreation: 12.50),
        // Opus 5.5 缓存读取为 0.05x 基础输入价。
        "claude-opus-5.5":   .init(input: 4,   output: 20,  cacheRead: 0.20, cacheCreation: 5),
        "claude-opus-5-5":   .init(input: 4,   output: 20,  cacheRead: 0.20, cacheCreation: 5),
        "claude-opus-5":     .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-8":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-7":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-6":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-5":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-1":   .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        "claude-opus-4":     .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        // Sonnet 5 官方已确认 $2/$10 为固定标准价（原定 2026-09-01 涨价 $3/$15 已取消），列入 fixedLocalOverrideKeys 锁死。
        "claude-sonnet-5":   .init(input: 2,   output: 10,  cacheRead: 0.20, cacheCreation: 2.50),
        "claude-sonnet-4-7": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-6": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-5": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4":   .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-haiku-4-5":  .init(input: 1,   output: 5,   cacheRead: 0.10, cacheCreation: 1.25),
        "claude-haiku-4":    .init(input: 0.8, output: 4,   cacheRead: 0.08, cacheCreation: 1.0),
        // —— Claude 3.5 / 3 经典系 ——
        "claude-3-5-sonnet": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-3-5-haiku":  .init(input: 0.8, output: 4,   cacheRead: 0.08, cacheCreation: 1.0),
        "claude-3-opus":     .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),

        // —— Codex / GPT-6、GPT-5 系（input 含 cache_read，调用侧已扣 billable）。
        "gpt-6-astra":       .init(input: 10,   output: 50,  cacheRead: 1,    cacheCreation: 12.5),
        "gpt-6-sol":         .init(input: 2,    output: 10,  cacheRead: 0.20, cacheCreation: 2.5),
        "gpt-6-luna":        .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheCreation: 0.125),
        "gpt-5.6":           .init(input: 5,    output: 30,  cacheRead: 0.50, cacheCreation: 6.25),
        "gpt-5.6-sol":       .init(input: 5,    output: 30,  cacheRead: 0.50, cacheCreation: 6.25),
        "gpt-5.6-terra":     .init(input: 2,    output: 12,  cacheRead: 0.20, cacheCreation: 2.5),
        "gpt-5.6-luna":      .init(input: 0.20, output: 1.20, cacheRead: 0.02, cacheCreation: 0.25),
        "gpt-5.6-cyber":     .init(input: 12.5, output: 75,  cacheRead: 1.25, cacheCreation: 15.625),
        "gpt-5.5":           .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-codex":     .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-pro":       .init(input: 30,   output: 180, cacheRead: 30,    cacheCreation: 0),
        "gpt-5.4":           .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.4-codex":     .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.4-mini":      .init(input: 0.25, output: 2,   cacheRead: 0.025, cacheCreation: 0),
        "gpt-5.3":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.3-codex":     .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.2":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.2-codex":     .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1-codex":     .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5":             .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5-codex":       .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5-mini":        .init(input: 0.25, output: 2,   cacheRead: 0.025, cacheCreation: 0),
        "gpt-5-nano":        .init(input: 0.05, output: 0.40, cacheRead: 0.005, cacheCreation: 0),
        "codex-mini-latest": .init(input: 1.50, output: 6,   cacheRead: 0.375, cacheCreation: 0),

        // —— OpenAI 经典常用与推理模型 ——
        "gpt-4o":            .init(input: 2.50, output: 10,  cacheRead: 1.25,  cacheCreation: 0),
        "gpt-4o-mini":       .init(input: 0.15, output: 0.60, cacheRead: 0.075, cacheCreation: 0),
        "o1":                .init(input: 15,   output: 60,  cacheRead: 7.50,  cacheCreation: 0),
        "o1-mini":           .init(input: 1.10, output: 4.40, cacheRead: 0.55,  cacheCreation: 0),
        "o3":                .init(input: 2.00, output: 8.00, cacheRead: 1.00,  cacheCreation: 0),
        "o3-mini":           .init(input: 1.10, output: 4.40, cacheRead: 0.55,  cacheCreation: 0),
        "o4-mini":           .init(input: 1.10, output: 4.40, cacheRead: 0.55,  cacheCreation: 0),

        // —— Cursor 官方模型 ——
        "composer-2.5":         .init(input: 3,    output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "cursor-composer-2-5":  .init(input: 3,    output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "grok-4-6":             .init(input: 2,    output: 6,   cacheRead: 0.50, cacheCreation: 0),
        "grok-4-5":             .init(input: 2,    output: 6,   cacheRead: 0.50, cacheCreation: 0),

        // —— Google Gemini 系列 ——
        "gemini-3.7-flash":  .init(input: 0.10, output: 0.40, cacheRead: 0.025,  cacheCreation: 0),
        "gemini-3.1-pro":    .init(input: 1.25, output: 5.00, cacheRead: 0.3125, cacheCreation: 0),

        // —— DeepSeek 系列（与 cc-switch seed_model_pricing 对齐）——
        // 缓存语义：通过 Anthropic 兼容端点使用时 input 不含 cache_read，直接乘价。
        // V4 系列官方 CNY 按 1 USD ≈ 7.14 折算。
        "deepseek-v4-pro":              .init(input: 0.435, output: 0.87,  cacheRead: 0.003625, cacheCreation: 0),
        "deepseek-v4-flash":            .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v4-flash-vision-exp": .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v3.2":                .init(input: 0.28,  output: 0.42,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-v3.1":                .init(input: 0.55,  output: 1.67,  cacheRead: 0.055,    cacheCreation: 0),
        "deepseek-v3":                  .init(input: 0.28,  output: 1.11,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-chat":                .init(input: 0.27,  output: 1.10,  cacheRead: 0.07,     cacheCreation: 0),
        "deepseek-reasoner":            .init(input: 0.55,  output: 2.19,  cacheRead: 0.14,     cacheCreation: 0),
        // codex-auto-review 内部 review，官方未公开计费；不入表 → cost=0，token 仍记录
    ]

    /// Fast / Priority 的离线兜底表。当前在线目录可提供部分 Fast 价格；
    /// 历史/特殊规则优先本地，其余型号在线优先、命中不到再回落这里。
    private static let codexFastPrices: [String: ModelPrice] = [
        "gpt-6-astra":   .init(input: 20,   output: 100, cacheRead: 2,    cacheCreation: 25),
        "gpt-6-sol":     .init(input: 4,    output: 20,  cacheRead: 0.4,  cacheCreation: 5),
        "gpt-6-luna":    .init(input: 0.2,  output: 1,   cacheRead: 0.02, cacheCreation: 0.25),
        "gpt-5.6":       .init(input: 10,   output: 60,  cacheRead: 1,    cacheCreation: 12.5),
        "gpt-5.6-sol":   .init(input: 10,   output: 60,  cacheRead: 1,    cacheCreation: 12.5),
        "gpt-5.6-terra": .init(input: 4,    output: 24,  cacheRead: 0.4,  cacheCreation: 5),
        "gpt-5.6-luna":  .init(input: 0.4,  output: 2.4, cacheRead: 0.04, cacheCreation: 0.5),
        "gpt-5.5":       .init(input: 12.5, output: 75,  cacheRead: 1.25, cacheCreation: 0),
        "gpt-5.5-codex": .init(input: 12.5, output: 75,  cacheRead: 1.25, cacheCreation: 0),
        "gpt-5.4":       .init(input: 5,    output: 30,  cacheRead: 0.5,  cacheCreation: 0),
        "gpt-5.4-codex": .init(input: 5,    output: 30,  cacheRead: 0.5,  cacheCreation: 0)
    ]

    private static let claudeFastPrices: [String: ModelPrice] = [
        "claude-opus-5.5": .init(input: 8,  output: 40,  cacheRead: 0.4, cacheCreation: 10),
        "claude-opus-5-5": .init(input: 8,  output: 40,  cacheRead: 0.4, cacheCreation: 10),
        "claude-opus-5":   .init(input: 10, output: 50,  cacheRead: 1, cacheCreation: 12.5),
        "claude-opus-4-8": .init(input: 10, output: 50,  cacheRead: 1, cacheCreation: 12.5),
        // 仅用于 2026-07-24 移除 Fast 前产生的历史日志计价。
        "claude-opus-4-7": .init(input: 30, output: 150, cacheRead: 3, cacheCreation: 37.5),
        // 仅用于 2026-06-29 停止支持 Fast 前产生的历史日志计价。
        "claude-opus-4-6": .init(input: 30, output: 150, cacheRead: 3, cacheCreation: 37.5)
    ]

    /// 历史价格或已核对的上游偏差必须固定使用本地价，不能被远端当前值覆盖。
    private static let fixedFastLocalOverrideKeys: Set<String> = [
        // LiteLLM 当前 GPT-5.5 Priority 仍是旧价；以已审计官方价固定覆盖。
        "gpt-5.5",
        "gpt-5.5-codex",
        "claude-opus-4-7",
        "claude-opus-4-6"
    ]

    /// Fast 的计费等效 Token 倍率。Codex 使用 ChatGPT credit 倍率；Claude 使用 Fast/Standard API 价比。
    private static let codexFastMultipliers: [String: Decimal] = [
        "gpt-6-astra": 2.5,
        "gpt-6-sol": 2.5,
        "gpt-6-luna": 2.5,
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
        "claude-opus-5.5": 2,
        "claude-opus-5-5": 2,
        "claude-opus-5": 2,
        "claude-opus-4-8": 2,
        "claude-opus-4-7": 6,
        "claude-opus-4-6": 6
    ]

    /// Anthropic 1 小时 prompt cache 写入按当前档位基础输入价的 2 倍计费。
    /// 5 分钟写入继续使用各模型 `ModelPrice.cacheCreation`（基础输入价的 1.25 倍）。
    private static let claudeCacheCreation1hMultiplier: Decimal = 2

    /// OpenAI Standard API 的 GPT-6 / GPT-5.6 / GPT-5.5 上下文阶梯价（USD / 百万 token）。
    /// 完整输入严格超过 272K 时，该次请求的输入、缓存读写和输出全部使用长上下文费率。
    /// `gpt-5.6` 是 Sol 的别名；Pro 是 reasoning.mode，不是独立 model slug。
    /// GPT-5.6 Sol 这里是 2026-08-21 促销前的原价，促销价见 `timedContextPriceTiers`。
    private static let contextPriceTiers: [String: ContextPriceTiers] = [
        "gpt-6-astra": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 10, output: 50, cacheRead: 1, cacheCreation: 12.5),
            longContext: .init(input: 20, output: 75, cacheRead: 2, cacheCreation: 25)
        ),
        "gpt-6-sol": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 2, output: 10, cacheRead: 0.2, cacheCreation: 2.5),
            longContext: .init(input: 4, output: 15, cacheRead: 0.4, cacheCreation: 5)
        ),
        "gpt-6-luna": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 0.1, output: 0.5, cacheRead: 0.01, cacheCreation: 0.125),
            longContext: .init(input: 0.2, output: 0.75, cacheRead: 0.02, cacheCreation: 0.25)
        ),
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
            shortContext: .init(input: 2, output: 12, cacheRead: 0.2, cacheCreation: 2.5),
            longContext: .init(input: 4, output: 18, cacheRead: 0.4, cacheCreation: 5)
        ),
        "gpt-5.6-luna": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 0.2, output: 1.2, cacheRead: 0.02, cacheCreation: 0.25),
            longContext: .init(input: 0.4, output: 1.8, cacheRead: 0.04, cacheCreation: 0.5)
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

    /// GPT-5.6 Sol 促销价：OpenAI 2026-08-21 起降为 $4 / $20，官方称至少持续到 2026-11-21。
    /// 促销结束且官方公布后续价格后，需要在这里追加新的分段。
    private static let gpt56SolPromoStart = utcDay(year: 2026, month: 8, day: 21)

    private static let gpt56SolPromoTiers = ContextPriceTiers(
        longContextThreshold: 272_000,
        shortContext: .init(input: 4, output: 20, cacheRead: 0.4, cacheCreation: 5),
        longContext: .init(input: 8, output: 30, cacheRead: 0.8, cacheCreation: 10)
    )

    /// 阶梯价模型的限时覆盖；每个 key 必须同时在 `contextPriceTiers` 提供最早时段的阶梯价，
    /// 每条按 `from` 升序排列，取用量记录日期满足条件里最晚的一档。
    private static let timedContextPriceTiers: [String: [TieredPricedPeriod]] = [
        "gpt-5.6": [.init(from: gpt56SolPromoStart, tiers: gpt56SolPromoTiers)],
        "gpt-5.6-sol": [.init(from: gpt56SolPromoStart, tiers: gpt56SolPromoTiers)]
    ]

    /// Codex Fast 的限时覆盖；每个 key 必须同时在 `codexFastPrices` 提供最早时段的价格。
    /// 命中这里的模型不读远端 Fast 价，因为远端只有当前单一价，会改写促销前的历史用量。
    private static let timedCodexFastPrices: [String: [PricedPeriod]] = [
        "gpt-5.6": [.init(from: gpt56SolPromoStart, price: .init(input: 8, output: 40, cacheRead: 0.8, cacheCreation: 10))],
        "gpt-5.6-sol": [.init(from: gpt56SolPromoStart, price: .init(input: 8, output: 40, cacheRead: 0.8, cacheCreation: 10))]
    ]

    private static func utcDay(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// 已审计的固定本地价；即使远端目录返回同名模型，也不能覆盖。
    private static let fixedLocalOverrideKeys: Set<String> = [
        "gpt-5.5-pro",
        // 官方已确认 Sonnet 5 的 $2/$10 为固定标准价，防止远端目录按旧计划价覆盖。
        "claude-sonnet-5"
    ]

    /// 少数模型中途涨价/降价的时间点覆盖；这里的每个 key 必须同时在 `table` 提供最早
    /// 时段的基础价，不在这里出现的模型永远用 `table` 里的固定价。
    /// 键为归一化后的模型名，每条按 `from` 升序排列；只要用量记录的日期 ≥ `from` 就换成对应新价，
    /// 取满足条件里最晚的一档（早于所有 `from` 时退回 `table` 的基准价）。
    /// 当前无分段价模型（Sonnet 5 原定 2026-09-01 涨价已取消），机制保留给未来限时调价场景。
    private static let timedOverrides: [String: [PricedPeriod]] = [:]

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
        precondition(
            timedContextPriceTiers.keys.allSatisfy { contextPriceTiers[$0] != nil },
            "timedContextPriceTiers 中的模型必须在 contextPriceTiers 中提供基础阶梯价"
        )
        precondition(
            timedCodexFastPrices.keys.allSatisfy { codexFastPrices[$0] != nil },
            "timedCodexFastPrices 中的模型必须在 codexFastPrices 中提供基础价"
        )
        return Set(contextPriceTiers.keys)
            .union(timedOverrides.keys)
            .union(fixedLocalOverrideKeys)
    }()

    /// 取某模型在 `date` 这天应使用的价格。
    /// A 类（`localOverrideKeys`）：走本地阶梯价 / 分段生效价，远端价格目录零参与。
    /// B 类（其余）：远端价格目录优先，命中不到才回落内置 `table`；两者都没有 → nil（未定价）。
    private static func standardPrice(
        for key: String,
        app: UsageApp,
        at date: Date,
        inputTotal: Int
    ) -> ModelPrice? {
        if var tiers = contextPriceTiers[key] {
            for period in timedContextPriceTiers[key] ?? [] where period.from <= date {
                tiers = period.tiers
            }
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
        return PricingCatalogStore.shared.rate(for: key, app: app, speed: .standard) ?? table[key]
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
            return standardPrice(for: key, app: app, at: date, inputTotal: inputTotal)
        case .unknown:
            return nil
        case .fast:
            if fixedFastLocalOverrideKeys.contains(key) {
                switch app {
                case .codex: return codexFastPrices[key]
                case .claude: return claudeFastPrices[key]
                case .cursor: return nil
                case .pi: return nil
                case .opencode: return nil
                }
            }
            switch app {
            case .codex:
                // OpenAI Priority 官方价格明确排除 >272K 长上下文；不能用 Standard 长上下文价猜测。
                guard inputTotal <= 272_000 else { return nil }
                if let periods = timedCodexFastPrices[key] {
                    var chosen = codexFastPrices[key]
                    for period in periods where period.from <= date {
                        chosen = period.price
                    }
                    return chosen
                }
                return PricingCatalogStore.shared.rate(for: key, app: app, speed: .fast)
                    ?? codexFastPrices[key]
            case .claude:
                return PricingCatalogStore.shared.rate(for: key, app: app, speed: .fast)
                    ?? claudeFastPrices[key]
            case .cursor:
                // Cursor 使用服务端 chargedCents，不走本地模型定价。
                return nil
            case .pi:
                // pi 没有 Fast 档位概念。
                return nil
            case .opencode:
                // opencode 没有 Fast 档位概念。
                return nil
            }
        }
    }

    /// 归一化模型名：循环去支持的 provider 前缀（含嵌套两层，如 `commandcode/deepseek/...`）；
    /// 剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；兼容 Vertex AI 的 `@日期` 写法。
    nonisolated static func normalize(model: String) -> String {
        var m = model
        // 循环剥除：Pi / OpenCode 日志里 provider 网关标签可能是 `commandcode/deepseek/...` 双层，
        // 剥掉外层后还要继续剥内层才能与本地表 / 远端目录对齐。
        let providerPrefixes = [
            "openai-codex/", "openai/", "anthropic/", "deepseek/",
            "opencode-go/", "commandcode/", "command-code/"
        ]
        var removed = true
        while removed {
            removed = false
            for prefix in providerPrefixes where m.hasPrefix(prefix) {
                m.removeFirst(prefix.count)
                removed = true
                break
            }
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
    ///   - at: 该条用量记录实际发生的时间，仅在模型存在 `timedOverrides` 时才会影响取价。
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
        let key = normalize(model: model)
        return price(for: key, app: app, speed: speed, at: Date(), inputTotal: inputTotal) != nil
    }

    /// 是否应因缺价主动刷新远端目录。明确不计价的内部模型不会触发网络请求。
    static func needsRemotePriceRefresh(model: String, app: UsageApp, speed: UsageSpeed) -> Bool {
        let key = normalize(model: model)
        guard speed != .unknown else { return false }
        if app == .codex, key == "codex-auto-review" { return false }
        return price(for: key, app: app, speed: speed, at: Date(), inputTotal: 0) == nil
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
            case .codex:
                // ChatGPT credit 倍率不是 API Priority 价格字段，不能从在线价格猜。
                return codexFastMultipliers[key]
            case .claude:
                return claudeFastMultipliers[key] ?? derivedClaudeFastMultiplier(for: key)
            case .cursor:
                return nil
            case .pi:
                // pi 无 Fast 档位概念。
                return nil
            case .opencode:
                // opencode 无 Fast 档位概念。
                return nil
            }
        }
    }

    /// Claude 的计费等效倍率定义为 Fast / Standard API 价比。只有四项费率的非零比例完全一致时才推导；
    /// 任一项不一致就返回 nil，让 UI 显示「—」，避免用输入价比例冒充整体倍率。
    private static func derivedClaudeFastMultiplier(for key: String) -> Decimal? {
        guard let standard = standardPrice(for: key, app: .claude, at: Date(), inputTotal: 0),
              let fast = price(for: key, app: .claude, speed: .fast, at: Date(), inputTotal: 0)
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

    /// 价格表内容指纹（SHA-256，确定性）。
    /// 扫描状态 / 汇总缓存持久化它；内容一变（新增模型、改价、修正数值、调整限时覆盖，或 B 类模型
    /// 的远端合并价变化）→ 指纹变 → 缓存自动失效并全量重扫重算历史桶，无需手动 bump 版本号。
    ///
    /// - Parameter knownUsage: 当前用量中实际出现过的 app/model/speed 集合。远端合并价只对
    ///   这个集合算入哈希，避免远端新增本地未使用模型时触发无关全量重扫。
    static func fingerprint(knownUsage: Set<PricingUsageKey>) -> String {
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
        let timedTierBody = timedContextPriceTiers.keys.sorted().map { key -> String in
            let parts = timedContextPriceTiers[key]!.sorted { $0.from < $1.from }.map { period -> String in
                let short = period.tiers.shortContext
                let long = period.tiers.longContext
                return "\(period.from.timeIntervalSince1970)=\(period.tiers.longContextThreshold):\(short.input)/\(short.output)/\(short.cacheRead)/\(short.cacheCreation):\(long.input)/\(long.output)/\(long.cacheRead)/\(long.cacheCreation)"
            }.joined(separator: ",")
            return "\(key)@\(parts)"
        }.joined(separator: ";")
        let timedFastBody = timedCodexFastPrices.keys.sorted().map { key -> String in
            let parts = timedCodexFastPrices[key]!.sorted { $0.from < $1.from }.map { period -> String in
                let p = period.price
                return "\(period.from.timeIntervalSince1970)=\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
            }.joined(separator: ",")
            return "codex:\(key)@\(parts)"
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
        let fixedFastOverrideBody = fixedFastLocalOverrideKeys.sorted().joined(separator: ";")
        let remoteBody = knownUsage.sorted { $0.persistedKey < $1.persistedKey }.compactMap { usage -> String? in
            if usage.speed == .standard, localOverrideKeys.contains(usage.model) { return nil }
            if usage.speed == .fast, fixedFastLocalOverrideKeys.contains(usage.model) { return nil }
            if usage.speed == .fast, usage.app == .codex, timedCodexFastPrices[usage.model] != nil { return nil }
            guard let rate = PricingCatalogStore.shared.rate(
                for: usage.model,
                app: usage.app,
                speed: usage.speed
            ) else { return nil }
            return "\(usage.persistedKey):\(rate.input)/\(rate.output)/\(rate.cacheRead)/\(rate.cacheCreation)"
        }.joined(separator: ";")
        let digest = SHA256.hash(data: Data("\(baseBody)|\(tierBody)|\(timedTierBody)|\(timedFastBody)|\(overrideBody)|\(fixedOverrideBody)|\(fixedFastOverrideBody)|\(fastPriceBody)|\(fastMultiplierBody)|\(cacheRuleBody)|\(remoteBody)".utf8))
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
