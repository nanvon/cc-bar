import Foundation

enum CredentialSource: String, Sendable {
    case file
    case keychain
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
}

struct ClaudeAccount: Sendable, Equatable {
    var source: CredentialSource
    var email: String?
    var subscriptionType: String?
    var expiresAt: Date?
    var expiredGuess: Bool
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
}

/// Grok Build / xAI CLI 登录态，对应 `~/.grok/auth.json`。
struct GrokAccount: Sendable, Equatable {
    /// auth.json 顶层 map 的 key，写回时用（如 `https://auth.x.ai::<client_id>`）
    var storageKey: String
    var email: String?
    var userId: String?
    var teamId: String?
    var planType: String?
    var expiresAt: Date?
    var expiredGuess: Bool
    var oidcIssuer: String
    var oidcClientId: String
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
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
