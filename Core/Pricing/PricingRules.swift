import Foundation

/// 模型价格（USD / 百万 token）。命中不到的模型未定价（`Pricing.cost` 返回 nil），token 仍记录。
nonisolated struct ModelPrice: Sendable, Codable, Equatable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal
}

/// 同一模型按单次请求完整输入量切换的上下文阶梯价。
/// `shortContext` / `longContext` 均为完整费率，避免值类型递归引用。
nonisolated struct ContextPriceTiers: Sendable, Equatable {
    let longContextThreshold: Int
    let shortContext: ModelPrice
    let longContext: ModelPrice

    func rates(for inputTotal: Int) -> ModelPrice {
        inputTotal > longContextThreshold ? longContext : shortContext
    }
}

/// 限时覆盖价：某模型从 `from` 起改用 `price`，用于「同一模型中途涨价 / 降价」的场景。
nonisolated struct PricedPeriod: Sendable, Equatable {
    let from: Date
    let price: ModelPrice
}

/// 阶梯价模型的限时覆盖：从 `from` 起整套短 / 长上下文价改为 `tiers`。
nonisolated struct TieredPricedPeriod: Sendable, Equatable {
    let from: Date
    let tiers: ContextPriceTiers
}

/// 本地价格规则：基础价、阶梯价、分段价、Fast 价、固定覆盖与倍率。
///
/// 数据来自 `pricing-rules.json`（App 内置一份，远端签名文件可热更新，见 `PricingRulesStore`）；
/// 取价算法留在 `Pricing`。格式见 `docs/技术实现.md` §7.6。
nonisolated struct PricingRules: Sendable, Equatable {
    /// App 能解析的最高格式版本。远端文件更高时整份拒绝，不做部分解析。
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    /// 单调递增的规则版本。App 只采纳比当前生效版本更大的文件。
    let revision: Int
    let table: [String: ModelPrice]
    let contextPriceTiers: [String: ContextPriceTiers]
    let timedContextPriceTiers: [String: [TieredPricedPeriod]]
    let timedOverrides: [String: [PricedPeriod]]
    let fixedLocalOverrideKeys: Set<String>
    let codexFastPrices: [String: ModelPrice]
    let claudeFastPrices: [String: ModelPrice]
    let fixedFastLocalOverrideKeys: Set<String>
    let timedCodexFastPrices: [String: [PricedPeriod]]
    let codexFastLongContextPrices: [String: ModelPrice]
    let timedCodexFastLongPrices: [String: [PricedPeriod]]
    let codexFastMultipliers: [String: Decimal]
    let claudeFastMultipliers: [String: Decimal]
    let claudeCacheCreation1hMultiplier: Decimal

    /// A 类模型：受本地特殊规则（阶梯价 / 分段生效价 / 固定价）管辖的 key，远端价格目录对它们零参与。
    let localOverrideKeys: Set<String>
    /// 规则内容的规范化文本，供 `Pricing` 计算本地价格指纹；不含 `revision` 和说明文字。
    let localPriceBody: String

    /// 内置文件读不出来时使用的空规则：所有本地价都缺失，token 照常记录，App 不崩溃。
    static let empty = PricingRules(
        schemaVersion: supportedSchemaVersion,
        revision: 0,
        table: [:],
        contextPriceTiers: [:],
        timedContextPriceTiers: [:],
        timedOverrides: [:],
        fixedLocalOverrideKeys: [],
        codexFastPrices: [:],
        claudeFastPrices: [:],
        fixedFastLocalOverrideKeys: [],
        timedCodexFastPrices: [:],
        codexFastLongContextPrices: [:],
        timedCodexFastLongPrices: [:],
        codexFastMultipliers: [:],
        claudeFastMultipliers: [:],
        claudeCacheCreation1hMultiplier: 2
    )

    init(
        schemaVersion: Int,
        revision: Int,
        table: [String: ModelPrice],
        contextPriceTiers: [String: ContextPriceTiers],
        timedContextPriceTiers: [String: [TieredPricedPeriod]],
        timedOverrides: [String: [PricedPeriod]],
        fixedLocalOverrideKeys: Set<String>,
        codexFastPrices: [String: ModelPrice],
        claudeFastPrices: [String: ModelPrice],
        fixedFastLocalOverrideKeys: Set<String>,
        timedCodexFastPrices: [String: [PricedPeriod]],
        codexFastLongContextPrices: [String: ModelPrice],
        timedCodexFastLongPrices: [String: [PricedPeriod]],
        codexFastMultipliers: [String: Decimal],
        claudeFastMultipliers: [String: Decimal],
        claudeCacheCreation1hMultiplier: Decimal
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.table = table
        self.contextPriceTiers = contextPriceTiers
        self.timedContextPriceTiers = timedContextPriceTiers
        self.timedOverrides = timedOverrides
        self.fixedLocalOverrideKeys = fixedLocalOverrideKeys
        self.codexFastPrices = codexFastPrices
        self.claudeFastPrices = claudeFastPrices
        self.fixedFastLocalOverrideKeys = fixedFastLocalOverrideKeys
        self.timedCodexFastPrices = timedCodexFastPrices
        self.codexFastLongContextPrices = codexFastLongContextPrices
        self.timedCodexFastLongPrices = timedCodexFastLongPrices
        self.codexFastMultipliers = codexFastMultipliers
        self.claudeFastMultipliers = claudeFastMultipliers
        self.claudeCacheCreation1hMultiplier = claudeCacheCreation1hMultiplier
        self.localOverrideKeys = Set(contextPriceTiers.keys)
            .union(timedOverrides.keys)
            .union(fixedLocalOverrideKeys)
        self.localPriceBody = Self.makeLocalPriceBody(
            table: table,
            contextPriceTiers: contextPriceTiers,
            timedContextPriceTiers: timedContextPriceTiers,
            timedOverrides: timedOverrides,
            fixedLocalOverrideKeys: fixedLocalOverrideKeys,
            codexFastPrices: codexFastPrices,
            claudeFastPrices: claudeFastPrices,
            fixedFastLocalOverrideKeys: fixedFastLocalOverrideKeys,
            timedCodexFastPrices: timedCodexFastPrices,
            codexFastLongContextPrices: codexFastLongContextPrices,
            timedCodexFastLongPrices: timedCodexFastLongPrices,
            claudeCacheCreation1hMultiplier: claudeCacheCreation1hMultiplier
        )
    }

    // MARK: - 解码与校验

    /// 解析并校验一份规则文件。任何一项不合格都整份拒绝，调用方继续使用当前生效的规则。
    static func decode(_ data: Data) throws -> PricingRules {
        // 先只读格式版本：更高版本可能改了结构，不能按当前结构解析。
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw PricingRulesError.malformed("\(error)")
        }
        guard header.schemaVersion <= supportedSchemaVersion else {
            throw PricingRulesError.unsupportedSchema(header.schemaVersion)
        }
        guard header.schemaVersion >= 1 else {
            throw PricingRulesError.invalid("schemaVersion \(header.schemaVersion)")
        }

        let document: Document
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw PricingRulesError.malformed("\(error)")
        }
        let rules = document.makeRules()
        try rules.validate()
        return rules
    }

    /// 原来由启动时 `precondition` 保证的约束；远端文件不合格时整份拒绝，不让 App 崩溃。
    func validate() throws {
        guard revision >= 1 else { throw PricingRulesError.invalid("revision \(revision)") }
        guard !table.isEmpty else { throw PricingRulesError.invalid("standard.prices is empty") }

        func requireBase(_ keys: some Collection<String>, _ hasBase: (String) -> Bool, _ name: String) throws {
            if let missing = keys.sorted().first(where: { !hasBase($0) }) {
                throw PricingRulesError.invalid("\(name) 的 \(missing) 缺少基础价")
            }
        }
        try requireBase(timedOverrides.keys, { table[$0] != nil }, "standard.timedPrices")
        try requireBase(timedContextPriceTiers.keys, { contextPriceTiers[$0] != nil }, "standard.timedContextTiers")
        try requireBase(timedCodexFastPrices.keys, { codexFastPrices[$0] != nil }, "fast.codexTimedPrices")
        try requireBase(
            timedCodexFastLongPrices.keys, { codexFastLongContextPrices[$0] != nil }, "fast.codexLongContextTimedPrices"
        )
        if let missing = fixedLocalOverrideKeys.sorted().first(where: { table[$0] == nil }) {
            throw PricingRulesError.invalid("standard.fixedKeys 的 \(missing) 缺少固定价")
        }
        if let missing = fixedFastLocalOverrideKeys.sorted().first(where: {
            codexFastPrices[$0] == nil && claudeFastPrices[$0] == nil
        }) {
            throw PricingRulesError.invalid("fast.fixedKeys 的 \(missing) 缺少 Fast 价")
        }

        // 取价时按顺序取最后一个已生效的分段，顺序错了会选错价。
        func requireAscending(_ periods: [String: [Date]], _ name: String) throws {
            for key in periods.keys.sorted() {
                let dates = periods[key] ?? []
                guard !dates.isEmpty, zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
                    throw PricingRulesError.invalid("\(name) 的 \(key) 分段为空或未按时间升序")
                }
            }
        }
        try requireAscending(timedOverrides.mapValues { $0.map(\.from) }, "standard.timedPrices")
        try requireAscending(timedContextPriceTiers.mapValues { $0.map(\.from) }, "standard.timedContextTiers")
        try requireAscending(timedCodexFastPrices.mapValues { $0.map(\.from) }, "fast.codexTimedPrices")
        try requireAscending(timedCodexFastLongPrices.mapValues { $0.map(\.from) }, "fast.codexLongContextTimedPrices")

        let thresholds = contextPriceTiers.values.map(\.longContextThreshold)
            + timedContextPriceTiers.values.flatMap { $0.map(\.tiers.longContextThreshold) }
        guard thresholds.allSatisfy({ $0 > 0 }) else {
            throw PricingRulesError.invalid("contextTiers 的 threshold 必须大于 0")
        }
        let multipliers = Array(codexFastMultipliers.values) + Array(claudeFastMultipliers.values)
            + [claudeCacheCreation1hMultiplier]
        guard multipliers.allSatisfy({ $0 > 0 }) else {
            throw PricingRulesError.invalid("倍率必须大于 0")
        }
    }

    // MARK: - 指纹

    /// 与改造前 `Pricing.localPriceBody()` 的格式保持一致（末尾的模型解析规则由 `Pricing` 追加）。
    private static func makeLocalPriceBody(
        table: [String: ModelPrice],
        contextPriceTiers: [String: ContextPriceTiers],
        timedContextPriceTiers: [String: [TieredPricedPeriod]],
        timedOverrides: [String: [PricedPeriod]],
        fixedLocalOverrideKeys: Set<String>,
        codexFastPrices: [String: ModelPrice],
        claudeFastPrices: [String: ModelPrice],
        fixedFastLocalOverrideKeys: Set<String>,
        timedCodexFastPrices: [String: [PricedPeriod]],
        codexFastLongContextPrices: [String: ModelPrice],
        timedCodexFastLongPrices: [String: [PricedPeriod]],
        claudeCacheCreation1hMultiplier: Decimal
    ) -> String {
        func rate(_ p: ModelPrice) -> String {
            "\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
        }
        func tiers(_ t: ContextPriceTiers) -> String {
            "\(t.longContextThreshold):\(rate(t.shortContext)):\(rate(t.longContext))"
        }
        func periods(_ values: [String: [PricedPeriod]], prefix: String) -> String {
            values.keys.sorted().map { key -> String in
                let parts = values[key]!.sorted { $0.from < $1.from }.map {
                    "\($0.from.timeIntervalSince1970)=\(rate($0.price))"
                }.joined(separator: ",")
                return "\(prefix)\(key)@\(parts)"
            }.joined(separator: ";")
        }

        let baseBody = table.keys.sorted().map { "\($0):\(rate(table[$0]!))" }.joined(separator: ";")
        let tierBody = contextPriceTiers.keys.sorted().map { "\($0):\(tiers(contextPriceTiers[$0]!))" }
            .joined(separator: ";")
        let timedTierBody = timedContextPriceTiers.keys.sorted().map { key -> String in
            let parts = timedContextPriceTiers[key]!.sorted { $0.from < $1.from }.map {
                "\($0.from.timeIntervalSince1970)=\(tiers($0.tiers))"
            }.joined(separator: ",")
            return "\(key)@\(parts)"
        }.joined(separator: ";")
        let timedFastBody = periods(timedCodexFastPrices, prefix: "codex:")
        let fastLongBody = fingerprintBody(codexFastLongContextPrices, prefix: "codex-long")
        let timedFastLongBody = periods(timedCodexFastLongPrices, prefix: "codex-long:")
        let overrideBody = periods(timedOverrides, prefix: "")
        let fastPriceBody = [
            fingerprintBody(codexFastPrices, prefix: "codex"),
            fingerprintBody(claudeFastPrices, prefix: "claude")
        ].joined(separator: ";")
        let cacheRuleBody = "claude-cache-creation-1h:\(claudeCacheCreation1hMultiplier)"
        let fixedOverrideBody = fixedLocalOverrideKeys.sorted().joined(separator: ";")
        let fixedFastOverrideBody = fixedFastLocalOverrideKeys.sorted().joined(separator: ";")
        return "\(baseBody)|\(tierBody)|\(timedTierBody)|\(timedFastBody)|\(fastLongBody)|\(timedFastLongBody)|\(overrideBody)|\(fixedOverrideBody)|\(fixedFastOverrideBody)|\(fastPriceBody)|\(cacheRuleBody)"
    }

    static func fingerprintBody(_ values: [String: ModelPrice], prefix: String) -> String {
        values.keys.sorted().map { key in
            let p = values[key]!
            return "\(prefix):\(key):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
        }.joined(separator: ";")
    }

    static func fingerprintBody(_ values: [String: Decimal], prefix: String) -> String {
        values.keys.sorted().map { "\(prefix):\($0):\(values[$0]!)" }.joined(separator: ";")
    }
}

