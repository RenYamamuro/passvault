import SwiftUI

struct CreateVaultView: View {
    @EnvironmentObject private var store: VaultStore

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var tooShort: Bool { password.count < 12 }
    private var mismatch: Bool { !confirmation.isEmpty && password != confirmation }
    private var canSubmit: Bool {
        !isWorking && !tooShort && !password.isEmpty && password == confirmation
    }

    var body: some View {
        GateScaffold(
            systemImage: "lock.rectangle.stack",
            title: "保管庫をつくる",
            subtitle: "マスターパスワードだけがこの保管庫を開ける鍵です。どこにも保存されないので、忘れると中身は取り出せません。"
        ) {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    SecureField("マスターパスワード", text: $password)
                        .textFieldStyle(.roundedBorder)
                    SecureField("もう一度入力", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canSubmit { submit() } }
                }

                VStack(alignment: .leading, spacing: 6) {
                    hint("12文字以上", satisfied: !tooShort && !password.isEmpty)
                    hint("2回の入力が一致", satisfied: !password.isEmpty && password == confirmation)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if mismatch {
                    Label("入力が一致していません", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("鍵を生成中…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("保管庫を作成").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)

                Text("ヒント: 覚えやすい単語を4〜5個つないだ長い文（例: 紫の 亀 が 図書館 で 走る）は、記号混じりの短いパスワードより安全で覚えやすいです。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hint(_ text: String, satisfied: Bool) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(satisfied ? Color.green : Color.secondary)
        }
        .foregroundStyle(satisfied ? .primary : .secondary)
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await store.createVault(masterPassword: password)
                password = ""
                confirmation = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
