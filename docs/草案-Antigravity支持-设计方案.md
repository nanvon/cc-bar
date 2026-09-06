# 重新支持 Antigravity 用量查询实现方案（OpenUsage / CodexBar 架构）

> 状态：**已落地**。`Core/Credentials/AntigravityCredentials.swift`（jetski 优先 + `oauth_creds.json` 兜底、双 client 刷新、secret 从本机官方组件提取）与 `Core/Quota/AntigravityQuotaClient.swift`（`loadCodeAssist` + `retrieveUserQuotaSummary` + `fetchAvailableModels` + `retrieveUserQuota` 四段富化）已实现，Popover、菜单栏、悬浮窗、设置账号行与 Onboarding 均已接入，Provider 默认开启。行为已同步到产品需求 §1/§3/§5、技术实现 §5.5/§6.1、设计风格 §4.2 与界面布局。Antigravity 没有本地日志，不进入主窗口用量统计。本文保留为设计与调研的追溯材料。

本方案旨在为 cc-bar 重新接入 **Antigravity（Google Antigravity / Gemini Code Assist）** 的额度与状态展示。
与旧版必须强依赖运行中本地进程（`ps` / `lsof` / 本地 127.0.0.1 端口）不同，本次接入采用与 **OpenUsage**、**CodexBar** 及现有 Codex/Claude 完全对齐的**「本机凭据复用 + 云端配额直连」**架构。电脑无需打开 VSCode / Antigravity App，菜单栏即可在后台静默刷新实时额度。

---

## 架构对比与核心决策

| 维度 | 旧版方案（已废弃） | 本次方案（OpenUsage 模式） |
| :--- | :--- | :--- |
| **工作前提** | 必须打开 Antigravity.app 或开着 VSCode 激活插件 | **无需开任何 IDE/App**，开机即用 |
| **凭据来源** | 每次扫描 `ps` 提取命令行 `--csrf_token` | 读取本机 `~/.gemini/jetski-standalone-oauth-token`（优先，Antigravity 生态真源）或 `~/.gemini/oauth_creds.json`（兜底） |
| **通信链路** | `lsof` 找本地动态端口 → 发往 `https://127.0.0.1:<port>` | 直接发往 Google Cloud Code 官方配额端点（HTTPS） |
| **Token 维护** | 随进程生命周期生成与销毁 | 本地自动按需通过 Google OAuth 端点静默续期（无弹窗） |
| **性能与功耗** | 定时启动 `ps` 和 `lsof` 探测进程，开销较大 | 纯网络异步请求，毫秒级响应，0 系统级进程损耗 |
| **产品一致性** | 唯一一个依赖前台进程的异类 | 与 Codex、Claude 架构完全统一（读取凭据 → 云端直连） |

---

## User Review Required

> [!IMPORTANT]
> **1. 凭据获取前提**：本方案依赖用户在当前 Mac 上通过官方渠道（VSCode Google Antigravity 插件、Antigravity CLI 或原 App）**成功登录过一次 Google 账号**，本地生成了 `~/.gemini/` 下的 OAuth 凭据。若从未登录过，cc-bar 将展示“未配置/未登录”引导。  
> **2. 顺序规范**：根据项目全局规则与规范，菜单栏和 Popover 中的展示顺序严格保持：**Codex → Claude → Antigravity**。

---

## Open Questions

> [!NOTE]
> **双模兜底设计**：是否保留轻量本地进程探测作为 Fallback 兜底？  
> *推荐策略*：默认优先使用云端凭据直连模式（Cloud Mode）；如果用户刚登录尚未写盘或有异常，可选回退探测本地运行中的 Language Server。

---

## Proposed Changes

### 1. 凭据管理层 (Credentials)

#### [NEW] [`Core/Credentials/AntigravityCredentials.swift`](file:///Users/nanvon/Code/cc-bar/Core/Credentials/AntigravityCredentials.swift)
- 负责从本机读取 Google 登录凭据：
  1. 优先读取 `~/.gemini/jetski-standalone-oauth-token`（Antigravity 生态真源：agy CLI / IDE 插件登录即写此文件，access_token 为不透明字符串，refresh_token 续期后回写此文件）；
  2. 兜底读取 `~/.gemini/oauth_creds.json`（旧版 Gemini CLI 遗留，已被 Google 弃用，仅 jetski 不存在时读取）；
  3. 账号身份（邮箱 / 展示名 / plan）由云端 `loadCodeAssist` 响应回填——jetski 的 token 本地无法解析出邮箱（非 JWT）。