nonisolated enum PricingRulesError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupportedSchema(Int)
    case invalid(String)
    case badSignature

    var description: String {
        switch self {
        case .malformed(let detail): "malformed: \(detail)"
        case .unsupportedSchema(let version): "unsupported schemaVersion \(version)"
        case .invalid(let detail): "invalid: \(detail)"
        case .badSignature: "bad signature"
        }
    }
}

// MARK: - 文件格式

private extension PricingRules {
    nonisolated struct Header: Decodable {
        let schemaVersion: Int
    }

    /// 价格一律存成字符串，用 `Decimal(string:)` 解析，避免 JSON number 经 Double 带来的尾差。
    nonisolated struct DecimalString: Decodable {
        let value: Decimal

        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            // `Decimal(string:)` 会接受 "1.2abc" 这类前缀，先整体匹配格式。
            guard text.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "价格必须是非负十进制字符串：\(text)"
                ))
            }
            self.value = value
        }
    }

    nonisolated struct PriceRecord: Decodable {
        let input: DecimalString
        let output: DecimalString
        let cacheRead: DecimalString
        let cacheCreation: DecimalString

        var price: ModelPrice {
            ModelPrice(
                input: input.value,
                output: output.value,
                cacheRead: cacheRead.value,
                cacheCreation: cacheCreation.value
            )
        }
    }

    nonisolated struct TiersRecord: Decodable {
        let threshold: Int
        let short: PriceRecord
        let long: PriceRecord

        var tiers: ContextPriceTiers {
            ContextPriceTiers(longContextThreshold: threshold, shortContext: short.price, longContext: long.price)
        }
    }

    nonisolated struct PricedPeriodRecord: Decodable {
        let from: Date
        let input: DecimalString
        let output: DecimalString
        let cacheRead: DecimalString
        let cacheCreation: DecimalString

        var period: PricedPeriod {
            PricedPeriod(from: from, price: ModelPrice(
                input: input.value,
                output: output.value,
                cacheRead: cacheRead.value,
                cacheCreation: cacheCreation.value
            ))
        }
    }

    nonisolated struct TieredPeriodRecord: Decodable {
        let from: Date
        let threshold: Int
        let short: PriceRecord
        let long: PriceRecord

        var period: TieredPricedPeriod {
            TieredPricedPeriod(from: from, tiers: ContextPriceTiers(
                longContextThreshold: threshold,
                shortContext: short.price,
                longContext: long.price
            ))
        }
    }

    nonisolated struct StandardSection: Decodable {
        let prices: [String: PriceRecord]
        let contextTiers: [String: TiersRecord]
        let timedContextTiers: [String: [TieredPeriodRecord]]
        let timedPrices: [String: [PricedPeriodRecord]]
        let fixedKeys: [String]
    }

    nonisolated struct FastSection: Decodable {
        let codexPrices: [String: PriceRecord]
        let claudePrices: [String: PriceRecord]
        let fixedKeys: [String]
        let codexTimedPrices: [String: [PricedPeriodRecord]]
        let codexLongContextPrices: [String: PriceRecord]
        let codexLongContextTimedPrices: [String: [PricedPeriodRecord]]
        let codexMultipliers: [String: DecimalString]
        let claudeMultipliers: [String: DecimalString]
    }

    /// `note` / `notes` 只是给维护者看的说明，解码时忽略，不参与计价和指纹。
    nonisolated struct Document: Decodable {
        let schemaVersion: Int
        let revision: Int
        let claudeCacheCreation1hMultiplier: DecimalString
        let standard: StandardSection
        let fast: FastSection

        func makeRules() -> PricingRules {
            PricingRules(
                schemaVersion: schemaVersion,
                revision: revision,
                table: standard.prices.mapValues(\.price),
                contextPriceTiers: standard.contextTiers.mapValues(\.tiers),
                timedContextPriceTiers: standard.timedContextTiers.mapValues { $0.map(\.period) },
                timedOverrides: standard.timedPrices.mapValues { $0.map(\.period) },
                fixedLocalOverrideKeys: Set(standard.fixedKeys),
                codexFastPrices: fast.codexPrices.mapValues(\.price),
                claudeFastPrices: fast.claudePrices.mapValues(\.price),
                fixedFastLocalOverrideKeys: Set(fast.fixedKeys),
                timedCodexFastPrices: fast.codexTimedPrices.mapValues { $0.map(\.period) },
                codexFastLongContextPrices: fast.codexLongContextPrices.mapValues(\.price),
                timedCodexFastLongPrices: fast.codexLongContextTimedPrices.mapValues { $0.map(\.period) },
                codexFastMultipliers: fast.codexMultipliers.mapValues(\.value),
                claudeFastMultipliers: fast.claudeMultipliers.mapValues(\.value),
                claudeCacheCreation1hMultiplier: claudeCacheCreation1hMultiplier.value
            )
        }
    }
}
