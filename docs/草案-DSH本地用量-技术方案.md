# 草案 · DSH 本地用量接入技术方案

> 状态：**已实施**（2026-09-24）。§7 的 S0–S7 全部落地：工程引入官方 `facebook/zstd` 1.5.7（App 与 CCBarTests 都链接 `libzstd`）、`Core/Usage/DshZstdFrames.swift` + `DshZstdDecoder.swift` + `DshSessionScanner.swift` + `DshContributionStore.swift` + `DshContributionRollup.swift`、`Core/Storage/DshContributionCache.swift`、`UsageService` 第 5 个扫描任务、DeepSeek 分段价、统计页 / 设置页 / 脱敏诊断接入。验证：`xcodebuild` Debug 构建通过；`xcodebuild test` 287 通过 / 1 跳过 / 0 失败。
>
> 实施中与本文档的三处偏差（有效内容已并入常驻文档，这里只作追溯）：
> 1. **S1 拆成两个文件**：§7 S1 原写「`DshZstdFrames.swift`：帧边界扫描 + 单帧解码」，实际拆为 `DshZstdFrames.swift`（纯 Swift 帧边界扫描，无外部依赖）与 `DshZstdDecoder.swift`（`import libzstd` 的单帧解码）。
> 2. **UI 穷举分支提前到 S2 落地**：给 `UsageApp` 增加 `dsh` 会同时打断 Core 与 UI 的穷举 `switch`，不补齐就无法编译，因此 `StatsView` / `DesignSystem` / `ConversationStatsView` / `CycleStatsView` / `SettingsRootView` 的分支随 S2 一起提交，S6 只补识别色、设置探测与诊断。
> 3. **`DshContributionStore.apply` 返回 `Update{contributions, changed}`**：第 5 个扫描器没有 seen 集合兜底，未落盘的一轮会重扫同样的帧，因此需要 `changed` 供 `UsageService` 做「只在真的落盘时才计入聚合」的门控。
>
> 另：本机只读快照的样本量随时间变化（§2.2 记的是 3 个项目 / 19 个会话 / 2498 帧），实施后复核为 24 个规范日志 / 3151 帧，0 撕裂 0 损坏。
>
> 2026-09-23 的调研依据：本机 DSH Desktop 2.0.13、随包的 `@deepseek-ai/dsh-session-persistence-jsonl` 0.1.5-rc.2、会话日志与 cc-bar 当时的代码。
>
> 同日已对照现有实现确定四项实施决策与实施步骤，见 §6、§7。

## 1. 结论与第一版范围

DSH CLI 与当前稳定版 DSH Desktop 在默认配置下共用 Harness home `~/.dsh`，会话日志位于 `~/.dsh/sessions`。cc-bar 第一版只从这个默认根**只读**采集，统一显示为一个「DSH」本地用量服务，不按 CLI、Desktop 或 profile 拆分。Desktop 自定义数据目录、显式 `DSH_HOME`、Beta home 与自定义持久化 root 不做自动发现；没有默认日志不能据此断定用户未安装 DSH。

接入主窗口统计的 Overview、Conversations、用量图表以及按服务、模型、提供商分组。**不接入 Cycles 和额度 Timeline**：它们依赖 Codex / Claude 的额度周期和额度历史；DSH 没有对应 `QuotaApp`。不进入菜单栏、Popover、悬浮窗或 Onboarding。设置页增加统计服务开关与本地日志探测；诊断只记录默认根存在性、候选文件数量和扫描结果，不记录会话路径、标题、正文或凭据。

