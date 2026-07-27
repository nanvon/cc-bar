# cc-bar

> macOS 菜单栏小工具 —— 一眼看清 Codex、Claude Code、Antigravity 与 Grok 的剩余额度。

<p>
  <img alt="platform" src="https://img.shields.io/badge/macOS-14+-blue.svg">
  <img alt="swift" src="https://img.shields.io/badge/Swift-5.9-orange.svg">
</p>

<p align="center">
  <img src="docs/Screenshots/popover-light.png" width="360" alt="Popover 总览 - 浅色模式">
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover 总览 - 深色模式">
</p>

## 功能

- **额度显示** —— Codex、Claude Code、Antigravity 与 Grok 的剩余额度,实时同步
- **菜单栏 + 悬浮窗** —— 状态栏图标显示剩余百分比;可选桌面悬浮 HUD,可拖动、边缘吸附、置顶不抢焦
- **多 Codex 账号** —— 支持导入多个 Codex 账号,主副账号在 Popover 同屏展示;设置页可查看每个账号的额外重置次数与到期时间
- **Token 与费用统计** —— 按今天 / 昨天 / 本周 / 本月 / 本年 / 7 天 / 30 天 / 全部 / 自定义切换;KPI、堆叠柱状图、按服务占比、按模型明细（Codex / Claude）
- **丰富的设置** —— 账号开关、菜单栏显示项、悬浮窗、刷新间隔、重置时间显示、中英双语、开机自动启动

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="用量统计 - 概览"><br>
  <sub>概览:本月 Token / 花费汇总、按服务与模型拆分</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="用量统计 - 对话"><br>
  <sub>对话:按单个对话查看 Token 与费用明细</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-timeline.png" width="720" alt="用量统计 - 时间线"><br>
  <sub>时间线:5 小时窗口额度随时间变化</sub>
</p>

## 安装

要求 macOS 14 Sonoma 或更新版本。Codex / Claude Code / Grok 需已通过终端登录；Antigravity 需安装官方 App 或 IDE，并在运行时提供本地额度服务。

1. 到 [Releases](https://github.com/nanvon/cc-bar/releases) 下载最新 `CCBar.app.zip`,解压后把 `CCBar.app` 拖入 `/Applications`。

2. CCBar 未做 Apple 付费公证,首次启动会被 Gatekeeper 拦下,需手动放行一次。打开「终端」,粘贴回车:

   ```bash
   xattr -dr com.apple.quarantine /Applications/CCBar.app
   ```

   然后双击打开。若仍被拦,到 **系统设置 → 隐私与安全性**,下滑找到 CCBar 的提示,点**「仍要打开」**。
   (macOS Sequoia 起,旧的「右键 → 打开」已失效,只能用上面这种方式。)

3. 若本机无 `~/.claude/.credentials.json`,会弹出说明后请求 Keychain 授权,请选「**始终允许**」。

## 关于本项目与安全性

cc-bar 是 vibe coding 出来满足个人需求的小工具,并非商业化产品。为了显示额度,它需要读取本地的登录凭据:Codex 的 `~/.codex/auth.json`、Claude Code 的 `~/.claude/.credentials.json` 与 macOS Keychain、Grok Build 的 `~/.grok/auth.json`。Antigravity 只连接官方进程在 `127.0.0.1` 暴露的本地 Language Server,不保存 Google OAuth 凭据,也不会启动 CLI 或发送模型请求。Grok 额度来自 xAI 统一计费接口（与 `grok` CLI 相同），token 过期时会用 refresh_token 续期并写回 `auth.json`。

发布的 `CCBar.app` 未做 Apple 付费公证(详见上方「安装」)。如果你介意安全性,完全可以**自己用 AI 审阅本仓库代码**,确认无误后**按下方教程自行构建**,不依赖我发布的二进制包。

## 从源码构建

需要安装完整 Xcode(非仅 Command Line Tools)。

**日常开发**:双击 `ccbar.xcodeproj`,选 scheme `ccbar` 与「My Mac」,按 **⌘R** 运行调试。

**打包分发**:用命令行不签名构建,产物为 ad-hoc 签名,可在任意 Mac 上运行,无需付费证书或公证。

1. 首次需把命令行工具指向完整 Xcode(一次性):

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

2. 在项目根目录执行构建脚本:

   ```bash
   ./scripts/build.sh
   ```

   脚本会以 `CODE_SIGNING_ALLOWED=NO` 做 Release 构建(工具链自动 ad-hoc 签名),
   清理扩展属性并打包,产物输出到 `dist/CCBar.app.zip`。

3. 把 `dist/CCBar.app.zip` 上传到 GitHub Release 即可。用户首次安装按上方「安装」一节手动放行一次。

> 不要用 Xcode 的 Archive 导出分发:那会引入 "Apple Development" 开发证书,只能在本机运行,拷给别人会打不开。

## 反馈

请到 [Issues](https://github.com/nanvon/cc-bar/issues) 留言。

## 致谢

cc-bar 在设计与实现上参考了以下优秀的开源项目,在此特别感谢:

- [cc-switch](https://github.com/farion1231/cc-switch) —— 多 Provider 账号切换器,启发了本项目的多账号管理与导入流程
- [cockpit-tools](https://github.com/jlcodes99/cockpit-tools) —— 多平台 AI 编码助手仪表盘,在额度与刷新策略上提供了参考
- [CodexBar](https://github.com/steipete/CodexBar) —— macOS 菜单栏 AI 用量监控,在菜单栏交互与本地解析思路上多有借鉴
