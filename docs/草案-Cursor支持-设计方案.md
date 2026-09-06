# 草案 · Cursor 支持（额度 + 用量统计）

> 状态：开发实现已完成，待使用真实已登录的 Cursor.app 做端到端验收。额度基础模型、`usage-summary` 离线解析、只读 SQLite/JWT/Cookie 认证、刷新调度、账号隔离缓存，远端用量分页与主窗口统计均已落地；Popover、菜单栏、悬浮窗、设置、Onboarding 和图标也已接入。Cursor 的额度 Provider 与统计可独立开启，默认关闭时不会产生远端刷新；`All` 只使用现有缓存且不会无界回溯，覆盖与刷新状态不额外显示在页面。产品、技术、布局和设计风格文档已同步。本文保留为接口字段、映射规则与风险判断的追溯材料。

## 1. 背景、目标与范围

在 cc-bar 中新增 Cursor 支持，展示形态对齐现有 Provider，但明确区分“远端账户数据”和“本机日志数据”：

- **Popover**：展示 Cursor 的 Total / Auto / API 剩余额度、计费周期、重置时间、套餐名，并复用现有今日 / 本周费用展示位。
- **主窗口统计页**：展示 Cursor 账户级 Token 和服务端计量消耗，支持现有日 / 周 / 月等时间范围。
- **设置**：Cursor Provider 总开关、菜单栏、悬浮窗、统计服务各有独立入口。含义与既有 Provider 一致——菜单栏与悬浮窗彼此独立，统计服务独立于额度 Provider（可以只看 Cursor 统计而不显示额度卡片）；但菜单栏 / 悬浮窗是 Provider 总开关的子开关，总开关关闭时不会绕过它单独显示。完整层级见 [界面布局.md](界面布局.md) §4.5 Accounts「开关层级语义」。

第一版明确不做：

- 不新增近 30 天额度趋势图或新的历史折线形态。
- 不把 Cursor 月度额度接入现有 Codex / Claude 的 5 小时、周额度周期对比；Cursor 用量仍可进入统计页的时间范围对比。
- 不调用 Cursor OAuth 刷新接口，不写 Cursor 的 SQLite，不保存 Cursor token 到 cc-bar Keychain。
- 不把套餐内计量消耗表述成信用卡实际扣款。

## 2. 调研结论与技术选择

Cursor 官方没有面向个人 Hobby / Pro / Pro+ / Ultra 用户的公开稳定额度 API。官方 Admin API 面向 Teams / Enterprise 组织管理员，需要管理员创建 API Key，不能作为个人用户的默认接入方式：

- Admin API：<https://docs.cursor.com/en/account/teams/admin-api>
- 套餐与用量说明：<https://docs.cursor.com/account/pricing>

个人账号只能参考 Cursor Dashboard 自用的非公开接口，因此必须把它视为可失效的兼容层，而不是官方 API 契约。

### 2.1 本地参考项目

| | CodexBar | OpenUsage |
|---|---|---|
| 本地仓库 | `../CodexBar` | `../openusage` |
| 认证 | Cursor.app access token 组装网页 Cookie，并可回退浏览器 Cookie | api2 RPC Bearer token |
| 额度 | `cursor.com/api/usage-summary` | api2 RPC，必要时回退 `usage-summary` / request usage |
| Token 刷新 | 不主动刷新 Cursor token，优先重读 Cursor.app 登录态 | 主动 OAuth 刷新，并按凭据来源写回 Cursor SQLite 或原 Keychain |
| 历史用量 | Dashboard 事件 JSON；同时区分 `chargedCents` 与 `tokenUsage.totalCents` | Dashboard CSV；按本地模型价格估算费用 |
| 侵入性 | 主路径只读 Cursor 数据 | SQLite 来源下会修改 Cursor 数据库 |

关键源码：

