# Antigravity 额度用满预估与周期统计设计方案（草案）

> 状态：草案（待评审确认后实施）
> 关联模块：`Core/Storage/QuotaCycleStore.swift`、`Core/Usage/CycleUsage.swift`、`Core/Usage/UsageService.swift`、`Core/AppState.swift`、`Main/CycleStatsView.swift`、`Main/StatsView.swift`

---

## 1. 背景与目标

cc-bar 主窗口「额度」页目前只展示 Codex 与 Claude Code 的三个区块：**额度用满预估**、**历史周期**与**额度变化时间线**。Antigravity 已经具备完整的底层数据：

- **官方额度与窗口边界**：`AntigravityQuotaClient`（`agy /quota` CLI 优先、云端 `retrieveUserQuotaSummary` 兜底）已解析出各模型组的 `remainingFraction`、`resetTime`（精确到秒）与 `windowSeconds`（5 小时 / 7 天）。
- **本机请求级用量**：`AntigravityScanner` 已扫描 `~/.gemini/antigravity*/conversations/*.db`，提取每条请求的时间戳、去重后的四类 token、模型名及 `conversationKey`。
- **定价覆盖**：`Resources/pricing-rules.json` 已收录 Gemini 2.5 / 3.x / 4（Argon / Carbon / Hydrogen / Neon）与 Claude 4.6 的标准单价。
- **时间线历史**：`QuotaHistoryStore.record` 已在后台为 Antigravity 持续记录 `gemini-5h` 与 `gemini-weekly` 的变动事件，只是 UI 未展示。

本方案目标：在主窗口「额度」页接入 Antigravity，提供与 Codex / Claude 一致的「额度用满预估」「历史周期」和「额度变化时间线」，同时妥善处理 Antigravity 特有的**多额度池**、**0% 滑动空窗**和**按会话整库重读**问题。

不在本方案范围内：
- 菜单栏、Popover、桌面悬浮窗的 Antigravity 展示保持现状，不新增预估字段。
- 不在 Popover 新增 Antigravity 今日/本周花费（`QuotaProviderDescriptor.showsCost` 保持 `false`，后续按需单独评估）。

---

## 2. Antigravity 与 Codex / Claude 的核心差异及设计取舍

### 2.1 多独立额度池（按 `limitID` 隔离）

Codex 和 Claude 每个账号只有一组「主 5H + 主周」；Antigravity 一个账号最多同时存在 6 个独立额度池，且 `primaryLimit` / `secondaryLimit` 的槽位会随账号是否包含 Argon 而偏移（例如含 Argon 时，`gemini-weekly`、`claude-5h`、`claude-weekly` 都落在 `auxiliaryLimits` 中）：

| 额度池 `limitID` | `QuotaLimitKind` | 窗口时长 | 对应的本机请求模型 |
| --- | --- | --- | --- |
| `gemini-5h` | `.fiveHour` | 5 小时 (`18000s`) | 非 Argon/Carbon 的 `gemini-*`（Neon / Hydrogen / 3.x / 2.5 等） |
| `gemini-weekly` | `.weekly` | 7 天 (`604800s`) | 同上 |
| `claude-5h` | `.fiveHour` | 5 小时 (`18000s`) | `claude-*`、`gpt-*` |
| `claude-weekly` | `.weekly` | 7 天 (`604800s`) | 同上 |
| `gemini-argon-wtu-weekly` | `.modelWeekly` | 7 天 (`604800s`) | `gemini-4-argon` |
| `gemini-carbon-wtu-weekly` | `.modelWeekly` | 7 天 (`604800s`) | `gemini-4-carbon` |

**取舍结论**：
- **数据层全量按 `limitID` 建模**：`QuotaCycleStore` 与 `CycleUsageAggregator` 对 Antigravity 从 `snapshot.allLimits` 读取全部受支持的 `limitID`，每个池独立建周期、独立归集本机用量，互不串池。
- **未识别模型（`unknown`）的处理**：当 Antigravity 上新 `MODEL_PLACEHOLDER_M<n>` 但 `AntigravityScanner` 尚未收录映射时，模型记为 `unknown`（无单价、`costUSD == nil`）。这类请求无法确认属于 Gemini 还是 Claude 池，默认**不归入**任何池的预估，避免污染特定池；若后续补齐映射表，通过安全重算自动补录。
- **Argon / Carbon 与 Gemini 共享池的扣减关系**：目前按独立池隔离（`gemini-4-argon` 只进 `gemini-argon-wtu-weekly`，`gemini-4-carbon` 只进 `gemini-carbon-wtu-weekly`）。若后续实测发现 Argon / Carbon 消耗同时扣减 `gemini-5h` 或 `gemini-weekly`，只需调整模型路由表中的目标 `limitID` 集合即可，不改存储格式。

