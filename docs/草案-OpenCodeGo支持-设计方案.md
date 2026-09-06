# 草案 · OpenCode Go 支持（额度）

> 状态：**未实施**。当前代码里 `QuotaApp` 没有 `opencodeGo`，也没有对应的凭据读取或额度客户端；Popover / 设置 / Onboarding 都没有 OpenCode Go 条目。注意与已落地的 `Core/Usage/OpencodeScanner.swift` 区分——后者扫的是本地 `~/.local/share/opencode/opencode.db` 会话库，属于**用量统计**，与本文的 OpenCode Go **订阅额度**是两件事。本文是范围与技术契约已收敛的设计方案，尚未落地。实现完成并通过验收后，再把最终行为并入正式产品 / 技术 / 界面文档并将本草案归档。接口来源已经抓取并交叉验证：`GET https://opencode.ai/zen/go/v1/usage` 与 Bearer token，响应字段 `usage.{rolling,weekly,monthly}{status, percent, resetsAt}`（百分号为**已用**）。macOS 上的 Go API key 位于 OpenCode 全局数据目录的 `auth.json` 中 `opencode-go` provider 项，默认路径为 `~/.local/share/opencode/auth.json`，兜底环境变量为 `OPENCODE_API_KEY`。第一版订阅额度只进 Popover + 设置 Accounts + Onboarding 检测；菜单栏、悬浮窗不做，也不把订阅额度注入主窗口的 Agent 对话统计。现有 OpenCode / Pi 等 Agent 对话若使用 `opencode-go/<model-id>`，仍按本地日志正常统计 Token 与预估费用，不受本功能影响。

## 1. 背景、目标与范围

### 1.1 用户诉求

在 cc-bar 中接入 OpenCode Go **订阅额度**展示，对齐 Codex / Claude Code 的“设置 Accounts 总开关 + Popover 额度卡片”产品形态，但不进入菜单栏 / 悬浮窗，也不作为新的 Agent 对话用量数据源进入主窗口。

### 1.2 第一版范围

- **Popover**：在已有 Codex / Claude Code / Cursor 之后新增 OpenCode Go block，显示 rolling（5h）/ weekly / monthly 三档剩余比例，复用现有通用 block 模板。
- **设置**：Accounts 一栏手工增加 OpenCode Go 一行（自动检测 + Provider 总开关，首次默认关闭）；菜单栏与悬浮窗设置区不显示 Go 占位开关；不新增“统计服务”开关。
- **Onboarding**：Detect accounts 页加一行 OpenCode Go，只读扫描 `auth.json`，不触发任何写入或 OAuth。
- **失败态**：沿用通用失败态，不直出远端技术错误。
- **不可用降级**：端点 404 或字段 shape 变化时，Popover 显示空状态、不显示伪造百分比，保留账号探测。

### 1.3 第一版明确不做

- 不画菜单栏 logo / 百分比。
- 不在桌面悬浮窗出现 OpenCode Go 行。
- 不把远端 Go 订阅额度、窗口消费或缓存写入主窗口的 Overview / Conversations / Timeline / Cycles / 按服务 / 按提供商 / 按模型面板。
- 不调用 OpenCode OAuth、不写 OpenCode SQLite、不把 Go key 写入 cc-bar Keychain / UserDefaults / `quota-cache.json` 或日志。额度快照与不可逆账号指纹允许写入现有 `quota-cache.json`，用于重启恢复和同账号失败时保留旧数据。
- 不从 Go usage 端点构造历史用量、Token、请求数或预估费用；它们不计入 Agent 对话统计。
- 不改现有按提供商归并（本地日志中的 `opencode-go/<model-id>` 已由 `ModelProvider.opencodeGo` 处理；本需求不新增统计入口或规则）。
- 不做 Go 套餐消费量折算到本机 token 的反推；本机用量继续走现有 `OpencodeScanner` + Zen pay-as-you-go 路径。
- 不为 Go 引入新的识别色 assets 或新建 logo SVG（资源占用最小化；识别色沿用 OpenCode 现有的 `OpencodeAccent`；`ServiceTile` 在资源缺失时先显示字母 `G`，正式 logo 后续单独补充）。

### 1.4 两套产品数据的边界

“OpenCode Go 订阅额度”与“Agent 对话用量”是两套独立产品能力，名称相近但不能混算：

| 维度 | 订阅额度查询 | Agent 对话用量查询 |
|---|---|---|
| 用户问题 | 套餐还剩多少、何时重置 | 哪个 Agent / 会话用了多少 Token、预估多少钱 |
| 数据来源 | OpenCode Go 远端 `usage` API | Codex、Claude Code、OpenCode、Pi 等 Agent 的本地对话日志；既有 Cursor 远端历史保持原逻辑 |
| 核心模型 | `QuotaApp.opencodeGo` / `QuotaSnapshot` | `UsageApp` / Conversation / `UsageAggregator` |
| 设置入口 | Settings → Accounts 的 OpenCode Go 总开关 | 主窗口统计服务可见性；本需求不新增 Go 服务开关 |
| 展示入口 | Popover 的 Rolling / Weekly / Monthly 剩余比例 | 主窗口 Overview / Conversations / Cycles / 按服务 / 按提供商 / 按模型 |
| 金额语义 | 套餐窗口额度，不展示本地费用 | 按对话 Token 和定价规则计算的预估费用 |

