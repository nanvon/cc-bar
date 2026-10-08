import SwiftUI

/// 独立原生窗口，不依赖 Popover 的显示生命周期。
struct AppUpdateWindow: View {
    let updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(updater.currentVersion)
                    if let version = updater.availableVersion {
                        Image(systemName: "arrow.right")
                        Text(version)
                    }
                    Spacer()
                    if let date = updater.publishedAt {
                        Text(date, format: .dateTime.year().month().day())
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if updater.hasUpdate, !updater.informationOnly {
                    Text(tr("CCBar will restart automatically after downloading and preparing the update.", "下载并准备完成后，CCBar 会自动安装更新并重新启动。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if updater.isLoadingReleaseNotes {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(tr("Loading release notes…", "正在加载更新内容…"))
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !updater.releaseNotes.isEmpty {
                        UpdateMarkdownView(markdown: updater.releaseNotes)
                    }
                    if let error = updater.releaseNotesError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button(tr("View release notes", "查看发布说明")) { updater.openReleasePage() }
                    }
                    if let error = updater.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                progress
                HStack(spacing: 12) {
                    if updater.canSkipVersion, !updater.informationOnly {
                        Button(tr("Skip this version", "跳过此版本")) { updater.skipVersion() }
                            .buttonStyle(.borderless)
                    } else if let minimum = updater.minimumSystemVersion, updater.hasUpdate {
                        Text("macOS \(minimum)+").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    buttons
                }
                .controlSize(.regular)
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 380)
    }

    private var title: String {
        switch updater.phase {
        case .checking, .downloading, .preparing, .installing:
            return tr("CCBar Update", "CCBar 更新")
        case .failed: return tr("Update could not be completed", "更新未能完成")
        case .upToDate: return tr("You’re up to date", "已是最新版本")
        case .available, .idle: return tr("CCBar Update", "CCBar 更新")
        }
    }

    @ViewBuilder private var progress: some View {
        if updater.phase == .downloading {
            if let value = updater.downloadProgress { ProgressView(value: value) }
            else { ProgressView().progressViewStyle(.linear) }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: updater.downloadedBytes), countStyle: .file))
                if updater.expectedBytes > 0 {
                    Text("/ \(ByteCountFormatter.string(fromByteCount: Int64(clamping: updater.expectedBytes), countStyle: .file))")
                    Spacer()
                    Text("\(Int((updater.downloadProgress ?? 0) * 100))%")
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if updater.phase == .preparing || updater.phase == .installing || updater.phase == .checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(updater.statusText ?? "").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .available:
            Button(updater.informationOnly ? tr("View release", "查看发布说明") : tr("Download and Install", "下载并安装")) {
                updater.installUpdate()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!updater.canInstall)
        case .checking:
            Button(tr("Cancel", "取消")) {
                updater.cancelDownloadOrCheck()
                updater.closeWindow()
            }
        case .downloading:
            Button(tr("Cancel", "取消")) { updater.cancelDownloadOrCheck() }
        case .preparing, .installing:
            EmptyView()
        case .failed:
            Button(tr("Download Manually", "手动下载")) { updater.openReleasePage() }
            Button(updater.canRetryInstallation ? tr("Retry Installation", "重试安装") : tr("Retry", "重试")) { updater.retry() }
                .buttonStyle(.borderedProminent)
        case .idle, .upToDate:
            Button(tr("Done", "完成")) { updater.closeWindow() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// 发布说明来自签名后的 Markdown，按行使用原生 Text 渲染，不加载网页或脚本。
private struct UpdateMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if line.hasPrefix("## ") {
                        Text(String(line.dropFirst(3))).font(.headline).padding(.top, 8)
                    } else if line.hasPrefix("# ") {
                        Text(String(line.dropFirst(2))).font(.title3.weight(.semibold)).padding(.top, 8)
                    } else if line.hasPrefix("- ") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            inline(String(line.dropFirst(2)))
                        }
                    } else {
                        inline(line)
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