- CodexBar：`Sources/CodexBarCore/Providers/Cursor/`
  - `CursorAppAuth.swift`：只读 `state.vscdb`、JWT 与 Cookie。
  - `CursorStatusProbe.swift`：`usage-summary` 模型与账户类型回退。
  - `CursorUsageEventsFetcher.swift`：事件分页、完整性检查、`chargedCents` 与 `totalCents` 两种口径。
- OpenUsage：`Sources/OpenUsage/Providers/Cursor/`
  - `CursorAuthStore.swift`：SQLite / Keychain 凭据来源与写回。
  - `CursorUsageClient.swift`：api2 RPC、OAuth 与 Dashboard 接口。
  - `CursorProvider.swift`：刷新、重试及套餐回退编排。

### 2.2 第一版组合决策

1. **额度和历史用量都走 Cursor Dashboard 的 Cookie 接口**：避免同时维护两套数据协议，但仍按非官方接口对待。
2. **认证采用 CodexBar 的只读路线**：每次刷新重新读取 Cursor.app 当前 access token；不使用 refresh token，不调用 `api2.cursor.sh/oauth/token`。
3. **远端用量采用独立快照与替换语义**：不能把重复拉取的完整时间窗口直接增量 `ingest` 到本地日志聚合器。
4. **费用同时保留口径名称**：统计页使用 `chargedCents` 表示“Cursor 服务端计量消耗”；`tokenUsage.totalCents` 仅作模型标价参考，不互相回退或混算。

该选择的代价是：Cursor.app 长时间未运行、access token 已过期时，cc-bar 只能保留旧快照并等待 Cursor 登录态恢复。第一版接受这个限制，以避免争用或轮换 Cursor 的 refresh token。

## 3. 额度数据与映射

### 3.1 接口

`GET https://cursor.com/api/usage-summary`

请求头：

```http
Accept: application/json
Cookie: WorkosCursorSessionToken=<userID>%3A%3A<accessToken>
```

关键返回字段：

| 字段 | 含义 | 单位 |
|---|---|---|
| `billingCycleStart` / `billingCycleEnd` | 计费周期起止 | ISO8601 |
| `membershipType` | `pro` / `pro_plus` / `ultra` / `team` / `enterprise` / `free` 等 | — |
| `limitType` | 个人 / 团队等额度类型 | — |
| `individualUsage.plan.used / limit / remaining` | 个人套餐用量 | 美分 |
| `individualUsage.plan.autoPercentUsed / apiPercentUsed / totalPercentUsed` | 三类已用百分比 | 0～100 |
| `individualUsage.plan.breakdown.included / bonus / total` | 套餐内 / 赠送 / 合计 | 美分 |
| `individualUsage.onDemand` | 个人超额按量用量 | 美分 |
| `individualUsage.overall` | Team / Enterprise 成员个人上限 | 美分 |
| `teamUsage.onDemand / pooled` | 团队按量用量 / 共享池 | 美分 |
| `isUnlimited` | 是否报告为无限额度 | Bool |

### 3.2 Total 回退顺序

不能在字段缺失时伪造 `0% used`。Total 按以下顺序选择第一个可用来源：

1. `limitType == "team"` 且 `teamUsage.pooled` 有有效 limit 时，使用 pooled 的 `used / limit`。
2. `individualUsage.plan.totalPercentUsed`。
3. `individualUsage.plan.used / limit`。
4. `individualUsage.overall.used / limit`。
5. `teamUsage.pooled.used / limit`。

如果以上都不可用：

- `isUnlimited == true`：展示 `Unlimited / 无限`，不伪造进度百分比。
- 否则 Total 为空，并显示“Cursor 未返回可用额度”。

Auto / API 只使用各自明确的百分比字段，不用两者平均值反推 Total。所有百分比只在展示边界 clamp 到 0～100，解析层保留原始异常供诊断。

### 3.3 `QuotaSnapshot` 映射

Cursor 的三个额度必须使用稳定且互不相同的 ID，不能调用当前会按 `windowSeconds` 生成 ID 的 `QuotaLimit.standard(kind: .unknown, ...)`：