### 2.2 未消耗池子的 `resetTime` 随采样时间滑动

实测发现，Antigravity 中 `usedPercent == 0%` 的未使用池子，服务端返回的 `resetTime` 固定为「本次采样时刻 + 窗口时长」（例如每次刷新都顺延几分钟）。如果直接写入 `QuotaCycleStore`，每次刷新都会因 `resetsAt` 漂移而触发新周期或反复重建。

**处理策略**：
- 对 Antigravity，记录周期时若 `usedPercent <= 0`：
  - 若当前**不存在**同一 `(accountKey, limitID)` 的活跃周期（`endAt > sampledAt`），**跳过不建新周期**；
  - 若当前**已存在**活跃周期（例如刚刚满 5h 重置回 0%，或发生周期内重置），按既有逻辑更新或忽略漂移，不新建伪周期。
- 一旦某个池子出现真实消耗（`usedPercent > 0`），服务端会锁定该窗口的 `resetsAt`，此时建立周期并反推 `startAt = resetsAt - windowSeconds`，再由周期重算把 `[startAt, resetsAt)` 内的本机请求补齐。

### 2.3 按对话整库重读（非追加流）

`AntigravityScanner` 与 `OpencodeScanner` 类似，每次扫描会对变动的对话 `.db` 整库重读并产出该对话的完整条目，不能作为增量重复 `ingest`。

**处理策略**：
- 常规增量扫描时，对 Antigravity 走 `cycleAggregator.replaceConversations(app: .antigravity, conversationKeys: ..., entries: ..., cycles: ..., accountSegments: ...)`，与 OpenCode 保持完全一致。
- 全量重算 / 受限重建时，将 `.antigravity` 纳入周期源服务集合。

### 2.4 账号键与无邮箱回退迁移

- 账号键统一使用已有的 `QuotaHistoryAccountKey.antigravityPrimary(email: antigravityAccount?.email)`：有邮箱时为 `antigravity:primary:<sha256(email)>`，纯 `agy` CLI 未取到邮箱时回退为 `antigravity:primary`。
- 参照 `QuotaCycleStore.migratingLegacyClaudeAccountKey(_:to:)`，新增 `migratingLegacyAntigravityAccountKey(_:to:)`：首次从 `antigravity:primary` 拿到真实邮箱时，将旧常量键的周期记录与账号段原地迁移到真实账号键，保留 `cycle.id` 避免 rollup 断链。

---

## 3. 数据模型与核心逻辑改动

### 3.1 `Core/Storage/QuotaCycleStore.swift`

现有 `QuotaCycleRecord` 已经包含 `limitID: String` 字段，**无需提升 `QuotaCyclePayload.currentVersion`（保持 v4 向后兼容）**。具体改动：

1. **窗口提取范围**：
   - `record(payload:accountKey:app:snapshot:source:sampledAt:)` 抽取辅助方法 `trackedLimits(in:app:)`：
     - `.codex` / `.claude`：保持现状，取 `[snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 }` 中 `kind == .fiveHour || kind == .weekly` 的项；
     - `.antigravity`：从 `snapshot.allLimits` 中取 `id` 属于受支持 6 池集合（`gemini-5h`、`gemini-weekly`、`claude-5h`、`claude-weekly`、`gemini-argon-wtu-weekly`、`gemini-carbon-wtu-weekly`）的项。
2. **0% 滑动空窗过滤**：
   - 仅对 `.antigravity` 生效：当 `usedPercent <= 0` 且当前无匹配活跃记录时，直接 `continue`，不新建记录。
3. **周期匹配与清理增加 `limitID` 维度**：
   - `matchIndex` 候选过滤、`closeOverlappingCycles`、`deduplicatingOverlapping`、`coalescingResetDriftFragments` 中，把原本按 `(accountKey, app, limitKind)` 分组/匹配的逻辑收紧为 `(accountKey, app, limitKind, limitID)`。
   - 对 Codex / Claude 无行为变化（两者每个 `limitKind` 均只有一个固定 `limitID`）；对 Antigravity 可彻底防止 `gemini-5h` 与 `claude-5h`、`gemini-weekly` 与 `claude-weekly`、`argon` 与 `carbon` 互相吞并或截断。
