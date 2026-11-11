import CryptoKit
import Foundation
import os

/// 本地价格规则的生效快照：内置 `pricing-rules.json` 兜底，签名的远端规则文件热更新，调价不用发版。
///
/// 与 `PricingCatalogStore` 相同的 active / pending 机制：远端刷新只写 pending，扫描开始前
/// `commitPending()` 才切换，保证同一轮扫描的计价和最终指纹读同一份规则。读侧保持同步
/// （`Pricing.cost()` 被各 Scanner 同步调用），用锁保护的普通 class，不用 actor。
///
/// 采纳规则：远端文件必须用 App 内置的 Sparkle 公钥（`SUPublicEDKey`）验签通过、通过 `PricingRules.decode`
/// 的整份校验，且 `revision` 严格大于当前生效版本。远端回滚、CDN 返回旧文件都不会被采纳，也就不会反复重建历史。
nonisolated final class PricingRulesStore: @unchecked Sendable {
    static let shared = PricingRulesStore()

    enum Origin: String, Sendable {
        case bundled
        case remote
    }

    struct Snapshot: Sendable {
        let rules: PricingRules
        let origin: Origin
        /// 规则体加模型解析规则；`Pricing.fingerprint(knownUsage:)` 在它后面追加倍率与远端价。
        let localBody: String
        /// `Pricing.localPricingFingerprint()`，随快照只算一次。
        let localFingerprint: String

        init(rules: PricingRules, origin: Origin) {
            self.rules = rules
            self.origin = origin
            // 模型解析规则改变会让原本未定价的用量命中新键，也要触发重建。
            localBody = "\(rules.localPriceBody)|\(ModelIdentity.ruleSignature)"
            localFingerprint = Pricing.sha256Hex(localBody)
        }
    }

    private struct State {
        var active: Snapshot
        var pending: Snapshot?
        /// 只在内存里记录：App 每次启动检查一次，之后按间隔检查。
        var fetchedAt: Date?
        var failedAt: Date?
    }

    /// 规则文件由 `.github/workflows/pricing-rules.yml` 签名后上传到固定 tag 的 prerelease。
    static let rulesURL = URL(
        string: "https://github.com/nanvon/cc-bar/releases/download/pricing-rules/pricing-rules.json"
    )!
    static let signatureURL = URL(
        string: "https://github.com/nanvon/cc-bar/releases/download/pricing-rules/pricing-rules.json.sig"
    )!

    private let refreshInterval: TimeInterval = 12 * 3600
    private let failureRetryInterval: TimeInterval = 3600
    /// 规则文件约 40KB；超过 1MB 视为异常响应。
    private static let maximumFileSize = 1 << 20

    private let state: OSAllocatedUnfairLock<State>
    private let refreshRunning = OSAllocatedUnfairLock(initialState: false)

    private init() {
        let bundled = Self.loadBundled()
        var active = Snapshot(rules: bundled, origin: .bundled)
        // App 升级后内置文件可能比缓存的远端文件新：取 revision 较大的一份，相同时用内置。
        // 单元测试只读内置文件，不读用户目录。
        if !AppRuntime.isRunningUnitTests,
           let publicKey = Self.publicKey(),
           let cached = PricingRulesCache.load(publicKey: publicKey),
           cached.revision > bundled.revision {
            active = Snapshot(rules: cached, origin: .remote)
        }
        state = OSAllocatedUnfairLock(initialState: State(active: active))
        AppLog.info(.pricing, "pricing rules active: \(active.origin.rawValue) revision=\(active.rules.revision)")
    }

    /// 当前扫描可读取的规则快照。零 I/O。
    func current() -> Snapshot {
        state.withLock { $0.active }
    }

    /// 扫描开始前提交已采纳的远端规则。提交后本地价格指纹变化，由重建基准触发一次完整重建。
    @discardableResult
    func commitPending() -> Bool {
        let committed = state.withLock { state -> Snapshot? in
            guard let pending = state.pending else { return nil }
            state.active = pending
            state.pending = nil
            return pending
        }
        guard let committed else { return false }
        AppLog.info(.pricing, "pricing rules committed: revision=\(committed.rules.revision)")
        return true
    }

    /// App 启动和每次用量扫描开始时调用。非阻塞：到期才发请求，已有刷新在跑则直接返回。
    func refreshIfNeeded() {
        guard !AppRuntime.isRunningUnitTests else { return }
        let now = Date()
        let due = state.withLock { isDue($0, now: now) }
        guard due, beginRefresh() else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.performRefresh()
            self.refreshRunning.withLock { $0 = false }
        }
    }

    /// 用户手动更新价格：绕过检查间隔。返回是否采纳了更新的规则。
    func forceRefresh() async -> Bool {
        guard !AppRuntime.isRunningUnitTests else { return false }
        while !beginRefresh() {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let adopted = await performRefresh()
        refreshRunning.withLock { $0 = false }
        return adopted
    }

    /// 只采纳 revision 严格更大的规则，放进 pending 等下一次扫描开始时提交。
    @discardableResult
    func stage(_ rules: PricingRules) -> Bool {
        let snapshot = Snapshot(rules: rules, origin: .remote)
        return state.withLock { state -> Bool in
            let current = state.pending ?? state.active
            guard rules.revision > current.rules.revision else { return false }
            state.pending = snapshot
            return true
        }
    }

    /// 验签并整份校验远端文件。签名是 Sparkle `sign_update -p` 输出的 base64 文本。
    static func verifiedRules(
        data: Data,
        signature: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> PricingRules {
        guard let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == 64,
              publicKey.isValidSignature(raw, for: data)
        else { throw PricingRulesError.badSignature }
        return try PricingRules.decode(data)
    }

    /// 与 Sparkle 更新验签用同一把公钥；构建没有配置公钥时不读取远端规则。
    static func publicKey(bundle: Bundle = .main) -> Curve25519.Signing.PublicKey? {
        guard let text = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let raw = Data(base64Encoded: text), raw.count == 32
        else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// 内置规则读不出来或校验失败只会是打包错误：记日志，按全部未定价运行，不让 App 崩溃。
    static func loadBundled(bundle: Bundle = .main) -> PricingRules {
        guard let url = bundle.url(forResource: "pricing-rules", withExtension: "json") else {
            AppLog.error(.pricing, "bundled pricing rules missing")
            return .empty
        }
        do {
            return try PricingRules.decode(Data(contentsOf: url))
        } catch {
            AppLog.error(.pricing, "bundled pricing rules rejected: \(error)")
            return .empty
        }
    }

    #if DEBUG
    /// 单元测试隔离：直接替换生效规则，不碰磁盘和网络。
    func installRulesForTesting(_ rules: PricingRules) {
        state.withLock { $0 = State(active: Snapshot(rules: rules, origin: .bundled)) }
    }

    func resetToBundledForTesting() {
        installRulesForTesting(Self.loadBundled())
    }
    #endif

    // MARK: - 刷新

    private func isDue(_ state: State, now: Date) -> Bool {
        if let failedAt = state.failedAt, now.timeIntervalSince(failedAt) < failureRetryInterval {
            return false
        }
        guard let fetchedAt = state.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= refreshInterval
    }

    private func beginRefresh() -> Bool {
        refreshRunning.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
    }

    private func performRefresh() async -> Bool {
        let now = Date()
        guard let publicKey = Self.publicKey() else {
            state.withLock { $0.failedAt = now }
            return false
        }
        let data: Data
        let signature: Data
        let rules: PricingRules
        do {
            data = try await Self.fetch(Self.rulesURL)
            signature = try await Self.fetch(Self.signatureURL)
            rules = try Self.verifiedRules(data: data, signature: signature, publicKey: publicKey)
        } catch {
            // 请求、验签、校验任一失败都保留当前规则，只记退避时间。
            state.withLock { $0.failedAt = now }
            AppLog.warn(.pricing, "pricing rules refresh failed, kept current rules: \(Redact.error(error))")
            return false
        }
        state.withLock {
            $0.fetchedAt = now
            $0.failedAt = nil
        }
        guard stage(rules) else { return false }
        do {
            try PricingRulesCache.save(data: data, signature: signature)
        } catch {
            AppLog.error(.pricing, "pricing rules cache save failed: \(Redact.error(error))")
        }
        AppLog.info(.pricing, "pricing rules staged: revision=\(rules.revision)")
        return true
    }

    private enum FetchError: Error {
        case http(Int)
        case nonHTTP
        case tooLarge(Int)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await NetworkProxy.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.nonHTTP }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        guard data.count <= maximumFileSize else { throw FetchError.tooLarge(data.count) }
        return data
    }
}

/// 已采纳的远端规则：原样保存文件和签名，启动时重新验签、校验后才使用。
enum PricingRulesCache {
    nonisolated private static let fileName = "pricing-rules.json"
    nonisolated private static let signatureFileName = "pricing-rules.json.sig"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load(publicKey: Curve25519.Signing.PublicKey) -> PricingRules? {
        let directory = directoryURL()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let signature = try? Data(contentsOf: directory.appendingPathComponent(signatureFileName))
        else { return nil }
        do {
            return try PricingRulesStore.verifiedRules(data: data, signature: signature, publicKey: publicKey)
        } catch {
            AppLog.warn(.pricing, "cached pricing rules rejected, using bundled rules: \(error)")
            return nil
        }
    }

    nonisolated static func save(data: Data, signature: Data) throws {
        let directory = directoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
        try signature.write(to: directory.appendingPathComponent(signatureFileName), options: [.atomic])
    }

    nonisolated static func directoryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(bundleDirectory, isDirectory: true)
    }
}
