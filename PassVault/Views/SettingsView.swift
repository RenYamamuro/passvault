import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: VaultStore

    @State private var showingPasswordChange = false
    @State private var showingSync = false
    @State private var message: String?

    private let lockChoices: [Int] = [0, 1, 5, 15, 30, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section("セキュリティ") {
                    Picker("自動ロック", selection: $store.autoLockMinutes) {
                        ForEach(lockChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "しない" : "\(minutes) 分後").tag(minutes)
                        }
                    }

                    if BiometricKeyStore.isAvailable {
                        Toggle("\(BiometricKeyStore.displayName)でロック解除", isOn: biometricsBinding)
                    } else {
                        LabeledContent("生体認証", value: "この端末では使えません")
                            .foregroundStyle(.secondary)
                    }

                    Button("マスターパスワードを変更…") { showingPasswordChange = true }
                }

                Section {
                    Button {
                        showingSync = true
                    } label: {
                        Label("この端末どうしで同期…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                } header: {
                    Text("同期")
                } footer: {
                    Text("同じ Wi-Fi につながったもう 1 台と保管庫を突き合わせます。項目ごとに新しい方が残ります。")
                }

                Section("保管庫") {
                    LabeledContent("登録件数", value: "\(store.activeItems.count) 件")
                    LabeledContent("ゴミ箱", value: "\(store.trashedItems.count) 件")
                    LabeledContent("暗号化", value: "AES-256-GCM")
                    LabeledContent("鍵導出", value: "PBKDF2-SHA512 / \(VaultHeader.defaultIterations.formatted()) 回")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ファイルの場所").font(.caption).foregroundStyle(.secondary)
                        Text(VaultFile.vaultURL.path)
                            .font(.caption)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("このファイルをコピーしておけばバックアップになります。中身は暗号化されているので、そのままクラウドに置いても平文は漏れません。ただしマスターパスワードを忘れると復元は不可能です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    Section {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("設定")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPasswordChange) {
                ChangeMasterPasswordView().environmentObject(store)
            }
            .sheet(isPresented: $showingSync) {
                SyncView(store: store).environmentObject(store)
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { store.biometricsEnabled },
            set: { enabled in
                if enabled {
                    do {
                        try store.enableBiometrics()
                        message = "\(BiometricKeyStore.displayName)を登録しました。"
                    } catch {
                        message = error.localizedDescription
                    }
                } else {
                    store.disableBiometrics()
                    message = "登録を解除しました。"
                }
            }
        )
    }
}

struct ChangeMasterPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: VaultStore

    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !isWorking && !current.isEmpty && newPassword.count >= 12 && newPassword == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("現在のマスターパスワード") {
                    SecureField("現在のパスワード", text: $current)
                }
                Section("新しいマスターパスワード") {
                    SecureField("12文字以上", text: $newPassword)
                    SecureField("もう一度入力", text: $confirmation)
                }
                Section {
                    Text("変更すると保管庫全体を新しい鍵で暗号化しなおします。生体認証を登録している場合は自動で更新されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("マスターパスワードの変更")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("変更", action: submit).disabled(!canSubmit)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 480)
        #endif
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await store.changeMasterPassword(current: current, new: newPassword)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