4. **支持 `.modelWeekly` 窗口时长**：
   - `windowSeconds(forKind:)` 对 `.modelWeekly` 返回 `7 * 24 * 3600`（`604800`），使 Argon / Carbon 周池也能通过 `repairingOversizedCycles` 和漂移合并的窗口长度反推。
5. **旧账号键迁移**：
   - 新增 `migratingLegacyAntigravityAccountKey(_:to:)`，行为与 `migratingLegacyClaudeAccountKey` 对称。

### 3.2 `Core/Usage/CycleUsage.swift`

现有 `CycleUsageBucket` 以 `cycleID`（已内含 `limitID`）作为主键的一部分，**无需提升 `CycleUsageRollupPayload.currentVersion`（保持 v4）**。具体改动：

1. **放行 `.antigravity`**：
   - `CycleUsageAggregator.cycleApp(app:model:)` 对 `.antigravity` 返回 `.antigravity`。
2. **按模型路由到目标 `limitID`**：
   - 新增 `targetLimitIDs(for entry: UsageEntry) -> [String]?`（仅 `.antigravity` 使用；Codex / Claude 仍按 `[.weekly, .fiveHour]` 匹配）：
     - `model == "gemini-4-argon"` → `["gemini-argon-wtu-weekly"]`
     - `model == "gemini-4-carbon"` → `["gemini-carbon-wtu-weekly"]`
     - `model.hasPrefix("gemini-")` → `["gemini-weekly", "gemini-5h"]`
     - `model.hasPrefix("claude-") || model.hasPrefix("gpt-")` → `["claude-weekly", "claude-5h"]`
     - 其他（含 `unknown`）→ `[]`（跳过）
   - `ingest(...)` 对 `.antigravity` 遍历 `targetLimitIDs`，调用 `bestCycle(for:app:accountKey:limitID:cycles:)` 精准匹配对应池的周期。
3. **查询接口扩展**：
   - `summaries(cycles:kind:app:limitID:otherAgentSources:now:)` 增加可选参数 `limitID: String? = nil`；传 `nil` 时行为与现有一致，传具体 `limitID` 时只返回该池的周期汇总。

### 3.3 `Core/AppState.swift`

1. **记录周期**：
   - 在 Antigravity 额度刷新成功路径（调用 `recordAntigravityQuotaHistory` 处）同步调用 `recordQuotaCycles(accountKey:app:.antigravity, snapshot:snapshot, source:source, sampledAt:sampledAt)`。
2. **账号键迁移**：
   - 当 `antigravityAccount?.email` 首次取得非空值时，调用 `QuotaCycleStore.migratingLegacyAntigravityAccountKey` 并触发周期保存。
3. **初始重建与周期变动联动**：
   - 复用现有 `quotaCycles` 变更触发 `usageService.scheduleCycleRebuild(...)` 的机制，无需另起调度链路。

### 3.4 `Core/Usage/UsageService.swift`

1. **增量扫描同步周期桶**：
   - 在 `scanIncremental` 中，与 `opencodeReplaced` 并列增加：
     ```swift
     let antigravityReplaced = antigravity.isComplete && cycleAggregator.replaceConversations(
         app: .antigravity,
         conversationKeys: Set(antigravity.refreshedConversationIDs.map { "antigravity:\($0)" }),
         entries: antigravity.entries,
         cycles: cycles,
         accountSegments: appState?.quotaCycles.accountSegments ?? []
     )
     ```
   - `cycleChanged` 并入 `antigravityReplaced`。
2. **首次重建与受限重建**：
   - `requiredCycleSourceApps(cycles:)`、`pendingInitialCycleRebuildApps`、`cyclesToRebuild`、`cycleRebuildFailedApps` 纳入 `.antigravity`（当 `antigravity.failedDatabaseCount > 0` 或 `!antigravity.isComplete` 时标记失败，留待下轮补算）。
   - `rebuildRange` 传入 `antigravity.entries`（仅在 `.antigravity` 在 `sourceApps` 中时）。
   - `rebuildSafe` 中 `preservedApps` 移除 `.antigravity` 对周期桶的盲目保留（或与 OpenCode 一致，确保安全重算能按新周期边界/新映射重算 Antigravity 周期桶，同时保留源库已删除的对话贡献）。

