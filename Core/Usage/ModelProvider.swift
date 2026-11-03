import Foundation

/// 把模型标识拆成渠道链、模型名和附加标记；无法解释的结构原样保留。
/// 原始标识用于存储和来源明细，解析结果供查价与展示共用。渠道不决定价格：
/// 除 Cursor 这类自有定价渠道外，同一型号无论经哪个渠道调用都按官方价计。
nonisolated struct ModelIdentity: Sendable, Equatable {
    enum Channel: Sendable, Equatable { case cursor, other }
    enum Speed: String, Sendable { case fast, slow, unspecified }

    let raw: String
    /// 最后一个 `/` 之前的各段，如 `magpie/trae-cn/x` 为 `["magpie", "trae-cn"]`。
    let route: [String]
    /// 直接提供模型的一段为 `cursor` 时，按 Cursor 的上下文与速度档位单独定价。
    let channel: Channel
    /// 去掉速度、上下文与日期标记后的模型名（小写）；无法解析时为原始标识。
    let name: String
    let context: String?
    let speed: Speed
    let isResolved: Bool

    /// 多段渠道链的入口，如 `magpie/cursor/...` 的 `magpie`。
    var entry: String? { route.count > 1 ? route.first : nil }

    /// 展示用型号：能按官方价确认的型号，否则为解析出的模型名；无法解析时原样保留。
    var model: String { isResolved ? Pricing.displayModel(for: self) : raw }

    /// 渠道自有价格的键。目前只有 Cursor 按模型、上下文和速度单独定价，未写速度时没有自有价。
    var channelPricingKey: String? {
        guard isResolved, channel == .cursor, speed != .unspecified else { return nil }
        return "cursor-sdk:\(name):\(context ?? "-"):\(speed.rawValue)"
    }

    /// 查价身份：可再次解析出相同候选的最短写法，用作价格目录与缓存指纹的键。
    var pricingIdentity: String {
        guard isResolved, channel == .cursor else { return name }
        let contextPart = context.map { "@\($0)" } ?? ""
        let speedPart = speed == .unspecified ? "" : ":\(speed.rawValue)"
        return "cursor/\(name)\(contextPart)\(speedPart)"
    }

    /// 按官方价查价时依次尝试的型号，见 `candidates(for:)`。
    var modelCandidates: [String] { isResolved ? Self.candidates(for: name) : [name] }

    /// 原名优先，再逐个去掉末尾的渠道标记，最后是同型号别名。原名优先保证 `-max` 这类
    /// 本身就是独立定价型号的名字不会被改写；`-fast` 不算渠道标记，Fast 档价格不同。
    static func candidates(for name: String) -> [String] {
        var candidates = [name]
        var current = name
        while let stripped = strippingVariantTag(current) {
            current = stripped
            candidates.append(current)
        }
        for candidate in candidates {
            if let alias = aliases[candidate], !candidates.contains(alias) { candidates.append(alias) }
        }
        return candidates
    }

    /// 渠道附加在型号名末尾、不改变官方价的标记：免费渠道和推理档位。
    static let variantTags = ["-free", "-low", "-medium", "-high", "-xhigh", "-max"]
    /// 渠道自己的 4 位版本号，如 `trae-cn/deepseek-v4.1-flash-1017`。
    private static let buildTagPattern = #"-\d{4}$"#

    private static func strippingVariantTag(_ name: String) -> String? {
        if let tag = variantTags.first(where: { name.hasSuffix($0) && name.count > $0.count }) {
            return String(name.dropLast(tag.count))
        }
        if let range = name.range(of: buildTagPattern, options: .regularExpression), range.lowerBound > name.startIndex {
            return String(name[..<range.lowerBound])
        }
        return nil
    }

    /// 同一型号的不同写法；值是价格表与展示统一使用的名称。
    static let aliases: [String: String] = [
        "grok-4-7": "grok-4.7",
        "deepseek-v41-flash": "deepseek-v4.1-flash",
        "cursor-composer-2-5": "composer-2.5"
    ]

    /// 解析规则的指纹。规则变化会让原本缺价的用量命中新价格，需要触发历史重算；
    /// 调整 `parse` 的结构解析时同步提高版本号。
    static let ruleSignature: String = {
        let aliasBody = aliases.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "model-identity-v2|\(variantTags.joined(separator: ","))|\(buildTagPattern)|\(aliasBody)"
    }()

    static func parse(_ raw: String) -> ModelIdentity {
        let unresolved = ModelIdentity(
            raw: raw, route: [], channel: .other, name: raw.lowercased(),
            context: nil, speed: .unspecified, isResolved: false
        )
        var route = raw.lowercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var name = route.removeLast()
        var speed = Speed.unspecified
        if let colon = name.lastIndex(of: ":") {
            guard let parsed = Speed(rawValue: String(name[name.index(after: colon)...])),
                  parsed != .unspecified else { return unresolved }
            speed = parsed
            name = String(name[..<colon])
        }
        var context: String?
        if let at = name.lastIndex(of: "@") {
            let tag = String(name[name.index(after: at)...])
            if isContextTag(tag) {
                context = tag
            } else if !isDateTag(tag) {
                return unresolved
            }
            name = String(name[..<at])
        }
        name = Pricing.strippingDateSuffix(name)
        guard !name.isEmpty, name.utf8.allSatisfy({
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }) else { return unresolved }
        return ModelIdentity(
            raw: raw, route: route, channel: route.last == "cursor" ? .cursor : .other,
            name: name, context: context, speed: speed, isResolved: true
        )
    }

    /// `256k`、`1m` 这类正整数上下文标记。
    private static func isContextTag(_ tag: String) -> Bool {
        guard let unit = tag.last, unit == "k" || unit == "m" else { return false }
        let digits = tag.dropLast()
        return !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) } && digits.contains { $0 != "0" }
    }

    /// Vertex 风格的 `@YYYYMMDD` 日期标记。
    private static func isDateTag(_ tag: String) -> Bool {
        tag.utf8.count == 8 && tag.utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// 模型提供商（厂商归并 + opencode-go / command code 单列）分组键。
///
/// 从 `UsageBucket.model` 字符串推导：前缀优先（`openai/`、`openai-codex/`、
/// `anthropic/`、`deepseek/`、`opencode-go/`、`commandcode/`、`command-code/`），
/// 无前缀时按 app / 模型名关键词兜底。
/// 纯展示层用途，不参与定价与存储；价格仍由 `Pricing` 按模型名单独解析。
nonisolated enum ModelProvider: String, Sendable, CaseIterable {
    case openAI
    case anthropic
    case deepseek
    case opencodeGo
    case commandCode
    case other

    /// 推导提供商。
    ///
    /// 顺序：前缀匹配 → 模型名关键词匹配 → 按 app 兜底 → 其他。
    /// - 前缀（Pi / OpenCode 日志保留 `provider/model` 形态）
    /// - 关键词（裸模型，以及未能验证渠道的旧 Codex / Claude 历史）
    /// - app 兜底：codex → OpenAI、claude → Anthropic（两者日志模型几乎固定厂商）
    static func resolve(app: UsageApp, model: String) -> ModelProvider {
        let m = model.lowercased()

        let prefixes: [(String, ModelProvider)] = [
            ("openai-codex/", .openAI),
            ("openai/", .openAI),
            ("anthropic/", .anthropic),
            ("deepseek/", .deepseek),
            ("opencode-go/", .opencodeGo),
            ("commandcode/", .commandCode),
            ("command-code/", .commandCode)
        ]
        for (prefix, provider) in prefixes where m.hasPrefix(prefix) {
            return provider
        }

        if m.hasPrefix("claude-") { return .anthropic }
        if m.hasPrefix("gpt-") || m.hasPrefix("o1") || m.hasPrefix("o3")
            || m.hasPrefix("o4") || m.hasPrefix("chatgpt-") || m.hasPrefix("codex-") {
            return .openAI
        }
        if m.hasPrefix("deepseek-") { return .deepseek }

        switch app {
        case .codex: return .openAI
        case .claude: return .anthropic
        case .cursor: return .other
        case .pi, .opencode: return .other
        case .dsh, .antigravity: return .other
        }
    }

    /// 双语显示名。品牌名中英一致，「其他」单独翻译。
    @MainActor
    var displayName: String {
        switch self {
        case .openAI: return tr("OpenAI", "OpenAI")
        case .anthropic: return tr("Anthropic", "Anthropic")
        case .deepseek: return tr("DeepSeek", "DeepSeek")
        case .opencodeGo: return tr("OpenCode-Go", "OpenCode-Go")
        case .commandCode: return tr("Command Code", "Command Code")
        case .other: return tr("Other", "其他")
        }
    }
}