| 位置 | ID | 来源 | 标题 |
|---|---|---|---|
| `primaryLimit` | `cursor-total` | Total 回退结果 | `TOTAL` |
| `secondaryLimit` | `cursor-auto` | `autoPercentUsed` | `AUTO` |
| `auxiliaryLimits[0]` | `cursor-api` | `apiPercentUsed` | `API` |

三者均使用：

- `kind = .unknown`
- `window.resetsAt = billingCycleEnd`
- `window.windowSeconds = billingCycleEnd - billingCycleStart`
- `displayName` 分别为 `Total`、`Auto`、`API`

为避免把 API 额度伪装成模型额度，`QuotaSnapshot` 新增通用的 `auxiliaryLimits: [QuotaLimit]`，默认空数组并保持旧缓存可解码；`allLimits` 合并 primary、secondary、auxiliary 和 model limits。另新增可选 `isUnlimited`，供没有数值进度时展示。`preservingFutureResetDates(from:now:)` 目前只回写 primary / secondary / modelLimits，新增 `auxiliaryLimits` 后必须同步遍历回写，否则 API 额度的 reset 时间保留逻辑缺失。

`planType` 来自格式化后的 `membershipType`；`fetchedAt` 为本次成功拉取时间。

## 4. 历史用量、费用口径与完整性

### 4.1 接口与分页

`POST https://cursor.com/api/dashboard/get-filtered-usage-events`

请求头必须包含：

```http
Content-Type: application/json
Accept: application/json
Origin: https://cursor.com
Cookie: WorkosCursorSessionToken=<userID>%3A%3A<accessToken>
```

请求体：

```json
{
  "page": 1,
  "pageSize": 1000,
  "startDate": "<epoch milliseconds>",
  "endDate": "<epoch milliseconds>"
}
```

单个日期分片最多 200 页。每一页都要验证 `totalUsageEventsCount` 一致；只有出现空页或短页，且最终数量与服务端总数一致，才视为完整。接口没有稳定事件 ID，只能在服务端总数证明存在重复时，按相邻页边界的完全相同事件消除对应数量。

如果月度分片达到 200 页仍未完成，自动二分日期范围继续拉取；细分到单日仍无法完整获取时，本轮失败，不发布半截数据。

### 4.2 事件映射

每条事件关注：

| 字段 | 用途 |
|---|---|
| `timestamp` | 毫秒时间戳，按用户当前时区归入自然日 |
| `model` | 模型维度，缺失时使用 `unknown` |
| `tokenUsage.inputTokens / outputTokens / cacheWriteTokens / cacheReadTokens` | Token 明细 |
| `tokenUsage.totalCents` | 模型标价成本，仅作参考 |
| `chargedCents` | Cursor 服务端计量到套餐或按量池的消耗 |
| `isChargeable / kind / requestsCosts / usageBasedCosts` | 诊断计费类别，不据此把套餐内事件删除 |

映射规则：

- `app = .cursor`
- `speed = .standard`；Cursor 没有 cc-bar 的 Standard / Fast 概念，这里只表示不走 Fast 倍率。
- `cacheWriteTokens → cacheCreationTokens`
- `requestCount = 1`
- `costUSD = chargedCents / 100`
- 不能用 `tokenUsage.totalCents` 填补缺失的 `chargedCents`，否则会混合“套餐计量”和“模型标价”两种口径。

缺少或全零 `tokenUsage` 的事件仍可贡献 `chargedCents` 和 request count；缺少有效 timestamp 的事件无法正确归日，必须把该日期分片标为不完整。

只要查询区间内任一有效事件缺少、为负数或包含非有限的 `chargedCents`，该区间的 Cursor 费用标记为不完整。Token 与已知 `chargedCents` 仍可展示，费用继续汇总有效的服务端计量；不能用 `tokenUsage.totalCents` 填补缺失字段。Token 完整性和费用完整性需要分开记录。