---

## 4. UI 展示方案（主窗口「额度」页）

遵循 `docs/设计风格.md` 与 `docs/界面布局.md` §3（不增加冗余文案、不自造控件、进度条与百分比统一走 `statusColor`）。

### 4.1 侧栏筛选与服务范围（`Main/StatsView.swift`）

- `quotaApps` 纳入 `.antigravity`：
  - 侧栏选「全部」：按 `SettingsStore.shared.orderedProviders` 中已启用的顺序返回 Codex / Claude / Antigravity。
  - 侧栏单选「Antigravity」：返回 `[.antigravity]`（若已启用）。
  - 空态提示文案更新为：`只有 Codex、Claude Code 与 Antigravity 提供额度周期。` / `Only Codex, Claude Code, and Antigravity report quota cycles.`。

### 4.2 区块一：额度用满预估（`Main/CycleStatsView.swift`）

为了避免「全部」视图下卡片数量过多导致布局拥挤，按视图范围分层展示：

- **侧栏「全部」视图**：
  - Antigravity 固定展示主池 2 张卡：**`Antigravity · Gemini 5H`** 与 **`Antigravity · Gemini WK`**（与 Codex 2 张、Claude 2 张对齐）。
  - 网格列数策略调整：当总卡数 `> 4` 时，宽画布改为 3 列（或 2 列换行），避免 6 张卡硬挤在一行导致主数字被压缩；具体为 `cards.count <= 4 ? cards.count : (isWide ? 3 : 2)`。
- **侧栏单选「Antigravity」视图**：
  - 常驻展示 **`Gemini 5H`**、**`Gemini WK`** 两张卡（无活跃周期时显示现有空态卡）。
  - 其余 4 个池（**`Claude 5H`**、**`Claude WK`**、**`Argon 周`**、**`Carbon 周`**）按需展开：当该池在 `quotaCycles` 中存在**当前活跃周期**（`isCurrent()` 且 `latestUsedPercent > 0`）时显示对应卡片；全为 0% 时不占版面。
- **卡内信息**：
  - 与 Codex / Claude 卡片完全同构：顶部 `ServiceTile` + `<服务/池短名>` + `ResetTimeText` → 中部用满预估主数字（`Tokens · 费用`）+ 可信度说明（早期估算 / 粗略估算 / 参考 / 较可靠）→ 底部 `ProgressBar` + `已用 Tokens · 费用` + 官方已用百分比。
  - 若当前周期内存在未定价模型，费用侧自动沿用 `StatsFormatter.tierCostWhole(..., hasUnpricedUsage:)` 的既有展示规则。

### 4.3 区块二：历史周期（`Main/CycleStatsView.swift`）

- `QuotaCycleHistorySection` 为 Antigravity 渲染一个历史周期面板，顶部与 Codex / Claude 一致支持 `5 小时 / 周` 分段切换。
- 默认口径为 **Gemini 共享池**（`gemini-5h` / `gemini-weekly`）。
- 单选 Antigravity 且存在其他池（如 `claude-5h` / `claude-weekly` / `argon` / `carbon`）的已结束周期时，面板右上角或标题旁可提供轻量池切换（首版可先聚焦 Gemini 共享池，确认界面简洁后再决定是否加池切换）。

### 4.4 区块三：额度变化时间线（`Main/StatsView.swift`）

- `timelineSections` 增加 `case .antigravity` 分支：
  - 使用 `QuotaHistoryAccountKey.antigravityPrimary(email: appState.antigravityAccount?.email)`；
  - 复用 `QuotaHistoryStore.record` 已记录的 `gemini-5h` / `gemini-weekly` 时间线数据；
  - 标题显示 `Antigravity`（单选或全部视图下按 Provider 自定义序排列）。

---

## 5. 边界条件与风险说明

