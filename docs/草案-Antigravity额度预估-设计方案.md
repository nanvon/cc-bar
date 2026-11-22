# Antigravity 额度用满预估与周期统计设计方案（草案）

> 状态：已实现，待手动验收（2026-11-22 按精简范围改写）
> 关联模块：`Core/Storage/QuotaCycleStore.swift`、`Core/Usage/CycleUsage.swift`、`Core/Usage/UsageService.swift`、`Core/AppState.swift`、`Main/CycleStatsView.swift`、`Main/StatsView.swift`

---

## 1. 目标与范围

主窗口「额度」页按 Claude Code 的方式显示 Antigravity 的 **Gemini 5H** 和 **Gemini WK** 两个额度池：额度用满预估、历史周期、额度变化时间线三个区块都接入。

只接入 `gemini-5h` / `gemini-weekly`。其余 4 个池（Claude 5H / WK、Argon 周、Carbon 周）不建周期、不出卡片。

不在范围内：

- 菜单栏、Popover、悬浮窗保持现状。
- 不做多池切换、不做单选 Antigravity 时按需展开其他池。
- 不做无邮箱账号键 `antigravity:primary` 到真实邮箱键的迁移（额度历史目前也没有这项迁移，两边保持一致）。

## 2. 依据

- 额度快照 `AntigravityQuotaClient` 已解析出 `gemini-5h`（5 小时）与 `gemini-weekly`（7 天）的已用比例和 `resetTime`。
- 本机用量 `AntigravityScanner` 已逐条产出请求时间、四类 token、模型名和 `conversationKey`（`antigravity:<id>`）。
- 额度历史 `QuotaHistoryStore.record` 已按 id 记录这两个池，时间线只差 UI。

## 3. 实现

### 3.1 周期记录（`QuotaCycleStore.record`）

- Antigravity 按 id 从 `snapshot.allLimits` 取 `gemini-5h` / `gemini-weekly`，不读 primary / secondary 槽位：账号含 Argon 时槽位会错开。Codex / Claude 不变。
- **跳过 0% 采样**：未消耗的池子 `resetTime` 等于「采样时刻 + 窗口时长」，每次刷新都会顺延，写入会不断生成假周期。用量 >0 后服务端锁定 `resetTime`，这时再建周期，`startAt = resetsAt - 窗口时长`。
- 每种窗口只记一个池，周期匹配 / 合并逻辑无需加 `limitID` 维度，对 Codex / Claude 无影响。
- `AppState` 在 Antigravity 额度刷新成功和启动补记缓存时调用 `recordQuotaCycles`，账号键用 `QuotaHistoryAccountKey.antigravityPrimary(email:)`，与额度历史一致。

### 3.2 用量归集（`CycleUsageAggregator`）

- `cycleApp(app:model:)` 对 Antigravity 只放行计入 Gemini 共享池的模型：`gemini-*` 中除 `gemini-4-argon`、`gemini-4-carbon` 以外的模型（两者有独立周额度池）。Claude / GPT 及 `unknown` 不计入。
- 周期卡的「首个采样晚于周期起点 10 分钟即标为不完整」规则不适用于 Antigravity：周期本来就从首次消耗后才建立，起点之前没有用量。

### 3.3 扫描与重建（`UsageService`）

Antigravity 每次把变动对话整库重读，给出的是对话完整用量，处理方式与 OpenCode 相同：

- 增量扫描：`cycleAggregator.replaceConversations(app: .antigravity, ...)` 按对话替换周期桶，不累加。
- `requiredCycleSourceApps` 纳入 `.antigravity`，首次重建、受限重建、安全重算都扫描 Antigravity 对话库。
- 读不出的库：首次重建时记为来源失败，下轮重试；受限重建与安全重算时该对话沿用已有周期桶。

### 3.4 界面

- `StatsView.quotaApps` 纳入 Antigravity，侧栏「全部」和单选「Antigravity」都显示。空态文案改为「只有 Codex、Claude Code 与 Antigravity 提供额度周期。」
- 周期卡标题为 `Antigravity · Gemini 5 小时` / `Antigravity · Gemini 周`，卡内结构与 Claude 完全相同。
- 宽画布一行最多 4 张卡：「全部」视图 6 张卡时，Antigravity 两张换到第二行。
- 历史周期面板标题为 `Antigravity · Gemini`。
- 额度变化时间线增加 Antigravity 账号面板，窗口按 id 取 `gemini-5h` / `gemini-weekly`。

## 4. 风险

| 风险 | 表现 | 处理 |
| --- | --- | --- |
| Argon / Carbon 请求是否也扣 Gemini 5H / WK | 若会扣，本机用量偏少，用满预估偏低 | 发一次 Argon 请求，对比前后 Gemini 5H 百分比；若会扣，只需在 `cycleApp` 里放行这两个模型 |
| 新模型编号未收录 | 记为 `unknown`，不计入 | 补齐 `AntigravityScanner` 映射后，安全重算会补回 |
| 其他设备 / 网页端消耗 | 官方已用比例高于本机用量，预估偏低 | 与 Codex / Claude 相同，区块说明已写「仅供参考」 |
| 刚重置回 0% 但旧周期未到期 | 0% 采样被跳过，旧周期保持重置前的比例直到到期 | 首次产生用量时建立新周期，并截断旧周期 |

## 5. 验收

- 「全部」视图第一行 Codex / Claude 四张卡，第二行 Antigravity 两张卡；单选 Antigravity 只显示这两张。
- 核对 Gemini 5H / WK 的已用比例、重置倒计时、进度条颜色（≥20% 石墨灰、<20% 橙、=0 红）。
- 未消耗时 `quota-cycle-history.json` 不出现 Antigravity 周期。
- 时间线出现 Antigravity 面板。