**不能复用现有 `hasUnpricedUsage` 承载该状态。**两者语义不同且现有 UI 行为已固化：

- `hasUnpricedUsage` 的现有语义是“本地缺价、按 0 计入聚合”，Codex / Claude / Pi / OpenCode 缺价时都会置位，且 `StatsFormatter.tierCost*` 系列当前**故意忽略**该标记（参数名带 `_`），金额照常显示。
- 若借用它，诊断链路无法区分“本地缺价”和“Cursor 服务端计量字段缺失”两种来源，也会改变既有本地缺价按 0 聚合的语义。

因此新增独立的费用完整性标记（如 `UsageTotals.costIncomplete`，默认 false，仅 Cursor 远端分区可置位，合并时按 OR 传播）；`hasUnpricedUsage` 的现有语义与展示行为保持不变。两个标记都只作诊断，UI 继续显示已知金额；只有没有任何远端快照时才显示 `--`。

### 4.3 刷新范围与覆盖信息

远端历史不能每隔几分钟全量重拉。采用以下策略：

1. 首次成功：从 `billingCycleStart`、当前自然周周一与最近三天修正窗口三者中较早者的本地 0 点开始拉取，确保 Popover 的今天 / 本周可用，同时避免首日只有半个日桶。
2. 周期刷新：从“当前本地自然日往前两天的 0 点”重拉到现在，以修正迟到事件；若当前自然周有覆盖缺口，额外补拉缺失的自然日。完整成功后按自然日替换受影响日桶；不能用未对齐日界线的 48 小时区间直接覆盖日聚合桶。
3. 用户选择尚未覆盖的更早有限范围：按月分片静默懒加载缺失区间；期间保留已有聚合金额，不新增 loading 状态行。
4. “全部”范围：只使用现有缓存，不发起无界回溯；不能把当前缓存误称为完整历史，也不显示覆盖起止时间或 Partial 文案。
5. 缓存记录 `accountID`、完整覆盖区间、各分片状态、`fetchedAt` 与聚合桶。账号变化时先隔离旧缓存，不能显示“新账号 + 旧账号用量”。

网络失败、401、429、解析失败或分页不完整时，保留上一份完整快照，不覆盖为半截或空数据。

### 4.4 独立远端聚合

当前 `UsageAggregator.ingest(_:)` 是累加语义，不能用于反复拉取同一 Cursor 窗口。实现时拆分本地和远端分区：

- 本地日志：继续由 `ingestLocal(_:)` 增量累计，并写现有 `usage-rollup`。
- Cursor 远端：由 `replaceRemote(app:dayRange:buckets:)` 按自然日原子替换完整日桶，并写独立 `cursor-usage-rollup`。
- 读取入口必须分成两个，不能只有一个合并快照：
  - `snapshotLocal()`：仅本地分区。`UsageService` 里所有算 pricing fingerprint、`pricingUsageKeys`、缺价刷新候选（`refreshMissingPricingIfNeeded`）以及落盘 `usage-rollup` 的调用点一律改用它。否则 Cursor 的 (app, model, speed) 会混进指纹，远端数据一变指纹就变，scan cache 反复失效触发全量重扫，Cursor 模型还会进入缺价刷新循环。
  - `snapshot()` / `totals(...)`：合并本地与远端分区，仅供 UI 展示。
- 本地 full rebuild、价格指纹变化或 scan cache 失效只能重建本地分区，不得清空 Cursor 远端分区。
- Cursor 使用服务端费用，不参与本地 Pricing Catalog 指纹和价格重算。
- `publishTotals` / `todayCost(for: .cursor)` 若走合并快照，其语义是“全设备今日计量消耗”；Popover 复用既有 today/week cost 展示位，但不得把它标成或回退为本机成本。

远端缓存不与本地 conversation / cycle rollup 共用 generation，也不进入对话统计；Cursor Dashboard 事件没有本机会话 ID，不能伪造 conversationKey。

