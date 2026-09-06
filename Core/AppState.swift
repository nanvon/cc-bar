import AppKit
import Foundation
import Observation

// MARK: - UpdateStatus

/// 设置页「检查更新」的展示状态。`checking` 时不再重复发起请求(去重)。
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(latest: String)
    case updateAvailable(version: String)
    case failed
    /// GitHub 匿名 API 额度被当前出口 IP 用尽,与普通失败区分展示,提示用户稍后重试。
    case rateLimited
}

@Observable
@MainActor
final class AppState {
    var codexAccount: CodexAccount?
    var claudeAccount: ClaudeAccount?
    var antigravityAccount: AntigravityAccount?
    // 账号态同步给设置层：Cursor 未安装 / 未登录时统计页不再渲染空的 Cursor 服务行，
    // 用户的统计开关偏好本身保留，重新登录后自动恢复（见 SettingsStore.cursorAccountDetected）。
    var cursorAccount: CursorAuthSession? {
        didSet { SettingsStore.shared.cursorAccountDetected = cursorAccount != nil }
    }
    var commandCodeAccount: CommandCodeAuthSession? {
        didSet { SettingsStore.shared.commandCodeAccountDetected = commandCodeAccount != nil }
    }
    var codexError: String?
    var claudeError: String?
    var antigravityError: String?
    var cursorError: String?
    var commandCodeError: String?

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
    var codexQuotaError: String? {
        get { quotaError(for: .codex) }
        set { updatePrimaryState(.codex) { $0.error = newValue } }
    }
    var claudeQuotaError: String? {
        get { quotaError(for: .claude) }
        set { updatePrimaryState(.claude) { $0.error = newValue } }
    }
    var codexQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .codex) }
        set { updatePrimaryState(.codex) { $0.source = newValue } }
    }
    var claudeQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .claude) }
        set { updatePrimaryState(.claude) { $0.source = newValue } }
    }
    var codexRefreshState: QuotaRefreshState {
        get { refreshState(for: .codex) }
        set { updatePrimaryState(.codex) { $0.refresh = newValue } }
    }
    var claudeRefreshState: QuotaRefreshState {
        get { refreshState(for: .claude) }
        set { updatePrimaryState(.claude) { $0.refresh = newValue } }
    }
    var cursorQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .cursor) }
        set { updatePrimaryState(.cursor) { $0.snapshot = newValue } }
    }
    var cursorQuotaError: String? {
        get { quotaError(for: .cursor) }
        set { updatePrimaryState(.cursor) { $0.error = newValue } }
    }
    var cursorQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .cursor) }
        set { updatePrimaryState(.cursor) { $0.source = newValue } }
    }
    var cursorRefreshState: QuotaRefreshState {
        get { refreshState(for: .cursor) }
        set { updatePrimaryState(.cursor) { $0.refresh = newValue } }
    }
    var antigravityQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.snapshot = newValue } }
    }
    var antigravityQuotaError: String? {
        get { quotaError(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.error = newValue } }
    }
    var antigravityQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.source = newValue } }
    }
    var antigravityRefreshState: QuotaRefreshState {
        get { refreshState(for: .antigravity) }
        set { updatePrimaryState(.antigravity) { $0.refresh = newValue } }
    }
    var commandCodeQuota: QuotaSnapshot? {
        get { quotaSnapshot(for: .commandCode) }
        set { updatePrimaryState(.commandCode) { $0.snapshot = newValue } }
    }
    var commandCodeQuotaError: String? {
        get { quotaError(for: .commandCode) }
        set { updatePrimaryState(.commandCode) { $0.error = newValue } }
    }
    var commandCodeQuotaSource: QuotaSnapshotSource? {
        get { quotaSource(for: .commandCode) }
        set { updatePrimaryState(.commandCode) { $0.source = newValue } }
    }
    var commandCodeRefreshState: QuotaRefreshState {
        get { refreshState(for: .commandCode) }
        set { updatePrimaryState(.commandCode) { $0.refresh = newValue } }
    }
    var quotaHistory = QuotaHistoryPayload()
    var quotaCycles = QuotaCyclePayload()

    var codexTodayCost: Decimal?
    var claudeTodayCost: Decimal?
    var cursorTodayCost: Decimal?
    var piTodayCost: Decimal?
    var opencodeTodayCost: Decimal?

    /// OpenAI / Anthropic / Cursor statuspage.io 最新快照,失败时保留上一份。
    var codexServiceStatus: ServiceStatus?
    var claudeServiceStatus: ServiceStatus?
    var cursorServiceStatus: ServiceStatus?

    let usageService = UsageService()
    private let scheduler = Scheduler()
    private var didBootstrap = false
    private var quotaCache = QuotaCachePayload()
    private var claudeFallbackBackoffUntil: Date?
    /// 批次 C：本轮标脏的额度持久化文件，刷新 / bootstrap / 设置操作末尾统一落盘。
    private var dirtyQuotaFiles: Set<QuotaFile> = []
    /// load 时被超长自检修复的周期 ID；在启动扫描后触发受限重建。
    private var pendingCycleRepairs: Set<String> = []
    /// 批次 C：额度持久化 coordinator，编码与原子写移出 MainActor。
    private let quotaPersistenceCoordinator = QuotaPersistenceCoordinator()
    /// 批次 C：持久化提交的单调递增序列号。`Task.detached` 的执行顺序无语言保证，
    /// 序列号用于让 coordinator 丢弃乱序到达的过期快照，防止旧数据覆盖新数据。
    private var persistenceSequence: UInt64 = 0
    /// quota-history 的最短写盘间隔。每次采样 `sampledAt` 都会前进，快照必然不等，
    /// 因此它会跟着额度刷新频率被整份重写——本机实测 220KB，2 分钟一次就是每小时
    /// 6.6MB。它只承载历史曲线，当前额度由 quota-cache（数 KB）承载，
    /// 丢几个采样点对用户没有实质影响，所以单独限速。cache / cycles 体量小或本就不常变，
    /// 不受这里限制。
    private static let quotaHistoryWriteInterval: TimeInterval = 15 * 60
    private var lastQuotaHistoryWriteAt: Date?

    /// `refreshNow()` 的去重锁。同一时刻只允许一个真正在跑的整体刷新;
    /// 期间额外的 `refreshNow()` 调用立即返回(no-op),不再排队。
    /// UI 的"刷新按钮"依然每点必转图标,只是不会真的发起重复请求。
    private var refreshInFlight: Task<Void, Never>?

    /// 是否有一次由 `refreshNow()` 发起的整体刷新正在进行(用户点击 popover 刷新按钮或按 ⌘R)。
    /// popover 用它统一驱动刷新按钮的转圈动画,让两个入口的视觉反馈一致。
    /// 周期性后台刷新(Scheduler 的 quotaLoop/usageLoop)不走 `refreshNow()`,不会触发这个信号。
    var isRefreshing: Bool { refreshInFlight != nil }

    /// 设置页「检查更新」状态;初始 idle,首次检查前不显示任何文案。
    var updateStatus: UpdateStatus = .idle

    private let minSuccessInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 10 * 60

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        loadQuotaCache()
        loadQuotaHistory()
        loadQuotaCycles()
        reloadImportedCodexAccounts()
        await usageService.bootstrap(appState: self)
        await loadCodex()
        maybeShowKeychainPrompt()
        await loadClaude()
        await loadAntigravity()
        // Cursor 只读本机 SQLite，用于账号页和 Onboarding 的登录态检测；
        // 是否请求其远端额度仍由 Provider / Stats 开关控制。
        await loadCursor()
        await loadCommandCode()
        recordCachedQuotaCycleObservations()
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
        Task {
            await usageService.scanNow()
            await usageService.rebuildCycleUsageIfNeeded()
            // load 时修复过超长周期记录：旧 rollup 桶按污染窗口切分过，必须重算。
            // 放在初始重建之后，避免与全量重建的桶清空互相干扰（两者都能自愈，
            // 前一置位后一幂等）。
            // 两种情况都只需要一次受限重建（最近 `rebuildWindowDays` 天）：
            // 超长周期被回写起点，或启动时丢弃过落在窗口内的孤儿周期桶。
            if !pendingCycleRepairs.isEmpty || usageService.hasPendingOrphanCycleRebuild {
                pendingCycleRepairs = []
                await usageService.rebuildCycleUsageForRecentChanges()
            }
        }
        // 启动后异步拉一次服务状态;后续由 Scheduler 5 分钟刷新一次
        Task { await refreshServiceStatus() }
        // 启动时自动检查更新(可在设置中关闭)。延迟几秒避开启动高峰,不阻塞 bootstrap;
        // 检查结果由设置页「检查更新」行展示。
        if settings.autoCheckForUpdates {
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await checkForUpdates()
            }
        }
        // 启动 7 秒后打一次官方额度请求,让 Popover 尽快有最新额度(不阻塞 bootstrap)。
        // 走 .periodic:与定时刷新同规则,60s 最小间隔与 429 退避照常生效,不绕过限流;
        // 延迟期内的手动刷新会先置 inFlight,本任务到点后自动跳过。
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await refreshQuotas(reason: .periodic)
        }
        // 批次 C：bootstrap 期间标脏的额度文件统一落盘
        scheduleQuotaPersistenceFlush()
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

    /// 每次刷新(手动 / Scheduler 定时)只重读已启用主 Provider 的本地凭据,
    /// 以便用户在外部(如 cc-switch)切换账号后 ccbar 能感知到。
    /// loadCodex / loadClaude 内部会比较 accountId / email,若身份变化则清掉
    /// 旧的额度缓存,避免出现"新账号 + 旧额度"的错配。
    func refreshQuotas(reason: QuotaRefreshReason = .periodic) async {
        let plan = QuotaRefreshPlan.make(
            showCodex: SettingsStore.shared.showCodex,
            showClaude: SettingsStore.shared.showClaude,
            showAntigravity: SettingsStore.shared.showAntigravity,
            // Cursor 额度展示与远端统计可分别启用；任一入口启用后才允许网络刷新。
            // 这里刻意读用户偏好而不是 isUsageServiceEffectivelyVisible：后者依赖账号检测结果，
            // 账号一旦丢失就会把刷新链路一起关掉，从而再也检测不回来。
            showCursor: SettingsStore.shared.isProviderEnabled(.cursor)
                || SettingsStore.shared.isUsageServiceVisible(.cursor),
            showCommandCode: SettingsStore.shared.isProviderEnabled(.commandCode),
            hasVisibleImported: importedCodexAccounts.contains(where: \.visibleInPopover)
        )
        if plan.refreshCodex {
            await loadCodex()
            await loadCodexQuota(reason: reason)
        }
        if plan.refreshClaude {
            await loadClaude()
            await loadClaudeQuota(reason: reason)
        }
        if plan.refreshAntigravity {
            await loadAntigravity()
            await loadAntigravityQuota(reason: reason)
        }
        if plan.refreshCursor {
            await loadCursor()
            await loadCursorQuota(reason: reason)
            // 远端用量与额度是两个独立接口：usage-summary 失败、限流退避或返回空额度时，
            // get-filtered-usage-events 仍应照常拉取，否则统计页会永远停在"暂不可用"。
            // 节流由 UsageService 自己的 inFlight / backoff 负责，不复用额度的刷新门禁。
            await refreshCursorRemoteUsage(snapshot: cursorQuota)
        }
        if plan.refreshCommandCode {
            await loadCommandCode()
            await loadCommandCodeQuota(reason: reason)
        }
        if plan.refreshImported {
            await loadAllImportedCodexQuotas(
                reason: reason,
                canMirrorPrimary: plan.canMirrorPrimary
            )
        }
        logQuotaSummary()
        // 批次 C：本轮标脏的额度文件统一落盘（每文件每轮最多写一次）
        scheduleQuotaPersistenceFlush()
    }

    /// 拉取 OpenAI / Anthropic / Cursor statuspage 状态。失败保留旧快照,不清空。
    /// 三个请求并发,任意一个失败不影响其他。
    func refreshServiceStatus() async {
        async let codex = Self.fetchServiceStatus(url: ServiceStatusClient.openAIStatusURL, tag: "openai")
        async let claude = Self.fetchServiceStatus(url: ServiceStatusClient.anthropicStatusURL, tag: "anthropic")
        async let cursor = Self.fetchServiceStatus(url: ServiceStatusClient.cursorStatusURL, tag: "cursor")
        let codexResult = await codex
        let claudeResult = await claude
        let cursorResult = await cursor
        if let codexResult { codexServiceStatus = codexResult }
        if let claudeResult { claudeServiceStatus = claudeResult }
        if let cursorResult { cursorServiceStatus = cursorResult }
    }

    private static func fetchServiceStatus(url: URL, tag: String) async -> ServiceStatus? {
        do {
            return try await ServiceStatusClient.fetch(from: url)
        } catch {
            print("[service-status] \(tag) fetch failed: \(error)")
            return nil
        }
    }

    // MARK: - Update check

    /// 检查 GitHub 是否有新版本。`checking` 期间重复调用直接返回(与 refreshNow 同款去重);
    /// 失败置 `failed`,用户可再次点击重试。
    func checkForUpdates() async {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        do {
            let info = try await UpdateChecker.fetchLatestRelease()
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            if UpdateChecker.isNewer(tag: info.tag, than: current) {
                updateStatus = .updateAvailable(version: info.tag)
            } else {
                updateStatus = .upToDate(latest: info.tag)
            }
        } catch UpdateChecker.CheckError.rateLimited {
            print("[update-check] rate limited by GitHub")
            updateStatus = .rateLimited
        } catch {
            print("[update-check] fetch failed: \(error)")
            updateStatus = .failed
        }
    }

    /// 打开 GitHub Releases 下载页。
    func openReleasePage() {
        NSWorkspace.shared.open(UpdateChecker.releasePageURL)
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

    private func loadQuotaCycles() {
        let (payload, repairedCycleIDs) = QuotaCycleStore.load()
        quotaCycles = payload
        pendingCycleRepairs = repairedCycleIDs
        if !repairedCycleIDs.isEmpty {
            dirtyQuotaFiles.insert(.cycles)
        }
    }

    private func recordCachedQuotaCycleObservations() {
        let observedAt = Date()
        if let record = quotaCache.codex, codexAccount != nil {
            recordQuotaCycles(
                accountKey: QuotaHistoryAccountKey.codexPrimary(accountId: codexAccount?.accountId),
                app: .codex,
                snapshot: record.snapshot,
                source: .cache,
                sampledAt: observedAt
            )
        }
        if let record = quotaCache.claude, claudeAccount != nil {
            recordQuotaCycles(
                accountKey: QuotaHistoryAccountKey.claudePrimary(email: claudeAccount?.email),
                app: .claude,
                snapshot: record.snapshot,
                source: .cache,
                sampledAt: observedAt
            )
        }
        // Antigravity 暂无本地用量周期，仅记录额度历史，不参与 cycle 统计
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
        // 批次 C：设置操作产生的标脏立即落盘
        scheduleQuotaPersistenceFlush()
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
    private func loadAllImportedCodexQuotas(
        reason: QuotaRefreshReason,
        canMirrorPrimary: Bool
    ) async {
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
                        await self.loadImportedCodexQuota(
                            account: account,
                            reason: reason,
                            canMirrorPrimary: canMirrorPrimary
                        )
                    }
                }
            }
            index += maxConcurrent
        }
    }

    private func loadImportedCodexQuota(
        account: ImportedCodexAccount,
        reason: QuotaRefreshReason,
        canMirrorPrimary: Bool
    ) async {
        if canMirrorPrimary, importedCodexIdentityMatchesPrimary(account) {
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
        // 主 Provider 关闭时不能镜像内存里的旧快照；可见导入账号必须用自己的凭据独立刷新。
        guard SettingsStore.shared.showCodex else { return false }
        return importedCodexIdentityMatchesPrimary(account)
    }

    private func importedCodexIdentityMatchesPrimary(_ account: ImportedCodexAccount) -> Bool {
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
            try ImportedCodexStore.saveTokensIfChanged(tokens, accountId: id)
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

    /// 批次 C：只标记 cache 本轮有变化，实际编码与原子写由 flush 统一提交。
    private func saveQuotaCache() {
        dirtyQuotaFiles.insert(.cache)
    }

    /// 批次 C：只标记 history 本轮有变化，实际编码与原子写由 flush 统一提交。
    private func saveQuotaHistory() {
        dirtyQuotaFiles.insert(.history)
    }

    /// 批次 C：把本轮标脏的 quota 文件以不可变快照提交给持久化 coordinator。
    /// 非 async，所有写盘点（刷新 / bootstrap / 设置操作）都能直接调用；
    /// 编码与原子写在 utility 任务里执行，不再阻塞 MainActor。
    private func scheduleQuotaPersistenceFlush() {
        guard !dirtyQuotaFiles.isEmpty else { return }
        let now = Date()
        let historyDue = lastQuotaHistoryWriteAt.map {
            now.timeIntervalSince($0) >= Self.quotaHistoryWriteInterval
        } ?? true
        let writesCache = dirtyQuotaFiles.contains(.cache)
        let writesCycles = dirtyQuotaFiles.contains(.cycles)
        let writesHistory = dirtyQuotaFiles.contains(.history) && historyDue
        // 只有 history 脏、且还没到写盘间隔时，本轮什么都不用提交；脏标记留到下一轮。
        guard writesCache || writesCycles || writesHistory else { return }
        persistenceSequence &+= 1
        let snapshot = QuotaPersistenceCoordinator.Snapshot(
            sequence: persistenceSequence,
            cache: writesCache ? quotaCache : nil,
            history: writesHistory ? quotaHistory : nil,
            cycles: writesCycles ? quotaCycles : nil
        )
        if writesCache { dirtyQuotaFiles.remove(.cache) }
        if writesCycles { dirtyQuotaFiles.remove(.cycles) }
        if writesHistory {
            dirtyQuotaFiles.remove(.history)
            lastQuotaHistoryWriteAt = now
        }
        let coordinator = quotaPersistenceCoordinator
        Task.detached(priority: .utility) {
            await coordinator.submit(snapshot)
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
            accountKey: QuotaHistoryAccountKey.claudePrimary(email: claudeAccount?.email),
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordAntigravityQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.antigravityPrimary(email: antigravityAccount?.email),
            app: .antigravity,
            kind: .antigravityPrimary,
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

    private func recordQuotaCycles(
        accountKey: String,
        app: UsageApp,
        snapshot: QuotaSnapshot,
        source: QuotaSnapshotSource,
        sampledAt: Date
    ) {
        let next = QuotaCycleStore.record(
            payload: quotaCycles,
            accountKey: accountKey,
            app: app,
            snapshot: snapshot,
            source: source,
            sampledAt: sampledAt
        )
        guard next != quotaCycles else { return }
        let previousPartition = cycleUsagePartition(for: quotaCycles)
        let previousAccountSegments = quotaCycles.accountSegments
        quotaCycles = next
        dirtyQuotaFiles.insert(.cycles)
        if cycleUsagePartition(for: next) != previousPartition
            || next.accountSegments != previousAccountSegments
        {
            // 周期边界滚动后做受限重建（只重扫最近窗口），不再全量重扫历史日志。
            Task { await usageService.rebuildCycleUsageForRecentChanges() }
        }
    }

    private func cycleUsagePartition(for payload: QuotaCyclePayload) -> [String] {
        let now = Date()
        return payload.records.flatMap { cycle in
            // 活跃周期的右边界排除在指纹之外：服务端 resets_at 会持续漂移（实测 Codex
            // five-hour 近 1:1 跟随墙钟，39 分钟漂 2279 秒），任何有限容差都会被周期性
            // 击穿。而活跃周期的 endAt 只决定它还能容纳多少后续用量，不改变已归集用量的
            // 切分方式——新条目本来就由常规增量扫描持续灌入。把它计入指纹会让几乎每次
            // 额度采样都触发一次受限重建。周期结束后边界固定，指纹此时变化一次，
            // 那才是真正需要重灌的时刻。
            let boundary = cycle.isComplete(at: now)
                ? "\(cycle.endAt.timeIntervalSince1970)"
                : "active"
            let cycleBoundary = [
                "cycle|\(cycle.id)|\(cycle.startAt.timeIntervalSince1970)|\(boundary)",
            ]
            let allowanceBoundaries = cycle.allowanceSegments.map { segment in
                "allowance|\(segment.id)|\(segment.startAt.timeIntervalSince1970)|\(segment.endAt?.timeIntervalSince1970 ?? -1)"
            }
            return cycleBoundary + allowanceBoundaries
        }
        .sorted()
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
            migrateLegacyClaudeAccountData(
                to: QuotaHistoryAccountKey.claudePrimary(email: next.email)
            )
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

    private func migrateLegacyClaudeAccountData(to accountKey: String) {
        let nextHistory = QuotaHistoryStore.migratingLegacyClaudeAccountKey(
            quotaHistory,
            to: accountKey
        )
        if nextHistory != quotaHistory {
            quotaHistory = nextHistory
            dirtyQuotaFiles.insert(.history)
        }

        let nextCycles = QuotaCycleStore.migratingLegacyClaudeAccountKey(
            quotaCycles,
            to: accountKey
        )
        if nextCycles != quotaCycles {
            quotaCycles = nextCycles
            dirtyQuotaFiles.insert(.cycles)
        }
    }

    private func resetClaudeQuotaState() {
        claudeQuota = nil
        claudeQuotaSource = nil
        claudeQuotaError = nil
        claudeRefreshState = QuotaRefreshState()
        quotaCache.claude = nil
        saveQuotaCache()
    }

    private func loadAntigravity() async {
        do {
            var next = try await Task.detached(priority: .utility) {
                try AntigravityCredentials.load()
            }.value
            guard var next else {
                antigravityAccount = nil
                antigravityError = "未配置 Antigravity：请先在 VSCode/Antigravity CLI 中登录 Google 账号"
                return
            }
            if antigravityIdentityChanged(previous: antigravityAccount, next: next) {
                resetAntigravityQuotaState()
            } else if let prev = antigravityAccount {
                // 邮箱/plan 靠首次取数回填，重读 jetski 时这些字段为空。
                // 同一凭据未变则沿用上次回填的身份，避免 UI 抖动 / 误判账号切换。
                next.email = next.email ?? prev.email
                next.displayName = next.displayName ?? prev.displayName
                next.planType = next.planType ?? prev.planType
            }
            antigravityAccount = next
            antigravityError = nil
        } catch {
            antigravityAccount = nil
            antigravityError = "\(error)"
        }
    }

    private func antigravityIdentityChanged(previous: AntigravityAccount?, next: AntigravityAccount) -> Bool {
        guard let previous else { return false }
        if let a = previous.email, let b = next.email, !a.isEmpty, !b.isEmpty {
            return a != b
        }
        if let prevRef = previous.refreshToken, let nextRef = next.refreshToken {
            return prevRef != nextRef
        }
        return previous.accessToken != next.accessToken
    }

    private func resetAntigravityQuotaState() {
        antigravityQuota = nil
        antigravityQuotaSource = nil
        antigravityQuotaError = nil
        antigravityRefreshState = QuotaRefreshState()
        quotaCache.antigravity = nil
        saveQuotaCache()
    }

    private func loadCursor() async {
        do {
            let next = try await Task.detached(priority: .utility) {
                try CursorAuth.load()
            }.value
            guard let next else {
                cursorAccount = nil
                cursorError = "Cursor is not installed or is not signed in"
                return
            }

            let changedFromRuntime = cursorAccount.map {
                !$0.belongsToSameAccount(as: next)
            } ?? false
            let changedFromCache: Bool = {
                guard cursorAccount == nil,
                      let cachedID = quotaCache.cursor?.accountID?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ),
                      !cachedID.isEmpty
                else { return false }
                return cachedID.caseInsensitiveCompare(next.userID) != .orderedSame
            }()
            if changedFromRuntime || changedFromCache {
                resetCursorQuotaState()
            }

            cursorAccount = next
            usageService.activateCursorRemoteUsage(accountID: next.userID)
            cursorError = nil
        } catch {
            cursorAccount = nil
            cursorError = String(describing: error)
        }
    }

    private func resetCursorQuotaState() {
        cursorQuota = nil
        cursorQuotaSource = nil
        cursorQuotaError = nil
        cursorRefreshState = QuotaRefreshState()
        quotaCache.cursor = nil
        saveQuotaCache()
    }

    func loadCommandCode() async {
        let pref = SettingsStore.shared.commandCodeCredentialPreference
        let next = await Task.detached(priority: .utility) {
            CommandCodeAuth.load(preference: pref)
        }.value

        guard var next else {
            commandCodeAccount = nil
            commandCodeError = "未检测到 Command Code 登录态或 API Key"
            return
        }

        // 同一令牌未变时沿用上次回填的身份，避免 UI 抖动 / 误判账号切换
        if let prev = commandCodeAccount, prev.accessToken == next.accessToken {
            next.login = next.login ?? prev.login
            next.name = next.name ?? prev.name
            next.email = next.email ?? prev.email
            next.orgID = next.orgID ?? prev.orgID
            next.planType = next.planType ?? prev.planType
        }

        let changedFromRuntime = commandCodeAccount.map {
            $0.accountKey != next.accountKey
        } ?? false
        let changedFromCache: Bool = {
            guard commandCodeAccount == nil,
                  let cachedID = quotaCache.commandCode?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cachedID.isEmpty
            else { return false }
            return cachedID != next.accountKey
        }()
        if changedFromRuntime || changedFromCache {
            resetCommandCodeQuotaState()
        }

        commandCodeAccount = next
        commandCodeError = nil
    }

    private func resetCommandCodeQuotaState() {
        commandCodeQuota = nil
        commandCodeQuotaSource = nil
        commandCodeQuotaError = nil
        commandCodeRefreshState = QuotaRefreshState()
        quotaCache.commandCode = nil
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
            // 凭据过期时 cc-bar 不再自己刷新(会作废 Claude Code 的 refresh_token),
            // 用户手动刷新时改走 claude CLI 兜底取数——CLI 用自己的会话身份,
            // 刷新对它是安全的。已有快照会被 markClaudeFailure 保留,不会被清空。
            if err.isCredentialsExpired, reason == .userInitiated {
                await loadClaudeCLIFallback(apiError: err)
            }
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

    private func loadAntigravityQuota(reason: QuotaRefreshReason) async {
        guard beginAntigravityRefresh(reason: reason) else { return }
        defer { antigravityRefreshState.inFlight = false }

        guard var account = antigravityAccount else {
            markAntigravityFailure(antigravityError ?? "no antigravity account")
            return
        }
        guard account.accessToken != nil else {
            markAntigravityFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await AntigravityCredentials.ensureFreshAccessToken(account: &account)
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
            if t != antigravityAccount?.accessToken {
                antigravityAccount = account
            }
        case .failure(let err):
            markAntigravityFailure(err.description, error: err)
            return
        }
        let result = await AntigravityQuotaClient.fetch(accessToken: activeToken)
        switch result {
        case .success(let fetched):
            // 回填 plan；邮箱 jetski 本地解不出（非 JWT），额度链路成功后用 UserInfo
            // 单独回填一次，仅当仍未取得时再调用（避免每轮都打 UserInfo）。
            var email = fetched.account.email ?? account.email
            if email == nil {
                email = await AntigravityQuotaClient.fetchAccountEmail(accessToken: activeToken)
            }
            if let email {
                account.email = email
            }
            account.planType = fetched.account.planType ?? account.planType
            antigravityAccount = account
            let snapshot = fetched.snapshot
            storeAntigravity(snapshot: snapshot, source: .api)
        case .failure(let err):
            markAntigravityFailure(err.description, error: err)
        }
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
        quotaCache.antigravity = QuotaCacheRecord(snapshot: mergedSnapshot, source: source, updatedAt: updatedAt, accountID: antigravityAccount?.email)
        saveQuotaCache()
        recordAntigravityQuotaHistory(snapshot: mergedSnapshot, sampledAt: updatedAt)
    }

    private func markAntigravityFailure(_ message: String, error: QuotaError? = nil) {
        antigravityQuotaError = message
        antigravityRefreshState.lastError = message
        if error?.isRateLimited == true {
            antigravityRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func loadCursorQuota(reason: QuotaRefreshReason) async {
        guard beginCursorRefresh(reason: reason) else { return }
        defer { cursorRefreshState.inFlight = false }

        guard let session = cursorAccount else {
            markCursorFailure(cursorError ?? "no Cursor account")
            return
        }

        let initial = await CursorQuotaClient.fetch(cookieHeader: session.cookieHeader)
        switch initial {
        case .success(let snapshot):
            storeCursor(snapshot: snapshot, source: .api)
        case .failure(let error) where error.httpStatusCode == 401:
            // Cursor token 由 Cursor.app 持有。401 后只允许重读一次本地登录态；
            // 仅当 access token 确实变化时才重试，绝不调用 OAuth refresh。
            let previousToken = session.accessToken
            await loadCursor()
            guard let reloaded = cursorAccount,
                  reloaded.accessToken != previousToken
            else {
                markCursorFailure(cursorError ?? error.description, error: error)
                return
            }

            let retried = await CursorQuotaClient.fetch(cookieHeader: reloaded.cookieHeader)
            switch retried {
            case .success(let snapshot):
                storeCursor(snapshot: snapshot, source: .api)
            case .failure(let retryError):
                markCursorFailure(retryError.description, error: retryError)
            }
        case .failure(let error):
            markCursorFailure(error.description, error: error)
        }
    }

    private func beginCommandCodeRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !commandCodeRefreshState.inFlight else { return false }
        if let backoffUntil = commandCodeRefreshState.backoffUntil, backoffUntil > now {
            markCommandCodeFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = commandCodeRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        commandCodeRefreshState.inFlight = true
        commandCodeRefreshState.lastAttemptAt = now
        return true
    }

    private func loadCommandCodeQuota(reason: QuotaRefreshReason) async {
        guard beginCommandCodeRefresh(reason: reason) else { return }
        defer { commandCodeRefreshState.inFlight = false }

        guard let session = commandCodeAccount else {
            markCommandCodeFailure(commandCodeError ?? "未检测到 Command Code 账号")
            return
        }

        let result = await CommandCodeQuotaClient.fetch(accessToken: session.accessToken)
        switch result {
        case .success(let response):
            if var current = commandCodeAccount {
                current.login = response.accountDetails.login
                current.name = response.accountDetails.name
                current.email = response.accountDetails.email
                current.orgID = response.accountDetails.orgID
                current.planType = response.accountDetails.planType
                commandCodeAccount = current
            }
            storeCommandCode(snapshot: response.snapshot, source: .api)
        case .failure(let error) where error.httpStatusCode == 401 || error.httpStatusCode == 403:
            let previousToken = session.accessToken
            await loadCommandCode()
            guard let reloaded = commandCodeAccount, reloaded.accessToken != previousToken else {
                markCommandCodeFailure("凭据已失效", error: error)
                return
            }
            let retried = await CommandCodeQuotaClient.fetch(accessToken: reloaded.accessToken)
            switch retried {
            case .success(let response):
                if var current = commandCodeAccount {
                    current.login = response.accountDetails.login
                    current.name = response.accountDetails.name
                    current.email = response.accountDetails.email
                    current.orgID = response.accountDetails.orgID
                    current.planType = response.accountDetails.planType
                    commandCodeAccount = current
                }
                storeCommandCode(snapshot: response.snapshot, source: .api)
            case .failure(let retryError):
                markCommandCodeFailure(retryError.description, error: retryError)
            }
        case .failure(let error):
            markCommandCodeFailure(error.description, error: error)
        }
    }

    /// Cursor 用量接口同样使用 Cursor.app 的只读登录态。401 时只重读一次 SQLite，
    /// 且 token 必须实际变化才重试；不调用 OAuth refresh，也不影响已成功的额度快照。
    ///
    /// `snapshot` 只用来推首次拉取的起点，允许为 nil：额度失败时用量仍要刷新，
    /// 此时退化成"最近三天"窗口。
    private func refreshCursorRemoteUsage(snapshot: QuotaSnapshot?) async {
        guard let session = cursorAccount else { return }
        // 计费周期对 Cursor 的 Total / Auto / API 是同一个，不能只认 primaryLimit：
        // Free 账号没有可用的 plan used/limit，Total 解析为 nil，周期信息只挂在 Auto 上。
        let billingWindow: Range<Date>? = snapshot.flatMap { snapshot in
            snapshot.allLimits.lazy.compactMap { limit -> Range<Date>? in
                guard let endsAt = limit.window.resetsAt,
                      let seconds = limit.window.windowSeconds,
                      seconds > 0
                else { return nil }
                let startsAt = endsAt.addingTimeInterval(-Double(seconds))
                return startsAt < endsAt ? startsAt..<endsAt : nil
            }.first
        }
        let initial = await usageService.refreshCursorRemoteUsage(
            session: session,
            billingWindow: billingWindow
        )
        guard initial?.httpStatusCode == 401 else { return }

        let previousToken = session.accessToken
        await loadCursor()
        guard let reloaded = cursorAccount, reloaded.accessToken != previousToken else { return }
        _ = await usageService.refreshCursorRemoteUsage(
            session: reloaded,
            billingWindow: billingWindow
        )
    }

    /// 统计页选中 Cursor 尚未缓存的有限日期范围时按月补拉。仅重读当前 Cursor.app
    /// 登录态来处理 401，不触发 OAuth 刷新，也不影响已成功的额度快照。
    func loadCursorUsageHistory(for range: Range<Date>) async {
        guard let session = cursorAccount else { return }
        let initial = await usageService.loadCursorRemoteUsageHistory(session: session, range: range)
        guard initial?.httpStatusCode == 401 else { return }

        let previousToken = session.accessToken
        await loadCursor()
        guard let reloaded = cursorAccount, reloaded.accessToken != previousToken else { return }
        _ = await usageService.loadCursorRemoteUsageHistory(session: reloaded, range: range)
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

    private func beginCursorRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !cursorRefreshState.inFlight else { return false }
        if let backoffUntil = cursorRefreshState.backoffUntil, backoffUntil > now {
            markCursorFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = cursorRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        cursorRefreshState.inFlight = true
        cursorRefreshState.lastAttemptAt = now
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
        recordQuotaCycles(
            accountKey: QuotaHistoryAccountKey.codexPrimary(accountId: codexAccount?.accountId),
            app: .codex,
            snapshot: mergedSnapshot,
            source: source,
            sampledAt: updatedAt
        )
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
        recordQuotaCycles(
            accountKey: QuotaHistoryAccountKey.claudePrimary(email: claudeAccount?.email),
            app: .claude,
            snapshot: mergedSnapshot,
            source: source,
            sampledAt: updatedAt
        )
    }

    private func storeCursor(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(from: cursorQuota, now: updatedAt)
        cursorQuota = mergedSnapshot
        cursorQuotaSource = source
        cursorQuotaError = nil
        cursorRefreshState.lastSuccessAt = updatedAt
        cursorRefreshState.lastError = nil
        cursorRefreshState.backoffUntil = nil
        cursorRefreshState.source = source
        quotaCache.cursor = QuotaCacheRecord(
            snapshot: mergedSnapshot,
            source: source,
            updatedAt: updatedAt,
            accountID: cursorAccount?.userID
        )
        saveQuotaCache()
    }

    private func storeCommandCode(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        let mergedSnapshot = snapshot.preservingFutureResetDates(from: commandCodeQuota, now: updatedAt)
        commandCodeQuota = mergedSnapshot
        commandCodeQuotaSource = source
        commandCodeQuotaError = nil
        commandCodeRefreshState.lastSuccessAt = updatedAt
        commandCodeRefreshState.lastError = nil
        commandCodeRefreshState.backoffUntil = nil
        commandCodeRefreshState.source = source
        quotaCache.commandCode = QuotaCacheRecord(
            snapshot: mergedSnapshot,
            source: source,
            updatedAt: updatedAt,
            accountID: commandCodeAccount?.accountKey
        )
        saveQuotaCache()
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

    private func markCursorFailure(_ message: String, error: QuotaError? = nil) {
        cursorQuotaError = message
        cursorRefreshState.lastError = message
        if error?.isRateLimited == true {
            cursorRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func markCommandCodeFailure(_ message: String, error: QuotaError? = nil) {
        commandCodeQuotaError = message
        commandCodeRefreshState.lastError = message
        if error?.isRateLimited == true {
            commandCodeRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
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
        if let c = antigravityAccount {
            print("[Credentials 凭据] Antigravity: email=\(c.email ?? "—") plan=\(c.planType ?? "—") expiry=\(c.expiryDate.map { "\($0)" } ?? "—") hasAccessToken=\(c.accessToken != nil)")
        } else {
            print("[Credentials 凭据] Antigravity 未加载: error=\(antigravityError ?? "unknown")")
        }
        if let c = cursorAccount {
            print("[Credentials 凭据] Cursor: userID=\(c.userID) email=\(c.email ?? "—") expiresAt=\(c.expiresAt) hasAccessToken=true")
        } else {
            print("[Credentials 凭据] Cursor 未加载: error=\(cursorError ?? "unknown")")
        }
        if let c = commandCodeAccount {
            print("[Credentials 凭据] Command Code: login=\(c.login ?? "—") source=\(c.source.displayName) plan=\(c.planType ?? "—")")
        } else {
            print("[Credentials 凭据] Command Code 未加载: error=\(commandCodeError ?? "unknown")")
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
            var antigravityExtra = ""
            if let gw = q.geminiWindow { antigravityExtra += " GM=\(format(window: gw))" }
            if let gw = q.geminiWeekly { antigravityExtra += " GW=\(format(window: gw))" }
            print("[Quota 额度] Antigravity: source=\(antigravityQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))\(antigravityExtra)")
        } else if SettingsStore.shared.isProviderEnabled(.antigravity) {
            print("[Quota 额度] Antigravity 拉取失败: error=\(antigravityQuotaError ?? antigravityError ?? "unknown")")
        }
        if let q = cursorQuota {
            print("[Quota 额度] Cursor: source=\(cursorQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
        } else {
            print("[Quota 额度] Cursor 拉取失败: error=\(cursorQuotaError ?? cursorError ?? "unknown")")
        }
        if let q = commandCodeQuota {
            print("[Quota 额度] Command Code: source=\(commandCodeQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
        } else if SettingsStore.shared.isProviderEnabled(.commandCode) {
            print("[Quota 额度] Command Code 拉取失败: error=\(commandCodeQuotaError ?? commandCodeError ?? "unknown")")
        }
        // 远端用量和额度是两个独立接口，失败原因必须单独可见，
        // 否则统计页只剩一句"暂不可用"，无法区分未登录和拉取失败。
        if let error = usageService.cursorRemoteUsageError {
            print("[Usage 用量] Cursor 远端拉取失败: error=\(error)")
        } else {
            let covered = usageService.cursorUsageCoveredDayRanges
            print("[Usage 用量] Cursor 远端已覆盖 \(covered.count) 段自然日区间")
        }
    }

    private func format(_ q: QuotaSnapshot) -> String {
        let parts = [
            q.primaryLimit.map { "primary[\($0.kind.rawValue)]=\(format(window: $0.window))" },
            q.secondaryLimit.map { "secondary[\($0.kind.rawValue)]=\(format(window: $0.window))" },
            q.isUnlimited == true ? "unlimited" : nil,
        ].compactMap { $0 } + q.auxiliaryLimits.map {
            "auxiliary[\($0.id)]=\(format(window: $0.window))"
        }
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