| 风险 / 边界 | 表现 | 缓解措施 |
| --- | --- | --- |
| **快照采样时刻与本地日志时间差** | 用户刚发完请求，本地 `.db` 已写入，但额度快照仍是几分钟前的百分比，导致短期预估偏高 | 属所有服务共性（Codex/Claude 同样存在）；可信度分档（`<10%` 早期、`10–30%` 粗略）已向用户提示波动，不额外做复杂时间截断（避免刷新间隙卡内“已用”不动） |
| **Argon / Carbon 是否同时扣 Gemini 共享池** | 若服务端双重扣减，按独立池隔离会导致 `gemini-5h/weekly` 的本机用量偏低、预估偏低 | 实测一次 Argon 请求前后 `gemini-5h` / `gemini-weekly` / `gemini-argon-wtu-weekly` 的百分比变化即可确认；若双重扣减，将 Argon 路由改为 `["gemini-argon-wtu-weekly", "gemini-weekly", "gemini-5h"]` 即可 |
| **新模型占位编号未收录** | `AntigravityScanner` 输出 `unknown`，跳过归池 | 保持既有模型映射更新节奏；不把 `unknown` 猜归某池，防止跨池污染 |
| **跨设备 / 网页端消耗** | 同一 Google 账号在另一台电脑或网页端使用，官方已用比例高于本机日志 | 与 Codex / Claude 相同，区块副标题已注明「按本机用量和官方已用比例估算，仅供参考」 |
| **无邮箱时的 `agy` CLI 切换账号** | 仅通过 `agy` 取数且未拿到邮箱时，全部落入 `antigravity:primary` | 现有 `AppState` 已在有效 OAuth token 可用时补拉邮箱；拿到邮箱后通过 `migratingLegacyAntigravityAccountKey` 自动迁移 |

---

## 6. 测试与验收计划

### 6.1 单元测试（`CCBarTests`）

1. **`QuotaCycleStore` 测试**：
   - Antigravity 6 池快照同时写入时，各自按 `limitID` 独立建周期，互不触发 `closeOverlappingCycles` 或 `deduplicatingOverlapping`。
   - `usedPercent == 0` 且无活跃周期的池不建新记录；`usedPercent` 从 `0` 升至 `>0` 后正常建立周期。
   - `.modelWeekly`（Argon / Carbon）支持 `repairingOversizedCycles`（7 天窗口反推起点）。
   - `migratingLegacyAntigravityAccountKey` 正确迁移旧常量键且不改变 `cycle.id`。
   - 回归验证 Codex / Claude 既有周期合并、抖动容差、额外重置用例全部通过。
2. **`CycleUsageAggregator` 测试**：
   - 模型路由：`gemini-4-neon` / `gemini-4-hydrogen` / `gemini-3.1-pro` 进 `gemini-5h` & `gemini-weekly`；`claude-opus-4-6` 进 `claude-5h` & `claude-weekly`；`gemini-4-argon` 进 `gemini-argon-wtu-weekly`；`unknown` 不进任何池。
   - `replaceConversations(app: .antigravity, ...)` 多次调用幂等，不重复累加。
   - `summaries(limitID:)` 按池隔离返回正确预估值。
3. **安全重算 / 一致性测试**：
   - 确认 `UsageHistoryConsistency` 与 `UsageSafeRebuildTests` 覆盖 Antigravity 周期桶。

### 6.2 手动验收要点

- 开启 Antigravity 服务后，主窗口「额度」页在「全部」视图下显示 Codex / Claude / Antigravity 卡片（宽画布排版无挤压、无截断）。
- 切到侧栏「Antigravity」单选视图，核对 Gemini 5H / WK 的已用、用满预估、重置倒计时与进度条状态色（`>=20%` 石墨灰、`<20%` 橙、`=0` 红）。
- 核对未使用池（0%）不会在 `quota-cycle-history.json` 中反复产生垃圾周期。
- 核对「额度变化时间线」展示 Antigravity 的历史曲线与最新采样点。
- 检查新增控件均无 macOS 蓝色键盘焦点环。

---

## 7. 落地后需同步更新的常驻文档

- `docs/产品需求.md`：更新主窗口「额度」页支持的服务列表（纳入 Antigravity）。
- `docs/技术实现.md`：更新 `QuotaCycleStore` 多 `limitID` 周期规则、`CycleUsageAggregator` 的 Antigravity 模型路由与 `replaceConversations` 流程。
- `docs/界面布局.md`：更新主窗口「额度」页网格列数（>4 卡换行规则）、Antigravity 卡片命名与单选视图按需展开规则。
- `docs/README.md`：将本草案状态更新为已实施并注明验收结果。