## 5. 认证与安全设计

### 5.1 只读本地登录态

Cursor.app 登录态通常位于：

```text
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

从 `ItemTable` 只读取：

- `cursorAuth/accessToken`

第一版不读取也不使用 `cursorAuth/refreshToken`。

实现独立的 `CursorSQLiteReader`：

1. 优先用 `SQLITE_OPEN_READONLY` 打开，让 SQLite 正确读取活动 WAL。
2. 设置短 `busy_timeout`，不能阻塞 Cursor。
3. 仅当普通只读打开返回 `SQLITE_CANTOPEN`，并确认 `-wal` / `-shm` 都不存在时，才用 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` 和 `?immutable=1` 回退。
4. WAL 存在时绝不能使用 immutable，否则会忽略尚未 checkpoint 的最新登录态。

当前 `OpencodeScanner` 只有普通只读打开，没有上述 immutable fallback；可以复用 SQLite3 基础方式，但不能声称直接复用了完整实现。具体边界以 CodexBar 的 `CursorAppAuth.swift` 为参考。

### 5.2 JWT 与 Cookie

复用 `Core/Credentials/JWT.swift` 解析：

- `sub`：取最后一个 `|` 后的非空部分作为 userID，并限制为安全字符。
- `email`：用于账号展示和身份变化判断。
- `exp`：剩余有效期大于 60 秒才直接使用。

Cookie 必须无多余空格：

```text
WorkosCursorSessionToken=<userID>%3A%3A<accessToken>
```

### 5.3 过期与账号切换

- 每轮额度 / 用量刷新前重新读取 Cursor SQLite，Cursor.app 中更新后的 token 优先。
- 请求返回 401 时只允许再重读 SQLite 并重试一次；如果 token 未变化或仍失败，结束本轮。
- token 过期时只记录日志并保留旧额度和用量快照，界面沿用普通空值状态。
- JWT subject 或 email 明确变化时视为账号切换；先切换运行时身份，再加载该账号自己的缓存或重新拉取，不能沿用旧账号快照。

### 5.4 安全边界

- 凭据只发送到 `https://cursor.com`，不发送到其他域名。
- 不调用 OAuth refresh，不写 Cursor SQLite，不把 token 保存到 Keychain、UserDefaults、缓存或日志。
- 日志只记录固定错误类别、HTTP 状态和无凭据的分页信息。
- 429 遵守现有退避策略；手动刷新不能绕过退避。
- 网络失败保留最后一次完整快照。

## 6. 架构改动清单

### 6.1 新增文件

| 文件 | 职责 |
|---|---|
| `Core/Credentials/CursorAuth.swift` | 只读 SQLite、JWT 身份与有效期、Cookie 构造；不含 OAuth 刷新 |
| `Core/Quota/CursorQuotaClient.swift` | `usage-summary` 解码、账户类型回退、`QuotaSnapshot` 映射 |
| `Core/Usage/CursorUsageFetcher.swift` | 日期分片、分页完整性、事件解析与临时聚合 |
| `Core/Storage/CursorUsageCache.swift` | 账号绑定的远端桶、覆盖区间和完整性状态 |
| 资源 | Cursor logo、识别色 asset |

### 6.2 修改文件与真实影响面

