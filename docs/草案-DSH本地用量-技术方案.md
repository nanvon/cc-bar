# 草案 · DSH 本地用量（技术方案）

> 状态：**未实施**。当前 `UsageApp` 没有 `dsh` case，也没有 `dsh` 对应的扫描器、watermark、日志监听、设置探测与诊断路径。本文是范围与技术契约已收敛的设计方案，尚未落地。实现完成并通过验收后，把最终行为并入 `技术实现.md` / `界面布局.md` / `设计风格.md` / `产品需求.md`，并把本草案归档。
>
> 方案已完成的调研：DSH 官方会话持久化实现位于 `DSH Desktop.app/Contents/Resources/app/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js`（CLI 与 Desktop 共用同一个包），帧扫描算法、压缩参数、generation 选择逻辑均以该实现为契约，不靠猜测。

## 1. 背景、目标与范围

### 1.1 用户诉求

在 cc-bar 主窗口的本地用量统计中接入 **DSH（DeepSeek Harness）**，让 DSH 和已支持的 Codex / Claude Code / Pi / OpenCode 一样，能看到 token、请求数、预估费用、对话归属与时间线。

### 1.2 第一版范围

- **主窗口统计**：DSH 作为一个本地用量数据源进入 Overview / Conversations / Timeline / Cycles / 按服务 / 按提供商 / 按模型全部面板，复用现有 `UsageEntry` → `UsageAggregator` → `ConversationAggregator` 链路。
- **设置**：统计服务可见性列表新增 DSH 一行（默认可见，见 §4.2）；用量数据源探测新增 DSH 一行。
- **诊断**：`DiagnosticsBundle` 纳入 DSH 会话目录的存在性与元信息。
- **展示位**：只进主窗口统计。**不进**菜单栏、Popover、桌面悬浮窗、Onboarding——这两处是"额度 Provider"的展示位，DSH 没有订阅额度概念。

### 1.3 第一版明确不做

- 不做 DSH 的额度 / 订阅查询，`QuotaApp` 不新增 case。
- 不画 DSH 的 logo SVG（`ServiceTile` 资源缺失时回退字母 `T`/占位，见 §4.6）。
- 不引入任何第三方 zstd 依赖，不调用系统 `zstd` 命令行，不新增 Xcode framework 链接（见 §2.3）。
- 不读取 `~/.dsh/.credentials.yaml`、`~/.dsh/settings.yaml`、`storages/*.json`、`agy-accounts/pool.json` 等**非会话**文件；只读会话日志。
- 不解析消息正文（`content` / `reasoning` / `text`），不落盘任何对话内容；只取标题摘要，口径与现有对话档案一致。
- 不做 DSH 子代理（`delegationDepth > 0`）的独立会话拆分，全部归入所属会话文件。
- 不改动 `ModelProvider` 的归并规则（DSH 的 provider 前缀已被现有前缀表覆盖，见 §4.5）。

## 2. 调研结论与技术选择

### 2.1 DSH 与 DSH Desktop 是同一个产品

**结论：当作一个实体处理，UI 只出现一个「DSH」条目，扫描层同时覆盖两个根目录。**

依据：

