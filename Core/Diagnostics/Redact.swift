import CryptoKit
import Foundation

/// 日志与诊断包的脱敏工具。见 `docs/草案-诊断日志-设计方案.md` §4。
///
/// 两道防线：
/// 1. 调用点只写结构化安全字段，敏感字段必须先过这里的 `account` / `path` / `url` / `error`。
/// 2. `scrub(_:)` 在 `AppLog` 出口对每条消息统一兜底，防止将来新增调用点漏掉第一道。
///
/// 绝对不允许进日志的东西：access / refresh / id token、API key、明文邮箱、对话内容。
/// token 连长度和前后缀都不写——只写 `hasAccess=true/false` 这类布尔值。
nonisolated enum Redact {
    // MARK: - 账号标识

    /// 把邮箱 / account_id / userID 折成稳定短哈希 `acct#3f9a2c11`。
    ///
    /// 同一账号跨行、跨天一致，可用来判断"是不是同一个账号""有没有切过账号"，
    /// 但不可反推。salt 每台机器随机生成且**不进导出包**，因此不同用户之间也不可比对。
    static func account(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return "acct#" + digest(value)
    }

    /// 项目 / 仓库名折哈希。用户的仓库名可能是公司内部名称，不能进日志。
    static func project(_ value: String) -> String {
        value.isEmpty ? "none" : "proj#" + digest(value)
    }

    // MARK: - 路径与 URL

    static func path(_ url: URL) -> String { path(url.path) }

    /// 家目录换成 `~`；`projects/` 下一级目录名（= 用户仓库名）折哈希；
    /// 文件名只保留后缀。结果仍能看出是哪个数据源、第几层，但看不出具体项目和会话。
    static func path(_ raw: String) -> String {
        var text = raw
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, text.hasPrefix(home) {
            text = "~" + text.dropFirst(home.count)
        }
        var parts = text.components(separatedBy: "/")
        for index in parts.indices where index + 1 < parts.count {
            // Claude 的 `~/.claude/projects/<项目名>`；Codex sessions 按日期分层，不需要打码。
            if parts[index] == "projects", !parts[index + 1].isEmpty {
                parts[index + 1] = project(parts[index + 1])
            }
        }
        if let last = parts.last, last.contains(".") {
            let ext = (last as NSString).pathExtension
            parts[parts.count - 1] = ext.isEmpty ? "file" : "file.\(ext)"
        }
        return parts.joined(separator: "/")
    }

    /// 只保留 scheme + host + path。query 与 fragment 常带 token 和 account id，一律丢弃。
    static func url(_ url: URL?) -> String {
        guard let url else { return "none" }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return scrub(url.absoluteString)
        }
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        return scrub(comps.string ?? url.absoluteString)
    }

    // MARK: - 错误

    /// 系统错误域只取 domain / code / localizedDescription，**不取 `userInfo`**——
    /// 里面常带失败请求的完整 URL 和响应体。Swift 原生错误用 `String(describing:)`，
    /// 拿到的是类型名 + case，信息量更大且不含请求细节。两条路径最后都过 `scrub`。
    static func error(_ error: Error) -> String {
        let ns = error as NSError
        if systemErrorDomains.contains(ns.domain) {
            return scrub(oneLine("\(ns.domain)/\(ns.code): \(ns.localizedDescription)"))
        }
        return scrub(oneLine(String(describing: error)))
    }

    /// 调用点已经有自己构造的、可靠的错误描述时用这个（例如 `err.description`、
    /// 已经写进 UI 的 `lastError`）。仍然过一遍兜底清洗。
    static func message(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "none" }
        return scrub(oneLine(text))
    }

    private static let systemErrorDomains: Set<String> = [
        NSCocoaErrorDomain,
        NSURLErrorDomain,
        NSPOSIXErrorDomain,
        NSOSStatusErrorDomain,
        NSMachErrorDomain,
    ]

    // MARK: - 兜底清洗

    /// 对任意文本做模式匹配清洗。命中即整体替换，不保留任何原始片段。
    ///
    /// 最后一条"长串"规则会误伤一些正常的长字符串，这是有意的取舍：
    /// **日志可读性让位于不泄露**。若误伤影响定位，在调用点把该字段显式写成短字段。
    static func scrub(_ text: String) -> String {
        var result = text
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
        return result
    }

    /// `NSRegularExpression` 本身线程安全，只是没有标 `Sendable`；规则表只读，可安全共享。
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let specs: [(String, String)] = [
            // JWT：Codex / Claude / Antigravity 的 access token 都是这个形状
            (#"eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*"#, "<redacted:jwt>"),
            // 各家 API key / 个人访问令牌
            (#"sk-ant-[A-Za-z0-9_-]{8,}"#, "<redacted:key>"),
            (#"sk-[A-Za-z0-9_-]{16,}"#, "<redacted:key>"),
            (#"(?<![A-Za-z0-9])at-[A-Za-z0-9_-]{8,}"#, "<redacted:key>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            // `key: value` / `key=value` 形态。`\b` 保证不误伤 hasAccessToken 这类驼峰字段名
            (
                #"(?i)\b(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password|passwd|cookie|session[_-]?key)\b\s*[:=]\s*["']?[^\s"',;)}\]]+"#,
                "$1=<redacted>"
            ),
            // URL query：`?a=b&c=d`
            (#"([?&])[A-Za-z0-9_%.\[\]-]+=[^\s&"'<>]+"#, "$1<redacted>"),
            // 邮箱
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<redacted:email>"),
            // UUID（account_uuid / organization_uuid / 会话 id）
            (
                #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
                "<redacted:uuid>"
            ),
            // 40 字符以上的连续 token 样长串：兜底未知形态的密钥与 base64 载荷
            // 前后界用不含 `=` 的字符类：base64 的 `=` 只出现在串尾，且 `key=value`
            // 里的 `=` 必须能当作左边界，否则 `payload=<长串>` 会整条漏掉。
            (
                #"(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/=_-]{40,}(?![A-Za-z0-9+/_-])"#,
                "<redacted:blob>"
            ),
        ]
        return specs.compactMap { pattern, template -> Rule? in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(regex: regex, template: template)
        }
    }()

    // MARK: - 工具

    static func oneLine(_ text: String, limit: Int = 300) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 3)) + "..."
    }

    private static func digest(_ value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: salt)
        return code.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 本机随机 salt，只存在 UserDefaults，**不进导出包**。
    /// 用户重置后哈希会变，跨版本比对会断——可接受，换来的是哈希不可被外部反查。
    private static let salt: SymmetricKey = {
        let defaults = UserDefaults.standard
        if let existing = defaults.data(forKey: saltKey), existing.count == 16 {
            return SymmetricKey(data: existing)
        }
        let generated = SymmetricKey(size: .bits128)
        let data = generated.withUnsafeBytes { Data($0) }
        defaults.set(data, forKey: saltKey)
        return SymmetricKey(data: data)
    }()

    private static let saltKey = "ccbar.diagnostics.redactionSalt"
}
