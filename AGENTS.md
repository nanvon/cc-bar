# cc-bar Agent Guide

本文件同时给 Claude Code 和 Codex 使用。`AGENTS.md` 应作为指向本文件的软链接，避免两份规则不一致。

## 项目概况

cc-bar 是一个原生 macOS 菜单栏 App，用 Swift / SwiftUI 实现。

- 额度 Provider（`QuotaApp`）：Codex、Claude Code、Antigravity、Cursor、Command Code，外加用户手动导入的其他 Codex 账号。
- 本地用量数据源（`UsageApp`）：Codex、Claude Code、Pi、OpenCode 走本机日志扫描，Cursor 走远端计量。
- 展示位：菜单栏标签、Popover、主窗口（统计 / 设置）、桌面悬浮窗、首次启动引导。

项目主体功能已开发完成，后续以新需求和迭代为主，不再按初始里程碑推进。

工程结构：

- 入口：`CCBarApp.swift`
- 全局状态：`Core/AppState.swift`
- 菜单栏：`MenuBar/`
- 主窗口：`Main/`
- 悬浮窗：`Floating/`
- 引导：`Onboarding/`
- 设置：`Settings/`
- 凭据 / 额度 / 调度 / 用量 / 定价 / 存储 / 本地化：`Core/`（`Credentials` `Quota` `Scheduler` `Usage` `Pricing` `Storage`、`L10n.swift`）
- Xcode 工程：`ccbar.xcodeproj`

## 必读文档

改动前优先阅读相关文档和现有实现。文档索引见 [docs/README.md](docs/README.md),常用入口：

- `docs/产品需求.md`：产品形态、功能范围、边界
- `docs/技术实现.md`：架构、模块、关键流程、并发与持久化
- `docs/设计风格.md`：视觉规范、颜色、字体、状态色、组件尺寸、双语词表
- `docs/界面布局.md`：菜单栏、Popover、主窗口、悬浮窗、设置、引导的逐界面尺寸与字段
- `docs/打包发布.md`：`scripts/build.sh` 与 GitHub Actions 发布流程、Developer ID 公证归档
- `docs/历史用量数据补录指南.md`：Claude 日志被自动清理后如何补录历史用量（一次性操作手册）

`docs/` 下的 `草案-*.md` 是各功能的设计方案，落地状态见 `docs/README.md` 的草案表。

历史参考(已归档)位于 `docs/历史参考/`,含 `实施里程碑.md`、`设计稿/`、`外部项目分析/`。新需求**不**受里程碑顺序约束;需要对照外部项目行为时,优先看 `外部项目分析/` 已整理的笔记。

## 协作规则

- 未经明确要求“修改、实现、修复”等，不要擅自改代码。默认先分析、定位问题、给方案和风险。
- 如果需求、边界、验收标准或影响范围不明确，并且会影响实现或引入风险，先确认。
- 对大型项目，不要主动运行 `build`、`lint`、`type-check`、`test`、`dev` 等耗时或大量输出命令。确实需要时，先说明原因并询问。
- 修改前先读现有实现、项目规则、公共组件、公共规范和相关文档。
- 涉及功能、交互、数据结构、接口或配置行为变更时，必须同步更新相关文档；若判断无需更新文档，需要在回复里说明原因。
- 遵循当前项目风格，不做无关重构。
- 只改和当前任务直接相关的文件。不要顺手整理无关代码、格式或项目结构。
- 工作区可能已有用户改动。不要回滚、覆盖或清理非本次任务产生的改动。

## 实现约束

- UI 优先使用 SwiftUI / AppKit 系统默认控件和 macOS 原生风格。
- 视觉规则以 `docs/设计风格.md` 为准：
  - Codex 使用石墨灰识别色，Claude Code 使用桃橙识别色；识别色仅用于 tile / logo 等品牌识别，不再用于额度状态着色。
  - 额度状态色按剩余比例分 4 档（统一走 `statusColor`）：剩余 `>50%` 中性石墨灰、`20%~50%` 黄、`<20%` 橙、`=0` 红。
  - 数字使用 `.monospacedDigit()`。
  - 图标优先使用 SF Symbols。
- 不自造大面积背景、玻璃阴影、Web 风格控件或无关装饰。
- 菜单栏和 Popover 中 Provider 顺序固定：Codex → Claude Code → Antigravity → Cursor → Command Code（由 `QuotaProviderDescriptor.allProviders` 定义）。
- 网络请求失败时保留已有快照，不要清空可展示数据。
- 429 后必须遵守现有退避策略，不要为了手动刷新绕过限流。

## 常用验证方式

按任务风险选择最小验证手段：

- 小范围 UI 改动：先做静态检查和代码审阅。
- 需要编译确认时，先说明原因，再询问是否运行 Xcode 构建；得到同意后用下面「编译」一节里的命令，不要临时现编，避免命令写错或选错 configuration。
- 需要手动验收时，说明在 Xcode 中打开 `ccbar.xcodeproj` 并运行 App，按本次需求的验收点检查。

不要为了验证一个小改动主动跑完整构建、完整测试或启动开发服务，除非用户明确要求。

## 编译

只是想确认改动能编译通过（不产出正式安装包）时，用 Debug 配置直接 build，不要用 Archive：

