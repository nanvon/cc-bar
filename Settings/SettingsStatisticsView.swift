import AppKit
import SwiftUI

// MARK: - Statistics & Metering View

struct SettingsStatisticsView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore
    let highlightedSection: String?
    @Binding var isRecalculatingUsage: Bool
    @Binding var pricingCatalogMessage: String?
    @Binding var pricingCatalogMessageIsError: Bool

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .statistics)

            // 排行口径与单位
            SettingsCard(
                title: "Display & Units",
                chinese: "口径与单位",
                isHighlighted: highlightedSection == "stats-metrics"
            ) {
                SettingsRow(
                    label: "Ranking metric",
                    chinese: "排行口径",
                    desc: "Used for sorting and percentage shares in Overview and Projects.",
                    chineseDesc: "用于统计概览与项目页的默认排序和占比计算"
                ) {
                    Picker("", selection: $settings.statsRankMetric) {
                        Text("Tokens").tag(StatsRankMetric.tokens)
                        Text(tr("Cost", "费用")).tag(StatsRankMetric.cost)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(
                    label: "Token units",
                    chinese: "Token 单位",
                    desc: "Formatting style for large token numbers.",
                    chineseDesc: "大额 Token 数值的简写单位"
                ) {
                    Picker("", selection: $settings.tokenUnitStyle) {
                        Text(tr("Auto", "跟随语言")).tag(TokenUnitStyle.automatic)
                        Text("万 / 亿").tag(TokenUnitStyle.chinese)
                        Text("k / M / B").tag(TokenUnitStyle.western)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            // 跨 Agent 归属
            SettingsCard(
                title: "Cross-Agent Attribution",
                chinese: "跨 Agent 订阅归属",
                desc: "Attribute subscription usage from multi-model agents back to the primary quota account.",
                chineseDesc: "将第三方多模型 Agent 中消耗的订阅用量合并计入对应主账号",
                isHighlighted: highlightedSection == "stats-attribution"
            ) {
                SettingsRow(
                    label: "Include Codex usage from Pi, OpenCode & DSH",
                    chinese: "包含 Pi、OpenCode、DSH 中的 Codex 订阅用量",
                    desc: "Adds Codex subscription usage from enabled agents to the primary Codex account in quota estimates and popover spend.",
                    chineseDesc: "将已启用的 Pi、OpenCode 和 DSH 中的 Codex 订阅用量计入主账号的额度预估和弹出面板花费"
                ) {
                    Toggle("", isOn: $settings.cycleIncludesOtherAgents)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Include Antigravity usage from Pi, OpenCode & DSH",
                    chinese: "包含 Pi、OpenCode、DSH 中的 Antigravity 订阅用量",
                    desc: "Adds usage from enabled agents connecting to Antigravity directly to the primary account. Usage via the Magpie agy plugin is always included.",
                    chineseDesc: "将已启用的 Pi、OpenCode 和 DSH 直连 Antigravity 的用量计入主账号。经 Magpie agy 插件的用量始终计入"
                ) {
                    Toggle("", isOn: $settings.cycleIncludesOtherAgentsForAntigravity)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }

            // 速度估算
            SettingsCard(
                title: "Output Speed",
                chinese: "输出速度估算",
                isHighlighted: highlightedSection == "stats-speed"
            ) {
                SettingsRow(
                    label: "Estimate Pi output speed",
                    chinese: "估算 Pi 输出速度",
                    desc: "Pi logs only record total request time (including time to first token), so estimates read low. Requests timed by the Pi timing plugin always use actual generation time.",
                    chineseDesc: "Pi 日志只记录请求总耗时（包含首字等待），估算值偏低。装了 Pi 计时插件的请求始终按实际生成时间计算",
                    detail: AnyView(PiTimingGuideButton())
                ) {
                    Toggle("", isOn: $settings.piEstimatedOutputSpeed)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }

            // 价格与历史重算
            SettingsCard(
                title: "Pricing & History Maintenance",
                chinese: "价格目录与数据维护",
                isHighlighted: highlightedSection == "stats-maintenance"
            ) {
                SettingsRow(
                    label: "Price catalog",
                    chinese: "价格目录",
                    desc: "Past costs are recalculated automatically when model prices change.",
                    chineseDesc: "模型价格变化后会自动重算历史费用"
                ) {
                    HStack(spacing: 8) {
                        if let pricingCatalogMessage {
                            Text(pricingCatalogMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    pricingCatalogMessageIsError
                                        ? SettingsSemanticTone.danger.foreground
                                        : SettingsSemanticTone.success.foreground
                                )
                        }
                        Button {
                            pricingCatalogMessage = nil
                            Task {
                                let succeeded = await appState.usageService.refreshPricingCatalog()
                                pricingCatalogMessageIsError = !succeeded
                                pricingCatalogMessage = succeeded
                                    ? tr("Updated", "已更新")
                                    : tr("Update failed", "更新失败")
                            }
                        } label: {
                            if appState.usageService.isRefreshingPricingCatalog {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(tr("Update", "检查更新"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.usageService.isRefreshingPricingCatalog)
                    }
                }

                SettingsDivider()

                let recalculating = isRecalculatingUsage || appState.usageService.isRebuildingHistory
                SettingsRow(
                    label: "Recalculate usage",
                    chinese: "重新计算用量",
                    desc: "Recompute usage for enabled services using the latest prices and rules. Usage from deleted logs is preserved.",
                    chineseDesc: "按最新价格和统计规则重算已启用服务的用量，保留已删除日志的历史用量",
                    detail: recalculateOutcomeDetail
                ) {
                    HStack(spacing: 8) {
                        if appState.usageService.cycleUsageNeedsManualRecalculation, !recalculating {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                Text(tr("Cycle incomplete", "周期用量不完整"))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(SettingsSemanticTone.warning.foreground)
                            .help(tr(
                                "Some past cycles are missing usage data. Recalculate to fill it in.",
                                "部分历史周期缺少用量数据，点「重新计算」补齐"
                            ))
                        }
                        if let progress = appState.usageService.scanProgress, recalculating {
                            Text(scanProgressText(progress))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        Button {
                            isRecalculatingUsage = true
                            Task {
                                await appState.usageService.forceRescan()
                                isRecalculatingUsage = false
                            }
                        } label: {
                            if recalculating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(tr("Recalculate", "重新计算"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(recalculating || SettingsStore.shared.enabledLocalUsageApps.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Rebuild Outcome Helpers

    private var recalculateOutcomeDetail: AnyView? {
        guard !isRecalculatingUsage,
              let hint = rebuildOutcomeHint(appState.usageService.lastRebuildOutcome)
        else { return nil }
        return AnyView(
            SettingsCallout(
                tone: .warning,
                icon: "exclamationmark.triangle.fill",
                title: tr("Last recalculation notice", "上次重算提示"),
                message: hint
            )
            .help(PrivacyDisplay.help(appState.usageService.lastRebuildDiagnostic ?? ""))
            .padding(.top, 4)
        )
    }

    private func rebuildOutcomeHint(_ outcome: UsageRebuildOutcome?) -> String? {
        switch outcome {
        case .rejectedUsageChanged:
            return tr(
                "Not applied: recalculated usage did not match existing data. Existing data kept.",
                "未生效：重算结果与已有数据不一致，原数据未改动"
            )
        case .rejectedIncompleteSources:
            if let issue = appState.usageService.logReadIssue {
                let cause = issue.localizedCause
                if let fix = issue.localizedFix {
                    return tr("Not applied: \(cause). Existing data kept; \(fix), then try again.",
                              "未生效：\(cause)。原数据未改动，\(fix)后再试")
                }
                return tr("Not applied: \(cause). Existing data kept.", "未生效：\(cause)，原数据未改动")
            }
            return tr(
                "Not applied: some logs could not be read. Existing data kept.",
                "未生效：部分日志读取失败，原数据未改动"
            )
        case .commitFailed:
            return tr(
                "Could not save the result. Existing data kept.",
                "结果保存失败，原数据未改动"
            )
        case .partiallyCommitted:
            return tr(
                "Partly applied: costs for models with newly fetched prices were not updated.",
                "部分生效：新获取价格的模型费用未更新"
            )
        case .restrictedRecoveryRejected:
            return tr(
                "Verification failed. Existing data kept; new usage is paused. Restore the logs or fix disk read/write errors, then retry.",
                "校验未通过：原数据保留，已暂停统计新用量。恢复日志或解决磁盘读写问题后再试"
            )
        case .restrictedRecoveryRequiresEnabledApps:
            return tr(
                "Existing data kept. To verify history, enable the services with saved usage and try again.",
                "现有数据保留。请启用有历史用量的服务，再重新校验"
            )
        case .sourcesChanged:
            return tr(
                "Services changed during recalculation. Existing data kept. Recalculate again to apply the new selection.",
                "重算期间服务开关发生变化，现有数据保留。请重新计算"
            )
        case .replaced, .recoveredFromRestrictedHistory, .none:
            return nil
        }
    }

    private func scanProgressText(_ progress: ScanProgress) -> String {
        let appName = progress.app.displayName
        if progress.filesTotal > 0 {
            return tr(
                "Scanning \(appName): \(progress.filesCompleted)/\(progress.filesTotal) files",
                "正在扫描 \(appName)：\(progress.filesCompleted)/\(progress.filesTotal) 个文件"
            )
        }
        return tr(
            "Scanning \(appName): \(progress.linesParsed) items",
            "正在扫描 \(appName)：已处理 \(progress.linesParsed) 条"
        )
    }
}

// MARK: - Pi 计时插件说明

private struct PiTimingGuideButton: View {
    @State private var isPresented = false
    @State private var copied = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10.5))
                Text(tr("Timing plugin instructions", "查看计时插件说明"))
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
        .buttonStyle(.link)
        .focusEffectDisabled()
        .pointingHandCursor()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Pi timing plugin", "Pi 计时插件"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr(
                    "Give the instructions below to an AI to write a timing plugin for Pi. Once installed, Pi's first token and output speed use actual generation time.",
                    "把下面的说明交给 AI，为 Pi 写一个计时插件。装好后，Pi 的首字和输出速度按实际生成时间计算。"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(PiTimingPluginGuide.text)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                Button(copied ? tr("Copied", "已复制") : tr("Copy", "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PiTimingPluginGuide.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(14)
            .frame(width: 360, alignment: .leading)
        }
    }
}

private enum PiTimingPluginGuide {
    static var text: String {
        let field = PiJSONLScanner.timingField
        return tr(
            """
            Please write a Pi coding agent plugin (Pi calls it an extension) so that CCBar can compute first token latency and output speed from actual generation time.

            Before you start:
            - Check that the installed Pi lets a message_end handler return a replacement message (MessageEndEventResult in the extension types, or the message_end section of docs/extensions.md in the Pi package). If it does not, stop and tell me. Do not switch to appendEntry, extra files or any other way of writing the data.
            - Check the custom provider plugins I have installed. If any of them sends the whole assistant message object to the model API (instead of picking fields such as content), stop and tell me.

            Requirements:
            1. Create a standalone plugin file. Do not modify plugin packages installed through npm, because updates overwrite them.
            2. On turn_start, record the request send time. Built-in providers also fire before_provider_request; when it fires before the first delta of the request, overwrite the send time with it.
            3. On message_start with role "assistant", clear the first-delta and last-delta times of the current request. Do not clear the send time from step 2.
            4. On message_update with role "assistant", when assistantMessageEvent.type is text_delta, thinking_delta or toolcall_delta, record the arrival time of the first delta and of the latest delta.
            5. On message_end with role "assistant": if at least one delta arrived and stopReason is neither "error" nor "aborted", return a replacement message that adds a \(field) field:
               return { message: { ...event.message, \(field): { v: 1, firstTokenMs, generationMs } } };
               - v: the number 1
               - generationMs: milliseconds from the first delta to the last delta, rounded to an integer
               - firstTokenMs: milliseconds from the send time to the first delta, rounded to an integer; omit the key if no send time was recorded
               Keep the role and every other field unchanged (the spread also keeps fields added by other plugins). In all other cases return nothing.
               Pi writes the replacement message to the session JSONL as is, so timing and usage end up on the same line.
            6. Measure all times with performance.now(), not Date.now().
            7. Do not filter by duration or token count; CCBar applies its own thresholds.

            Put the file in ~/.pi/agent/extensions/ and restart Pi to load it.

            To verify: have one conversation in Pi, open the newest .jsonl file under ~/.pi/agent/sessions/, and check that the assistant message lines contain "\(field)":{"v":1,...} with integer values.
            """,
            """
            请为 Pi coding agent 写一个插件（Pi 文档里叫 extension），让 CCBar 能按实际生成时间统计首字延迟和输出速度。

            开始前先确认两件事：
            - 已安装的 Pi 支持 message_end 处理函数返回替换后的消息（插件类型里有 MessageEndEventResult，或 Pi 安装包 docs/extensions.md 的 message_end 说明）。不支持就停下来告诉我，不要改用 appendEntry、另写文件或其他方式记录数据。
            - 检查我安装的自定义 provider 插件。如果有插件把 assistant 消息对象整个发给模型 API（而不是只取 content 等字段），停下来告诉我。

            要求：
            1. 新建一个独立的插件文件。不要修改通过 npm 安装的插件包，更新时会被覆盖。
            2. 在 turn_start 记录请求发出时间。内置 provider 还会触发 before_provider_request；它在该请求第一个片段之前触发时，用它覆盖发出时间。
            3. 在 message_start（role 为 assistant）时，清空当前请求的首个片段和最近片段的到达时间。不要清空第 2 步记录的发出时间。
            4. 在 message_update（role 为 assistant）中，assistantMessageEvent.type 为 text_delta、thinking_delta 或 toolcall_delta 时，记录第一个片段和最近一个片段的到达时间。
            5. 在 message_end（role 为 assistant）中：如果收到过片段，且 stopReason 不是 "error" 或 "aborted"，返回替换后的消息，附加 \(field) 字段：
               return { message: { ...event.message, \(field): { v: 1, firstTokenMs, generationMs } } };
               - v：数字 1
               - generationMs：第一个片段到最后一个片段的毫秒数，取整
               - firstTokenMs：发出时间到第一个片段的毫秒数，取整；没有记录到发出时间就不写这个键
               role 和其他字段保持不变（展开写法也会保留其他插件加的字段）。其他情况不返回任何值。
               Pi 会把替换后的消息原样写入会话 JSONL，计时和用量在同一行。
            6. 所有时间用 performance.now() 测量，不用 Date.now()。
            7. 不要按时长或 token 数筛选，CCBar 会自己设门槛。

            文件放在 ~/.pi/agent/extensions/ 下，重启 Pi 生效。

            验证方法：用 Pi 聊一轮，打开 ~/.pi/agent/sessions/ 下最新的 .jsonl 文件，确认 assistant 消息行里有 "\(field)":{"v":1,...}，且数值是整数。
            """
        )
    }
}