现有 Agent 对话中出现 `opencode-go/<model-id>` 时，仍按 `UsageApp.opencode` 或实际 Agent 来源进入主窗口，并可由既有 `ModelProvider.opencodeGo` 归并。它表示“该次对话使用了 OpenCode Go 模型提供商”，**不表示**主窗口读取或拆解了 Go 订阅额度。本功能不得过滤、重写或重复计入这些既有对话。

## 2. 调研结论与技术选择

### 2.1 远端接口（已交叉验证）

OpenCode Go 是 OpenCode 团队推出的 **$10/月** 订阅，包含三个按美元计费的滚动窗口：

| 窗口 | 上限 | 备注 |
|---|---|---|
| rolling（5 小时） | $12 | 5 小时滚动窗口，不是固定自然时段 |
| weekly | $30 | UTC 自然周（周一 0:00）重置 |
| monthly | $60 | 按订阅锚定时间重置 |

> 注：文档原文使用 "5 hour / week / month"，响应字段名为 `rolling / weekly / monthly`。本文档统称为三窗口。

**端点**：`GET https://opencode.ai/zen/go/v1/usage`
**认证**：`Authorization: Bearer <OPENCODE_API_KEY>`
**响应 schema**（已经通过 [OpenCode 官方源码 `packages/console/app/src/routes/zen/go/v1/usage.ts`](https://github.com/anomalyco/opencode/pull/16513) 抓取并与外部客户端实现交叉确认）：

```json
{
  "usage": {
    "rolling": { "status": "ok" | "rate-limited", "percent": 4,  "resetsAt": "2026-08-13T16:27:38.287Z" },
    "weekly":  { "status": "ok" | "rate-limited", "percent": 3,  "resetsAt": "2026-08-17T00:00:00.287Z" },
    "monthly": { "status": "ok" | "rate-limited", "percent": 1,  "resetsAt": "2026-09-13T06:06:01.287Z" }
  }
}
```

关键事实：

- `percent` 是 **已用**，不是剩余。展示层必须换算为 `100 - percent` 后再走 `statusColor` 四档（>50% 绿 / 20~50% 黄 / <20% 橙 / =0 红）。
- `status == "rate-limited"` 是有效额度状态，按“100% 已用 / 0% 剩余”展示，复用空档红；即使三个窗口全部命中，也不等于端点不可用。
- `resetsAt` 是 UTC ISO8601。`windowSeconds` 表示完整窗口长度，不用 `(resetsAt - now)` 这种剩余时长冒充：rolling 固定为 5 小时、weekly 固定为 7 天、monthly 因端点未返回本周期起点而设为 `nil`。第一版不做三窗口之间的依赖推导。
- 401 = key 无效；403 + `EntitlementError` = key 没有 Go 订阅（免费 / Zen-only）。
- 端点**只返回当前窗口**，**没有历史用量**。
- OpenCode 官方文档已经正式说明 Go 套餐与 `$12 / $30 / $60` 三档限额，但尚未把 usage 查询端点列为公开 API；实现仍以官方服务端源码和真实响应为契约，并保持容错。

### 2.2 本地凭据位置

macOS 上 OpenCode Desktop / CLI 的认证存放在 OpenCode 全局数据目录：

```text
$XDG_DATA_HOME/opencode/auth.json
# XDG_DATA_HOME 未设置时：~/.local/share/opencode/auth.json
```

格式（来自 OpenCode 源码 `packages/opencode/src/cli/cmd/auth.ts`）：

```json
{
  "opencode-go": {
    "type": "api",
    "key": "sk-...",
    "metadata": { "...": "..." }
  }
}
```

- 只接受 provider id 为 **`opencode-go`** 且 `type == "api"` 的条目；它与现有 `ModelProvider.opencodeGo` 已识别的字符串一致，也跟 Pi / OpenCode 本地日志里的 `opencode-go/<model-id>` 模型前缀一致。
- 兜底环境变量：`OPENCODE_API_KEY`。第一版不读取 `OPENCODE_CONFIG_DIR` / `OPENCODE_CONFIG` / `opencode.json`，也不支持 OpenCode 内部的 `OPENCODE_AUTH_CONTENT` 注入；这些属于明确延后项。macOS 从 Finder / Launchpad 启动时通常不会继承终端临时环境变量，环境变量来源变化后以重启 CCBar 为生效边界。
- key 长期有效（订阅取消才会失效），不需要 OAuth 续期、不需要过期检测。

### 2.3 第一版组合决策

1. **额度和账号检测走同一条只读路径**：每次刷新重读 `auth.json` 的 `opencode-go.key`，不缓存 key、不调用 OAuth。
2. **`OPENCODE_API_KEY` 环境变量作为低优先级兜底**，仅在 `auth.json` 没有 `opencode-go` 项时使用；不在 UI 区分两种来源（避免把内部探测路径暴露给用户）。
3. **percent 映射在 `OpenCodeGoQuotaClient` 内部完成**：客户端返回 `QuotaSnapshot` 时将服务端 `percent` 夹在 `0...100` 后赋给 `usedPercent`；剩余比例继续由 `QuotaWindow.remainingPercent` 统一计算，UI 不自行做减法。
4. **订阅额度不进入 Agent 对话统计**：Go 端点不返回历史，**不**为这份远端数据引入任何用量链路 / cache / 远端分区；`UsageAggregator` 不增加 Go 分区、`UsageApp` 不增加 `.opencodeGo` 枚举值。现有本地 Agent 对话及其 `ModelProvider.opencodeGo` 归并保持原样。
5. **不可用降级硬编码**：解析层遇到端点消失、响应 envelope 改变或三窗口全部无法解析时，整体标记为“OpenCode Go 不可用”（区别于“未检测到”，后者是没有可用 key），Popover 走空状态，不显示伪造百分比，但保留账号探测和磁盘旧快照。
6. **失败分级只分两类**：通用失败（沿用 "刷新失败" 文案，不直出错误）+ 不可用降级（端点缺失 / shape 改变）；401 与 403 走通用失败文案（用户场景里二者都等同 "Go 当前不可用"，进一步细分没有用户价值）。

### 2.4 与 Cursor 草案的边界

| 维度 | Cursor | OpenCode Go |
|---|---|---|
| 远端数据 | 额度 + 历史用量（独立 cache、按日 replacement） | 仅额度 |
| 本地 SQLite 读取 | 需要 WAL / immutable fallback | 不需要（`auth.json` 是普通 JSON 文件） |
| JWT 解析 | 需要（`sub` 拆分 userID） | 不需要（Bearer token 是不透明字符串） |
| 凭据失效处理 | 只读 + 不刷新 + 过期保留快照 | key 长期有效；订阅取消通过 403 自动收敛 |
| 远端数据是否进入统计页 | 进入（Dashboard 远端分区） | 不进入；但既有 OpenCode / Pi Agent 本地对话照常统计 |
| 是否进入 Onboarding | 加入 Detect accounts | 加入 Detect accounts |
| 是否进入菜单栏 | 进入（已实现） | 不进入 |
| 是否进入悬浮窗 | 进入（已实现） | 不进入 |
| 是否改动 `ModelProvider` | 否 | 否（已支持 `opencode-go` 前缀） |

> 本草案不复用 `CursorUsageFetcher` / `CursorUsageCache` / `replaceRemote` / Cursor 远端分区链路——这些都跟 Dashboard 历史用量绑定。Go 没有历史，不需要远端历史分区；仅复用通用 `quota-cache.json` 保存最后一次额度快照和账号摘要。

## 3. 额度数据与映射

### 3.1 `QuotaSnapshot` 映射

Go 的三窗口必须使用稳定且互不相同的 ID，直接构造 `QuotaLimit`，不调用会按 `windowSeconds` 生成 unknown ID 的 `QuotaLimit.standard(kind: .unknown, ...)`。三者设计：

| 位置 | ID | kind | windowSeconds | 来源 | displayName |
|---|---|---|---:|---|---|
| `primaryLimit` | `opencode-go-rolling` | `.fiveHour` | `18_000` | `usage.rolling.percent` | `Rolling` |
| `secondaryLimit` | `opencode-go-weekly` | `.weekly` | `604_800` | `usage.weekly.percent` | `Weekly` |
| `auxiliaryLimits[0]` | `opencode-go-monthly` | `.unknown` | `nil` | `usage.monthly.percent` | `Monthly` |

三者统一：

- `window.resetsAt = <服务端 resetsAt>`，原样保留 UTC ISO8601。
- `window.usedPercent = <服务端 percent>`。

`planType` 不设置：Go 只有一种套餐，"OpenCode Go" 已经在副标题中体现，不再冗余展示。

`fetchedAt` 为本次成功拉取时间。

> `rolling` 是服务端配置的 5 小时滚动窗口，`weekly` 是 7 天自然周窗口，因此分别使用 `.fiveHour` / `.weekly` 才符合模型语义。Timeline / Cycles 的隔离由调用链保证：第一版不为 Go 调用 `recordQuotaHistory` / `recordQuotaCycles`，不能靠把真实窗口伪装成 `.unknown` 隔离。monthly 暂无专用 kind，保留 `.unknown`。

### 3.2 percent → 状态色

`statusColor(remainingPercent:tint:)` 的输入是**剩余**比例。Go 服务端返回**已用**，客户端在 `parse` 内部完成换算：

```text
remaining = max(0, min(100, 100 - percent))
window.usedPercent = max(0, min(100, percent))
```

- `percent` 缺失或非有限数 → 该窗口不进入 `QuotaSnapshot`（与 Cursor 的字段缺失不伪造 0% 一致）。
- `status == "rate-limited"` → 该窗口按 `usedPercent = 100` 处理，强制红档。
- 三窗口全部 `rate-limited` → 仍是成功快照，三档都显示 0% 剩余。
- 三窗口全部缺失或全部解析失败 → 走“OpenCode Go 不可用”状态（详见 §3.4）。

### 3.3 `preservingFutureResetDates`

Go 沿用现有 `QuotaSnapshot.preservingFutureResetDates(from:now:)` 的实现，无需修改——`auxiliaryLimits` 已经在 Cursor 草案落地时遍历过。

### 3.4 不可用 vs 未检测到

两种状态必须有显式区分，否则用户无法判断是「去 OpenCode 订阅」还是「等一会儿再试」：

| 状态 | 触发 | Popover 行为 |
|---|---|---|
| 未检测到 | 没有合法 `opencode-go` API key，且 `OPENCODE_API_KEY` 未设 | block 不渲染；Provider 偏好保留，重新检测到后自动恢复 |
| 凭据失效 | 401 / 403 | block 显示通用“刷新失败”并沿用同账号旧快照；不直出错误 |
| 不可用 | 端点 404 / envelope 改变 / 三窗口全部无法解析 | block 渲染，但数值与 reset 显示 `—`，无进度条；磁盘旧快照保留但本状态下不展示旧数字 |
| 正常 | 至少一个窗口成功解析；`rate-limited` 也属于成功窗口 | 展示已成功解析的窗口；缺失窗口不伪造 0% |

实现层不在 `OpenCodeGoQuotaClient` 保存可变静态状态。Client 保持无状态并返回类型化失败；账号检测和展示可用性统一由 `AppState` 承载：

```swift
nonisolated enum OpenCodeGoAvailability: Sendable, Equatable {
    case checking
    case notDetected
    case available
    case unavailable
}

nonisolated enum OpenCodeGoFetchFailure: Error, Sendable, Equatable {
    case unauthorized
    case subscriptionRequired
    case endpointUnavailable
    case invalidPayload
    case rateLimited
    case transport
    case server(Int)
}
```

`PrimaryQuotaState.error / refresh` 继续承载通用失败与退避；`opencodeGoAvailability` 只决定账号探测和不可用布局，避免出现 Client 与 AppState 两套状态源。

## 4. 认证与安全设计

### 4.1 只读采用

第一版完全只读：

- 优先读取 `$XDG_DATA_HOME/opencode/auth.json`，未设置时读取 `~/.local/share/opencode/auth.json`，解析 `opencode-go` 下 `type == "api"` 的 `key`。
- `OPENCODE_API_KEY` 环境变量作为低优先级兜底（仅在文件未提供时）。
- **不**读取 `OPENCODE_CONFIG_DIR` / `OPENCODE_CONFIG` / `opencode.json` 里的全局 provider 配置（避免把 OpenCode 整个配置体系背进来，第一版只覆盖最常见路径）。
- **不**调用 OAuth、不写 OpenCode SQLite，不把 key 写入 cc-bar Keychain / UserDefaults / 任何持久化缓存；仅把额度快照与账号摘要写入通用 `quota-cache.json`。
- **不**把 key 或其片段写入日志：日志只记录固定错误类别和 HTTP 状态。Go 没有可读账号身份，第一版使用 key 的完整 SHA-256 十六进制摘要作为内部 `accountID`，只用于账号切换和缓存绑定，不展示、不记录。

实现独立的 `OpenCodeGoAuth`：

```swift
nonisolated enum OpenCodeGoAuth {
    struct Session: Sendable, Equatable {
        let apiKey: String
        let accountID: String          // SHA-256(apiKey) 完整 hex
        let source: Source             // .authFile / .environment
    }

    enum Source: Sendable, Equatable {
        case authFile(URL)
        case environment
    }

    static func defaultAuthURL(home: URL, environment: [String: String]) -> URL { ... }
    static func load(
        authURL: URL = defaultAuthURL(...),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Session? { ... }
}
```

读取规则：

1. auth.json 存在 → 解析顶层 `"opencode-go"`，仅接受 `type == "api"`；`key` 去除首尾空白后非空且不含控制字符才返回 `.authFile`。
2. 文件不存在、没有该项、类型不符或 key 为空 → 读取 `environment["OPENCODE_API_KEY"]`，通过同样校验后返回 `.environment`。
3. auth.json 损坏 / 无法读取 → 记录固定本地读取错误，不抛出 key 或完整路径；本轮账号态为未检测到，不影响其他 Provider。第一版不在损坏文件上静默采用环境变量，避免用另一个隐式凭据掩盖本地配置损坏。
4. 都没有 → 返回 `nil`。

> 第一版**不**做 OS 钥匙串回退。OpenCode 不写钥匙串，回退无意义。

### 4.2 账号切换

Go 没有传统意义上的"账号"概念，只有 key。一个用户理论上可以同时持有多个 Go 订阅 key（个人 + 团队），但每个 `auth.json` / 环境变量只能写一个值，且 OpenCode CLI / Desktop 只用一个。**第一版只展示一个 key**，策略：

- 把完整 SHA-256 `accountID` 作为内部账号身份。
- 每次刷新前重读 `auth.json` / 环境变量，发现 `accountID` 变化时视为账号切换，立即清空内存旧快照和 `quota-cache.json` 中旧 Go 记录，再请求新账号，防止“新 key + 旧额度”短暂串号。
- `loadQuotaCache()` 读取到 Go 记录时先暂存；只有账号检测完成且缓存 `accountID` 与当前摘要一致，才把快照公开到 `primaryQuotaStates`。账号检测完成前 Popover 不渲染 Go，避免启动瞬间闪出上一个账号的缓存。
- 未检测到 key 时不展示 block，但可以保留同摘要缓存供 key 恢复后复用；检测到不同 key 时必须删除旧记录。

### 4.3 凭据失效

| 情况 | 行为 |
|---|---|
| key 为空或含控制字符 | 不发请求；无环境变量兜底时视为未检测到，记录固定本地错误类别 |
| 401 | `.unauthorized`；保留同账号旧快照；本轮不立即重试 |
| 403 `EntitlementError` | `.subscriptionRequired`；保留同账号旧快照；本轮不立即重试 |
| 404 | `.endpointUnavailable`；保留磁盘旧快照但 UI 不展示旧数字；本轮不立即重试 |
| 200 但 envelope 改变 / 三窗口全无效 | `.invalidPayload`；行为同 endpointUnavailable |
| 429 | `.rateLimited`；保留并展示旧快照，进入现有 10 分钟退避，手动刷新不绕过 |
| 网络 / 5xx | `.transport` / `.server`；保留并展示旧快照，显示通用失败 |

“本轮不立即重试”不等于永久停刷：后续 Scheduler 仍按设置周期发起下一轮，key 恢复或重新订阅后自动回到正常态。账号摘要变化优先于“保留旧快照”：新 key 绝不能沿用旧 key 的缓存。

### 4.4 安全边界

- 凭据只发送到 `https://opencode.ai/zen/go/v1/usage`，不发送到其他域名。
- 不调用 OAuth，不写 OpenCode SQLite，不把 key 写入 cc-bar Keychain / UserDefaults / quota cache；只持久化额度快照与不可逆账号摘要。
- 日志只记录固定错误类别与 HTTP 状态；不记录 key、摘要或响应 body。
- 请求设置能识别 CCBar 的专用 `User-Agent`，避免使用宽泛或冒充 OpenCode CLI 的标识。
- 429 遵守现有退避策略（10 分钟），手动刷新不绕过。
- 网络失败保留最后一次完整快照。

## 5. 架构改动清单

### 5.1 新增文件

| 文件 | 职责 |
|---|---|
| `Core/Credentials/OpenCodeGoAuth.swift` | `Session` 模型、auth.json 解析、`OPENCODE_API_KEY` 兜底、完整 `accountID` 派生；不含 OAuth |
| `Core/Quota/OpenCodeGoQuotaClient.swift` | `GET /zen/go/v1/usage`、Bearer 构造、响应解码、窗口映射与类型化错误；客户端保持无状态 |
| `CCBarTests/OpenCodeGoAuthTests.swift` | 认证路径、格式校验、环境变量兜底、账号摘要与安全输入测试 |
| `CCBarTests/OpenCodeGoQuotaClientTests.swift` | 三窗口、部分窗口、rate-limited、HTTP 与响应结构测试 |

首版不新增 logo 文件。`ServiceTile` 沿用现有无资源 fallback，显示字母 `G`；正式图标属于后续视觉需求，不阻塞功能接入。

### 5.2 修改文件与真实影响面

| 文件 / 模块 | 改动 |
|---|---|
| `Core/Quota/QuotaModels.swift` | 新增 `QuotaApp.opencodeGo`；`QuotaProviderDescriptor.primaryProviders` 末尾追加 Go；Descriptor 增加并统一消费 `supportsMenuBar`、`supportsFloatingHUD`、`showsCost` 能力，Go 均为 `false`；`usageApp` 为 `nil` |
| `Core/Quota/QuotaRefreshPlan.swift` | `refreshOpenCodeGo` 加入按 Provider 启用的调度构造 |
| `Core/AppState.swift` | 新增账号、可用性和额度状态；认证加载、账号切换清理、缓存待验证、类型化失败映射；接入 `refreshQuotas`、`refreshNow` 与 Onboarding 检测；不写额度历史 / 周期存储 |
| `Core/Storage/Settings.swift` | `providerDisplaySettings[.opencodeGo]` 首次默认 `enabled/menuBar/floatingHUD = false`；`enabled` 是 Settings → Accounts 的订阅额度总开关，另外两个字段因能力不支持而始终不进入对应 UI；旧 UserDefaults 缺 key 时自然取默认，不做迁移 |
| `Core/Storage/QuotaCache.swift` | 不升 schema 版本；现有动态 providers map 可保存 Go 快照及完整账号摘要；恢复时必须先校验当前摘要，摘要不符或尚未确认时不得暴露旧数字 |
| `MenuBar/PopoverRootView.swift` | Go block 复用 Provider block；仅在检测到账户且总开关启用时出现；支持部分有效窗口、不可用无进度条、同账号旧快照 + 通用失败；不显示费用 |
| `MenuBar/MenuBarLabel.swift` | 按 `supportsMenuBar` 过滤 Provider；Go 不渲染，也不出现在设置候选项 |
| `Floating/FloatingContentView.swift` | 按 `supportsFloatingHUD` 过滤 Provider；Go 不渲染，也不出现在设置候选项 |
| `Main/StatsView.swift` | **不**为订阅额度改动；`visibleUsageApps` 仍保持 Codex / Claude Code / Cursor / Pi / OpenCode。既有 OpenCode / Pi Agent 对话即使模型 Provider 为 `opencode-go`，也继续正常展示 |
| `Main/CycleStatsView.swift` | **不**改 |
| `Settings/SettingsRootView.swift` | Accounts 当前为手写行：显式新增 Go 订阅额度总开关与刷新；菜单栏 / 悬浮窗设置继续由 Descriptor 生成并按能力过滤，不添加禁用占位；Agent 对话统计设置不增加独立的 Go 服务开关 |
| `Onboarding/OnboardingView.swift` | Detect accounts 当前为手写行：显式追加 Go，并纳入 `anyDetected`；未检测到时沿用现有状态 |
| `Main/DesignSystem.swift` | 仅给 `QuotaApp.tintColor` 补 `.opencodeGo: .opencodeAccent`；当前不存在 `providerName` / `vendorName` 方法，不新增无必要抽象 |
| `Core/L10n.swift` | 预计不改；项目当前通过调用点内联 `tr(en, zh)`，Go 文案遵循同一方式 |
| `Core/Usage/Pricing.swift` | **不**为订阅额度改动；现有 `opencode-go` Agent 对话继续沿用既有本地模型定价与预估费用链路 |
| `Core/Usage/ModelProvider.swift` | **不**改（已支持 `opencode-go/` 前缀） |
| `ccbar.xcodeproj/project.pbxproj` | 显式加入新增 Swift 源文件、测试文件引用及对应 Build Phase；本工程不是自动同步文件组，不能只在磁盘创建文件 |
| 正式文档 / README | 功能通过验收后并入产品、技术、布局、设计和 README；随后归档本草案 |

`QuotaProviderDescriptor.primaryProviders` 顺序固定为：

```text
Codex → Claude Code → Cursor → OpenCode Go
```

后续若再加入 Provider，重新评审排序与能力，不在本需求中预留虚拟位置。

### 5.3 不动的链路（显式边界）

| 模块 | 原因 |
|---|---|
| `UsageAggregator.ingestLocal` / `replaceRemote` | Go 订阅额度不是 Agent 对话历史，不进入聚合；既有本地对话聚合不变 |
| `UsageApp` 枚举 | 不新增 `.opencodeGo`；现有 OpenCode / Pi 等 Agent 来源保持原枚举与统计方式 |
| `CycleUsage` | 不写入 Go 订阅额度；既有 Agent 对话周期统计不变 |
| `QuotaHistoryStore` / `QuotaCycleStore` | Go 端点没有历史额度采样，Timeline / Cycles 第一版不增加订阅额度视图 |
| `CursorUsageFetcher` / `CursorUsageCache` | 与 Cursor Dashboard 绑定，Go 不复用 |
| `ModelProvider` 归并规则 | 已支持 `opencode-go/` 前缀，不改 |
| `Pricing.normalize` | 已支持 `opencode-go/` 剥离 |

## 6. 产品口径

- **产品归属**：OpenCode Go 在本需求中是 `QuotaApp` 订阅额度 Provider，不是新的 `UsageApp` Agent 工具。Settings → Accounts 总开关只控制远端额度刷新与 Popover 卡片，不控制主窗口中的任何 Agent 对话。
- **账户范围**：Go 订阅额度来自远端账号，覆盖该账号所有设备，与本机 `OpencodeScanner` 读取的 Agent 对话 SQLite 完全独立。现有 `opencodeTodayCost` 聚合本地 OpenCode Agent 用量，无法代表 Go 订阅窗口，因此 Go 卡片不展示今日 / 本周费用，也不改现有本地统计。
- **Token / 请求数**：Go usage 端点不返回 Token / 请求数，第一版不根据订阅额度构造“按模型用量统计”。本地对话已有 Token 与预估费用继续照常展示，包括模型 Provider 为 `opencode-go` 的对话。
- **额度窗口语义**：rolling 为 5 小时滚动窗口、weekly 为 7 天窗口、monthly 为订阅月；三个窗口彼此独立，不做依赖推导。
- **percent 口径**：`100 - percent` = 剩余比例；UI 永远只展示剩余。
- **rate-limited**：是有效窗口结果，与 `usedPercent = 100` 等价展示，触发 0% 剩余红档；三个窗口全命中仍是成功快照。
- **覆盖范围**：Go 端点不返回历史，无覆盖范围 / 不完整概念；首次认证检测完成前不渲染卡片，避免启动闪现旧账号数字。
- **来源说明**：Bearer 端点、`auth.json` 路径和完整 SHA-256 账号摘要只留在技术实现与本草案；Popover 不增加 Go 专属 tooltip、不直出技术错误。

## 7. 界面文案

| EN | 中文 | 出现位置 |
|---|---|---|
| `OpenCode Go` | `OpenCode Go` | Provider 名称 |
| `OpenCode` | `OpenCode` | Provider vendor 名 |
| `Go` | `Go` | 副标简化 |
| `Rolling` | `Rolling` | Popover 额度标签（与 Codex 5HOUR 同形，不翻译） |
| `Weekly` | `Weekly` | 同上 |
| `Monthly` | `Monthly` | 同上 |
| `OpenCode Go unavailable` | `OpenCode Go 暂不可用` | Popover 不可用态副行 |
| `Refresh failed` | `刷新失败` | Popover 通用失败态 |
| `Read-only access` | `仅读取` | Onboarding 复用既有文案 |
| `Detected from OpenCode auth.json` | `已从 OpenCode auth.json 读取` | Onboarding 副标；兼容 XDG 路径且不暴露完整本机路径 |

文案在调用点使用现有 `tr(en, zh)`，不建立不存在的 L10n 词条注册表；不直出 `EntitlementError` / `AuthError` 等技术错误。

## 8. 风险与降级

| 风险 | 处理 |
|---|---|
| usage 端点仍是实现契约、字段可能变化 | 集中解码；未知额外字段忽略，envelope 或三窗口全无效则 `.invalidPayload`；磁盘快照保留但 UI 不展示旧数字 |
| 端点 404 / 关闭 | `.endpointUnavailable`；账户仍可检测，卡片显示不可用且无进度条；不展示旧数字 |
| 401 / 403 `EntitlementError` | 同账号旧快照继续展示并附通用刷新失败；本轮不立即重试，后续 Scheduler 仍会重试 |
| key 撤销 / 订阅取消 | 下一轮刷新进入 401 / 403 降级；key 或订阅恢复后由后续调度自动恢复 |
| 账号切换（key 被换） | 完整 `accountID` 变化时立即清旧内存与持久化快照，新账号不得继承旧数字 |
| rate-limited 三窗口全部命中 | 作为有效成功快照，三个窗口均显示 0% 剩余红档 |
| 用户同时通过 OpenCode 改 key | 每次刷新前重读 auth；文件读取保持只读，不假设其它进程的写入时机或方式 |
| `auth.json` 损坏 / 非 JSON | 固定类别日志 + "未检测到"；不抛错影响其它 Provider，也不回退使用同文件中的不可信内容 |
| key 含换行、NUL 等控制字符 | 去除首尾空白后再拒绝任意控制字符；为空视为无凭据；不记录原值 |
| macOS GUI 环境变量变化 | `OPENCODE_API_KEY` 仅作兜底；环境变化通常需重启 App 才生效，界面不承诺热更新 |
| 429 | 现有 10 分钟退避；手动刷新不绕过 |
| 网络 / 5xx | 同账号旧快照继续展示并附通用失败；无旧快照时显示不可用 |
| 启动读取到旧缓存 | 当前认证摘要确认前不向 UI 发布 Go 缓存；确认匹配后再恢复，避免旧账号闪现 |
| 服务识别 / 风控 | 使用 CCBar 专用 `User-Agent`，不冒充 OpenCode CLI |

## 9. 实施顺序

1. **模型、认证与客户端**：新增 `QuotaApp` / Descriptor 能力、`OpenCodeGoAuth`、无状态 `OpenCodeGoQuotaClient` 及类型化结果；同时编写认证和客户端单元测试。
2. **状态、缓存与调度**：接入 `AppState` / `QuotaRefreshPlan`；实现账号切换、缓存摘要校验、失败降级与 429 退避；补对应状态测试。
3. **能力隔离**：菜单栏、悬浮窗和相关设置统一按 Descriptor 能力过滤；确认远端 Go 订阅额度不进入 Agent 对话聚合、费用、Timeline 与 Cycles，同时既有 `opencode-go` 模型对话不被过滤或重复计入。
4. **界面接入**：Popover、Settings Accounts、Onboarding 和 tint；Accounts / Onboarding 按当前手写结构显式增加 Go，不借机重构成通用列表。
5. **工程接入**：把新增源文件与测试文件显式加入 `ccbar.xcodeproj/project.pbxproj`。
6. **静态与自动化验证**：代码审阅、`git diff --check`、认证 / 客户端 / 缓存 / 调度的聚焦测试。运行 Xcode 测试或 Debug build 前按仓库规则单独征得同意。
7. **真实验收与文档收口**：经用户允许后使用本机真实 key 做只读网络联调和 App 手动验收；通过后并入正式产品、技术、布局、设计与 README 文档，再将本草案归档到 `历史参考/`。

## 10. 验收标准

- `QuotaApp.opencodeGo` 不破坏 Codex / Claude / Cursor；旧 `quota-cache.json` 无需 schema 迁移即可解码，Go 缓存仅在完整账号摘要匹配后恢复。
- `QuotaProviderDescriptor.primaryProviders` 顺序为 Codex → Claude Code → Cursor → OpenCode Go；Popover、Settings Accounts 与 Onboarding 保持一致。
- 认证依次支持 `$XDG_DATA_HOME/opencode/auth.json`、默认 `~/.local/share/opencode/auth.json` 和 `OPENCODE_API_KEY` 兜底；仅接受 `opencode-go.type == "api"` 且非空、无控制字符的 key。
- 检测到账户且总开关启用时，Popover 显示有效窗口：`Rolling` / `Weekly` / `Monthly`；未检测到账户时整个 block 不渲染。
- `percent` 作为已用比例并规范化到 `0...100`，UI 展示剩余；窗口 `windowSeconds` 分别为 `18000`、`604800`、`nil`。
- 单个无效窗口不拖垮其它有效窗口；三窗口全无效或 envelope 改变显示不可用且不展示旧数字。
- 单个或全部 `rate-limited` 均为成功结果，显示 0% 剩余红档，不标记不可用。
- 401 / 403 保留并展示同账号旧快照和通用失败；404 / invalid payload 保留磁盘快照但 UI 不展示旧数字；429 / 网络 / 5xx 展示同账号旧快照和通用失败。
- “本轮不立即重试”不阻止后续 Scheduler；429 进入现有 10 分钟退避，手动刷新不绕过。
- key 切换后立即清理旧账号内存和持久化快照；启动时认证摘要确认前不闪现旧账号数字；`accountID` 使用完整 SHA-256，不记录到日志。
- key 不进入 cc-bar Keychain / UserDefaults / quota cache / 日志；额度快照和不可逆完整账号摘要可进入现有 `quota-cache.json`；key 只发送到 `https://opencode.ai/zen/go/v1/usage`。
- OpenCode Go 订阅额度不出现在菜单栏、悬浮窗及二者设置中，也不注入主窗口统计 / Timeline / Cycles / 按服务 / 按提供商 / 按模型；`SettingsStore.usageServiceVisibility` 不新增独立 Go 开关。
- Go 订阅额度接入不触发 `UsageApp`、`ModelProvider` 或 Agent 对话归并规则变更；现有 `OpencodeScanner` 的 SQLite 扫描路径与 prefix 剥离路径都不动，使用 `opencode-go/<model-id>` 的既有对话仍正常进入 Token 与预估费用统计。
- Go 卡片不复用 `opencodeTodayCost`，不展示今日 / 本周费用；本地日志 full rebuild 与 Go 额度互不影响。
- 请求使用 CCBar 专用 `User-Agent`；日志只记录固定错误类别和必要 HTTP 状态，不记录 key、摘要或响应 body。
- 不调用 OpenCode OAuth、不写 OpenCode SQLite / UserDefaults / cc-bar Keychain。
- 首版 `ServiceTile` fallback 显示字母 `G`，不要求新增 SVG 或 SF Symbol 特例。
- 新增 Swift 与测试文件已加入 Xcode 工程引用和对应 Build Phase；聚焦测试通过。Debug build、真实 key 网络联调和手动 UI 验收分别记录，不互相替代。

## 11. 实施门禁与完成定义

本草案经本轮修订后是 **OpenCode Go 第一版的可执行实现基线**：字段映射、状态语义、改动文件、明确不改范围、实施顺序和验收标准均已收敛。实现过程中若远端真实响应与本文契约不一致，应先回到本文修订契约，不在代码中静默猜字段。

实施前无需再做一轮架构设计，但仍有以下门禁：

1. 用户明确下达“开始实现”后再修改代码；本次“修订草案”不等于已授权代码实现。
2. 首版已固定产品决定：OpenCode Go 订阅额度与 Agent 对话用量严格分离；Accounts 提供首次默认关闭的总开关；不持久化 key、允许缓存快照和完整账号摘要；Go 卡片不展示本地费用；菜单栏 / 悬浮窗不提供占位开关；首版使用字母 `G` fallback。若要改变其中任何一项，先修订本文。
3. 实现完成不等于功能验收完成。至少需要代码静态审阅和聚焦测试；Xcode Debug build 属于编译验证，需另行同意；真实 key 网络联调及 App 手动验收需用户允许读取本机凭据并向指定端点发起只读请求。
4. 只有实现、自动化验证、真实响应核对和界面验收均完成后，才将内容并入正式文档并归档本草案。