```bash
xcodebuild -project ccbar.xcodeproj -scheme ccbar -configuration Debug -destination 'platform=macOS' build
```

这属于「耗时命令」，按上面协作规则，运行前要先说明原因并征得同意。看到 `** BUILD SUCCEEDED **` 即代表本次改动没有语法/类型错误；不代表功能正确，功能验收仍需按「常用验证方式」走手动验收。

## 打包分发

打包的唯一入口是仓库自带的脚本，**不要用 Xcode 的 Archive / Export（含 Developer ID 导出）分发**，也不要手动 `codesign`/`ditto` 现拼流程：

```bash
./scripts/build.sh
```

- 首次需要把命令行工具指向完整 Xcode（一次性）：`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
- 脚本用 `CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO` 做 Release 构建，工具链自动 ad-hoc 签名，可在任意 Mac 运行，不需要付费 Developer ID 证书或公证。
- **产物固定输出到 `dist/CCBar.dmg` 和 `dist/CCBar.app.zip`**（`dist/` 已在 `.gitignore` 里，不进版本库）。脚本会先清空 `build/` 目录再重新构建。
- 打包好的 DMG 和 zip 上传到 GitHub Release 即可分发；不要直接替换用户本机 `/Applications/CCBar.app`——那是覆盖用户正在使用的安装，属于有风险操作，要打包验证就在 `dist/` 或临时目录里查看，不要动 `/Applications`。
- 完整背景说明见 [README.md](README.md#从源码构建) 和 [docs/打包发布.md](docs/打包发布.md)（该文档里的 Archive / Developer ID 流程只是给需要公证发布给别人用的场景保留的可选项，日常打包不要用）。

### 标准发布流程（用户说「发版」「提交代码、版本号+1、构建打包」或「升级版本、tag，提交推送」时）

这是用户预先授权的固定发布指令，出现这句话（或明显同义的表述，如「发布一下」「发个新版本」）时按下面四步顺序执行，**不用逐步等确认**。`发版` 是首选的最短触发词；tag 推送成功后，立即汇报新版本号、提交和 Actions / Release 链接即可。

1. **提交代码**：把当前工作区未提交的改动按仓库惯例的 commit message 风格提交（可用 `git-commit-messages` skill；无关改动分开提交，不要混在一起）。
2. **编写用户更新说明**：对比上一个 `v*` tag 与当前代码、提交和文档，只提炼真实、用户可感知的新增功能、问题修复、体验优化和必要注意事项；不要罗列 commit、文件、重构、CI 或版本号。创建 `release-notes/vX.Y.Z.md`，格式和正文规则见 [release-notes/README.md](release-notes/README.md)：只写更新内容本身：按「注意 / 新增 / 修复 / 优化」分组，组头用加粗（不用 `#` 标题，Release 页字号过大），组内每条一行列出；不加安装说明等每版重复的固定段落。文件全文原样作为 Release 正文，Release 标题沿用默认的 tag 名。
3. **版本号 +1**：修改 `ccbar.xcodeproj/project.pbxproj` 里两处 `MARKETING_VERSION`（Debug/Release 配置各一处，要同时改），patch 位 +1（如 `1.0.0` → `1.0.1`），除非用户明确要求升 minor/major。把版本号和 `release-notes/vX.Y.Z.md` 一起单独提交，message 形如 `chore: 发布 vX.Y.Z`。
4. **触发远程构建发布**：推送分支 + 打带 `v` 前缀的 tag 触发 [.github/workflows/release.yml](.github/workflows/release.yml)，由 GitHub 的 macOS runner 自动运行 `scripts/build.sh`、读取同名更新说明，并将 `dist/CCBar.dmg`、`dist/CCBar.app.zip` 与 `dist/version.json`（App 检查更新读取的版本清单，由 workflow 自动生成，本地打包不产出）挂到 GitHub Release：
   ```bash
   git push origin main
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

- **更新日志由 AI 在发布前编写**：`release-notes/vX.Y.Z.md` 是该版本唯一的 Release Notes 来源；GitHub Actions 会校验其存在且非空，然后把全文原样作为 Release 正文；缺失时不会创建 Release。它不是传统的聚合 `CHANGELOG.md`，每个版本只保留一份面向用户的说明。
- **版本号从 `1.0.0` 重新起算**：仓库早期（`73ddff4` 之前）用过不带 `v` 前缀的 `0.x.y` 裸版本号 tag，那批是历史遗留，不再接续；新发布一律带 `v` 前缀，从 `v1.0.0` 开始。
- tag 必须和已提交的 `MARKETING_VERSION` 一致，tag 本身不改版本号，只是给已提交好的版本打标记。
- 打错 tag 可撤销：`git tag -d vX.Y.Z && git push origin :vX.Y.Z`。
- `git push origin vX.Y.Z` 成功即代表本地发版操作完成；只汇报版本号、提交和 Actions / Release 链接，**不得主动查询、等待或轮询** CI、Release 或产物状态。只有用户明确要求“看进度”“确认发布成功”或“检查产物”时，才查询远端状态。
- 如果用户只是单独说「打个正式版」但没有前面步骤的上下文（比如工作区本来就是干净的），照样按这四步走，第 1 步无改动则跳过、直接从第 2 步开始。
