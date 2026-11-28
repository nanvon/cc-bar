import Darwin
import Foundation

/// Antigravity 额度客户端：仅通过官方 `agy` CLI（`agy -p "/usage" --output-format json`）获取额度。
///
/// cc-bar 不提取 client secret、不自行刷新 Google OAuth 令牌，也不直连 Google Cloud Code 接口，
/// 仅由官方签名二进制发起查询并在低频策略下解析其结构化输出；未安装 `agy` 时只保留本地对话与用量统计。
nonisolated enum AntigravityQuotaClient {
    /// 解析结果，保留 `Fetched` 结构供本地单测及快照构建复用。
    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var account: AntigravityAccount
    }

    enum CLIResult: Sendable {
        case success(QuotaSnapshot)
        case failure(QuotaError)
        /// agy 的登录态失效或缺失，需要用户在终端运行 agy 重新登录。此时不调用 agy。
        case signedOut
        /// 本机未检测到官方 agy CLI（仅安装桌面端 / IDE 时不提供在线额度查询）。
        case cliMissing
    }

    struct CLIRun: Sendable {
        /// nil 表示进程没启动，或 stdout 读不出来（超过 1 MiB / 读取失败）。
        var data: Data?
        /// stderr 摘要（最多 64 KiB），仅用于识别 429 或登录失效错误。
        var errorData: Data?
        /// nil 表示没能确认进程已经退出。
        var exitStatus: Int32?
        var timedOut: Bool
        /// 读取线程是否在超时内排空；false 时 `data` 可能不完整。
        var drained: Bool
    }

    static func isCLIAvailable() -> Bool {
        cliExecutable() != nil
    }

    static func fetchCLIQuota(sessionKey: String, force: Bool = false) async -> CLIResult {
        await CLIQuery.shared.fetch(sessionKey: sessionKey, force: force)
    }

    // MARK: - CLI 查询（仅调用官方 agy）

    private actor CLIQuery {
        static let shared = CLIQuery()
        private var failedSession: String?
        private var failedAt: Date?
        private var lastError: QuotaError = .transport("Antigravity CLI quota unavailable")

        private static let signedOutDefaultsKey = "antigravityCLISignedOutTokenSignatureV1"
        /// 确认 agy 登录失效时其凭据（钥匙串或文件）的签名。凭据变化后才再调用 agy；持久化，重启后不再试。
        private var signedOutSignature = UserDefaults.standard.string(forKey: CLIQuery.signedOutDefaultsKey)

        func fetch(sessionKey: String, force: Bool) async -> CLIResult {
            if !force, failedSession == sessionKey, let failedAt, Date().timeIntervalSince(failedAt) < 15 * 60 {
                return .failure(lastError)
            }
            guard let executable = AntigravityQuotaClient.cliExecutable() else {
                return .cliMissing
            }
            // 代理配置不可用时不让 agy 绕开代理直连。
            guard let environment = NetworkProxy.subprocessEnvironment(base: ProcessInfo.processInfo.environment) else {
                return .failure(.network(.proxyUnavailable))
            }
            // 仅在存在钥匙串 / CLI 登录态时调用 agy，防止未登录时唤醒浏览器登录页。
            let token: AntigravityCredentials.CLIToken
            switch await Self.loadCLIToken() {
            case .found(let found):
                token = found
            case .missing:
                return .signedOut
            case .unreadable(let error):
                recordFailure(error, sessionKey: sessionKey, detail: "keychain read failed")
                return .failure(error)
            }
            if token.signature == signedOutSignature {
                return .signedOut
            }
            if token.refreshToken == nil, !token.isValid {
                markSignedOut(token.signature)
                return .signedOut
            }

            let tokenWasValid = token.isValid
            let run = await Task.detached(priority: .utility) {
                AntigravityQuotaClient.runCLI(executable: executable, environment: environment)
            }.value
            let result = AntigravityQuotaClient.evaluateCLIRun(run)
            switch result {
            case .success(let snapshot):
                failedSession = nil
                failedAt = nil
                if signedOutSignature != nil {
                    signedOutSignature = nil
                    UserDefaults.standard.removeObject(forKey: Self.signedOutDefaultsKey)
                }
                return .success(snapshot)
            case .failure(let error):
                if case .antigravitySignedOut = error {
                    markSignedOut(token.signature)
                    return .signedOut
                }
                // token 本就过期且调用 agy 后仍未续期成功：视为登录失效，停调用直到重新登录。
                if !tokenWasValid, case .found(let current) = await Self.loadCLIToken(), !current.isValid {
                    markSignedOut(current.signature)
                    return .signedOut
                }
                recordFailure(error, sessionKey: sessionKey, detail: AntigravityQuotaClient.describe(run))
                return .failure(error)
            }
        }

        private func recordFailure(_ error: QuotaError, sessionKey: String, detail: String? = nil) {
            failedSession = sessionKey
            failedAt = Date()
            lastError = error
            var message = "antigravity CLI fetch failed: \(Redact.message(error.description))"
            if let detail, !detail.isEmpty { message += " (\(detail))" }
            AppLog.warn(.quota, message)
        }

        private func markSignedOut(_ signature: String) {
            signedOutSignature = signature
            UserDefaults.standard.set(signature, forKey: Self.signedOutDefaultsKey)
            AppLog.info(.credentials, "antigravity CLI signed out; agy skipped until its credential changes")
        }

        private static func loadCLIToken() async -> AntigravityCredentials.CLITokenLoad {
            await Task.detached(priority: .utility) { AntigravityCredentials.loadCLIToken() }.value
        }
    }

    static func cliExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let path = environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin",
            home.appendingPathComponent(".gemini/bin").path,
            home.appendingPathComponent(".gemini/antigravity/bin").path,
        ]
        return directories.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("agy")
        }.first { isExecutable($0.path) }
    }

    /// 按 stdout 判定成败，不要求进程正常退出：agy 可能已经输出完整 JSON，
    /// 却因为收尾、争锁迟迟不退。JSON 不完整时解析不出来，不会把半截数据当成功。
    static func evaluateCLIRun(_ run: CLIRun, fetchedAt: Date = Date()) -> Result<QuotaSnapshot, QuotaError> {
        let stderrText = run.errorData.flatMap { String(data: $0, encoding: .utf8) }?.lowercased() ?? ""
        if let data = run.data,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if root["status"] as? String != "SUCCESS" {
                let errText = (root["error"] as? String)
                    ?? ((root["error"] as? [String: Any])?["message"] as? String)
                    ?? ""
                let message = ((root["response"] as? String ?? "") + " " + errText + " " + stderrText).lowercased()
                if isRateLimitText(message) {
                    return .failure(.http(429, "Antigravity CLI quota is rate limited"))
                }
                if isAuthFailureText(message) {
                    return .failure(.antigravitySignedOut)
                }
            }
            if let snapshot = parseCLI(root: root, fetchedAt: fetchedAt) {
                return .success(snapshot)
            }
            return .failure(.decode("Antigravity CLI quota unavailable"))
        }
        let stdoutText = run.data.flatMap { String(data: $0, encoding: .utf8) }?.lowercased() ?? ""
        let combined = stdoutText + " " + stderrText
        if isRateLimitText(combined) {
            return .failure(.http(429, "Antigravity CLI quota is rate limited"))
        }
        if isAuthFailureText(combined) {
            return .failure(.antigravitySignedOut)
        }
        return .failure(.transport("Antigravity CLI quota unavailable"))
    }

    private static func isRateLimitText(_ text: String) -> Bool {
        ["429", "rate limit", "rate_limit", "resource_exhausted", "too many requests"].contains(where: text.contains)
    }

    private static func isAuthFailureText(_ text: String) -> Bool {
        ["401", "unauthenticated", "invalid_grant", "not logged in", "login required", "sign in", "re-authenticate", "reauthenticate"]
            .contains(where: text.contains)
    }

    /// 失败日志用：只描述进程层面发生了什么，不打印 stdout（可能含账号相关内容）。
    private static func describe(_ run: CLIRun) -> String {
        guard let exitStatus = run.exitStatus else { return "did not start or exit" }
        var parts = ["exit \(exitStatus)"]
        if run.timedOut { parts.append("timed out") }
        if !run.drained { parts.append("stdout not drained") }
        if run.data == nil { parts.append("no readable stdout") }
        return parts.joined(separator: ", ")
    }

    private static func runCLI(executable: URL, environment: [String: String]) -> CLIRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null"]
        var environment = environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["BROWSER"] = "/usr/bin/true"
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return CLIRun(data: nil, errorData: nil, exitStatus: nil, timedOut: false, drained: false)
        }
        output.fileHandleForWriting.closeFile()
        errorOutput.fileHandleForWriting.closeFile()

        let buffer = BoundedOutput(limit: 1024 * 1024)
        let errorBuffer = BoundedOutput(limit: 64 * 1024)
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            drain(handle: output.fileHandleForReading, into: buffer) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            drain(handle: errorOutput.fileHandleForReading, into: errorBuffer, onOverflow: {})
        }

        let timedOut = completed.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        let drained = reader.wait(timeout: .now() + 1) == .success
        output.fileHandleForReading.closeFile()
        errorOutput.fileHandleForReading.closeFile()
        let exitStatus: Int32? = process.isRunning ? nil : process.terminationStatus
        return CLIRun(
            data: buffer.result(),
            errorData: errorBuffer.result(),
            exitStatus: exitStatus,
            timedOut: timedOut,
            drained: drained
        )
    }

    private static func drain(handle: FileHandle, into buffer: BoundedOutput, onOverflow: () -> Void) {
        do {
            while let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty {
                if !buffer.append(chunk) {
                    onOverflow()
                    break
                }
            }
        } catch {
            buffer.invalidate()
        }
    }

    nonisolated private final class BoundedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var valid = true

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard valid, data.count + chunk.count <= limit else {
                valid = false
                return false
            }
            data.append(chunk)
            return true
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            valid = false
        }

        func result() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return valid ? data : nil
        }
    }

    // MARK: - Parse

    /// 解析 `agy -p "/usage" --output-format json`（兼容 `/quota` 别名）的结构化输出。
    static func parseCLI(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot? {
        guard root["status"] as? String == "SUCCESS",
              let command = root["command"] as? [String: Any],
              ["usage", "quota"].contains(command["name"] as? String ?? ""),
              let data = command["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]]
        else { return nil }
        let normalized = groups.map { group -> [String: Any] in
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).map { bucket -> [String: Any] in
                var result = bucket
                result["bucketId"] = bucket["id"]
                result["displayName"] = bucket["name"]
                result["remainingFraction"] = bucket["remaining_fraction"]
                result["resetTime"] = bucket["reset_time"]
                return result
            }
            return ["displayName": group["name"] as? String ?? "", "buckets": buckets]
        }
        let snapshot = parse(root: ["groups": normalized], fetchedAt: fetchedAt).snapshot
        return snapshot.allLimits.isEmpty ? nil : snapshot
    }

    private static let groupedLimitOrder = [
        "gemini-5h", "gemini-weekly", "gemini-carbon-wtu-weekly", "claude-5h", "claude-weekly", "gemini-argon-wtu-weekly",
    ]

    private static func assigningGroupedLimits(_ limits: [QuotaLimit], onto snapshot: inout QuotaSnapshot) {
        let sorted = limits.sorted {
            (groupedLimitOrder.firstIndex(of: $0.id) ?? 99) < (groupedLimitOrder.firstIndex(of: $1.id) ?? 99)
        }
        snapshot.primaryLimit = sorted.first
        snapshot.secondaryLimit = sorted.dropFirst().first
        snapshot.auxiliaryLimits = Array(sorted.dropFirst(2))
    }

    /// 兼容旧缓存中仍把 Argon 放在 primaryLimit 的快照，按当前分组展示顺序重排。
    static func reorderedGroupedSnapshot(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        guard snapshot.app == .antigravity,
              snapshot.primaryLimit?.id == "gemini-argon-wtu-weekly"
        else { return snapshot }
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 } + snapshot.auxiliaryLimits
        guard limits.count > 1 else { return snapshot }
        var updated = snapshot
        assigningGroupedLimits(limits, onto: &updated)
        return updated
    }

    nonisolated static func parse(root: [String: Any], fetchedAt: Date = Date()) -> Fetched {
        let root = root["response"] as? [String: Any] ?? root
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var argonWeekly: QuotaWindow?
        var carbonWeekly: QuotaWindow?
        var claude5h: QuotaWindow?
        var claudeWeekly: QuotaWindow?
        var planType: String?
        var hasGroupedData = false

        if let paid = root["paidTier"] as? [String: Any],
           let paidPlan = paidTierPlanName(paid)
        {
            planType = paidPlan
        } else if let cur = root["currentTier"] as? [String: Any], let id = cur["id"] as? String {
            planType = tierPlanName(id)
        } else if let cur = root["currentTier"] as? String {
            planType = tierPlanName(cur)
        } else if let allowed = root["allowedTiers"] as? [[String: Any]], let first = allowed.first, let id = first["id"] as? String {
            planType = tierPlanName(id)
        } else if let tier = root["tier"] as? [String: Any], let id = tier["id"] as? String {
            planType = tierPlanName(id)
        }

        if let groups = root["groups"] as? [[String: Any]] {
            let parsed = parseGroups(groups, fetchedAt: fetchedAt)
            claude5h = parsed.fiveHour
            claudeWeekly = parsed.weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? geminiWeekly
            argonWeekly = parsed.argonWeekly
            carbonWeekly = parsed.carbonWeekly
            hasGroupedData = parsed.fiveHour != nil || parsed.weekly != nil
                || parsed.geminiWindow != nil || parsed.geminiWeekly != nil || argonWeekly != nil
                || carbonWeekly != nil
            if planType == nil { planType = parsed.planType }
        }

        if let quota = root["quota"] as? [String: Any] {
            let parsed = parseQuotaDict(quota, fetchedAt: fetchedAt)
            fiveHour = fiveHour ?? parsed.fiveHour
            weekly = weekly ?? parsed.weekly
            geminiWindow = geminiWindow ?? parsed.geminiWindow
            geminiWeekly = geminiWeekly ?? parsed.geminiWeekly
        }
        if let buckets = root["buckets"] as? [[String: Any]] {
            let parsed = parseBuckets(buckets, fetchedAt: fetchedAt)
            fiveHour = parsed.fiveHour ?? fiveHour
            weekly = parsed.weekly ?? weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? parsed.geminiWeekly
        }
        if fiveHour == nil, weekly == nil, geminiWindow == nil, geminiWeekly == nil, claude5h == nil, claudeWeekly == nil {
            if let info = root["quotaInfo"] as? [String: Any] {
                let parsed = parseQuotaDict(info, fetchedAt: fetchedAt)
                fiveHour = fiveHour ?? parsed.fiveHour
                weekly = weekly ?? parsed.weekly
                geminiWindow = geminiWindow ?? parsed.geminiWindow
                geminiWeekly = geminiWeekly ?? parsed.geminiWeekly
            }
        }

        let primaryLimit: QuotaLimit?
        let secondaryLimit: QuotaLimit?
        let auxiliaryLimits: [QuotaLimit]
        if hasGroupedData {
            var limits: [QuotaLimit] = []
            if let geminiWindow {
                limits.append(QuotaLimit(id: "gemini-5h", kind: .fiveHour, displayName: "Gemini 5H", window: geminiWindow, isActive: nil))
            }
            if let geminiWeekly {
                limits.append(QuotaLimit(id: "gemini-weekly", kind: .weekly, displayName: "Gemini WK", window: geminiWeekly, isActive: nil))
            }
            if let carbonWeekly {
                limits.append(QuotaLimit(id: "gemini-carbon-wtu-weekly", kind: .modelWeekly, displayName: "Gemini 4 Carbon", window: carbonWeekly, isActive: nil))
            }
            if let claude5h { limits.append(QuotaLimit(id: "claude-5h", kind: .fiveHour, displayName: "Claude 5H", window: claude5h, isActive: nil)) }
            if let claudeWeekly { limits.append(QuotaLimit(id: "claude-weekly", kind: .weekly, displayName: "Claude WK", window: claudeWeekly, isActive: nil)) }
            if let argonWeekly {
                limits.append(QuotaLimit(id: "gemini-argon-wtu-weekly", kind: .modelWeekly, displayName: "Gemini 4 Argon", window: argonWeekly, isActive: nil))
            }
            primaryLimit = limits.first
            secondaryLimit = limits.dropFirst().first
            auxiliaryLimits = Array(limits.dropFirst(2))
        } else {
            let primaryWindow = fiveHour ?? weekly
            let secondaryWindow = fiveHour != nil ? weekly : nil
            primaryLimit = primaryWindow.map { QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0, fallback: .fiveHour), window: $0) }
            secondaryLimit = secondaryWindow.map { QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0, fallback: .weekly), window: $0) }
            auxiliaryLimits = []
        }

        let snapshot = QuotaSnapshot(
            app: .antigravity,
            primaryLimit: primaryLimit,
            secondaryLimit: secondaryLimit,
            auxiliaryLimits: auxiliaryLimits,
            geminiWindow: hasGroupedData ? nil : geminiWindow,
            geminiWeekly: hasGroupedData ? nil : geminiWeekly,
            planType: planType,
            fetchedAt: fetchedAt
        )
        let account = AntigravityAccount(email: nil, planType: planType, source: .cliToken)
        return Fetched(snapshot: snapshot, account: account)
    }

    // MARK: - Groups & buckets parser

    private struct GroupParsed {
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var argonWeekly: QuotaWindow?
        var carbonWeekly: QuotaWindow?
        var planType: String?
    }

    private static func parseGroups(_ groups: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for group in groups {
            guard let groupBuckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupName = ((group["displayName"] as? String) ?? "").lowercased()
            for bucket in groupBuckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = remainingFraction(in: bucket), remaining.isFinite,
                      (0...1).contains(remaining) else { continue }
                let id = (bucket["bucketId"] as? String ?? "").lowercased()
                let name = (bucket["displayName"] as? String ?? "").lowercased()
                let windowTag = (bucket["window"] as? String ?? "").lowercased()
                let reset = resetDate(value: bucket["resetTime"])

                if id == "gemini-argon-wtu-weekly" {
                    adoptMin(&result.argonWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    continue
                }
                if id == "gemini-carbon-wtu-weekly" {
                    adoptMin(&result.carbonWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    continue
                }

                let isGemini: Bool
                if id.hasPrefix("gemini") {
                    isGemini = true
                } else if id.hasPrefix("3p") || id.hasPrefix("third") || id.hasPrefix("claude") || id.hasPrefix("gpt") {
                    isGemini = false
                } else {
                    isGemini = groupName.contains("gemini")
                }
                let isWeekly = id.contains("week") || windowTag.contains("week") || name.contains("week")
                if isGemini {
                    if isWeekly {
                        adoptMin(&result.geminiWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    } else {
                        adoptMin(&result.geminiWindow, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
                    }
                } else if isWeekly {
                    adoptMin(&result.weekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                } else {
                    adoptMin(&result.fiveHour, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
                }
            }
        }
        return result
    }

    private static func bucketFamily(_ bucket: [String: Any]) -> Family {
        let model = (bucket["modelId"] as? String ?? bucket["model"] as? String ?? "").lowercased()
        let bucketID = (bucket["bucketId"] as? String ?? "").lowercased()
        if model.contains("gemini") || model.contains("tab_") || model.contains("chat_") {
            return bucketID.contains("week") || bucketID.contains("weekly") ? .geminiWeekly : .geminiWindow
        }
        if bucketID.contains("week") || bucketID.contains("weekly") { return .weekly }
        if model.contains("claude") || model.contains("gpt") || model.contains("opus") || model.contains("sonnet") { return .thirdPartyWindow }
        return .internalPlaceholder
    }

    private enum Family {
        case weekly
        case geminiWeekly
        case geminiWindow
        case thirdPartyWindow
        case internalPlaceholder
    }

    private static func parseBuckets(_ buckets: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for bucket in buckets {
            guard let remaining = remainingFraction(in: bucket) else { continue }
            let family = bucketFamily(bucket)
            guard family != .internalPlaceholder else { continue }
            let reset = resetDate(value: bucket["resetTime"] ?? bucket["reset_time"])
            if remaining >= 1.0, reset == nil { continue }
            switch family {
            case .weekly:
                adoptMin(&result.weekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
            case .geminiWeekly:
                adoptMin(&result.geminiWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
            case .geminiWindow:
                adoptMin(&result.geminiWindow, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
            case .thirdPartyWindow:
                adoptMin(&result.fiveHour, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
            case .internalPlaceholder:
                continue
            }
        }
        return result
    }

    private static func adoptMin(_ slot: inout QuotaWindow?, remaining: Double, reset: Date?, windowSeconds: Int?) {
        guard let existing = slot else {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
            return
        }
        if remaining < existing.remainingPercent / 100 {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
        } else if remaining == existing.remainingPercent / 100, existing.resetsAt == nil, reset != nil {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
        }
    }

    private static func parseQuotaDict(_ dict: [String: Any], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for (k, v) in dict {
            guard let bucket = v as? [String: Any], let remaining = remainingFraction(in: bucket) else { continue }
            let key = k.lowercased()
            let reset = resetDate(value: bucket["resetTime"] ?? bucket["reset_time"])
            let isWeekly = key.contains("week")
            let windowSecs: Int = isWeekly ? 7 * 24 * 3600 : 5 * 3600
            let window = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSecs)
            if key.contains("gemini") {
                if key.contains("week") { result.geminiWeekly = window } else { result.geminiWindow = window }
            } else {
                if key.contains("week") { result.weekly = window } else { result.fiveHour = window }
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func remainingFraction(in bucket: [String: Any]) -> Double? {
        if let v = bucket["remainingFraction"] as? Double { return v }
        if let v = bucket["remaining_fraction"] as? Double { return v }
        if let v = bucket["remaining"] as? Double { return v > 1 ? v / 100 : v }
        if let v = bucket["remainingPercent"] as? Double { return 1 - v / 100 }
        if let s = bucket["remainingFraction"] as? String, let d = Double(s) { return d }
        if let n = bucket["remainingFraction"] as? NSNumber { return n.doubleValue }
        if let used = bucket["usedPercent"] as? Double { return 1 - used / 100 }
        return nil
    }

    private static func tierPlanName(_ id: String) -> String {
        id == "free-tier" ? "Free" : id
    }

    private static func paidTierPlanName(_ tier: [String: Any]) -> String? {
        if let id = nonEmpty(tier["id"] as? String), id == "free-tier" { return tierPlanName(id) }
        return nonEmpty(tier["name"] as? String) ?? nonEmpty(tier["id"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func resetDate(value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            if let n = Double(s) {
                guard n > 0 else { return nil }
                return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
            }
        }
        if let n = value as? Double {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = value as? Int {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(n) > 1e12 ? Double(n) / 1000 : Double(n))
        }
        return nil
    }
}
