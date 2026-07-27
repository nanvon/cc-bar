import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    var codexAccount: CodexAccount?
    var claudeAccount: ClaudeAccount?
    var antigravityAccount: AntigravityAccount?
    var antigravityAvailability: AntigravityAvailability = .notInstalled
    var grokAccount: GrokAccount?
    var codexError: String?
    var claudeError: String?
    var grokError: String?

    // MARK: 导入的 Codex 副账号
    //
    // 用户手动粘贴 auth.json 添加的"其他账号"。与默认账号(`~/.codex/auth.json`)解耦,
    // 允许重复出现,token 走 Keychain (见 ImportedCodexStore)。
    // - `importedCodexAccounts` 元数据列表,保持添加顺序。
    // - `importedCodexQuotas / Sources / Errors / RefreshStates` 按 account.id 索引,
    //   只在该账号 `visibleInPopover` 为 true 时才刷新与展示。
    var importedCodexAccounts: [ImportedCodexAccount] = []
    var importedCodexQuotas: [String: QuotaSnapshot] = [:]
    var importedCodexSources: [String: QuotaSnapshotSource] = [:]
    var importedCodexErrors: [String: String] = [:]
    var importedCodexRefreshStates: [String: QuotaRefreshState] = [:]

    /// 主窗口当前 tab,允许 ⌘1 / ⌘, 等命令从外部驱动切换
    var mainTab: MainTab = .stats

    /// 首次启动时由 bootstrap 设为 true,触发 Onboarding 窗口
    var shouldShowOnboarding: Bool = false

    var primaryQuotaStates: [QuotaApp: PrimaryQuotaState] = [:]

    var codexQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .codex) }
        set { updatePrimaryState(.codex) { $0.snapshot = newValue } }
    }
    var claudeQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .claude) }
        set { updatePrimaryState(.claude) { $0.snapshot = newValue } }
    }
    var antigravityQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.snapshot = newValue } }
    }
    var grokQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .grok) }
        set { updatePrimaryState(.grok) { $0.snapshot = newValue } }
    }
    var codexQuotaError: String? {
        get { quotaError(for: .codex) }
        set { updatePrimaryState(.codex) { $0.error = newValue } }
    }
    var claudeQuotaError: String? {
        get { quotaError(for: .claude) }
        set { updatePrimaryState(.claude) { $0.error = newValue } }
    }
    var antigravityQuotaError: String? {
        get { quotaError(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.error = newValue } }
    }
    var grokQuotaError: String? {
        get { quotaError(for: .grok) }
        set { updatePrimaryState(.grok) { $0.error = newValue } }
    }
    var codexQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .codex) }
        set { updatePrimaryState(.codex) { $0.source = newValue } }
    }
    var claudeQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .claude) }
        set { updatePrimaryState(.claude) { $0.source = newValue } }
    }
    var antigravityQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.source = newValue } }
    }
    var grokQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .grok) }
        set { updatePrimaryState(.grok) { $0.source = newValue } }
    }
    var codexRefreshState: QuotaRefreshState {
        get { refreshState(for: .codex) }
        set { updatePrimaryState(.codex) { $0.refresh = newValue } }
    }
    var claudeRefreshState: QuotaRefreshState {
        get { refreshState(for: .claude) }
        set { updatePrimaryState(.claude) { $0.refresh = newValue } }
    }
    var antigravityRefreshState: QuotaRefreshState {
        get { refreshState(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.refresh = newValue } }
    }
    var grokRefreshState: QuotaRefreshState {
        get { refreshState(for: .grok) }
        set { updatePrimaryState(.grok) { $0.refresh = newValue } }
    }
    var quotaHistory = QuotaHistoryPayload()

    var codexTodayCost: Decimal?
    var claudeTodayCost: Decimal?
    var grokTodayCost: Decimal?

    /// OpenAI / Anthropic statuspage.io 最新快照,失败时保留上一份。
    var codexServiceStatus: ServiceStatus?
    var claudeServiceStatus: ServiceStatus?

    let usageService = UsageService()
    private let scheduler = Scheduler()
    private var didBootstrap = false
    private var quotaCache = QuotaCachePayload()
    private var claudeFallbackBackoffUntil: Date?

    /// `refreshNow()` 的去重锁。同一时刻只允许一个真正在跑的整体刷新;
    /// 期间额外的 `refreshNow()` 调用立即返回(no-op),不再排队。
    /// UI 的"刷新按钮"依然每点必转图标,只是不会真的发起重复请求。
    private var refreshInFlight: Task<Void, Never>?

    /// 是否有一次由 `refreshNow()` 发起的整体刷新正在进行(用户点击 popover 刷新按钮或按 ⌘R)。
    /// popover 用它统一驱动刷新按钮的转圈动画,让两个入口的视觉反馈一致。
    /// 周期性后台刷新(Scheduler 的 quotaLoop/usageLoop)不走 `refreshNow()`,不会触发这个信号。
    var isRefreshing: Bool { refreshInFlight != nil }

    /// `ClaudeDelegatedRefresh` 完成成功时的通知订阅。
    /// 保留引用以便释放时取消(目前 AppState 生命周期 = App 生命周期,实际不会释放)。
    private var delegatedRefreshObserver: NSObjectProtocol?

    private let minSuccessInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 10 * 60

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        subscribeToDelegatedRefreshSuccess()
        loadQuotaCache()
        loadQuotaHistory()
        reloadImportedCodexAccounts()
        usageService.bootstrap(appState: self)
        await loadCodex()
        maybeShowKeychainPrompt()
        await loadClaude()
        await loadGrok()
        antigravityAvailability = await AntigravityQuotaClient.detectAvailability()
        logCredentialSummary()

        if !SettingsStore.shared.didCompleteOnboarding {
            shouldShowOnboarding = true
        }

        let settings = SettingsStore.shared
        scheduler.start(
            appState: self,
            quotaInterval: settings.quotaInterval.seconds,
            usageInterval: settings.usageInterval.seconds
        )
        // 启动后台触发一次 JSONL 扫描，让今日 cost 立刻更新（不阻塞 bootstrap）
        Task { await usageService.scanNow() }
        // 启动后异步拉一次服务状态;后续由 Scheduler 5 分钟刷新一次
        Task { await refreshServiceStatus() }
    }

    /// 设置变更后，把刷新间隔同步到 Scheduler
    func applySettingsChange() {
        let settings = SettingsStore.shared
        scheduler.setQuotaInterval(settings.quotaInterval.seconds)
        scheduler.setUsageInterval(settings.usageInterval.seconds)
    }

    func refreshNow() async {
        // 去重:已有刷新在跑就直接返回,避免用户连点导致多份并发请求。
        // UI 端不依赖这里的 await 时长,按钮立刻就响应了。
        if refreshInFlight != nil { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.refreshQuotas(reason: .userInitiated)
            await self.usageService.scanNow()
            await self.refreshServiceStatus()
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    /// 订阅 `ClaudeDelegatedRefresh` 后台委托刷新成功的通知。
    /// 一旦 claude CLI 在后台帮我们刷新了 token 并写回了 keychain,
    /// 这里会自动触发一次完整刷新,UI 拿到新数据,用户全程无感。
    private func subscribeToDelegatedRefreshSuccess() {
        delegatedRefreshObserver = NotificationCenter.default.addObserver(
            forName: .claudeDelegatedRefreshDidSucceed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证回调线程,再 Task 进 MainActor 做异步刷新。
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 用 .periodic 而不是 .userInitiated,避免被当作"用户操作"
                // 影响速率限制 / 退避策略。
                await self.refreshQuotas(reason: .periodic)
            }
        }
    }

    /// 每次刷新(手动 / Scheduler 定时)都先重读本地凭据,以便用户在外部
    /// (如 cc-switch)切换账号后 ccbar 能感知到。loadCodex / loadClaude
    /// 内部会比较 accountId / email,若身份变化则清掉旧的额度缓存,避免
    /// 出现"新账号 + 旧额度"的错配。
    func refreshQuotas(reason: QuotaRefreshReason = .periodic) async {
        await loadCodex()
        await loadClaude()
        await loadGrok()
        await loadCodexQuota(reason: reason)
        await loadClaudeQuota(reason: reason)
        await loadGrokQuota(reason: reason)
        await loadAntigravityQuota(reason: reason)
        await loadAllImportedCodexQuotas(reason: reason)
        logQuotaSummary()
    }

    /// 拉取 OpenAI / Anthropic statuspage 状态。失败保留旧快照,不清空。
    /// 两个请求并发,任意一个失败不影响另一个。
    func refreshServiceStatus() async {
        async let codex = Self.fetchServiceStatus(url: ServiceStatusClient.openAIStatusURL, tag: "openai")
        async let claude = Self.fetchServiceStatus(url: ServiceStatusClient.anthropicStatusURL, tag: "anthropic")
        let codexResult = await codex
        let claudeResult = await claude
        if let codexResult { codexServiceStatus = codexResult }
        if let claudeResult { claudeServiceStatus = claudeResult }
    }

    private static func fetchServiceStatus(url: URL, tag: String) async -> ServiceStatus? {
        do {
            return try await ServiceStatusClient.fetch(from: url)
        } catch {
            print("[service-status] \(tag) fetch failed: \(error)")
            return nil
        }
    }

    func quotaStatusLine(for app: QuotaApp) -> String? {
        let snapshot = quotaSnapshot(for: app)
        let source = quotaSource(for: app)
        let error = quotaError(for: app)
        let state = refreshState(for: app)

        var parts: [String] = []
        if let snapshot, !format(snapshot).isEmpty {
            parts.append(format(snapshot))
        }
        if let source {
            parts.append(source.displayName)
        }
        if let lastSuccessAt = state.lastSuccessAt {
            parts.append("更新 \(relativeAge(from: lastSuccessAt))前")
        }
        if let backoffUntil = state.backoffUntil, backoffUntil > Date() {
            parts.append("限流退避 \(relativeAge(until: backoffUntil))")
        }
        if let error, !error.isEmpty {
            parts.append("错误: \(shortError(error))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadQuotaCache() {
        quotaCache = QuotaCache.load()
        for (app, record) in quotaCache.providers {
            var state = primaryQuotaStates[app] ?? PrimaryQuotaState()
            state.snapshot = record.snapshot
            state.source = .cache
            state.refresh.lastSuccessAt = record.updatedAt
            state.refresh.source = .cache
            primaryQuotaStates[app] = state
        }
        for (id, record) in quotaCache.importedCodex ?? [:] {
            importedCodexQuotas[id] = record.snapshot
            importedCodexSources[id] = .cache
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            importedCodexRefreshStates[id] = state
        }
    }

    func quotaSnapshot(for app: QuotaApp) -> QuotaSnapshot? {
        primaryQuotaStates[app]?.snapshot
    }

    func quotaError(for app: QuotaApp) -> String? {
        primaryQuotaStates[app]?.error
    }

    func quotaSource(for app: QuotaApp) -> QuotaSnapshotSource? {
        primaryQuotaStates[app]?.source
    }

    func refreshState(for app: QuotaApp) -> QuotaRefreshState {
        primaryQuotaStates[app]?.refresh ?? QuotaRefreshState()
    }

    private func updatePrimaryState(_ app: QuotaApp, _ update: (inout PrimaryQuotaState) -> Void) {
        var state = primaryQuotaStates[app] ?? PrimaryQuotaState()
        update(&state)
        primaryQuotaStates[app] = state
    }

    private func loadQuotaHistory() {
        quotaHistory = QuotaHistoryStore.load()
        saveQuotaHistory()
    }

    // MARK: - Imported Codex accounts

    /// 从磁盘读取元数据列表,移除内存中已经不存在的账号的运行时状态。
    /// 设置页增删账号后由调用方触发。
    func reloadImportedCodexAccounts() {
        importedCodexAccounts = ImportedCodexStore.loadAll()
        let alive = Set(importedCodexAccounts.map(\.id))
        importedCodexQuotas = importedCodexQuotas.filter { alive.contains($0.key) }
        importedCodexSources = importedCodexSources.filter { alive.contains($0.key) }
        importedCodexErrors = importedCodexErrors.filter { alive.contains($0.key) }
        importedCodexRefreshStates = importedCodexRefreshStates.filter { alive.contains($0.key) }
        var importedCache = quotaCache.importedCodex ?? [:]
        importedCache = importedCache.filter { alive.contains($0.key) }
        quotaCache.importedCodex = importedCache.isEmpty ? nil : importedCache
        saveQuotaCache()
    }

    /// 增 / 改:同 account_id 静默覆盖 token,元数据按入参更新;新增时落到列表末尾。
    func upsertImportedCodexAccount(
        from parsed: ImportedCodexPaste.Parsed,
        alias: String,
        visibleInPopover: Bool
    ) throws {
        let tokens = ImportedCodexTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            idToken: parsed.idToken
        )
        try ImportedCodexStore.saveTokens(tokens, accountId: parsed.id)

        var list = ImportedCodexStore.loadAll()
        if let idx = list.firstIndex(where: { $0.id == parsed.id }) {
            var existing = list[idx]
            existing.alias = alias
            existing.email = parsed.email ?? existing.email
            existing.planType = parsed.planType ?? existing.planType
            existing.visibleInPopover = visibleInPopover
            list[idx] = existing
        } else {
            list.append(ImportedCodexAccount(
                id: parsed.id,
                alias: alias,
                email: parsed.email,
                planType: parsed.planType,
                visibleInPopover: visibleInPopover,
                addedAt: Date()
            ))
        }
        try ImportedCodexStore.saveAll(list)
        reloadImportedCodexAccounts()
    }

    /// 导入 personal access token 形态的副账号。
    /// PAT 不透明、本地拿不到 account_id，先联网发一次 usage 拿身份，再组复合 id 落库。
    /// 失败（令牌无效 / 无网络 / 缺 account_id）时抛错，由调用方展示。
    func importCodexPersonalAccessToken(token: String, visibleInPopover: Bool) async throws {
        let result = await CodexQuotaClient.fetch(accessToken: token, accountId: nil)
        let fetched: CodexQuotaClient.Fetched
        switch result {
        case .success(let f):
            fetched = f
        case .failure(let err):
            throw ImportedCodexPATError.validation(err.description)
        }
        guard let accountId = nonEmpty(fetched.accountId) else {
            throw ImportedCodexPATError.validation("usage 响应缺少 account_id")
        }
        let compositeId: String = {
            if let userId = nonEmpty(fetched.userId) { return "\(accountId):\(userId)" }
            return accountId
        }()

        try ImportedCodexStore.saveTokens(
            ImportedCodexTokens(accessToken: token, refreshToken: nil, idToken: nil),
            accountId: compositeId
        )

        var list = ImportedCodexStore.loadAll()
        if let idx = list.firstIndex(where: { $0.id == compositeId }) {
            var existing = list[idx]
            existing.email = fetched.email ?? existing.email
            existing.planType = fetched.snapshot.planType ?? existing.planType
            existing.visibleInPopover = visibleInPopover
            existing.isPersonalAccessToken = true
            list[idx] = existing
        } else {
            list.append(ImportedCodexAccount(
                id: compositeId,
                alias: "",
                email: fetched.email,
                planType: fetched.snapshot.planType,
                visibleInPopover: visibleInPopover,
                addedAt: Date(),
                isPersonalAccessToken: true
            ))
        }
        try ImportedCodexStore.saveAll(list)
        reloadImportedCodexAccounts()
        // 顺手存上刚拿到的快照，导入后立即可见，省一次请求。
        if visibleInPopover {
            storeImportedCodex(id: compositeId, snapshot: fetched.snapshot, source: .api)
        }
    }

    enum ImportedCodexPATError: Error, LocalizedError {
        case validation(String)
        var errorDescription: String? {
            switch self {
            case .validation(let msg): return msg
            }
        }
    }

    /// 仅更新元数据(别名、颜色、显示开关),不动 token。
    func updateImportedCodexMetadata(id: String, mutate: (inout ImportedCodexAccount) -> Void) {
        var list = ImportedCodexStore.loadAll()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[idx])
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] save metadata failed: \(error)")
            return
        }
        reloadImportedCodexAccounts()
    }

    /// 按给定 id 顺序重排导入账号(忽略不存在的 id,缺失的追加到末尾)。
    func reorderImportedCodexAccounts(orderedIds: [String]) {
        let list = ImportedCodexStore.loadAll()
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var seen = Set<String>()
        var reordered: [ImportedCodexAccount] = []
        for id in orderedIds {
            guard let acc = byId[id], !seen.contains(id) else { continue }
            reordered.append(acc)
            seen.insert(id)
        }
        for acc in list where !seen.contains(acc.id) {
            reordered.append(acc)
        }
        guard reordered.map(\.id) != list.map(\.id) else { return }
        do { try ImportedCodexStore.saveAll(reordered) } catch {
            print("[imported-codex] reorder failed: \(error)")
            return
        }
        reloadImportedCodexAccounts()
    }

    /// 删除:同步清 Keychain、元数据、运行时状态与缓存。
    func removeImportedCodexAccount(id: String) {
        ImportedCodexStore.deleteTokens(accountId: id)
        let list = ImportedCodexStore.loadAll().filter { $0.id != id }
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] delete failed: \(error)")
        }
        reloadImportedCodexAccounts()
    }

    func importedCodexQuota(for account: ImportedCodexAccount) -> QuotaSnapshot? {
        if importedCodexAccountMirrorsPrimary(account) { return codexQuota }
        return importedCodexQuotas[account.id]
    }

    func importedCodexError(for account: ImportedCodexAccount) -> String? {
        if importedCodexAccountMirrorsPrimary(account) { return codexQuotaError }
        return importedCodexErrors[account.id]
    }

    func importedCodexRefreshState(for account: ImportedCodexAccount) -> QuotaRefreshState {
        if importedCodexAccountMirrorsPrimary(account) { return codexRefreshState }
        return importedCodexRefreshStates[account.id] ?? QuotaRefreshState()
    }

    /// 对所有 `visibleInPopover` 为 true 的导入账号并发拉一遍配额,并发上限 3。
    private func loadAllImportedCodexQuotas(reason: QuotaRefreshReason) async {
        let visible = importedCodexAccounts.filter(\.visibleInPopover)
        guard !visible.isEmpty else { return }
        let maxConcurrent = 3
        var index = 0
        while index < visible.count {
            let batch = Array(visible[index..<min(index + maxConcurrent, visible.count)])
            await withTaskGroup(of: Void.self) { group in
                for account in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.loadImportedCodexQuota(account: account, reason: reason)
                    }
                }
            }
            index += maxConcurrent
        }
    }

    private func loadImportedCodexQuota(account: ImportedCodexAccount, reason: QuotaRefreshReason) async {
        if importedCodexAccountMirrorsPrimary(account) {
            mirrorPrimaryCodexQuota(toImportedId: account.id)
            syncPrimaryCodexTokensToImported(id: account.id)
            return
        }

        guard beginImportedCodexRefresh(id: account.id, reason: reason) else { return }
        defer { importedCodexRefreshStates[account.id]?.inFlight = false }

        guard let tokens = ImportedCodexStore.loadTokens(accountId: account.id) else {
            markImportedCodexFailure(id: account.id, message: "missing tokens in keychain")
            return
        }
        let isPAT = account.isPersonalAccessToken == true
        let activeToken: String
        if isPAT {
            // PAT 不透明、无 refresh，直接用，跳过续期。
            activeToken = tokens.accessToken
        } else {
            let refreshed = await CodexTokenRefresher.ensureFreshAccessToken(
                currentAccessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                writeBack: .importedAccount(id: account.id)
            )
            switch refreshed {
            case .success(let t):
                activeToken = t
            case .failure(let err):
                markImportedCodexFailure(id: account.id, message: err.description, error: err)
                return
            }
        }
        let result = await CodexQuotaClient.fetch(
            accessToken: activeToken,
            accountId: isPAT ? nil : account.chatgptAccountId
        )
        switch result {
        case .success(let fetched):
            storeImportedCodex(id: account.id, snapshot: fetched.snapshot, source: .api)
        case .failure(let err):
            markImportedCodexFailure(id: account.id, message: err.description, error: err)
        }
    }

    /// 按需拉取指定导入账号的额外「Full reset」credit(wham/rate-limit-reset-credits)。
    /// 懒加载:仅供设置页展开时调用一次,不接入 Scheduler 定时刷新,也不写入持久化快照。
    func fetchImportedCodexResetCredits(account: ImportedCodexAccount) async -> Result<CodexResetCreditsClient.Fetched, QuotaError> {
        guard let tokens = ImportedCodexStore.loadTokens(accountId: account.id) else {
            return .failure(.missingToken)
        }
        let isPAT = account.isPersonalAccessToken == true
        let activeToken: String
        if isPAT {
            activeToken = tokens.accessToken
        } else {
            let refreshed = await CodexTokenRefresher.ensureFreshAccessToken(
                currentAccessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                writeBack: .importedAccount(id: account.id)
            )
            switch refreshed {
            case .success(let t):
                activeToken = t
            case .failure(let err):
                return .failure(err)
            }
        }
        return await CodexResetCreditsClient.fetch(
            accessToken: activeToken,
            accountId: isPAT ? nil : account.chatgptAccountId
        )
    }

    /// 按需拉取当前 CLI 主账号的额外「Full reset」credit。
    /// 与 `fetchImportedCodexResetCredits` 对称:懒加载,仅供设置页展开时调用一次,
    /// 不接入 Scheduler 定时刷新,也不写入持久化快照。
    func fetchCodexResetCredits() async -> Result<CodexResetCreditsClient.Fetched, QuotaError> {
        guard let account = codexAccount, let token = account.accessToken else {
            return .failure(.missingToken)
        }
        let activeToken: String
        if account.isPersonalAccessToken {
            activeToken = token
        } else {
            let refreshed = await CodexTokenRefresher.ensureFreshAccessToken(
                currentAccessToken: token,
                refreshToken: account.refreshToken,
                writeBack: .codexAuthJSON
            )
            switch refreshed {
            case .success(let t):
                activeToken = t
            case .failure(let err):
                return .failure(err)
            }
        }
        return await CodexResetCreditsClient.fetch(
            accessToken: activeToken,
            accountId: account.isPersonalAccessToken ? nil : account.accountId
        )
    }

    /// 判断某导入账号是否与当前 CLI 主账号是同一身份(accountId 相等,且 userId 相等或有一方缺失)。
    /// 展示层(Popover / 统计页)据此对同一身份去重,只显示一次;设置页作为管理界面不去重。
    func importedCodexAccountMirrorsPrimary(_ account: ImportedCodexAccount) -> Bool {
        guard let primary = codexAccount,
              let primaryAccountId = nonEmpty(primary.accountId),
              let importedAccountId = nonEmpty(account.chatgptAccountId),
              primaryAccountId == importedAccountId
        else { return false }

        let primaryUserId = nonEmpty(primary.chatgptUserId)
        let importedUserId = importedCodexUserId(from: account)
        if let primaryUserId, let importedUserId {
            return primaryUserId == importedUserId
        }
        return true
    }

    private func importedCodexUserId(from account: ImportedCodexAccount) -> String? {
        guard let colon = account.id.firstIndex(of: ":") else { return nil }
        let tail = String(account.id[account.id.index(after: colon)...])
        return nonEmpty(tail)
    }

    private func mirrorPrimaryCodexQuota(toImportedId id: String) {
        importedCodexQuotas[id] = codexQuota
        importedCodexSources[id] = codexQuotaSource
        importedCodexErrors[id] = codexQuotaError
        importedCodexRefreshStates[id] = codexRefreshState

        if let snapshot = codexQuota, codexQuotaSource == .api {
            recordImportedCodexQuotaHistory(
                id: id,
                snapshot: snapshot,
                sampledAt: codexRefreshState.lastSuccessAt ?? Date()
            )
        }

        var cache = quotaCache.importedCodex ?? [:]
        if cache.removeValue(forKey: id) != nil {
            quotaCache.importedCodex = cache.isEmpty ? nil : cache
            saveQuotaCache()
        }
    }

    private func syncPrimaryCodexTokensToImported(id: String) {
        guard let account = codexAccount,
              let accessToken = nonEmpty(account.accessToken)
        else { return }
        let tokens = ImportedCodexTokens(
            accessToken: accessToken,
            refreshToken: nonEmpty(account.refreshToken),
            idToken: nonEmpty(account.idToken)
        )
        do {
            try ImportedCodexStore.saveTokens(tokens, accountId: id)
        } catch {
            print("[imported-codex] sync primary tokens failed: \(error)")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func beginImportedCodexRefresh(id: String, reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        guard !state.inFlight else { return false }
        if let backoffUntil = state.backoffUntil, backoffUntil > now {
            state.lastError = backoffMessage(until: backoffUntil)
            importedCodexRefreshStates[id] = state
            importedCodexErrors[id] = state.lastError
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = state.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        state.inFlight = true
        state.lastAttemptAt = now
        importedCodexRefreshStates[id] = state
        return true
    }

    private func storeImportedCodex(id: String, snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(
            from: importedCodexQuotas[id],
            now: updatedAt
        )
        importedCodexQuotas[id] = mergedSnapshot
        importedCodexSources[id] = source
        importedCodexErrors[id] = nil
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastSuccessAt = updatedAt
        state.lastError = nil
        state.backoffUntil = nil
        state.source = source
        importedCodexRefreshStates[id] = state

        var cache = quotaCache.importedCodex ?? [:]
        cache[id] = QuotaCacheRecord(snapshot: mergedSnapshot, source: source, updatedAt: updatedAt)
        quotaCache.importedCodex = cache
        saveQuotaCache()
        recordImportedCodexQuotaHistory(id: id, snapshot: mergedSnapshot, sampledAt: updatedAt)
    }

    private func markImportedCodexFailure(id: String, message: String, error: QuotaError? = nil) {
        importedCodexErrors[id] = message
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastError = message
        if error?.isRateLimited == true {
            state.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
        importedCodexRefreshStates[id] = state
    }

    private func saveQuotaCache() {
        do {
            try QuotaCache.save(quotaCache)
        } catch {
            print("[QuotaCache 额度缓存] 写盘失败 save failed: \(error)")
        }
    }

    private func recordCodexQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexPrimary(accountId: codexAccount?.accountId),
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordClaudeQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.claudePrimary(),
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordGrokQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.grokPrimary(userId: grokAccount?.userId),
            app: .grok,
            kind: .grokPrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordImportedCodexQuotaHistory(id: String, snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexImported(id: id),
            app: .codex,
            kind: .codexImported,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordQuotaHistory(
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) {
        let next = QuotaHistoryStore.record(
            payload: quotaHistory,
            accountKey: accountKey,
            app: app,
            kind: kind,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
        guard next != quotaHistory else { return }
        quotaHistory = next
        saveQuotaHistory()
    }

    private func saveQuotaHistory() {
        do {
            try QuotaHistoryStore.save(quotaHistory)
        } catch {
            print("[QuotaHistory 额度历史] 写盘失败 save failed: \(error)")
        }
    }

    private func loadCodex() async {
        do {
            var next = try await Task.detached(priority: .utility) {
                try CodexAuth.load()
            }.value
            if codexIdentityChanged(previous: codexAccount, next: next) {
                resetCodexQuotaState()
            } else if next.isPersonalAccessToken, let prev = codexAccount {
                // PAT 身份靠首次取数回填，重读 auth.json 时这些字段为空。
                // 同一令牌未变则沿用上次回填的身份，避免 UI 抖动 / 误判账号切换。
                next.email = next.email ?? prev.email
                next.planType = next.planType ?? prev.planType
                next.accountId = next.accountId ?? prev.accountId
                next.chatgptUserId = next.chatgptUserId ?? prev.chatgptUserId
            }
            self.codexAccount = next
            self.codexError = nil
        } catch {
            self.codexAccount = nil
            self.codexError = "\(error)"
        }
    }

    /// 比较 accountId 优先,缺失时回退到 email。仅当能确认"前后是不同账号"
    /// 时返回 true;previous 为 nil(首次加载)不算变化,避免误清启动缓存。
    private func codexIdentityChanged(previous: CodexAccount?, next: CodexAccount) -> Bool {
        guard let previous else { return false }
        // PAT 账号 email/account_id 由取数回填，重载时为空，不能据此判定切换；
        // 任一侧为 PAT 时以令牌本身判定身份。
        if previous.isPersonalAccessToken || next.isPersonalAccessToken {
            return previous.accessToken != next.accessToken
        }
        if let a = previous.accountId, let b = next.accountId, !a.isEmpty, !b.isEmpty {
            return a != b
        }
        return previous.email != next.email
    }

    private func resetCodexQuotaState() {
        codexQuota = nil
        codexQuotaSource = nil
        codexQuotaError = nil
        codexRefreshState = QuotaRefreshState()
        quotaCache.codex = nil
        saveQuotaCache()
    }

    /// 没有本地凭据文件、且尚未提示过时,先用一个模态 alert 告诉用户
    /// 接下来会弹出系统 Keychain 授权窗口,避免一上来就被系统弹窗吓到。
    private func maybeShowKeychainPrompt() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let hasFile = FileManager.default.fileExists(atPath: url.path)
        let settings = SettingsStore.shared
        guard !hasFile, !settings.didShowKeychainPrompt else { return }

        let alert = NSAlert()
        alert.messageText = tr("Allow Keychain Access", "允许访问 Keychain")
        alert.informativeText = tr(
            "CCBar reads the Claude credential stored in your macOS Keychain to query your quota. After you continue, macOS will ask for permission — choose \"Always Allow\".",
            "CCBar 需要读取 macOS 钥匙串里的 Claude 凭据来查询额度。点击「继续」后会弹出系统授权窗口,请选择「始终允许」。"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("Continue", "继续"))
        alert.runModal()
        settings.didShowKeychainPrompt = true
    }

    private func loadClaude() async {
        do {
            let next = try await Task.detached(priority: .utility) {
                try ClaudeAuth.load()
            }.value
            if claudeIdentityChanged(previous: claudeAccount, next: next) {
                resetClaudeQuotaState()
            }
            self.claudeAccount = next
            self.claudeError = nil
        } catch {
            self.claudeAccount = nil
            self.claudeError = "\(error)"
        }
    }

    private func claudeIdentityChanged(previous: ClaudeAccount?, next: ClaudeAccount) -> Bool {
        guard let previous else { return false }
        return previous.email != next.email
    }

    private func resetClaudeQuotaState() {
        claudeQuota = nil
        claudeQuotaSource = nil
        claudeQuotaError = nil
        claudeRefreshState = QuotaRefreshState()
        quotaCache.claude = nil
        saveQuotaCache()
    }

    private func loadGrok() async {
        do {
            var next = try await Task.detached(priority: .utility) {
                try GrokAuth.load()
            }.value
            if grokIdentityChanged(previous: grokAccount, next: next) {
                resetGrokQuotaState()
            } else if next.planType == nil, let prevPlan = grokAccount?.planType {
                // 重读 auth.json 不会带订阅档；保留上一次从 API 回填的 plan。
                next.planType = prevPlan
            }
            self.grokAccount = next
            self.grokError = nil
            // 设置页要立刻显示 subscription（类似 Claude 凭据里的 subscriptionType），
            // 不必等周期性额度刷新。
            await enrichGrokSubscriptionIfNeeded()
        } catch {
            self.grokAccount = nil
            self.grokError = "\(error)"
        }
    }

    /// 用 `/rest/subscriptions` 补全 `planType`，失败静默（额度刷新仍会再试）。
    private func enrichGrokSubscriptionIfNeeded() async {
        guard var account = grokAccount, account.planType == nil,
              let token = account.accessToken, !token.isEmpty
        else { return }
        // 先确保 token 可用，避免刚启动时 access 已过期。
        let refreshed = await GrokTokenRefresher.ensureFreshAccessToken(account: &account)
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
            if t != grokAccount?.accessToken {
                grokAccount = account
            }
        case .failure:
            return
        }
        switch await GrokQuotaClient.fetchSubscriptionDisplayName(accessToken: activeToken) {
        case .success(let plan):
            guard var current = grokAccount else { return }
            current.planType = plan
            grokAccount = current
        case .failure:
            break
        }
    }

    private func grokIdentityChanged(previous: GrokAccount?, next: GrokAccount) -> Bool {
        guard let previous else { return false }
        if let a = previous.userId, let b = next.userId, !a.isEmpty, !b.isEmpty {
            return a != b
        }
        return previous.email != next.email
    }

    private func resetGrokQuotaState() {
        grokQuota = nil
        grokQuotaSource = nil
        grokQuotaError = nil
        grokRefreshState = QuotaRefreshState()
        quotaCache.grok = nil
        saveQuotaCache()
    }

    private func loadCodexQuota(reason: QuotaRefreshReason) async {
        guard beginCodexRefresh(reason: reason) else { return }
        defer { codexRefreshState.inFlight = false }

        guard var account = codexAccount else {
            markCodexFailure("no codex account")
            return
        }
        guard let token = account.accessToken else {
            markCodexFailure(QuotaError.missingToken.description)
            return
        }

        let activeToken: String
        if account.isPersonalAccessToken {
            // personal access token 不透明、无 exp / refresh，直接用，跳过 OAuth 续期。
            activeToken = token
        } else {
            let refreshed = await CodexTokenRefresher.ensureFreshTokens(
                currentAccessToken: token,
                refreshToken: account.refreshToken,
                idToken: account.idToken
            )
            switch refreshed {
            case .success(let t):
                activeToken = t.accessToken
                account.accessToken = t.accessToken
                account.refreshToken = nonEmpty(t.refreshToken)
                account.idToken = t.idToken
                codexAccount = account
            case .failure(let err):
                markCodexFailure(err.description)
                return
            }
        }

        // PAT 令牌已绑定账号，无需（也无法）带 JWT 解析出的 account_id header。
        let result = await CodexQuotaClient.fetch(
            accessToken: activeToken,
            accountId: account.isPersonalAccessToken ? nil : account.accountId
        )
        switch result {
        case .success(let fetched):
            if account.isPersonalAccessToken {
                // 用 wham/usage 响应回填身份，供 UI 展示与额度历史 key 使用。
                account.email = account.email ?? fetched.email
                account.planType = account.planType ?? fetched.snapshot.planType
                account.accountId = account.accountId ?? fetched.accountId
                account.chatgptUserId = account.chatgptUserId ?? fetched.userId
                codexAccount = account
            }
            storeCodex(snapshot: fetched.snapshot, source: .api)
        case .failure(let err):
            markCodexFailure(err.description, error: err)
        }
    }

    private func loadClaudeQuota(reason: QuotaRefreshReason) async {
        guard beginClaudeRefresh(reason: reason) else { return }
        defer { claudeRefreshState.inFlight = false }

        guard var account = claudeAccount else {
            markClaudeFailure("no claude account")
            return
        }
        guard account.accessToken != nil else {
            markClaudeFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await ClaudeTokenRefresher.ensureFreshAccessToken(account: &account)
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
            if t != claudeAccount?.accessToken {
                claudeAccount = account
            }
        case .failure(let err):
            markClaudeFailure(err.description, error: err)
            return
        }
        let result = await ClaudeQuotaClient.fetch(accessToken: activeToken)
        switch result {
        case .success(let snapshot):
            storeClaude(snapshot: snapshot, source: .api)
        case .failure(let err):
            markClaudeFailure(err.description, error: err)
            if reason == .userInitiated, claudeQuota == nil {
                await loadClaudeCLIFallback(apiError: err)
            }
        }
    }

    private func loadGrokQuota(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showGrok else { return }
        guard beginGrokRefresh(reason: reason) else { return }
        defer { grokRefreshState.inFlight = false }

        guard var account = grokAccount else {
            markGrokFailure("no grok account")
            return
        }
        guard account.accessToken != nil else {
            markGrokFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await GrokTokenRefresher.ensureFreshAccessToken(account: &account)
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
            if t != grokAccount?.accessToken {
                grokAccount = account
            }
        case .failure(let err):
            if err.isAuthRevoked {
                markGrokFailure(
                    "Grok 登录已失效,请在终端运行 grok login 重新登录后再回来刷新",
                    error: err
                )
            } else {
                markGrokFailure(err.description, error: err)
            }
            return
        }
        let result = await GrokQuotaClient.fetch(accessToken: activeToken)
        switch result {
        case .success(let fetched):
            if let plan = fetched.planType, !plan.isEmpty, account.planType != plan {
                account.planType = plan
                grokAccount = account
            }
            storeGrok(snapshot: fetched.snapshot, source: .api)
        case .failure(let err):
            markGrokFailure(err.description, error: err)
        }
    }

    private func loadAntigravityQuota(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showAntigravity else { return }
        guard beginAntigravityRefresh(reason: reason) else { return }
        defer { antigravityRefreshState.inFlight = false }

        let availability = await AntigravityQuotaClient.detectAvailability()
        antigravityAvailability = availability
        guard availability == .running else {
            let message: String
            switch availability {
            case .notInstalled:
                message = "未检测到 Antigravity"
            case .installed:
                message = "Antigravity 未运行"
            case .unavailable(let detail):
                message = detail
            case .running:
                message = "Antigravity 本地服务不可用"
            }
            markAntigravityFailure(message)
            return
        }

        let result = await AntigravityQuotaClient.fetch()
        switch result {
        case .success(let fetched):
            if let previousEmail = antigravityAccount?.email,
               let nextEmail = fetched.account.email,
               !previousEmail.isEmpty,
               !nextEmail.isEmpty,
               previousEmail != nextEmail
            {
                antigravityQuota = nil
                antigravityQuotaSource = nil
                quotaCache.antigravity = nil
            }
            antigravityAccount = fetched.account
            antigravityAvailability = .running
            storeAntigravity(snapshot: fetched.snapshot, source: .local)
        case .failure(let error):
            antigravityAvailability = .unavailable(error.description)
            markAntigravityFailure(error.description, error: error)
        }
    }

    private func loadClaudeCLIFallback(apiError: QuotaError) async {
        let now = Date()
        if let claudeFallbackBackoffUntil, claudeFallbackBackoffUntil > now {
            markClaudeFailure("\(apiError.description); cli fallback cooling down until \(claudeFallbackBackoffUntil)")
            return
        }

        claudeFallbackBackoffUntil = now.addingTimeInterval(rateLimitBackoff)
        let result = await ClaudeCLIFallbackQuotaClient.fetch()
        switch result {
        case .success(let snapshot):
            storeClaude(snapshot: snapshot, source: .cliFallback)
        case .failure(let err):
            markClaudeFailure("\(apiError.description); cli fallback failed: \(err.description)", error: err)
        }
    }

    private func beginCodexRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !codexRefreshState.inFlight else { return false }
        if let backoffUntil = codexRefreshState.backoffUntil, backoffUntil > now {
            markCodexFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = codexRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        codexRefreshState.inFlight = true
        codexRefreshState.lastAttemptAt = now
        return true
    }

    private func beginClaudeRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !claudeRefreshState.inFlight else { return false }
        if let backoffUntil = claudeRefreshState.backoffUntil, backoffUntil > now {
            markClaudeFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = claudeRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        claudeRefreshState.inFlight = true
        claudeRefreshState.lastAttemptAt = now
        return true
    }

    private func beginGrokRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !grokRefreshState.inFlight else { return false }
        if let backoffUntil = grokRefreshState.backoffUntil, backoffUntil > now {
            markGrokFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = grokRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        grokRefreshState.inFlight = true
        grokRefreshState.lastAttemptAt = now
        return true
    }

    private func beginAntigravityRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !antigravityRefreshState.inFlight else { return false }
        if let backoffUntil = antigravityRefreshState.backoffUntil, backoffUntil > now {
            markAntigravityFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = antigravityRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        antigravityRefreshState.inFlight = true
        antigravityRefreshState.lastAttemptAt = now
        return true
    }

    private func storeCodex(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(from: codexQuota, now: updatedAt)
        codexQuota = mergedSnapshot
        codexQuotaSource = source
        codexQuotaError = nil
        codexRefreshState.lastSuccessAt = updatedAt
        codexRefreshState.lastError = nil
        codexRefreshState.backoffUntil = nil
        codexRefreshState.source = source
        quotaCache.codex = QuotaCacheRecord(snapshot: mergedSnapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordCodexQuotaHistory(snapshot: mergedSnapshot, sampledAt: updatedAt)
    }

    private func storeClaude(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(from: claudeQuota, now: updatedAt)
        claudeQuota = mergedSnapshot
        claudeQuotaSource = source
        claudeQuotaError = nil
        claudeRefreshState.lastSuccessAt = updatedAt
        claudeRefreshState.lastError = nil
        if source == .api {
            claudeRefreshState.backoffUntil = nil
        }
        claudeRefreshState.source = source
        quotaCache.claude = QuotaCacheRecord(snapshot: mergedSnapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordClaudeQuotaHistory(snapshot: mergedSnapshot, sampledAt: updatedAt)
    }

    private func storeAntigravity(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(from: antigravityQuota, now: updatedAt)
        antigravityQuota = mergedSnapshot
        antigravityQuotaSource = source
        antigravityQuotaError = nil
        antigravityRefreshState.lastSuccessAt = updatedAt
        antigravityRefreshState.lastError = nil
        antigravityRefreshState.backoffUntil = nil
        antigravityRefreshState.source = source
        quotaCache.antigravity = QuotaCacheRecord(
            snapshot: mergedSnapshot,
            source: source,
            updatedAt: updatedAt
        )
        saveQuotaCache()
    }

    private func storeGrok(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(from: grokQuota, now: updatedAt)
        grokQuota = mergedSnapshot
        grokQuotaSource = source
        grokQuotaError = nil
        grokRefreshState.lastSuccessAt = updatedAt
        grokRefreshState.lastError = nil
        if source == .api {
            grokRefreshState.backoffUntil = nil
        }
        grokRefreshState.source = source
        quotaCache.grok = QuotaCacheRecord(
            snapshot: mergedSnapshot,
            source: source,
            updatedAt: updatedAt
        )
        saveQuotaCache()
        recordGrokQuotaHistory(snapshot: mergedSnapshot, sampledAt: updatedAt)
    }

    private func markCodexFailure(_ message: String, error: QuotaError? = nil) {
        codexQuotaError = message
        codexRefreshState.lastError = message
        if error?.isRateLimited == true {
            codexRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func markClaudeFailure(_ message: String, error: QuotaError? = nil) {
        claudeQuotaError = message
        claudeRefreshState.lastError = message
        if error?.isRateLimited == true {
            claudeRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func markAntigravityFailure(_ message: String, error: QuotaError? = nil) {
        antigravityQuotaError = message
        antigravityRefreshState.lastError = message
        if error?.isRateLimited == true {
            antigravityRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func markGrokFailure(_ message: String, error: QuotaError? = nil) {
        grokQuotaError = message
        grokRefreshState.lastError = message
        if error?.isRateLimited == true {
            grokRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func backoffMessage(until: Date) -> String {
        "rate limited; retry in \(relativeAge(until: until))"
    }

    private func logCredentialSummary() {
        if let c = codexAccount {
            print("[Credentials 凭据] Codex: email=\(c.email ?? "—") plan=\(c.planType ?? "—") account_id=\(c.accountId ?? "—") expiredGuess=\(c.expiredGuess) hasAccessToken=\(c.accessToken != nil) hasRefreshToken=\(c.refreshToken != nil)")
        } else {
            print("[Credentials 凭据] Codex 未加载: error=\(codexError ?? "unknown")")
        }
        if let c = claudeAccount {
            print("[Credentials 凭据] Claude: source=\(c.source.rawValue) email=\(c.email ?? "—") plan=\(c.subscriptionType ?? "—") expiresAt=\(c.expiresAt.map { "\($0)" } ?? "—") expiredGuess=\(c.expiredGuess) hasAccessToken=\(c.accessToken != nil)")
        } else {
            print("[Credentials 凭据] Claude 未加载: error=\(claudeError ?? "unknown")")
        }
        switch antigravityAvailability {
        case .running:
            print("[Credentials 凭据] Antigravity: local language server running")
        case .installed:
            print("[Credentials 凭据] Antigravity 已安装但未运行")
        case .notInstalled:
            print("[Credentials 凭据] Antigravity 未安装")
        case .unavailable(let detail):
            print("[Credentials 凭据] Antigravity 检测失败: \(detail)")
        }
        if let g = grokAccount {
            print("[Credentials 凭据] Grok: email=\(g.email ?? "—") plan=\(g.planType ?? "—") user_id=\(g.userId ?? "—") expiredGuess=\(g.expiredGuess) hasAccessToken=\(g.accessToken != nil)")
        } else {
            print("[Credentials 凭据] Grok 未加载: error=\(grokError ?? "unknown")")
        }
    }

    private func logQuotaSummary() {
        if let q = codexQuota {
            print("[Quota 额度] Codex: source=\(codexQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
        } else {
            print("[Quota 额度] Codex 拉取失败: error=\(codexQuotaError ?? "unknown")")
        }
        if let q = claudeQuota {
            print("[Quota 额度] Claude: source=\(claudeQuotaSource?.rawValue ?? "—") \(format(q))")
            for limit in q.modelLimits {
                print("       └─ \(limit.displayName ?? limit.id)=\(format(window: limit.window))")
            }
        } else {
            print("[Quota 额度] Claude 拉取失败: error=\(claudeQuotaError ?? "unknown")")
        }
        if let q = antigravityQuota {
            print("[Quota 额度] Antigravity: source=\(antigravityQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
        } else {
            print("[Quota 额度] Antigravity 拉取失败: error=\(antigravityQuotaError ?? "unknown")")
        }
        if let q = grokQuota {
            print("[Quota 额度] Grok: source=\(grokQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
            for limit in q.modelLimits {
                print("       └─ \(limit.displayName ?? limit.id)=\(format(window: limit.window))")
            }
        } else {
            print("[Quota 额度] Grok 拉取失败: error=\(grokQuotaError ?? "unknown")")
        }
    }

    private func format(_ q: QuotaSnapshot) -> String {
        let parts = [
            q.primaryLimit.map { "primary[\($0.kind.rawValue)]=\(format(window: $0.window))" },
            q.secondaryLimit.map { "secondary[\($0.kind.rawValue)]=\(format(window: $0.window))" }
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    private func format(window w: QuotaWindow) -> String {
        let pct = String(format: "%.1f%% left", w.remainingPercent)
        let reset: String
        if let r = w.resetsAt {
            let mins = Int(r.timeIntervalSinceNow / 60)
            reset = mins > 0 ? "resets in ~\(mins)m" : "resets now"
        } else {
            reset = "resets ?"
        }
        return "\(pct) (\(reset))"
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private func relativeAge(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(Date())))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private func shortError(_ error: String) -> String {
        let oneLine = error.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 120 { return oneLine }
        return String(oneLine.prefix(117)) + "..."
    }
}
