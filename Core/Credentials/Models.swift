import Foundation

enum CredentialSource: String, Sendable {
    case file
    case keychain
    /// Claude Desktop 的 Electron token 缓存。只借用其中的 access_token，
    /// 永不读取 / 使用其 refresh_token，详见 `ClaudeDesktopAuth`。
    case desktop
}

struct CodexAccount: Sendable, Equatable {
    var email: String?
    var planType: String?
    var accountId: String?
    var chatgptUserId: String?
    var lastRefresh: Date?
    var expiredGuess: Bool
    var rawClaimKeys: [String]
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// auth.json 走 `personal_access_token`（Codex 工作区访问令牌）时为 true。
    /// 该令牌是不透明字符串、无 exp / refresh，取数时跳过 OAuth 续期，
    /// 身份（email/plan/account_id）由 `wham/usage` 响应回填。
    var isPersonalAccessToken: Bool = false

    /// `chatgpt_plan_type` / `plan_type` 的展示名。取值与官方名对照 Codex CLI 的
    /// `codex-rs/protocol/src/auth.rs` 与 `tui/src/subscription.rs`；同系列各档只显示大类
    /// （`prolite` / `pro` / `promax` 都是 Pro），倍数和价格会变，不细分。
    /// OpenAI 把 Team 改名 Business 后，`team` 对应 Business、`business` 对应 Enterprise。
    /// 认不出的值首字母大写原样显示。
    nonisolated static func planName(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !value.isEmpty else { return nil }
        switch value {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro", "prolite", "promax": return "Pro"
        case "team", "self_serve_business_usage_based", "self_serve_business_prolite": return "Business"
        case "business", "enterprise", "hc", "ent26",
             "enterprise_cbp_usage_based", "enterprise_cbp_automation": return "Enterprise"
        case "edu", "education", "edu_plus", "edu_pro": return "Edu"
        case "sci", "sci_plus": return "Academic"
        default: return value.capitalized
        }
    }
}

struct ClaudeAccount: Sendable, Equatable {
    var source: CredentialSource
    var email: String?
    /// 来自 `~/.claude.json` 的 `oauthAccount`，用于和 Claude Desktop 的凭据缓存
    /// 做账号比对——两边同属一个账号才允许借用 Desktop 的 access_token。
    var accountUuid: String?
    var organizationUuid: String?
    /// 本地凭据里记录的套餐，只在签发 / 刷新 token 时写入，可能落后于实际订阅；
    /// 展示优先用 `/api/oauth/profile` 的结果（`AppState.claudePlanName`）。
    var subscriptionType: String?
    var expiresAt: Date?
    var expiredGuess: Bool
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?

    /// 本地凭据推出的套餐名，profile 查询失败时兜底。
    var localPlanName: String? {
        Self.planName(subscriptionType)
    }

    /// `pro` / `claude_pro` → `Pro`，`max` / `claude_max` → `Max`。原 Max 20x 已改名 Ultra，
    /// 由 `ClaudeQuotaClient.parsePlanName` 按 profile 的 `rate_limit_tier` 识别；
    /// 本地 `subscriptionType` 不分档，兜底时 Ultra 仍显示 `Max`。
    nonisolated static func planName(_ type: String?) -> String? {
        var base = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if base.hasPrefix("claude_") { base.removeFirst("claude_".count) }
        guard !base.isEmpty else { return nil }
        return base.capitalized
    }
}

enum CredentialError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidJSON(String)
    case keychainUnavailable(String)
    case decodeFailed(String)

    var description: String {
        switch self {
        case .fileNotFound(let p): return "file not found: \(p)"
        case .invalidJSON(let p): return "invalid JSON at: \(p)"
        case .keychainUnavailable(let m): return "keychain unavailable: \(m)"
        case .decodeFailed(let m): return "decode failed: \(m)"
        }
    }
}