- 实现 Token 静默自动续期：
  - 检查 Token 是否临近过期（提前 5 分钟）；
  - 使用 Google OAuth 官方刷新端点 `POST https://oauth2.googleapis.com/token`，携带 `refresh_token` 与 client_id 换发新 `access_token` 并回写缓存（jetski 写回 `jetski-standalone-oauth-token`，oauth_creds 写回 `oauth_creds.json`）；
  - **client_secret 不硬编码进源码**：刷新时从本机已安装的官方组件按需提取（Antigravity `~/.gemini/bin/agy` 二进制与 Gemini CLI npm bundle 内嵌各自的 secret），并保留「无 secret」兜底候选。提取结果按就近配对 + 顺序平摊规则解析，避免把官方客户端密钥带入开源仓库与分发产物。

---

### 2. 额度客户端与数据模型 (Quota)

#### [NEW] [`Core/Quota/AntigravityQuotaClient.swift`](file:///Users/nanvon/Code/cc-bar/Core/Quota/AntigravityQuotaClient.swift)
- 直连 Google Cloud Code 配额接口（优先使用官方 Antigravity 2.12.0 实际调用的 `daily-cloudcode-pa.googleapis.com`，主域 `cloudcode-pa.googleapis.com` 仅在请求失败时回退；按信息完整度依次四段富化，任一失败保留已有数据）：
  - 端点 1：`v1internal:loadCodeAssist` —— 返回账号 tier / plan 与基础信息；Google AI Pro 账号会同时返回基础 `currentTier=free-tier` 与付费 `paidTier=Google AI Pro`，会员身份以 `paidTier` 为准；
  - 端点 2：`v1internal:retrieveUserQuotaSummary` —— **权威分组源**：返回 `groups[]`（Gemini Models / Claude and GPT models），每组含 5h + weekly 两个 bucket（`gemini-5h`/`gemini-weekly`、`3p-5h`/`3p-weekly`），与官方 UI 的 5 小时 / 周数据一致；
  - 端点 3：`v1internal:fetchAvailableModels` —— Gemini 轮换窗口（仅 summary 缺失时的补充）；
  - 端点 4：`v1internal:retrieveUserQuota` —— 按模型分桶的剩余额度（仅 5h 语义，无周/分组；summary 不可用时兜底）；
  - 均携带 Header：`Authorization: Bearer <access_token>`（后三个端点不接受 `cloudaicompanionProject`，空 body）
- 解析配额模型（桶语义 → 数据模型映射）：
  - `groups[].buckets[]` 按 `bucketId` 前缀（`gemini-*` / `3p-*`）与 `window`（weekly / 5h）归类，组 displayName 仅兼容兜底。展示以 Gemini 为关注点（与官方分组同名）：
    - `gemini-5h` → 主条 `primaryLimit`（displayName "Gemini 5H"）；
    - `gemini-weekly` → 副条 `secondaryLimit`（displayName "Gemini WK"）；
    - `3p-5h` / `3p-weekly` → `auxiliaryLimits` 两行（displayName "Claude 5H" / "Claude WK"）；
  - 无分组源（仅 buckets/models 兜底）时退化为旧行为：5h 主条 + weekly 副条，Gemini 窗口保留 `geminiWindow` / `geminiWeekly` 供细行展示；
  - 所有额度窗口只使用服务端返回的 `resetTime`，不按窗口标准时长推算未来重置时间；`retrieveUserQuota` 的 `remaining=1` 且无 `reset` 未消费占位桶直接忽略；
  - 提取账户订阅层级（Tier / Plan）——优先取 `paidTier.name` / `paidTier.id`，没有付费层级时回退 `currentTier.id`；

#### [MODIFY] [`Core/Quota/QuotaModels.swift`](file:///Users/nanvon/Code/cc-bar/Core/Quota/QuotaModels.swift)
- 在 `QuotaApp` 枚举中恢复 `.antigravity`：
  - 内部标识 `"antigravity"`，展示名称 `"Antigravity"`；
  - 排序权重置于 Codex、Claude 之后。
- 在 `QuotaSnapshot` 中恢复可选字段：
  - `geminiWindow: QuotaWindow?`
  - `geminiWeekly: QuotaWindow?`

#### [MODIFY] [`Core/Quota/QuotaRefreshPlan.swift`](file:///Users/nanvon/Code/cc-bar/Core/Quota/QuotaRefreshPlan.swift)
- 将 `.antigravity` 纳入自动刷新调度计划计算。

---

### 3. 全局状态与持久化 (Core / Storage)