1. **同一份持久化实现。** CLI 与 Desktop 共用 `@deepseek-ai/dsh-session-persistence-jsonl` 这一个包，帧格式、generation 命名规则、压缩参数完全一致。
2. **只差根目录和文件名。** 唯一的物理差异见 §2.2 的表。
3. **项目内已有先例。** cc-bar 现在就是这么处理 OpenCode 的：`OpencodeScanner` 只读 `~/.local/share/opencode/opencode.db`，而归并为一个 `opencode` 条目——[OpenChamber](https://github.com/openchamber/openchamber) 是与 OpenCode **同源同库**的可视化工作区（本机实测：`~/.local/share/opencode/` 下存在 OpenChamber 自己创建的 `auth.json.openchamber.backup`，且 `~/Library/Application Support/OpenChamber/` 已安装），cc-bar 从未为它单列条目。DSH 与 DSH Desktop 的关系与此同构。

用户几乎只使用 Desktop 版本，但把 CLI 根目录一并纳入的边际成本只是候选目录列表多一项，因此两个根都扫。

### 2.2 数据源契约（已实测 + 已对源码）

```text
DSH Desktop: ~/Library/Application Support/dsh-desktop/harness/sessions/
DSH CLI:     ~/.dsh/sessions/
```

两个根下都是 `<编码后的 cwd>/<session 目录>/<日志文件>` 两级结构。`<编码后的 cwd>` 形如 `--Users-alice-Code-my-project--`，但**解析不依赖目录名**——`session` 记录里有原始 `cwd` 字段，直接用它（比反解编码可靠）。

日志文件名有两种形态，都要扫：

| 形态 | 文件名 | 说明 |
|---|---|---|
| v0 | `session.jsonl.zstd` | 无版本号，仅 CLI 侧存在 |
| vN | `session.v3.jsonl.zstd` | 当前格式（实测 v3），Desktop 侧 |

**generation 是追加写、写完后不可变的**。官方选择逻辑是取**版本号最大**的 canonical generation（`generations.sort((l,r) => r.version - l.version)[0]`）。所以同一目录可能同时残留多个版本的日志文件，**只读最高版本那一个**；旧版本不再增长，不必重复计入。

> 实测一个目录下会并存 `session.jsonl.zstd` 与 `session.v3.jsonl.zstd`，若两者都扫会重复计费。

### 2.3 zstd 解压：不需要任何新依赖

三个结论决定了这一点：

1. **帧边界可以纯字节扫描。** 官方 `scanZstdFrames()` 在不做任何解压的前提下定位完整帧，算法完全公开（见 §3.1）。
2. **每帧独立可解码且带校验和。** 官方压缩参数为 `{ zstd: checksumFlag: 1 }`，注释明确写 "Compress one independently decodable, checksummed Zstandard frame"，且**不启用字典**（实测 `DictID: 0`）。
3. **系统框架够用。** 部署目标是 macOS 14.0，Apple `Compression` 框架自 10.15 起支持 `COMPRESSION_ZSTD`。

因此实现路径是：**Swift 复刻约 100 行帧扫描（定位边界）+ Apple Compression 逐帧解压**。不引入 libzstd、不引入 SPM 依赖、不改 `project.pbxproj` 的链接配置、不 shell out 到 `zstd`（GUI App 不保证 PATH，且进程开销不可接受）。

### 2.4 体量与压缩比实测

| 指标 | 实测值 |
|---|---|
| 会话文件数 | 15（Desktop 14 + CLI 1） |
| 累计 zstd 帧数 | 1507 |
| 压缩后体积 | 2.7 MB |
| 解压后体积 | 9.7 MB |
| 压缩比 | **约 3x**（帧小，平均 6.4 KB/帧，压缩收益有限） |
| 单文件最大帧数 | 165 |

两个含义：

- 数据量级远小于已支持的 Codex（3.5 GB / 1948 文件）和 Claude（737 MB / 1135 文件），**首扫无压力**。
- 但压缩比只有 3x，**全量重解没有任何收益**，而 DSH 是每天都在用的主力工具，会话文件持续增长。因此必须走增量，这与现有四个扫描器的架构一致（见 §3.2）。

## 3. 扫描架构

### 3.1 帧扫描算法（核心新增代码）

复刻官方 `scanZstdFrames()`。这段代码**不解压**，只做结构校验并返回完整帧区间；遇到写了一半的帧则返回其起始位置（`tornStart`）而不是报错。

```text
输入：整个文件的字节 buffer（或从 offset 起的新增字节）
输出：完整帧的 [(start, end)] 列表 + 可选 tornStart

offset = 0
while offset < buffer.length:
    start = offset
    if 剩余 < 4:                      → tornStart = start，返回
    校验 buffer.readUInt32LE(offset) == 0x28B52FFD   // ZSTD magic
    offset += 4
    if 剩余 == 0:                     → tornStart = start，返回
    descriptor = buffer.readUInt8(offset); offset += 1
    if (descriptor & 0x18) != 0:      → 结构损坏，抛错（reserved 位被置位）

    contentSizeFlag  = descriptor >>> 6
    singleSegment    = (descriptor & 0x20) != 0
    hasChecksum      = (descriptor & 0x04) != 0
    dictionaryFlag   = descriptor & 0x03
    dictionaryBytes  = (dictionaryFlag == 3) ? 4 : dictionaryFlag
    contentSizeBytes = (contentSizeFlag == 0) ? (singleSegment ? 1 : 0) : (1 << contentSizeFlag)
    remainingHeader  = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes
    if 剩余 < remainingHeader:        → tornStart = start，返回
    offset += remainingHeader

    loop:                             // 逐个 block 推进
        if 剩余 < 3:                  → tornStart = start，返回
        blockHeader = buffer.readUIntLE(offset, 3); offset += 3
        lastBlock  = (blockHeader & 1) != 0
        blockType  = (blockHeader >>> 1) & 3
        blockSize  = blockHeader >>> 3
        if blockType == 3:            → 结构损坏，抛错
        payloadBytes = (blockType == 1) ? 1 : blockSize     // RLE block
        if 剩余 < payloadBytes:       → tornStart = start，返回
        offset += payloadBytes
        if lastBlock: break

    if hasChecksum:
        if 剩余 < 4:                  → tornStart = start，返回
        offset += 4

    记录完整帧 (start, end = offset)
```

`readUInt32LE` / `readUIntLE` 在多字节读取前都做了剩余长度检查，因此对"文件正在被写入"这一常态是安全的：**返回的帧区间一定是完整帧，tornStart 一定是未完成的尾部**。

### 3.2 增量 watermark：帧边界对齐的字节偏移

现有四个扫描器共用同一套热路径原则（实测确认）：`ScanFileState{mtime, offset}` 三元组中 **mtime 与 size 都没变就整个文件跳过，连 open 都不做**；只有文件真变了才从 `offset` 续扫。Claude（1135 文件 / 737 MB）、Codex（1948 文件 / 3.5 GB）就是靠这个把每轮扫描成本压到近似 `stat`。

DSH 沿用同一契约，但偏移语义比明文 JSONL **更强**：

| | Claude / Codex / Pi（明文 JSONL） | DSH（zstd 帧） |
|---|---|---|
| offset 语义 | 字节偏移，靠"整行消费"对齐 | **恒落在帧边界上** |
| 半截数据处理 | 末尾残行留到下次 | 官方 `tornStart` 明确告知 |
| 续扫范围 | 从 offset 读新行 | 从 offset 扫新帧、逐帧解压 |

扫描流程：

```text
对每个候选日志文件：
  1. stat 取 mtime / size
  2. 若 mtime == state.mtime && state.offset == size  → 跳过（不 open）
  3. 否则从 state.offset 起读新增字节，跑 §3.1 帧扫描
  4. 对每个完整帧：解压 → 按行 JSON 解析 → 抽取 §3.3 的记录
  5. offset 推进到「最后一个完整帧的 end」；存在 tornStart 时不推进到那里
     （本轮丢弃该帧，下轮文件再增长时自然重读）
  6. 按行累加 linesParsed，写回 newState
```

关键不变式：

- **页内每帧只解压一次**：offset 只在帧边界推进，已计入的帧不会被重读。
- **写一半的帧不会漏也不会重**：不推进 offset → 下轮重读；帧内数据不完整所以本轮不入账。
- **generation 切换天然安全**：文件名含版本号，切换后是新的 `ScanFileState` key，走一次全量；旧 key 成为不再命中的陈旧项（现有扫描器同样会残留失效 key，随 `ScanCache` 落盘，不需要特殊清理）。

### 3.3 每行读什么（三类记录）

DSH 日志的记录类型实测共 20 种，**只关心以下三类**，其余全部忽略。

**① `session` — 会话元数据（取 `cwd` / `id`）**

```json
{"type":"session","version":3,"id":"session-1a2b3c4d-...","createdAt":1768435200000,
 "cwd":"~/Code/my-project","delegationDepth":0,"agentPreset":"standard"}
```

**② `session/title` — 对话标题**

```json
{"type":"session/title","seq":14,"time":1768435200000,
 "data":{"title":"重构用量统计面板","messageSeqs":[3],"source":{"kind":"fallback"}}}
```

**③ `assistant/message` — 用量（唯一权威来源）**

```json
{"type":"assistant/message","seq":147,"time":1768435200000,
 "data":{"turn":1,"step":1,
   "message":{"role":"assistant","content":[...],
              "source":{"kind":"model","provider":"<provider>","model":"<provider>/<model-id>"}},
   "usage":{"inputTokens":12247,"outputTokens":330,"cacheReadTokens":1280,
            "reasoningTokens":129,"totalTokens":13857}}}
```

> 上述示例为脱敏样本：会话 id、`cwd`、标题、`time` 均为占位值。`usage` 数值保留真实形态，用于说明 §3.4 的恒等式（示例满足 `12247 + 330 + 1280 = 13857`）。`provider` / `model` 在真实日志中是具体标识（如 `commandcode` + `deepseek/deepseek-v4.1-flash`），`message.content` 是完整消息正文本，扫描器**不读**该字段。

字段映射：

| DSH 字段 | `UsageEntry` | 处理 |
|---|---|---|
| `data.message.source.provider` + `.model` | `model` | 拼成 `provider/model`，与 Pi / OpenCode 的日志形态一致 |
| `data.usage.inputTokens` | `inputTokens` | **直接赋值，无需换算**（见 §3.4） |
| `data.usage.outputTokens` | `outputTokens` | 直接赋值 |
| `data.usage.cacheReadTokens` | `cacheReadTokens` | 缺省 0 |
| `data.usage.reasoningTokens` | —— | **不单独入账**（是 `outputTokens` 的子集，见 §3.4） |
| `data.usage.totalTokens` | —— | 只用于 §3.4 的口径校验，不参与聚合 |
| （DSH 无缓存写入概念） | `cacheCreationTokens` | 恒 0 |
| 每条 `assistant/message` | `requestCount` | 计 1 |
| `time`（epoch 毫秒） | `timestamp` / `day` | 按现有 ISO8601 / 本地日切逻辑换算 |
| —— | `speed` | `.standard`（DSH 无 Fast 档位概念，与 Pi / OpenCode 一致） |
| —— | `costUSD` | 走 §3.5 定价解析 |

**必须只认 `assistant/message` 一处。** 同一份 usage 还会出现在 `assistant/chunk` 且 `chunk.type == "usage"` 的事件里，实测两者**逐字段完全等值**（8/8 相同）。两处都取会**翻倍计费**。

### 3.4 口径校验（实测 384 条记录）

对全部会话、全部 `assistant/message` 记录（含 `totalTokens` 的 384 条）验证：

```text
totalTokens == inputTokens + outputTokens + cacheReadTokens   → 384 命中 / 0 不匹配
```

这条恒等式说明两件事，且都与 cc-bar 的既有约定一致：

1. **`inputTokens` 已扣除 `cacheReadTokens`。** 这正是 `UsageEntry.inputTokens` 的注释约定（"已扣 cacheRead"），所以直接赋值即可，**不要**再做减法。
2. **`reasoningTokens` 是 `outputTokens` 的子集**，不额外加进 total。因此不单独入账，避免重复计数。若将来要在 UI 暴露 reasoning 维度，必须新建独立字段而不是并入 output。

> 另有 10 条记录没有 `totalTokens` 字段（早期格式），不影响入账——只读 `inputTokens` / `outputTokens` / `cacheReadTokens`，这三个字段在实测中恒存在。

### 3.5 定价与 `ModelProvider` 归并

DSH 的模型名是 `provider/model` 的**双层嵌套**形态（例：`commandcode/deepseek/deepseek-v4.1-flash`）。现有实现已覆盖这条路径：

- `Pricing.normalize` 会**循环剥除** provider 前缀，注释里明确写了 `commandcode/deepseek/...` 这种双层情形，剥完得 `deepseek-v4.1-flash`。
- `ModelProvider.resolve` 的前缀表已含 `commandcode/`、`command-code/`、`deepseek/`、`anthropic/`、`openai/`、`opencode-go/`，无需改动。
- `Pricing.standardPrice` 的 `speed == .fast` 分支需要为新 app 补 `case .dsh: return nil`（DSH 无 Fast 档位），属编译期穷举要求。

**已知缺口**：本地价格表里有 `deepseek-v4-flash`，但**没有 `deepseek-v4.1-flash`**。未命中时 `resolve` 返回 `nil`，聚合按 0 计，UI 显示 token 但金额为空——这是既有约定（`costUSD == nil` 表示"没有可靠价格"），不是 bug。是否补价目见 §7。

## 4. 数据流与接线

### 4.1 新增文件与改动清单

**新增：**

| 文件 | 内容 |
|---|---|
| `Core/Usage/DshZstdFrames.swift` | §3.1 帧扫描 + 逐帧解压（Compression 框架封装） |
| `Core/Usage/DshJSONLScanner.swift` | 复刻 `PiJSONLScanner` 骨架：枚举、watermark、解析、seed |
| `CCBarTests/DshJSONLScannerTests.swift` | 见 §6 |

**改造：**

| 文件 | 改动 |
|---|---|
| `Core/Usage/UsageModels.swift` | `UsageApp` 加 `case dsh`；`localApps` 加 `.dsh` |
| `Core/Usage/UsageService.swift` | 加 `async let dshTask`；`ingestLocal` / `conversationAggregator.ingest` / `cycleEntries` / `hasNewEntries` / `newState` / 日志行 / `appState.dshTodayCost` |
| `Core/Storage/ScanCache.swift` | `ScanState` 加 `dsh: [String: ScanFileState]`；`ScanState.currentVersion` **14 → 15**；`UsageRollupPayload.currentVersion` **9 → 10**（理由见 §4.7）；补两处版本注释 |
| `Core/Usage/UsageLogWatcher.swift` | `candidateRoots()` 加 `~/Library/Application Support/dsh-desktop/harness` 与 `~/.dsh` |
| `Core/Usage/Pricing.swift` | `case .dsh: return nil`（两处 fast 分支） |
| `Core/Pricing/PricingCatalogStore.swift` | 同上 |
| `Core/Usage/ModelProvider.swift` | `case .dsh: return .other`（app 兜底分支） |
| `Core/AppState.swift` | `var dshTodayCost: Decimal?` |
| `Core/Diagnostics/DiagnosticsBundle.swift` | 纳入两个 DSH 会话根 |
| `Main/DesignSystem.swift` | `tintColor` + `displayName` |
| `Main/StatsView.swift` | 约 8 处穷举分支（filter / accent / totals / pair / range / domain / tooltip） |
| `Main/ConversationStatsView.swift` | app → 视图映射 |
| `Main/CycleStatsView.swift` | 按 app 分桶 |
| `Settings/SettingsRootView.swift` | `usageServiceInfo` 探测 + `scanProgressText` 的 appName |
| `Resources/Assets.xcassets/` | `DshAccent.colorset`（见 §4.6） |

> `Settings.usageServiceVisibility` 与 `isUsageServiceVisible` 用 `allCases` + `default: app == .cursor ? false : true` 推导，**新 app 自动默认可见**，无需改动——但这带来一个体验问题，见 §4.2。

### 4.2 设置可见性默认值（需注意的体验副作用）

`Settings.isUsageServiceVisible` 对非 Cursor 的 app 默认 `true`，`loadUsageServiceVisibility` 也用同一规则给 `allCases` 补默认值。因此加 `case dsh` 后：

- **没装 DSH 的用户**也会在统计页看到一行空的 DSH 服务。

这与 Pi / OpenCode 的现状一致（它们同样默认可见），所以不是新引入的问题。但 DSH 目前装机量低于 Pi / OpenCode，空行出现的概率更高。三个处理选项：

1. **保持现状**（默认可见），与 Pi / OpenCode 完全一致，零改动。**推荐**——一致性优先，用户可自行在设置里关掉。
2. 仿 Cursor 的 `isUsageServiceEffectivelyVisible` 模式，叠加"磁盘上是否存在会话目录"的运行时探测，目录不存在则整行不显示。改动小（一个 `dshSessionsDetected` 运行时状态），但引入了 Cursor 特有的"偏好 + 运行时可用性"双层语义。
3. 默认关闭。不推荐——已装 DSH 的用户要手动打开才能看到数据，违背"自动检测"的既有产品习惯。

### 4.3 扫描器返回契约

严格复用现有四者的形状（`PiJSONLScanner.Result` 逐字段同构）：

```swift
struct Result: Sendable {
    var entries: [UsageEntry]
    var conversationSeeds: [ConversationSeed]
    var newState: [String: ScanFileState]
    var newSeenIds: [String]        // DSH 恒为空数组，见 §4.4
    var filesScanned: Int
    var linesParsed: Int
    var failedFileCount: Int        // zstd 结构损坏 / 解压失败计数
}
```

签名照搬 Pi，含可注入 `root:` 以便测试：

```swift
nonisolated static func scan(
    previous: [String: ScanFileState],
    seenEntryIds: [String],          // 保留形参以对齐契约，内部不使用
    root: URL,
    onProgress: ScanProgressCallback? = nil
) -> Result
```

生产入口 `scan(previous:seenEntryIds:onProgress:)` 内部**遍历两个根目录**（§4.4）。

### 4.4 为什么不需要 `seenIds` 去重集合

Claude / Codex / Pi 各自都有跨文件去重集合（`claudeSeenMessageIds` / `codexSeenTokenIds` / `piSeenEntryIds`），存在的唯一理由是**这些工具的日志会把历史消息原样重放进新文件**：Claude 有 sidechain / subagent 重复引用，Codex 有 fork 会话重放父会话历史（`ScanState` v14 的注释就是专门修这个 bug），Pi 会话树有 fork / clone 复制旧行。

**DSH 没有这个行为**：每个会话文件独立、纯追加、不重放历史。因此：

- `seenIds` 恒为空数组，`newSeenIds` 也返回空。
- 不去重是**有依据的**，不是偷懒。若将来 DSH 引入会话 fork/分支复制，需要在此处补齐（并在 `ScanCache` bump 版本）。

同时这也意味着**不需要** §2.2 里"两个根目录可能互相重复"的额外去重——两个根是两套独立安装，会话文件不重叠。

### 4.5 对话归属与标题

| 维度 | 取值 |
|---|---|
| `conversationKey` | `"dsh:\(session.id)"`（对齐 Pi 的 `"pi:\(id)"`） |
| `id`（ConversationSeed） | `session.id` |
| `project` | `resolver.resolve(rawPath: session.cwd, source: .cwd)` —— 直接用 `cwd` 原始值，不反解目录名 |
| `title` | `session/title` 的 `data.title`；作为 `fallbackTitle` 参与现有标题优先级 |
| `sourcePath` | 日志文件的真实路径 |
| `includesSubtasks` | `false` |
| `cacheCreationAvailable` | `true`（对齐 Pi；DSH 无 cache creation，恒 0 不影响展示逻辑） |
| `gitBranch` | `nil`（DSH 日志不含分支，与 Pi 一致） |

`session/title` 可能晚于 `assistant/message` 出现（实测 seq 14 vs 11），因此 seed 需要在扫描过程中持续累积、以最后一次读到的值为准——与 Pi 处理 `fallbackTitle` 的方式相同。

### 4.6 识别色

需要一个 `DshAccent.colorset`。按 `设计风格.md` 的既有约束：

- 识别色**只用于 tile / logo 品牌识别**，不参与额度状态着色（状态色统一走 `statusColor`）。
- 参考现有 `PiAccent` / `OpencodeAccent` 的取色与命名规范（`Resources/Assets.xcassets/*.colorset`，含 light/dark 两档）。
- DSH 品牌色取 DeepSeek 蓝系，但**必须与既有 `CodexAccent`（石墨灰）、`ClaudeAccent`（桃橙）、`OpencodeAccent`、`PiAccent` 在明度/饱和度上可区分**，避免新色与既有色混淆。
- 第一版若无正式品牌色，允许先落地一个占位色并在 `ServiceTile` 资源缺失时回退字母，按 §1.3 不阻塞主流程。

### 4.7 升级路径：两个版本号必须一起 bump（**易漏，务必执行**）

已有用户的 `scan-state` 里没有 `dsh` 字段，解码时该字段缺省为空字典，所以启动后会从零重扫全部 DSH 会话。这里有个容易误判的地方——**首版落地其实不会出错，但必须靠 bump 版本号来保证今后也不出错**，原因在聚合器的累加语义：

```swift
// UsageService.bootstrap()：代次一致时直接加载磁盘 rollup，不清空
if generationsMatch { aggregator.load(from: payload.buckets) }

// UsageAggregator.ingestLocal()：纯累加，不用新结果替换既有桶
b.inputTokens += e.inputTokens
```

**首版落地**：旧版本从未扫过 DSH，磁盘 rollup 里没有 dsh 桶，所以"重扫全量 + 累加到空桶"= 正确结果。此时不 bump 也不会算错。

**真正的风险在第二次改口径时**（例如补 §7 的 `deepseek-v4.1-flash` 价目）：

```text
磁盘 rollup:  dsh 桶 = 按 0 价累计的存量
重扫产出:     dsh 条目 = 全量（按新价）
→ ingestLocal 二次累加 → token 翻倍、费用口径混杂 ✗
```

这与 `ScanCache` 注释里 "v9: Claude 流式半成品不再入账；旧 seen / rollup 可能已污染，必须全量重建" 以及 v14 修 Codex fork 重复计费，是同一类问题。

**规则：任何影响已入账 DSH 数值的改动（新增数据源、改口径、改价目），`ScanState.currentVersion` 与 `UsageRollupPayload.currentVersion` 必须同时 bump。** 只 bump 前者不足以清掉被污染的聚合桶；只 bump 后者会丢 watermark，全量重扫后再叠加到**未清空**的聚合器上，问题反而更严重。

首版落地时两个都 bump（`14 → 15` / `9 → 10`），一次性走全量重建，成本与既有 v9 / v14 迁移相同。**即便首版不 bump 也算得对，也建议照做**——把这条通路在第一次就验证过，比等到改口径时才发现漏 bump 更安全。

## 5. 性能与正确性

| 场景 | 行为 | 成本 |
|---|---|---|
| 无任何变化 | `UsageLogWatcher` 事件门控直接返回 false | 0 次系统调用 |
| 事件门控放行、所有文件 mtime+size 未变 | 逐文件 `stat` 后全部跳过 | O(文件数) 次 stat，不解压 |
| 当前会话正在追加 | 只读新增字节、只解新增帧 | O(增量)，与文件总长无关 |
| 单个文件结构损坏 | 该帧解压/解析失败 → `failedFileCount += 1`，**保留已有快照**（对齐"网络请求失败不清空可展示数据"的既有约束） | 不影响其他文件与其他 app |
| 首次全量 | 15 文件 / 1507 帧 / 9.7 MB | 与 Codex 首扫（3.5 GB）不同量级 |
| 30 分钟兜底 | `maxSkipInterval` 强制扫一轮 | 同上，走增量路径 |

正确性不变式（对应 §6 的测试点）：

1. 已入账的帧不会被二次解压计入（offset 只在帧边界推进）。
2. 写一半的帧既不计入也不丢失（不推进 offset）。
3. `assistant/chunk` 的等值 usage 副本不被计入。
4. 同一目录存在多版本日志时只计最高版本。
5. `inputTokens` 不再减 `cacheReadTokens`。

## 6. 验证方案

按项目现有 fixture 风格（`CCBarTests/PiJSONLScannerTests.swift`：`canonicalTempDirectory` + 临时目录 + 可注入 `root:`）新增 `DshJSONLScannerTests`：

**测试基础设施**：测试需要**生成** zstd 帧。用 Apple Compression 的 `COMPRESSION_ZSTD` 编码即可（与解压同框架），把 fixture 明文按 §2.3 的"每批一帧、带 checksum"形态切帧写入，确保帧结构与生产一致。

| 用例 | 断言 |
|---|---|
| 目录枚举 | 返回元数据；只识别 `session.jsonl.zstd` 与 `session.vN.jsonl.zstd`；忽略 `session.lock` |
| 全量解析 | 正确产出 entries 与 seed；token 三字段映射正确；`requestCount == 1` |
| **只认 `assistant/message`** | 同一 (turn, step) 同时写入 message 与 chunk usage → **只计 1 条**（回归防线，最重要） |
| **口径不变式** | `inputTokens` 直接等于日志值，不减 cacheRead；`reasoningTokens` 不额外入账 |
| **增量：未变跳过** | 二次扫描 `entries.count == 0`、`linesParsed == 0` |
| **增量：追加只读新帧** | 追加帧后只产出新增 entry；已有 entry 不重复 |
| **撕裂帧** | 截断最后一帧的部分字节 → 该帧不入账、offset 不越过它；补齐后下一轮正常入账 |
| **多 generation** | 同目录并存 v0 与 v3 → 只计最高版本 v3 |
| **损坏帧** | 破坏某帧结构 → `failedFileCount` 增加，其余帧正常入账 |
| 标题 | `session/title` 作为 fallbackTitle；后到覆盖先到 |
| 未知模型定价 | token 正常入账、`costUSD == nil`（聚合按 0），不报错 |
| 双根目录 | 两个 root 的会话都入账，且互不重复 |

**手动验收**（静态检查通过后）：在 Xcode 打开 `ccbar.xcodeproj` 运行 App，按以下点检查——主窗口统计页出现 DSH 服务行；Overview / 按服务 / 按模型 / Timeline 有数据；对话页出现 DSH 会话且标题、项目归属正确；设置页统计服务列表出现 DSH 且可切换；设置页用量数据源探测显示"已检测到本地日志"。

## 7. 待定项

| 项 | 说明 | 建议 |
|---|---|---|
| `deepseek-v4.1-flash` 定价 | 本地价格表无此条目，不补则金额显示 0 | 需拍板：补本地价目 / 只靠在线目录 / 先不计价。按 `ScanCache` 注释的既有约束，**若补本地价目需同时 bump `currentVersion`**，否则已发布用户的历史费用不会自动对齐 |
| DSH 识别色 | 无正式品牌色 | 先取可区分的占位色，后续替换 |
| 实时追加的读取时机 | DSH 按批次持久化（`batchTimer` 有界批处理），写入时机与扫描时机可能交错 | 交给 §3.2 的"tornStart 不推进"机制处理，无需额外协调 |
| Windows / Linux 路径 | 当前实现只覆盖 macOS（沿用现有扫描器的 `homeDirectoryForCurrentUser` 约定） | 不在第一版范围 |

## 8. 落地顺序（技术依赖顺序，非时间表）

1. `DshZstdFrames.swift`：帧扫描 + 解压，配单元测试（含撕裂帧、损坏帧）。这是唯一的技术未知点，先单独立住。
2. `DshJSONLScanner.swift`：解析 + watermark，配 §6 全部 fixture 用例。
3. `ScanCache` v15 + `UsageModels` / `UsageService` 接线，跑通端到端聚合。
4. 其余 UI / 设置 / 诊断 / 资源接线（编译期穷举驱动，逐一补齐）。
5. 文档回写：`技术实现.md`（数据源、扫描器、watermark）、`界面布局.md`（统计服务列表、探测行）、`设计风格.md`（双语词表 + 识别色）、`产品需求.md`（本地数据源清单）、`docs/README.md`（本草案状态改为已落地）。
