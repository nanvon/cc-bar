import Foundation

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
    /// - 关键词（Codex / Claude 入库时已 `Pricing.normalize` 剥前缀，剩裸模型名）
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
        case .dsh: return .other
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
