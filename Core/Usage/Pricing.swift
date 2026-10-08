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
    /// 价格表按各厂商官方定价页核对（最近一次 2026-10-08），起点对齐 cc-switch `seed_model_pricing` /
    /// CodexBar `CostUsagePricing`。命中不到时返回 nil。键为 `pricingKey(model:)` 归一化后的模型名（循环剥 provider 前缀
    /// `openai-codex/` / `openai/` / `anthropic/` / `deepseek/` / `opencode-go/` / `commandcode/` /
    /// `command-code/` / `antigravity/` / `z-ai/` / `zai/` / `minimax/` 和末尾 `-YYYYMMDD` /
    /// `-YYYY-MM-DD` 日期段）。
    ///
    /// Google Gemini、Cursor / xAI、Z.ai、MiniMax 的价格只能在这里维护：远端价格目录只收
    /// anthropic / openai / deepseek（见 `LiteLLMPricingDecoder` 与 `ModelsDevPricingDecoder` 的
    /// `allowedProviders`），这几家厂商的 key 在远端目录里永远命中不到。
    static let table: [String: ModelPrice] = [
        // —— Claude 4.x / 5.x 系（input 已不含 cache_read）——
        // Fable 5.1 自发布起缓存读取即为 0.025x 基础输入价（$0.25）；Fable 5 仍为 0.1x。
        "claude-fable-5.1":  .init(input: 10,  output: 50,  cacheRead: 0.25, cacheCreation: 12.50),
        "claude-fable-5-1":  .init(input: 10,  output: 50,  cacheRead: 0.25, cacheCreation: 12.50),
        "claude-fable-5":    .init(input: 10,  output: 50,  cacheRead: 1.00, cacheCreation: 12.50),
        // Mythos 5 / 5.1 与 Fable 5 / 5.1 同价：Mythos 5.1 缓存读取同为 0.025x（$0.25），Mythos 5 为 0.1x。
        "claude-mythos-5.1":     .init(input: 10, output: 50, cacheRead: 0.25, cacheCreation: 12.50),
        "claude-mythos-5-1":     .init(input: 10, output: 50, cacheRead: 0.25, cacheCreation: 12.50),
        "claude-mythos-5":       .init(input: 10, output: 50, cacheRead: 1.00, cacheCreation: 12.50),
        // Mythos Preview 是 Mythos 5 之前的邀请制版本，价格为 $25 / $125（缓存读 0.1x、5m 写入 1.25x）。
        "claude-mythos-preview": .init(input: 25, output: 125, cacheRead: 2.50, cacheCreation: 31.25),
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
        // Sonnet 5.5 上市价与 Sonnet 5 相同。2026-10-07 起缓存读取减半为 $0.10，见 timedOverrides。
        // 定价总表那一行仍印着 $0.20；以同页缓存章节和 10 月 7 日公告的 $0.10 为准。
        "claude-sonnet-5-5": .init(input: 2,   output: 10,  cacheRead: 0.20, cacheCreation: 2.50),
        "claude-sonnet-5.5": .init(input: 2,   output: 10,  cacheRead: 0.20, cacheCreation: 2.50),
        // Haiku 5.5（2026-10-07）：≤100K 为短上下文价，超过 100K 整次请求改按长上下文价，见 contextPriceTiers。
        "claude-haiku-5-5":  .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheCreation: 0.125),
        "claude-haiku-5.5":  .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheCreation: 0.125),
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
        // GPT-6.1 Sol（2026-09-29 DevDay 发布）：输入 / 输出与 GPT-6 Sol 同价，缓存输入减半为 $0.10（0.05x）；
        // 272K 长上下文阶梯见 contextPriceTiers，Fast 档见 codexFastPrices。
        "gpt-6.1-sol":       .init(input: 2,    output: 10,  cacheRead: 0.10, cacheCreation: 2.5),
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
        "gpt-5.4-mini":      .init(input: 0.75, output: 4.50, cacheRead: 0.075, cacheCreation: 0),
        "gpt-5.4-nano":      .init(input: 0.20, output: 1.25, cacheRead: 0.02,  cacheCreation: 0),
        // GPT-5.2 起该档位是 $1.75 / $14，不是 GPT-5.1 的 $1.25 / $10；5.3 系沿用同一价。
        "gpt-5.3":           .init(input: 1.75, output: 14,  cacheRead: 0.175, cacheCreation: 0),
        "gpt-5.3-codex":     .init(input: 1.75, output: 14,  cacheRead: 0.175, cacheCreation: 0),
        "gpt-5.2":           .init(input: 1.75, output: 14,  cacheRead: 0.175, cacheCreation: 0),
        "gpt-5.2-codex":     .init(input: 1.75, output: 14,  cacheRead: 0.175, cacheCreation: 0),
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

        // —— Cursor 官方模型（Cursor Models 池；官方无缓存写入费）——
        // Composer 2.5 标准档 $0.5 / $2.5；产品内默认走 Fast 档 $3 / $15，Cursor 日志里即 `composer-2.5-fast`。
        "composer-2.5":         .init(input: 0.50, output: 2.50, cacheRead: 0.20, cacheCreation: 0),
        "cursor-composer-2-5":  .init(input: 0.50, output: 2.50, cacheRead: 0.20, cacheCreation: 0),
        "composer-2.5-fast":    .init(input: 3,    output: 15,   cacheRead: 0.50, cacheCreation: 0),
        // Grok 4.7 输入超过 256K 时整次请求按 2 倍标准价，见 contextPriceTiers。Cursor 自身费用仍用服务端 chargedCents。
        "grok-4-7":             .init(input: 2,    output: 6,    cacheRead: 0.50, cacheCreation: 0),
        "grok-4-6":             .init(input: 2,    output: 6,    cacheRead: 0.50, cacheCreation: 0),
        "grok-4-5":             .init(input: 2,    output: 6,    cacheRead: 0.50, cacheCreation: 0),

        // —— Google Gemini 系列（远端目录不收 Google，只能靠本表）——
        // 3.6 / 3.7 / 3.8 Flash 同为 $0.75 / $3.75（促销价，到 2026-12-31）；2027-01-01 起的原价见 timedOverrides。
        "gemini-3.8-flash":  .init(input: 0.75, output: 3.75,  cacheRead: 0.075, cacheCreation: 0),
        "gemini-3.7-flash":  .init(input: 0.75, output: 3.75,  cacheRead: 0.075, cacheCreation: 0),
        "gemini-3.6-flash":  .init(input: 0.75, output: 3.75,  cacheRead: 0.075, cacheCreation: 0),
        // 3.1 Pro 完整输入超过 200K 时整次请求改按长上下文价（见 contextPriceTiers）。
        "gemini-3.1-pro":    .init(input: 2.00, output: 12.00, cacheRead: 0.20,  cacheCreation: 0),

        // —— DeepSeek 系列（与 cc-switch seed_model_pricing 对齐）——
        // 缓存语义：通过 Anthropic 兼容端点使用时 input 不含 cache_read，直接乘价。
        // V4 系列官方 CNY 按 1 USD ≈ 7.14 折算；下面 deepseek-v4-pro / flash 四 key 的
        // 2026-08-16 起的官方价见 `timedOverrides`，这里的行是最早时段的基础价（分段价的兜底基准）。
        "deepseek-v4-pro":              .init(input: 0.435, output: 0.87,  cacheRead: 0.003625, cacheCreation: 0),
        // `deepseek-flash` 与 `deepseek-v4.1-flash` 是官方现名与本机 DSH / CLI 日志里的标识；
        // 与下面两行同价，按仓库惯例写成重复行，不引入别名映射。
        "deepseek-flash":               .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v4.1-flash":          .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v4-flash":            .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v4-flash-vision-exp": .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        // `*-fast` 变体只有 Command Code 在售（DeepSeek 官方只提供 deepseek-flash 与 deepseek-v4-pro），
        // 价取 Command Code 定价页：v4.1-flash-fast 同源分时计价，沿用「两段都取高峰价」口径单行入表，
        // 两者都不进 timedOverrides，保持 B 类（远端目录永远命中不到，价只能由本表提供）。
        "deepseek-v4.1-flash-fast":     .init(input: 0.32,  output: 1.16,  cacheRead: 0.032,    cacheCreation: 0),
        "deepseek-v4-flash-fast":       .init(input: 0.28,  output: 0.56,  cacheRead: 0.07,     cacheCreation: 0),
        "deepseek-v3.2":                .init(input: 0.28,  output: 0.42,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-v3.1":                .init(input: 0.55,  output: 1.67,  cacheRead: 0.055,    cacheCreation: 0),
        "deepseek-v3":                  .init(input: 0.28,  output: 1.11,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-chat":                .init(input: 0.27,  output: 1.10,  cacheRead: 0.07,     cacheCreation: 0),
        "deepseek-reasoner":            .init(input: 0.55,  output: 2.19,  cacheRead: 0.14,     cacheCreation: 0),
        // —— 第三方网关模型（Command Code / OpenCode 转售，远端目录不收这些厂商）——
        // Z.ai 官方价。GLM-5.2 与 GLM-5.3 同价。缓存存储费官方限时免费，不入表。
        "glm-5.3":        .init(input: 1.40, output: 4.40, cacheRead: 0.26,  cacheCreation: 0),
        "glm-5.2":        .init(input: 1.40, output: 4.40, cacheRead: 0.26,  cacheCreation: 0),
        "glm-5.3-flash":  .init(input: 0.15, output: 0.50, cacheRead: 0.03,  cacheCreation: 0),
        "glm-5.3-flashx": .init(input: 0.37, output: 1.25, cacheRead: 0.075, cacheCreation: 0),
        // MiniMax 现价取永久五折后的实付价。M3 官方另有 >512K 的 2 倍档，Command Code 两档都按短上下文价，这里保持短上下文价。
        // M2.7 官方单列缓存写入；M3 定价页没有这项，继续为 0。
        "minimax-m3":              .init(input: 0.30, output: 1.20, cacheRead: 0.06, cacheCreation: 0),
        "minimax-m2.7":            .init(input: 0.30, output: 1.20, cacheRead: 0.06, cacheCreation: 0.375),
        "minimax-m2.7-highspeed":  .init(input: 0.60, output: 2.40, cacheRead: 0.06, cacheCreation: 0.375),
        // codex-auto-review 内部 review，官方未公开计费；不入表 → cost=0，token 仍记录
    ]

    /// Fast / Priority 的离线兜底表。当前在线目录可提供部分 Fast 价格；
    /// 历史/特殊规则优先本地，其余型号在线优先、命中不到再回落这里。
    private static let codexFastPrices: [String: ModelPrice] = [
        "gpt-6.1-sol":   .init(input: 4,    output: 20,  cacheRead: 0.2,  cacheCreation: 5),
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
        "gpt-6.1-sol": 2.5,
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

    /// Standard API 的上下文阶梯价（USD / 百万 token）。完整输入严格超过该模型阈值时，
    /// 该次请求的输入、缓存读写和输出全部使用长上下文费率。
    /// OpenAI（GPT-6 / GPT-5.6 / GPT-5.5 / GPT-5.4）阈值为 272K。
    /// GPT-6 与 GPT-5.6 的 Fast 有官方长上下文价，见 `codexFastLongContextPrices`；
    /// GPT-5.5 / GPT-5.4 的 Fast 仍排除长上下文，超阈值时返回 nil。
    /// Gemini 3.1 Pro 的阈值为 200K。Claude Haiku 5.5 为 100K。Grok 4.7 为 256K。
    /// `gpt-5.6` 是 Sol 的别名；Pro 是 reasoning.mode，不是独立 model slug。
    /// GPT-5.6 Sol 这里是 2026-08-21 促销前的原价，促销价见 `timedContextPriceTiers`。
    private static let contextPriceTiers: [String: ContextPriceTiers] = [
        "gpt-6.1-sol": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 2, output: 10, cacheRead: 0.10, cacheCreation: 2.5),
            longContext: .init(input: 4, output: 15, cacheRead: 0.20, cacheCreation: 5)
        ),
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
        ),
        "gpt-5.4": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 2.50, output: 15, cacheRead: 0.25, cacheCreation: 0),
            longContext: .init(input: 5, output: 22.50, cacheRead: 0.50, cacheCreation: 0)
        ),
        "gpt-5.4-codex": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 2.50, output: 15, cacheRead: 0.25, cacheCreation: 0),
            longContext: .init(input: 5, output: 22.50, cacheRead: 0.50, cacheCreation: 0)
        ),
        // 远端目录只收 anthropic / openai / deepseek，Gemini 的阶梯只能在这里表达。
        "gemini-3.1-pro": .init(
            longContextThreshold: 200_000,
            shortContext: .init(input: 2, output: 12, cacheRead: 0.20, cacheCreation: 0),
            longContext: .init(input: 4, output: 18, cacheRead: 0.40, cacheCreation: 0)
        ),
        // 官方：不超过 100K 用短价，超过 100K 整次请求用长价。1h 缓存写入仍按当时输入价的 2 倍。
        "claude-haiku-5-5": .init(
            longContextThreshold: 100_000,
            shortContext: .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheCreation: 0.125),
            longContext: .init(input: 0.50, output: 2.50, cacheRead: 0.05, cacheCreation: 0.625)
        ),
        "claude-haiku-5.5": .init(
            longContextThreshold: 100_000,
            shortContext: .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheCreation: 0.125),
            longContext: .init(input: 0.50, output: 2.50, cacheRead: 0.05, cacheCreation: 0.625)
        ),
        "grok-4-7": .init(
            longContextThreshold: 256_000,
            shortContext: .init(input: 2, output: 6, cacheRead: 0.50, cacheCreation: 0),
            longContext: .init(input: 4, output: 12, cacheRead: 1, cacheCreation: 0)
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

    /// Codex Fast 在完整输入超过 272K 时的官方价。只收录明确给出 Fast 长上下文的模型；
    /// GPT-5.5 / GPT-5.4 不在这里，超阈值继续返回 nil。费率是对应 Standard 长上下文的 2 倍。
    /// GPT-5.6 Sol 这一行是 2026-08-21 促销前的价，促销价见 `timedCodexFastLongPrices`。
    private static let codexFastLongContextPrices: [String: ModelPrice] = [
        "gpt-6.1-sol":   .init(input: 8,    output: 30,   cacheRead: 0.40, cacheCreation: 10),
        "gpt-6-astra":   .init(input: 40,   output: 150,  cacheRead: 4,    cacheCreation: 50),
        "gpt-6-sol":     .init(input: 8,    output: 30,   cacheRead: 0.8,  cacheCreation: 10),
        "gpt-6-luna":    .init(input: 0.40, output: 1.50, cacheRead: 0.04, cacheCreation: 0.50),
        "gpt-5.6":       .init(input: 20,   output: 90,   cacheRead: 2,    cacheCreation: 25),
        "gpt-5.6-sol":   .init(input: 20,   output: 90,   cacheRead: 2,    cacheCreation: 25),
        "gpt-5.6-terra": .init(input: 8,    output: 36,   cacheRead: 0.8,  cacheCreation: 10),
        "gpt-5.6-luna":  .init(input: 0.8,  output: 3.6,  cacheRead: 0.08, cacheCreation: 1)
    ]

    /// GPT-5.6 Sol 促销期的 Fast 长上下文价：短上下文 Fast 已在 `timedCodexFastPrices`，
    /// 这里只覆盖 >272K。官方写明输入 $16、输出 $60，缓存读写按 2 倍促销长上下文价。
    private static let timedCodexFastLongPrices: [String: [PricedPeriod]] = [
        "gpt-5.6": [.init(from: gpt56SolPromoStart, price: .init(input: 16, output: 60, cacheRead: 1.6, cacheCreation: 20))],
        "gpt-5.6-sol": [.init(from: gpt56SolPromoStart, price: .init(input: 16, output: 60, cacheRead: 1.6, cacheCreation: 20))]
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
    /// 键为归一化后的模型名，每条按 `from` 升序排列；只要用量记录的时间 ≥ `from` 就换成对应新价，
    /// 取满足条件里最晚的一档（早于所有 `from` 时退回 `table` 的基准价）。
    ///
    /// DeepSeek（2026-09 起）：官方按「高峰 / 空闲」两档峰谷计价，空闲时段是高峰价的五折。
    /// 第一版不实现峰谷时段与中国法定假日日历，**两段都取高峰价**，因此金额是估算上界：
    /// 偏高但不低报。分段按用量记录时间判定，历史天数仍落在旧价，重算也不会改写历史。
    private static let timedOverrides: [String: [PricedPeriod]] = [
        "deepseek-flash": deepseekFlashPeriods,
        "deepseek-v4-flash": deepseekFlashPeriods,
        "deepseek-v4-flash-vision-exp": deepseekFlashPeriods,
        "deepseek-v4.1-flash": deepseekFlashPeriods,
        "deepseek-v4-pro": deepseekProPeriods,
        "gemini-3.6-flash": geminiFlashPeriods,
        "gemini-3.7-flash": geminiFlashPeriods,
        "gemini-3.8-flash": geminiFlashPeriods,
        "claude-sonnet-5-5": sonnet55Periods,
        "claude-sonnet-5.5": sonnet55Periods,
    ]

    /// Gemini 3.6 / 3.7 / 3.8 Flash：表内 $0.75 / $3.75 是截至 2026-12-31 的促销价，
    /// 2027-01-01 起恢复原价 $1.5 / $7.5；缓存读取按同比例由 $0.075 回到 $0.15。
    private static let geminiFlashPeriods: [PricedPeriod] = [
        PricedPeriod(
            from: utcDay(year: 2027, month: 1, day: 1),
            price: ModelPrice(input: 1.50, output: 7.50, cacheRead: 0.15, cacheCreation: 0)
        ),
    ]

    /// Sonnet 5.5：2026-10-07（UTC 0 点）起缓存读取从 $0.20 降到 $0.10，其余费率不变。
    /// 公告没有更细的时刻，按日界处理；10 月 7 日之前的用量保持上市价。
    private static let sonnet55Periods: [PricedPeriod] = [
        PricedPeriod(
            from: utcDay(year: 2026, month: 10, day: 7),
            price: ModelPrice(input: 2, output: 10, cacheRead: 0.10, cacheCreation: 2.50)
        ),
    ]

    /// DeepSeek Flash（含官方兼容名与本机日志标识 `deepseek-v4.1-flash`）：
    /// 2026-08-16 16:00 UTC 起改为峰谷价，2026-09-10 04:00 UTC 起降价。
    /// `input` 是未命中缓存的输入价，`cacheRead` 是命中缓存的输入价，`cacheCreation` 官方未收（恒 0）。
    private static let deepseekFlashPeriods: [PricedPeriod] = [
        PricedPeriod(
            from: utcInstant(2026, 8, 16, 16),
            price: ModelPrice(input: 0.44, output: 1.32, cacheRead: 0.014, cacheCreation: 0)
        ),
        PricedPeriod(
            from: utcInstant(2026, 9, 10, 4),
            price: ModelPrice(input: 0.30, output: 1.20, cacheRead: 0.006, cacheCreation: 0)
        ),
    ]

    /// DeepSeek V4-Pro：官方 2026-08-16 起即为该价，此后未再调整；表内旧值（折算自更早的 CNY 价）已过期。
    private static let deepseekProPeriods: [PricedPeriod] = [
        PricedPeriod(
            from: utcInstant(2026, 8, 16, 16),
            price: ModelPrice(input: 1.32, output: 3.96, cacheRead: 0.044, cacheCreation: 0)
        ),
    ]

    /// 官方调价公告给的是 UTC 时刻，必须按 UTC 构造，不能用本地时区。
    private static func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date.distantPast
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
        precondition(
            timedContextPriceTiers.keys.allSatisfy { contextPriceTiers[$0] != nil },
            "timedContextPriceTiers 中的模型必须在 contextPriceTiers 中提供基础阶梯价"
        )
        precondition(
            timedCodexFastPrices.keys.allSatisfy { codexFastPrices[$0] != nil },
            "timedCodexFastPrices 中的模型必须在 codexFastPrices 中提供基础价"
        )
        precondition(
            timedCodexFastLongPrices.keys.allSatisfy { codexFastLongContextPrices[$0] != nil },
            "timedCodexFastLongPrices 中的模型必须在 codexFastLongContextPrices 中提供基础价"
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

    /// Codex Fast 的长上下文价。没有收录的模型返回 nil，不用短上下文 Fast 价或 Standard 长上下文价顶上。
    private static func codexFastLongPrice(for key: String, at date: Date) -> ModelPrice? {
        guard var chosen = codexFastLongContextPrices[key] else { return nil }
        for period in timedCodexFastLongPrices[key] ?? [] where period.from <= date {
            chosen = period.price
        }
        return chosen
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
            // 固定覆盖不能绕过长上下文：GPT-5.5 在这张表里，但它的 Fast 没有长上下文价。
            if app == .codex, inputTotal > 272_000 {
                return codexFastLongPrice(for: key, at: date)
            }
            if fixedFastLocalOverrideKeys.contains(key) {
                switch app {
                case .codex: return codexFastPrices[key]
                case .claude: return claudeFastPrices[key]
                case .cursor: return nil
                case .pi: return nil
                case .opencode: return nil
                case .dsh: return nil
                }
            }
            switch app {
            case .codex:
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
            case .dsh:
                // DSH 没有 Fast 档位概念。
                return nil
            }
        }
    }

    /// 归一化模型名：循环去支持的 provider 前缀（含嵌套两层，如 `commandcode/deepseek/...`）；
    /// 剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；兼容 Vertex AI 的 `@日期` 写法。
    /// 该结果同时是 Codex 旧存储身份与 Claude 存储身份（标识迁移按它对账旧快照），前缀表不能随定价需要扩充；
    /// 只为查价而剥的前缀放在 `pricingKey(model:)`。
    nonisolated static func normalize(model: String) -> String {
        normalize(model: model, stripping: identityPrefixes)
    }

    /// 查价用的模型键：在 `normalize(model:)` 基础上再剥转售标签，不作为任何存储身份。
    nonisolated static func pricingKey(model: String) -> String {
        normalize(model: model, stripping: pricingPrefixes)
    }

    private static let identityPrefixes = [
        "openai-codex/", "openai/", "anthropic/", "deepseek/",
        "opencode-go/", "commandcode/", "command-code/"
    ]

    /// Antigravity 与 Command Code / OpenCode 的转售标签：`antigravity/gemini-3.8-flash`、
    /// `commandcode/z-ai/glm-5.3-flash`、`commandcode/minimax/minimax-m3`。
    private static let pricingOnlyPrefixes = ["antigravity/", "z-ai/", "zai/", "minimax/"]

    private static let pricingPrefixes = identityPrefixes + pricingOnlyPrefixes

    private static func normalize(model: String, stripping providerPrefixes: [String]) -> String {
        var m = model
        // 循环剥除：Pi / OpenCode 日志里 provider 网关标签可能是 `commandcode/deepseek/...` 双层，
        // 剥掉外层后还要继续剥内层才能与本地表 / 远端目录对齐。
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
        let key = pricingKey(model: model)
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
        let key = pricingKey(model: model)
        return price(for: key, app: app, speed: speed, at: Date(), inputTotal: inputTotal) != nil
    }

    /// 是否应因缺价主动刷新远端目录。明确不计价的内部模型不会触发网络请求。
    static func needsRemotePriceRefresh(model: String, app: UsageApp, speed: UsageSpeed) -> Bool {
        let key = pricingKey(model: model)
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
            let key = pricingKey(model: model)
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
            case .dsh:
                // DSH 无 Fast 档位概念。
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

    /// 价格表内容指纹（SHA-256，确定性），只写进快照作诊断记录，加载时不做比对。
    /// 是否要按新价格重建历史由 `localPricingFingerprint()` 与 `remotePricingSignature(for:)`
    /// 逐项判断（见 `UsageRebuildBasis`）。
    ///
    /// - Parameter knownUsage: 当前用量中实际出现过的 app/model/speed 集合。远端合并价只对
    ///   这个集合算入哈希，避免远端目录里本地未使用模型的变化造成无关的指纹漂移。
    static func fingerprint(knownUsage: Set<PricingUsageKey>) -> String {
        let fastMultiplierBody = [
            fingerprintBody(codexFastMultipliers, prefix: "codex"),
            fingerprintBody(claudeFastMultipliers, prefix: "claude")
        ].joined(separator: ";")
        let remoteBody = knownUsage.sorted { $0.persistedKey < $1.persistedKey }.compactMap { usage -> String? in
            remoteRate(for: usage).map { rate in
                "\(usage.persistedKey):\(rate.input)/\(rate.output)/\(rate.cacheRead)/\(rate.cacheCreation)"
            }
        }.joined(separator: ";")
        return sha256Hex("\(localPriceBody())|\(fastMultiplierBody)|\(remoteBody)")
    }

    /// 本地价格规则（固定价、分段价、阶梯价、Fast 价、缓存规则）的指纹，不含远端目录与 Fast 倍率。
    /// 本地价格表随 App 更新改变；与历史计价时的值不同就说明历史费用需要按新价格重建。
    static func localPricingFingerprint() -> String {
        cachedLocalPricingFingerprint
    }

    /// 本地价格规则都是编译期常量，进程内只算一次；每轮扫描后的自动重建判断都要用它。
    private static let cachedLocalPricingFingerprint = sha256Hex(localPriceBody())

    /// 某个用量键当前采用的远端价格；本地规则管辖或远端没有收录时为 "-"。
    /// 与历史计价时记下的值不同，说明这个键的历史费用需要按新价格重建。
    static func remotePricingSignature(for usage: PricingUsageKey) -> String {
        guard let rate = remoteRate(for: usage) else { return "-" }
        return "\(rate.input)/\(rate.output)/\(rate.cacheRead)/\(rate.cacheCreation)"
    }

    /// 计价时实际会用到的远端价格。本地规则优先的键返回 nil，与 `price(for:)` 的取价顺序一致。
    private static func remoteRate(for usage: PricingUsageKey) -> ModelPrice? {
        if usage.speed == .standard, localOverrideKeys.contains(usage.model) { return nil }
        if usage.speed == .fast, fixedFastLocalOverrideKeys.contains(usage.model) { return nil }
        if usage.speed == .fast, usage.app == .codex, timedCodexFastPrices[usage.model] != nil { return nil }
        return PricingCatalogStore.shared.rate(for: usage.model, app: usage.app, speed: usage.speed)
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func localPriceBody() -> String {
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
        let fastLongBody = fingerprintBody(codexFastLongContextPrices, prefix: "codex-long")
        let timedFastLongBody = timedCodexFastLongPrices.keys.sorted().map { key -> String in
            let parts = timedCodexFastLongPrices[key]!.sorted { $0.from < $1.from }.map { period -> String in
                let p = period.price
                return "\(period.from.timeIntervalSince1970)=\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
            }.joined(separator: ",")
            return "codex-long:\(key)@\(parts)"
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
        let cacheRuleBody = "claude-cache-creation-1h:\(claudeCacheCreation1hMultiplier)"
        let fixedOverrideBody = fixedLocalOverrideKeys.sorted().joined(separator: ";")
        let fixedFastOverrideBody = fixedFastLocalOverrideKeys.sorted().joined(separator: ";")
        return "\(baseBody)|\(tierBody)|\(timedTierBody)|\(timedFastBody)|\(fastLongBody)|\(timedFastLongBody)|\(overrideBody)|\(fixedOverrideBody)|\(fixedFastOverrideBody)|\(fastPriceBody)|\(cacheRuleBody)"
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