#### [MODIFY] [`Core/AppState.swift`](file:///Users/nanvon/Code/cc-bar/Core/AppState.swift)
- 恢复 Antigravity 的配额快照状态：
  - `antigravitySnapshot: QuotaSnapshot?`
  - `antigravityAccount: AntigravityAccount`
  - `antigravityError: String?`
- 在 `refreshAllQuotas()` 和按应用刷新方法中加入 Antigravity 刷新分支；
- 失败时保留最后一次成功快照（满足不白屏、保留已有数据的全局规则）。

#### [MODIFY] [`Core/Storage/Settings.swift`](file:///Users/nanvon/Code/cc-bar/Core/Storage/Settings.swift)
- 恢复 Antigravity 相关偏好：
  - `antigravityEnabled: Bool` (默认 true)
  - `menuBarShowAntigravity: Bool`
  - `floatingShowAntigravity: Bool`

#### [MODIFY] [`Core/Storage/QuotaCache.swift`](file:///Users/nanvon/Code/cc-bar/Core/Storage/QuotaCache.swift)
- 恢复持久化缓存中对 `antigravity` 键名与快照的编解码支持。

---

### 4. 界面与设计系统 (UI & Assets)

#### [MODIFY] [`Main/DesignSystem.swift`](file:///Users/nanvon/Code/cc-bar/Main/DesignSystem.swift)
- 恢复 `Color.antigravityAccent` 品牌识别色（石墨灰，仅用于 Logo 与品牌 Tile，额度状态色统一走 4 档交通灯规范）。

#### [NEW] 资源文件恢复
- `Resources/Assets.xcassets/AntigravityAccent.colorset`
- `Resources/Logos/antigravity.svg`
- 在 `ccbar.xcodeproj/project.pbxproj` 中恢复相应资源索引。

#### [MODIFY] [`MenuBar/PopoverRootView.swift`](file:///Users/nanvon/Code/cc-bar/MenuBar/PopoverRootView.swift)
- 恢复 Antigravity 配额卡片，与 Codex/Claude 同构：
  - 大数字主条 = Gemini 5h（标签显示 Gemini 5H），下方副条 Gemini WK + Claude 5H + Claude WK 普通行（displayName 驱动）；
  - 标签逻辑：带 displayName 的额度行（Antigravity）优先显示组名，其余服务仍按窗口类型显示 5HOUR/WEEKLY；
  - 排版在 Codex 和 Claude 之后。

#### [MODIFY] [`Settings/SettingsRootView.swift`](file:///Users/nanvon/Code/cc-bar/Settings/SettingsRootView.swift)
- 恢复设置页中的 Antigravity 账号行、凭据状态展示、菜单栏与悬浮窗展示开关。

#### [MODIFY] [`Onboarding/OnboardingView.swift`](file:///Users/nanvon/Code/cc-bar/Onboarding/OnboardingView.swift)
- 恢复初次引导流程中对 Antigravity 本机凭据的自动探测与勾选。

---

### 5. 文档规范同步 (Docs)

严格遵循规范，变更数据结构与功能时同步更新相关文档：
- [MODIFY] [`docs/产品需求.md`](file:///Users/nanvon/Code/cc-bar/docs/产品需求.md)
- [MODIFY] [`docs/技术实现.md`](file:///Users/nanvon/Code/cc-bar/docs/技术实现.md)
- [MODIFY] [`docs/界面布局.md`](file:///Users/nanvon/Code/cc-bar/docs/界面布局.md)
- [MODIFY] [`docs/设计风格.md`](file:///Users/nanvon/Code/cc-bar/docs/设计风格.md)
- [MODIFY] [`README.md`](file:///Users/nanvon/Code/cc-bar/README.md) 与 [`README_EN.md`](file:///Users/nanvon/Code/cc-bar/README_EN.md)

---

## Verification Plan

### 静态检查与单元测试
- 针对 `AntigravityCredentials` 进行单测：测试本地凭据 JSON 解析、过期判断、Token 提取，以及 **client_secret 从本机官方组件提取与配对**（npm bundle / agy 二进制路径）。
- 针对 `AntigravityQuotaClient` 配额解析逻辑进行单测：测试 Claude/GPT 分组与 Gemini 独立分组的数据提取与计算。
- 针对 `QuotaCache` 编码与兼容性进行测试。

### 真实环境验证
1. 保证 VSCode / Antigravity 未运行；
2. 启动 cc-bar，验证菜单栏与 Popover 是否能够正常显示 Antigravity 的实时额度、邮箱与重置时间；
3. 验证 4 档交通灯状态色与 GM/GW 细行展示；
4. 验证设置页开关切换与持久化存储。