默认日志是 zstd。Apple `Compression` 公开算法集合**没有 Zstandard**，旧草案所说的 `COMPRESSION_ZSTD` 不存在。第一版要读默认日志，建议引入 [Zstandard 官方仓库的 `libzstd` Swift Package，固定 v1.5.7](https://github.com/facebook/zstd/blob/v1.5.7/Package.swift)，由 Xcode 工程链接其 `libzstd` 产品。不调用用户机器上的 `zstd` 命令，也不依赖 DSH Desktop.app 内部文件。[Apple 算法列表](https://developer.apple.com/documentation/compression/algorithm)与本机 Xcode SDK 的 `compression.h` 都不含 zstd。

## 2. 调研依据

### 2.1 默认数据根与 Desktop

随 Desktop 安装的 `@deepseek-ai/dsh-home-paths` 按“显式路径 → `DSH_HOME` → `~/.dsh`”解析 home；`@deepseek-ai/dsh-base/cordis.patch.yml` 把持久化 root 配为 `dshHomePath('sessions')`。当前 Desktop stable 默认 home 是 `~/.dsh`，启动时将选定 home 注入 `DSH_HOME`。profile 只决定插件组合。Desktop 另有自定义数据目录功能，因此“永远只有 `~/.dsh`”不是 DSH 的通用契约，只是本方案的支持范围。参见 [DSH 官方持久化说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/session/session-persistence-jsonl/README.md)。

本机 `~/.dsh/sessions` 存在；`/Applications/DSH Desktop.app` 为 2.0.13，随包持久化模块为 0.1.5-rc.2；Desktop 的 `data-directory/state.json` 当前不存在。没有读取设置文件或凭据。旧版 `~/Library/Application Support/dsh-desktop/harness/sessions/` 不作为候选根。

### 2.2 本机只读快照

2026-09-23 对默认根做字段统计：每个会话目录只取数值最高的规范 generation，逐帧解压，仅提取记录类型、会话关系、模型与 usage 数值；没有输出或保存消息正文、标题和原始路径。以下是会变化的样本数据，不能写成实现常量。

| 项目 | 本次结果 |
|---|---:|
| 项目目录 / 会话目录 | 3 / 19 |
| 选中日志编码 | zstd 19、明文 0 |
| 同目录另有旧 generation | 1 |
| 完整 zstd 帧 | 2,498 |
| 压缩 / 解压字节 | 4,825,778 / 17,143,475 |
| 顶层 / 一层子代理 / 更深子代理 | 9 / 5 / 5 |
| `assistant/message` / 其中带 usage | 695 / 693 |
| `data.usage` 与 stream usage 同时出现 / 不等值 | 693 / 0 |
| input / output / cacheRead / cacheWrite tokens | 1,287,386 / 507,382 / 58,163,712 / 0 |

直接把整份拼接帧文件交给一次单帧解压，只得到第一帧会话头；上述统计先定位帧边界，再逐帧解码。这是实现必须遵守的物理格式。

### 2.3 文件与记录

目录形态是 `sessions/<项目段>/<会话段>/<日志文件>`。目录段经过编码，不从目录名反推原始 `cwd` 或 session id；从文件内 `session` 头取 `id`、`cwd`、`parentSession` 与 `delegationDepth`。无 cwd 的 `_no-cwd` 项目段也须处理。

只识别规范名：v0 的 `session.jsonl.zstd` / `session.jsonl`，正整数 vN 的 `session.vN.jsonl.zstd` / `session.vN.jsonl`。忽略大写、`v0`、前导零、锁文件与临时文件。一个会话目录只选**版本号最高**的规范日志；相同版本的两种编码并存属于异常，cc-bar 可固定优先 zstd 并报告诊断。官方在配置编码与现存编码冲突时会报错，cc-bar 的宽容读取不表示 DSH 可以继续写该目录。[官方迁移说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/.agents/notes/implemented/architecture/2026-08-31-released-session-format-migrations.md)确认旧 generation 保留，新文件包含同一段逻辑历史。

当前格式只消费三类记录：`session`（元数据）、`session/title`（最后一个有效标题）、`assistant/message`（用量）。其他事件不计费，不从正文推算 token。用量优先取 `data.usage`；缺失时取 `data.stream` 最后一个 usage chunk。两处是同一份用量，**不可相加**。两处都缺失时既不计 token，也不计请求。`time` 是 Unix 毫秒，转为 `Date` 后用现有 `UsageDay.startOfDay` 计算本地日。

| DSH usage 字段 | `UsageEntry` | 规则 |
|---|---|---|
| `inputTokens` | `inputTokens` | 已排除缓存读写，不再扣减 |
| `outputTokens` | `outputTokens` | 原值 |
| `cacheReadTokens` | `cacheReadTokens` | 可选，缺省 0 |
| `cacheWriteTokens` | `cacheCreationTokens` | 可选，缺省 0 |
| `reasoningTokens` | 无额外字段 | 属于 output 子集，不重复计数 |
| `totalTokens` | 校验字段 | 有值时校验四项之和，不参与二次求和 |
| 一条有效 `assistant/message` | `requestCount = 1` | 无 usage 不计请求 |

模型标签按 `source.provider/source.model` 组合，外层 provider 只加一次，例如 `commandcode/deepseek/deepseek-v4.1-flash`。`Pricing.normalize` 再剥前缀查价。日志中的 provider 可能是转发商，不证明用户按 DeepSeek 官方 API 价付款。

## 3. 解码与增量扫描

### 3.1 zstd 依赖与帧处理

在 `ccbar.xcodeproj` 中加入官方 `facebook/zstd` package，固定 v1.5.7，App 和测试 target 链接 `libzstd`。不用 Homebrew、DSH 的 Node 运行时或私有系统 dylib；既有 `scripts/build.sh` 和 GitHub macOS runner 都须能解析此依赖。[官方 C 实现](https://github.com/facebook/zstd)采用 BSD 或 GPLv2 双许可，接入时保留选定许可声明。增加的构建时间和应用体积要在实施时测量。

Swift 封装只暴露“解码**一个完整帧**”接口。用 `ZSTD_createDCtx` / `ZSTD_decompressStream` / `ZSTD_isError` 检查解码错误与帧末状态，让 libzstd 校验 checksum；输出按块收集并设置每帧解压上限，避免损坏文件造成无界分配。`ZSTD_findFrameCompressedSize` 可用作边界交叉校验；API 用法以[官方 `zstd.h`](https://github.com/facebook/zstd/blob/v1.5.7/lib/zstd.h)为准。

按 DSH 随包源码的 `scanZstdFrames()` 规则扫描 magic、frame descriptor、可选字典与内容大小头、各 block 和 checksum 长度。只将完整帧交给 libzstd。尾部字节不足时返回 `tornStart`，本轮不消费；非法 magic、保留位、非法 block 或 checksum 失败视为损坏。偏移与长度加法要逐次检查越界。

### 3.2 watermark 与失败处理

`ScanFileState.offset` 对 zstd 恒落在上一个**成功解析并入账的完整帧末尾**；明文恒落在上一个完整换行末尾。未变化文件按 mtime + size 跳过，变化文件从旧 offset 续读。明文复用 `JSONLLineReader` 的整行规则。zstd 按块读取，只缓存当前未完成帧及其解压输出；本机首扫较小不构成整份文件无上限读取的理由。

每个文件先局部暂存本轮 entries、seed 和新 offset。解码、UTF-8、JSON 或读取失败时，丢弃**该文件本轮结果**并保留旧 watermark，其他文件照常处理。正常撕裂尾帧不算失败。新增完整帧只计一次。文件被截断或原地替换时不能简单将 offset 归零后累加，否则历史用量会翻倍。

### 3.3 逐会话贡献与 generation 切换

现有 `UsageAggregator.ingestLocal`、`ConversationAggregator.ingest` 都是累加。若 v0 已入账，DSH 随后发布内容等价的 v3，从新路径全量扫会把旧历史再加一次。旧草案所说的“新 key 天然安全”错误。单纯清掉 DSH 桶并重扫**当前所有日志**也有缺陷：此前已删除的会话文件无法重读，其历史桶会在这次重建中消失。

第一版增加持久化的 **DSH 逐会话贡献缓存**。每个 session id 保存：所选 generation 路径、文件身份（device/inode 与 mtime/size）、帧或行 watermark、头部元数据，以及按日、模型、速度汇总的该会话 token、请求数、费用分项与首末时间。它是本地派生数据，不含消息正文。缓存与两个主 rollup 同级落在 `~/Library/Application Support/CCBar/`，不放 `~/Library/Caches`——Caches 会被系统清理，而这份缓存的意义正是保住已删除会话文件的历史（见 §6 决策 2）。普通增量只把新 entries 合入对应会话贡献；已有会话切换 generation、原路径被替换或截断时，从新文件零 offset 重算并**替换该会话贡献**。新文件解码失败则保留该会话旧贡献和 watermark，报告扫描不完整，不把新旧版本相加。

每次贡献或父子关系图变化，从全部逐会话贡献重新归并出 DSH 的日桶与对话桶，只替换 `UsageAggregator`、`ConversationAggregator` 的 DSH 分区；Codex、Claude、Pi、OpenCode 保持原样。两个主 rollup、逐会话贡献缓存与 scan-state 必须带同一个 generationID，按“派生快照先写、watermark 最后写”的现有顺序提交。启动时若贡献缓存缺失、版本不符或代次不一致，就从现存 DSH 日志重建，不能将不匹配的贡献与旧桶混用。旧 generation 移除后，只要该会话贡献仍在，版本切换仍可精确替换此会话，并保留其他已清理会话的历史。

实施时给两个聚合器加按 `UsageApp` 替换分区的最小接口。普通源文件删除沿用现有扫描器保留历史入账的语义：保留其贡献，不因日志清理倒扣历史。若逐会话贡献缓存本身损坏或丢失，只能从仍存在的日志恢复；已删除源文件无法恢复，这是第一版限制，不可静默宣称历史完整。未来要支持删除同步，另定产品规则。

## 4. 子代理与预估费用

### 4.1 子代理归并

DSH 子代理有独立文件和 session id，`parentSession` 指向直接父会话。本机样本为 9 个顶层和 10 个子代理。父文件记自己的模型调用，子文件记子代理用量。第一版将子代理归到所属**根会话**，Conversations 只显示一行并标 `includesSubtasks`；总量不因归并改变。

每轮从所选日志头与逐会话贡献缓存建 `id → parentSession` 图，再解析根 id；设置环与深度上限。`conversationKey = "dsh:<根 id>"`。根会话 cwd、标题、sourcePath 优先。父文件暂缺时子会话先作为根，不丢用量；**父文件后来出现或父链改变时重新归并已有逐会话贡献**，不能只给未来条目换 key。相同 id 落在多个项目目录按损坏处理，不重复计费。扫描状态持久化 `conversationID`、`conversationCwd`、`fallbackTitle`、`conversationParentSession`；标题后到可通过现有 seed 合并，不需重算 token。

### 4.2 费用口径

DSH 日志提供 token usage，**没有可当作真实账单的费用**。沿用 `Pricing.resolveCostBreakdown`：有可靠价目时计算 USD API 等值估算，缺价时 `costUSD = nil`、token 仍入账。经过 `commandcode`、`opencode-go` 等转发商的调用，模型官方价可能不同于实付价，界面和文档不能称其为真实花费。

[DeepSeek 官方价格页](https://api-docs.deepseek.com/quick_start/pricing/)与[变更日志](https://api-docs.deepseek.com/updates)给出的 Flash（V4.1-Flash）价：2026-09-10 04:00 UTC 起高峰价为未命中缓存的输入 0.3、缓存命中的输入 0.006、输出 1.2（USD / 百万 tokens），空闲时段为高峰的一半；2026-08-16 16:00 UTC 起至 2026-09-10 04:00 UTC 之间为 0.44 / 0.014 / 1.32。官方明确旧名 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 仍被接受、请求由 V4.1-Flash 服务并按 Flash 价计费；本机日志里的 `deepseek-v4.1-flash` 是此方案要处理的本地模型标识，不声称它也是官方请求参数。

第一版不用「DSH 专用兜底价」，改为把上述官方节点做成**分段生效价**，同时挂在四个归一化 key 上（`deepseek-flash`、`deepseek-v4-flash`、`deepseek-v4-flash-vision-exp`、`deepseek-v4.1-flash`），数值与实现约束见 §6 决策 1。这样同一模型在 DSH / Pi / OpenCode 下口径一致，历史天数仍落在旧价（分段按天判定，手动重算也不会改写历史），也不影响其他服务价目。

扁平价无法准确表达每日峰谷、历史调价与转发商收费，因此金额始终是估算。若未来 DSH 日志出现 cache write，而模型没有可靠写入费率，不能把未知费用伪装成已知零费用。后续调整价格规则、并要求历史金额自动更新时，按第 5 节的缓存版本与重建规则处理。

## 5. 与当前代码的接线

| 位置 | 必要改动 |
|---|---|
| `Core/Usage/` | 新增 DSH 目录扫描、帧封装；`UsageApp` 加 `dsh` 和 `localApps` 条目 |
| `Core/Usage/UsageService.swift` | 后台并行扫描 DSH；按第 3.3 节更新逐会话贡献并替换 DSH 聚合分区；纳入进度、错误、持久化与扫描日志，DSH 的 `failedFileCount` 计入 `lastError`（`pi` / `opencode` 现状不动，见 §6 决策 4）。**不加入 `cycleEntries`** |
| `Core/Storage/ScanCache.swift` | 保存 DSH watermark、选中 generation、文件身份与父关系；`ScanState.currentVersion` 14 → 15 |
| 新增 DSH 贡献缓存与主 rollup | 落 `~/Library/Application Support/CCBar/`（决策 2）；持久化逐会话日、模型、速度聚合及元数据，和 scan-state、日/对话 rollup 同代；`UsageRollupPayload.currentVersion` 9 → 10、`ConversationRollupPayload.currentVersion` 7 → 8。DSH 不增加周期桶 |
| `Core/Usage/UsageLogWatcher.swift` | 将默认 `~/.dsh/sessions` 加入候选根；根未创建时沿用现有发现与 30 分钟兜底 |
| `Core/Usage/Pricing.swift` 等 | `case .dsh` 穷举分支（`Pricing.price` 的 fast 分支、`PricingCatalogStore.rate`、`ModelProvider`）；按 §6 决策 1 补四组 Flash key 的分段价（`deepseek-v4-pro` 是否一并纳入待确认）；不改其他服务价目 |
| 主窗口、设置、诊断 | 服务名、识别色、Stats 过滤项、Conversations 映射、统计服务开关、数据源探测与脱敏诊断；Cycles 和额度 Timeline 保持现状 |
| Xcode 工程与发布 | 工程是 `objectVersion 77` 的显式文件引用（无 file-system synchronized group），新增源文件要同时改 `PBXBuildFile` / `PBXFileReference` / group children / Sources 阶段；加官方 `facebook/zstd` v1.5.7 远程包与 product `libzstd`，**App 与 CCBarTests 两个 target 都要挂**（两者当前 `packageProductDependencies` 均为空，仓库现无任何 SPM 依赖）；源码包不涉及签名，但保留许可声明；后续验证 Debug 和仓库既定发布脚本 |

默认开关沿用 `SettingsStore`：除 Cursor 外的新 `UsageApp` 默认可见。未装 DSH 的用户会看到空服务项，和 Pi / OpenCode 现状一致；若未来要“未检测到则隐藏”，另加可用性状态，不要改写用户偏好。

首版落地要使旧扫描状态和主 rollup **一起失效**；只清 watermark 会重复计费，只清桶会漏计。后续 DSH 解析或价格规则改变，要重算受影响的逐会话贡献，再替换 DSH 分区；父子归属改变只需重新归并贡献。首次版本升级按现有机制全仓重建，实施验收要记录其他日志重扫成本。

## 6. 实施决策（已定）

### 决策 1：价格口径用分段生效价，不用「DSH 专用兜底价」

四个归一化 key 共用同一套分段规则（`deepseek-v4.1-flash` 是本机日志标识，其余三个是官方现名与兼容名）：

| 归一化 key | `< 2026-08-16 16:00 UTC`（沿用 `Pricing.table` 现值） | `≥ 2026-08-16 16:00 UTC` | `≥ 2026-09-10 04:00 UTC` |
|---|---|---|---|
| `deepseek-flash` / `deepseek-v4-flash` / `deepseek-v4-flash-vision-exp` / `deepseek-v4.1-flash` | input 0.14 · cacheRead 0.0028 · output 0.28 | input 0.44 · cacheRead 0.014 · output 1.32 | input 0.3 · cacheRead 0.006 · output 1.2 |

- `input` 是未命中缓存的输入价，`cacheRead` 是命中缓存的输入价，`cacheCreation` 恒 0，与 `ModelPrice` 字段一一对应；单位 USD / 百万 token。
- 两段新价都取**高峰价**，是估算上界（真实账单按时段计费，空闲为半价）。第一版不实现峰谷时段与中国法定假日日历，金额偏高但不低报。
- 官方称 `deepseek-v4-pro` 自 2026-08-16 起即为 input 1.32 · cacheRead 0.044 · output 3.96，此后未再调整；表内现值 0.435 · 0.003625 · 0.87 同样过期。**是否一并纳入待确认**：纳入则该 key 按同一分段规则修正，不纳入则维持现状。
- 实现约束（源码里是 `precondition`，违反会直接崩）：进 `timedOverrides` 的 key 必须在 `Pricing.table` 有基础价，所以四个 key 都要先补表行。进 `timedOverrides` 还等于把该 key 归入 A 类（`localOverrideKeys`），**远端价格目录对这些 key 零参与**——这是刻意选择：本地已按官方节点编码，不能让目录的单一现价覆盖分段规则。
- 规则按模型 key 生效、不分 app，所以 Pi / OpenCode 之后的 DeepSeek 估算也会对齐官方价；历史天数按分段规则仍落在旧价，满足「不静默重算历史金额」。
- key 变体按仓库既有惯例写成重复行（同 `claude-fable-5.1` / `claude-fable-5-1`），不引入别名映射机制。

### 决策 2：逐会话贡献缓存落 Application Support

`scan-state.json` 在 `~/Library/Caches`，两个 rollup 在 `~/Library/Application Support/CCBar/`。这份贡献缓存的全部意义是保住已删除会话文件的历史，放 Caches 等于把最该保护的东西放在系统可清理的位置。因此与两个 rollup 同级存放；缺失、版本不符或代次不一致时按第 3.3 节从现存日志重建，并接受「已删除文件无法恢复」这一限制。

### 决策 3：接受首版全量重建，并记录成本

`ScanState` 14 → 15 加两个 rollup bump，会让所有老用户升级后重扫 Codex / Claude 全量日志。这是既有 v9 / v13 / v14 迁移的同类代价，可以接受；验收时要记录重扫耗时，并确认其他服务数值不变。

### 决策 4：DSH 的失败文件计入 `lastError`

`UsageService` 目前只把 `claude` + `codex` 的 `failedFileCount` 累加进 `lastError`（`pi` / `opencode` 没有）。DSH 的坏帧、坏文件要能浮出来，因此把 `dsh` 加进这一行；`pi` / `opencode` 的既有行为不顺手改，不属本任务。

## 7. 实施步骤

按「每步都能单独编译、单独验证、单独提交」切，是**技术依赖顺序，不是时间表**。S0 与 S4 是仅有的两处「一动手就影响所有人」的步骤，各自单独提交。

| 步 | 产出 | 验证 |
|---|---|---|
| S0 | `ccbar.xcodeproj` 加远程包 `facebook/zstd`（固定 v1.5.7）与 product `libzstd`，App 与 CCBarTests 两个 target 都链接 | Debug build 通过、`import libzstd` 可用 |
| S1 | `Core/Usage/DshZstdFrames.swift`：帧边界扫描 + 单帧解码（`ZSTD_createDCtx` / `ZSTD_decompressStream` / `ZSTD_isError`，每帧输出上限） | 单测：坏 magic、保留位、checksum 失败、撕裂尾帧、补齐后正常入账；fixture 用 libzstd 现场编码 |
| S2 | `Core/Usage/DshSessionScanner.swift`：目录枚举、四种规范名与最高 generation、三类记录与字段映射、zstd 帧与明文两种 watermark、单文件失败隔离 | 单测对齐 `PiJSONLScannerTests` 风格（可注入 `root:` + 临时目录） |
| S3 | DSH 逐会话贡献缓存（新文件 + 版本 + generationID）；`UsageAggregator.replaceLocal(app:buckets:)`（照 `replaceRemote` 的形状）；`ConversationAggregator` 的等价替换接口 | 单测：generation 切换是替换而非相加、父链变化重归并、贡献缓存损坏时回退 |
| S4 | `UsageService` 接线：第 5 个 `async let dshTask`、`hasNewEntries`、`ScanState` 加 dsh 字段、贡献缓存插入落盘序列（两个 rollup 之后、`ScanCache.save` 之前）、扫描日志行；`ScanState` 15 / `UsageRollupPayload` 10 / `ConversationRollupPayload` 8 | 端到端扫一轮：其他服务桶数值不变，DSH 首次入账正确 |
| S5 | 定价：三处 `case .dsh` + 决策 1 的分段价与基础表行 | 复用 `UsageEquivalenceTests`，确认其他服务金额不变 |
| S6 | UI / 设置 / 诊断 / 资源：`StatsView`（14 处 `.opencode` 引用）、`SettingsRootView`（6 处 + 服务开关 + 数据源探测）、`DiagnosticsBundle`、`DesignSystem`；确认 Cycles 与额度 Timeline 不出现 DSH | 静态检查 + 手动验收 |
| S7 | §8 的四条跨轮聚合回归与中断写盘一致性测试；文档回写 | 测试通过 + 手动验收清单 |

## 8. 验证与完成条件

使用脱敏合成 fixture 和本次引入的 libzstd 编码能力生成**带 checksum 的多帧文件**；不再使用不存在的 Apple `COMPRESSION_ZSTD`。覆盖四种规范名、最高 generation、明文与 zstd、拼接帧、半截尾帧补齐、checksum 错误、无效 JSON、读失败不推进 watermark、未变化跳过、增量只计新增 usage、双位置 usage 只计一次、token 口径、无 usage 跳过、子代理多层归根和环保护。

必须做四条**跨轮聚合**回归，单测扫描器返回值不足以发现这些问题：① 第一轮入账 v0，第二轮发布内容等价 v3，总 token 与请求数不变；② 第一轮子文件缺父，第二轮父文件出现，总量不变且对话桶迁到根；③ 一个会话的新 generation 损坏，旧会话贡献保留，其他服务及 DSH 其他会话的新增量正常提交；④ 已删除会话文件的贡献留存，另一个会话切换 generation 后，已清理会话的历史桶仍在。另验证逐会话贡献、scan-state、日 rollup、对话 rollup 在中断写盘后不会形成同代但不同进度组合。

后续实施按仓库规则单独征得构建/测试许可。本次调研没有运行 Xcode 构建或 App 验收。自动化通过后，仍须在本机 DSH CLI 与 Desktop 产生新会话做手动验收：只出现一个 DSH 服务；普通统计与对话显示共享日志；子代理归一行；generation 切换不翻倍；设置与诊断正确；Cycles 和额度 Timeline 不出现 DSH。

## 9. 复核入口

- 本机安装包：`/Applications/DSH Desktop.app/Contents/Resources/app/lib/main.js`（home 选择与注入）、`node_modules/@deepseek-ai/dsh-home-paths/lib/index.js`、`node_modules/@deepseek-ai/dsh-base/cordis.patch.yml`、`node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js`（文件名、帧扫描、编码和 generation 选择）。这些只作调研证据，不是 cc-bar 的运行时依赖。
- [DSH 官方持久化说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/session/session-persistence-jsonl/README.md)、[官方 generation 迁移说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/.agents/notes/implemented/architecture/2026-08-31-released-session-format-migrations.md)。
- [Apple Compression 算法](https://developer.apple.com/documentation/compression/algorithm)、[Zstandard v1.5.7 Swift Package](https://github.com/facebook/zstd/blob/v1.5.7/Package.swift)、[zstd C API](https://github.com/facebook/zstd/blob/v1.5.7/lib/zstd.h)。
- 价格分段依据：[DeepSeek 当前价格页](https://api-docs.deepseek.com/quick_start/pricing/)、[2026-09-10 V4.1-Flash 发布公告](https://api-docs.deepseek.com/news/news260910)（降价生效时点）、[2026-08-13 V4-Pro GA 公告](https://api-docs.deepseek.com/news/news260813)（峰谷价生效时点与价目图）、[变更日志](https://api-docs.deepseek.com/updates)。