| 文件 / 模块 | 改动 |
|---|---|
| `Core/Quota/QuotaModels.swift` | `QuotaApp.cursor`、`auxiliaryLimits`、可选 `isUnlimited`、Cursor 三个稳定 limit ID |
| `Core/Usage/UsageModels.swift` | `UsageApp.cursor`；`UsageTotals` / `UsageBucket` 新增独立 `costIncomplete` 标记（见 §4.2，不复用 `hasUnpricedUsage`）；补充远端覆盖模型（如不放独立缓存模型中） |
| `Core/Quota/QuotaRefreshPlan.swift` | 增加 `refreshCursor`，由 Provider enabled 状态构造 |
| `Core/AppState.swift` | Cursor 账号、额度状态、身份切换清理、`loadCursorQuota()`、缓存与退避；所有 `QuotaApp` 穷举 switch 补齐 |
| `Core/Usage/UsageAggregator.swift` | 本地 ingest 与远端按日 replacement 分区；读取时合并 |
| `Core/Usage/UsageService.swift` | Cursor 远端刷新调度、懒加载、独立持久化；本地重算不影响远端；指纹 / 缺价 / rollup 落盘路径全部改用 `snapshotLocal()`（见 §4.4） |
| `Core/Storage/ScanCache.swift` | 仍只保存本地扫描状态；确认 Cursor 不进入本地 generation / pricing fingerprint |
| `Core/Storage/Settings.swift` | `providerDisplaySettings` 和 `usageServiceVisibility` 自动补默认值；可增加 `showCursor` 语义入口，但不新增三组平行存储 key |
| `Main/DesignSystem.swift` | `QuotaApp` / `UsageApp` 的 Cursor 名称与识别色 |
| `MenuBar/PopoverRootView.swift` | Cursor 账号副标题、三条额度与 Unlimited；复用既有今日 / 本周费用及错误状态样式，不增加 Cursor 专属 tooltip，技术错误只显示通用失败状态 |
| `MenuBar/MenuBarLabel.swift` | Cursor limit 选择与稳定 ID 去重 |
| `Floating/` | Cursor Provider 行和 Unlimited / 空态 |
| `Main/StatsView.swift` | Cursor filter、服务副标题、固定 DailySample 字段或等价通用化；Cursor 单服务及全部服务的费用完整性占位，历史按需静默补拉 |
| `Main/CycleStatsView.swift` | 补齐 `UsageApp.cursor` 穷举；第一版不为 Cursor 构造 5h / weekly account cycle |
| `Settings/SettingsRootView.swift` | Cursor Provider 开关与 Stats service 开关 |
| `Onboarding/OnboardingView.swift` | 检测 Cursor 数据库 / 登录态，只做只读提示，不触发 Keychain 或 OAuth |
| L10n / 文档 | Cursor、Unlimited 与既有 Provider 通用文案；不增加覆盖、加载、计量解释或重试文案 |

`QuotaProviderDescriptor.primaryProviders` 顺序固定为：

```text
Codex → Claude Code → Cursor → Antigravity
```

设置和 quota cache 已经按 Provider 索引，新增枚举值后可补默认项；但 UI 和统计层仍有多处穷举 switch 与固定四服务数据结构，不能写成“新增 Provider 自动出现”。

## 7. 产品口径

- **账户范围**：Cursor 数据来自远端账号，覆盖该账号所有设备；Codex / Claude / Pi / OpenCode 当前主要是本机日志来源。
- **Token**：来自 Cursor Dashboard 事件；缺少 tokenUsage 的事件不伪造 Token。
- **Cursor 计量消耗**：`chargedCents` 汇总，包含套餐内计量，可能不等于信用卡额外扣款。
- **On-demand**：`individualUsage.onDemand.used` 是额外按量用量，属于额度 / 账单摘要，不与事件 `chargedCents` 重复相加。
- **模型标价**：`tokenUsage.totalCents` 可用于诊断或未来单独展示，不写入同一个 `costUSD` 口径。
- **覆盖范围**：超出已完整拉取区间时静默补拉；不能用局部缓存回答“全部”，也不把覆盖状态显示成页面提示。
- **来源说明**：数据来源与费用语义只保留在技术文档；Popover 复用既有费用展示位，但不在 Stats 或 Popover 增加 Cursor 专属标签、tooltip 或状态行。

## 8. 风险与降级

