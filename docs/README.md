# cc-bar 文档索引

项目主体功能已交付,文档以"常驻规范"为主,描述当前实际成果。新需求迭代时优先更新本目录下的文件,保持与代码同步。

## 当前文档

| 文件 | 用途 |
|---|---|
| [产品需求.md](产品需求.md) | 已实现的产品形态、功能范围、边界与不做清单 |
| [技术实现.md](技术实现.md) | 架构、模块、关键流程、并发模型、持久化 |
| [设计风格.md](设计风格.md) | 视觉规范:材质 / 字体 / 颜色 / 圆角 / 间距 / 状态色 / 双语词表 / 组件尺寸 |
| [界面布局.md](界面布局.md) | 每个界面的尺寸、字段、控件位置、空状态;按 Popover / 悬浮窗 / 主窗口 / 设置 / 引导 分章 |
| [打包发布.md](打包发布.md) | 日常打包（`scripts/build.sh` + GitHub Actions 自动发布）与 Developer ID 公证归档、常见问题 |
| [历史用量数据补录指南.md](历史用量数据补录指南.md) | Claude Code 自动清理导致用量缺数据时，如何用 cc-switch 等外部工具的备份补回来（一次性操作手册，非产品功能） |

阅读顺序:先看产品需求(知道有什么),再看技术实现(知道怎么搭),做 UI 时配合设计风格 + 界面布局。

## 草案

| 文件 | 状态 |
|---|---|
| [草案-性能与功耗等价优化方案.md](草案-性能与功耗等价优化方案.md) | 批次 A/B/C 已落地(单一时基调度、FSEvents 日志门控、rollup / 额度写盘节流与 `QuotaPersistenceCoordinator`、`QuotaRefreshPlan`)，批次 D 保留为后续候选 |
| [草案-Cursor支持-设计方案.md](草案-Cursor支持-设计方案.md) | 已落地：`CursorAuth` 只读 SQLite、`CursorQuotaClient` / `CursorUsageFetcher`、独立 `cursor-usage-rollup.json`、Popover / 菜单栏 / 悬浮窗 / 统计页 / 设置 / Onboarding 全部接入。文档保留接口字段与风险说明的追溯细节 |
| [草案-CommandCode支持-设计方案.md](草案-CommandCode支持-设计方案.md) | 已落地：`CommandCodeAuth` 五级凭据扫描 + Keychain 手动 Key、`CommandCodeQuotaClient`、设置账号行与凭据 Sheet、Popover / 菜单栏 / 悬浮窗。按设计不进入主窗口用量统计 |
| [草案-Antigravity支持-设计方案.md](草案-Antigravity支持-设计方案.md) | 已落地：`AntigravityCredentials` 读 `~/.gemini/jetski-standalone-oauth-token`(兜底 `oauth_creds.json`) + 双 client 刷新、`AntigravityQuotaClient` 四段云端富化、Popover / 菜单栏 / 悬浮窗 / 设置 / Onboarding。无本地日志，不进入用量统计 |
| [草案-OpenCodeGo支持-设计方案.md](草案-OpenCodeGo支持-设计方案.md) | **未实施**：`QuotaApp` 中没有 opencodeGo，也没有对应的凭据 / 额度客户端。注意区分——`OpencodeScanner`(`~/.local/share/opencode/opencode.db`)是已落地的**本地用量**扫描器，与本草案的 OpenCode Go **订阅额度**不是一回事 |
| [草案-用量统计增强与对话明细-需求.md](草案-用量统计增强与对话明细-需求.md) | 单对话能力已并入常驻文档;仅保留未实施后续候选 |
| [草案-用量统计增强与对话明细-技术方案.md](草案-用量统计增强与对话明细-技术方案.md) | 原宽范围方案已收窄;仅保留后续技术候选 |

## 历史参考

[历史参考/](历史参考/) 下保留项目早期产物,仅用于追溯,**不**约束新需求实现:

| 项 | 内容 |
|---|---|
| [历史参考/实施里程碑.md](历史参考/实施里程碑.md) | 项目最初按 M1–M9 分阶段实施的计划与验收标准,已全部落地 |
| [历史参考/周期页统计审查报告.md](历史参考/周期页统计审查报告.md) | 周期统计准确性问题、修复依据与静态核验记录 |
| [历史参考/设计稿/](历史参考/设计稿/) | 原始设计稿(README + Prototype.html + Canvas.html + artboards) |
| [历史参考/外部项目分析/](历史参考/外部项目分析/) | CodexBar / cc-switch / cockpit-tools 三个参考项目的开发笔记与用量统计实现分析 |

## 维护规则

- 改代码时,顺手把对应小节回写到上面六份常驻文档之一。代码与文档冲突时**以代码为准**,并修正文档。
- 不在文档里写计划性 / 时间表内容;那些放 GitHub Issue 或 commit message。
- 新增大型功能可在本目录下添加单独的设计草案(命名 `草案-某功能-设计方案.md`);落地后把有效内容并入相应规范文档,草案本身保留为追溯材料并在上表标注真实状态。
