import SwiftUI

struct CommandCodeCredentialSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var preference: CommandCodeCredentialPreference = .automatic
    @State private var manualKeyInput: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var isSaving: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text(tr("Command Code Credentials", "Command Code 凭据设置"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                // 来源选择
                Picker(tr("Credential Source", "凭据来源"), selection: $preference) {
                    Text(tr("Automatic (Recommended)", "自动读取（推荐）")).tag(CommandCodeCredentialPreference.automatic)
                    Text(tr("Manual API Key", "手动 API Key")).tag(CommandCodeCredentialPreference.manual)
                }
                .pickerStyle(.segmented)

                if preference == .automatic {
                    automaticSection
                } else {
                    manualSection
                }

                Spacer(minLength: 0)

                // 底部按钮
                HStack {
                    Spacer()
                    Button(tr("Cancel", "取消")) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button {
                        saveAndDismiss()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(tr("Save", "保存并应用"))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding(.top, 10)
            }
            .padding(20)
        }
        .frame(width: 440, height: 320)
        .onAppear {
            preference = SettingsStore.shared.commandCodeCredentialPreference
            hasStoredKey = (CommandCodeAuth.loadFromKeychain() != nil)
        }
    }

    private var automaticSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr(
                "Reads local credentials in order: ~/.commandcode, Pi, OpenCode, environment variables.",
                "按顺序读取本机凭据：~/.commandcode → Pi → OpenCode → 环境变量。"
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.commandCodeAccount != nil ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)

                    if let account = appState.commandCodeAccount {
                        Text(tr("Detected: \(account.source.displayName)", "已检测到：\(account.source.displayName)"))
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(tr("No local credentials detected", "未检测到本机可用凭据"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if let login = appState.commandCodeAccount?.login {
                    Text(PrivacyDisplay.isEnabled ? PrivacyDisplay.account("primary:commandCode") : tr("Account: \(login)", "当前账号：\(login)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr(
                "The API key is stored in the macOS Keychain and only sent to Command Code to query quota.",
                "API Key 保存在 macOS 钥匙串中，只发送给 Command Code 用于查询额度。"
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                if hasStoredKey {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text(tr("API Key configured in Keychain", "Keychain 中已保存 API Key"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Remove", "清除")) {
                            CommandCodeAuth.deleteFromKeychain()
                            hasStoredKey = false
                            manualKeyInput = ""
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    }
                }

                SecureField(
                    hasStoredKey ? tr("Enter new API Key to replace", "输入新的 API Key 以替换") : tr("Paste Command Code API Key", "粘贴 Command Code API Key"),
                    text: $manualKeyInput
                )
                .textFieldStyle(.roundedBorder)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private func saveAndDismiss() {
        isSaving = true
        SettingsStore.shared.commandCodeCredentialPreference = preference

        if preference == .manual && !manualKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CommandCodeAuth.saveToKeychain(apiKey: manualKeyInput)
        }

        Task {
            await appState.loadCommandCode()
            if SettingsStore.shared.isProviderEnabled(.commandCode) {
                await appState.refreshQuotas(reason: .userInitiated)
            }
            isSaving = false
            dismiss()
        }
    }
}