| 风险 | 处理 |
|---|---|
| Dashboard 私有接口或字段变化 | 集中解码；未知 schema 整体失败并保留旧快照，不用 0 值掩盖 |
| Cursor token 过期 | 不主动刷新；记录日志并保留旧数据，页面沿用普通空值状态 |
| 分页重复或总数变化 | 按服务端总数和相邻页边界严格校验；不发布半截数据 |
| 单分片超过 20 万事件 | 自动二分日期范围；单日仍超限则报不完整 |
| 账号切换 | 以 JWT subject 优先、email 回退识别；缓存按 accountID 隔离 |
| `chargedCents` 缺失 | Token 与其他事件的已知 `chargedCents` 合计可展示，保留 `costIncomplete` 诊断；不回退到标价成本 |
| 本地 full rebuild | 只重建本地分区，Cursor 远端快照不丢失 |
| Cursor 未安装 / 未登录 | 沿用既有 Provider 的未检测到 / 空值状态，不增加操作提示，不清空已有账号的最后完整快照 |
| 429 | 使用现有退避；手动刷新不绕过 |

## 9. 实施顺序

1. **模型与测试夹具**：Cursor API JSON、三条稳定 limit、Team / Enterprise / Unlimited / 缺字段用例。
2. **只读认证**：SQLite WAL / immutable 边界、JWT、账号切换、401 单次重读。
3. **额度**：`CursorQuotaClient`、AppState 调度、独立错误和 cache 行为。
4. **远端用量**：严格分页、自然日对齐的日期分片、费用完整性、远端独立 cache 与按日 replacement。
5. **统计 UI**：Cursor service、按月静默补拉有限历史、费用完整性占位；不新增覆盖范围、Partial / Loading 或计量解释文案。（已完成）
6. **Quota UI**：Popover、菜单栏、悬浮窗、设置、Onboarding、图标和 L10n。（已完成）
7. **文档同步**：并入《产品需求》《技术实现》《界面布局》《设计风格》。（已完成，待真实验收后归档本草案）

## 10. 验收标准

- Cursor 顺序为 Codex → Claude Code → Cursor → Antigravity。
- Popover 能分别显示 Total / Auto / API，并在既有今日 / 本周费用位置展示完整的 Cursor 远端计量金额；三条 ID 不冲突，缺失字段不伪造 0%，Unlimited 有明确文本。
- Pro / Pro+ / Ultra、Team / Enterprise 的 `plan`、`overall`、`pooled` 形态都有解析测试。
- Cursor.app 登录有效时可只读拉取；token 过期或 401 时不调用 OAuth、不写 SQLite / Keychain，并保留旧快照。
- 同一完整用量窗口连续刷新两次，Token、requestCount 和费用不会翻倍。
- 本地日志 full rebuild 后 Cursor 远端数据仍存在；切换 Cursor 账号后不会显示旧账号快照。
- 分页总数变化、边界重复、200 页上限和 `chargedCents` 缺失都有明确测试；任何不完整结果都不覆盖完整缓存。
- 主窗口按日 / 周 / 月汇总 Cursor Token；费用内部使用 Cursor 服务端计量数据，始终保留已知 `chargedCents` 合计；`costIncomplete` 仅用于诊断，不显示 Partial 或来源解释。仅无任何 Cursor 远端快照时显示 `--`。
- Codex / Claude / Pi / OpenCode 的缺价展示行为（`hasUnpricedUsage` 按 0 计入、金额照常显示）与现状完全一致，无回归。
- Cursor 远端数据的任何变化都不影响本地 pricing fingerprint 与 scan cache：连续多轮远端刷新不触发本地全量重扫，Cursor 模型不进入缺价刷新候选。
- 超出缓存覆盖范围时静默补拉，不把局部数据标成“全部”，也不增加 Loading / Partial 状态行。
- Cursor 未安装 / 未登录时沿用既有 Provider 的未检测到 / 空值状态，不增加操作提示；未安装 Cursor 的机器上统计页不出现无意义的 Cursor 空服务行。网络失败和 429 不清空已有数据，也不绕过退避。
- 凭据不进入日志、UserDefaults、cc-bar Keychain 或持久化缓存，只发送到 `https://cursor.com`。
