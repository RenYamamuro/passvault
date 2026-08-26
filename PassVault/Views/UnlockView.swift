import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var store: VaultStore

    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        GateScaffold(
            systemImage: "lock.fill",
            title: "ロック中",
            subtitle: "マスターパスワードを入力してください。"
        ) {
            VStack(spacing: 16) {
                SecureField("マスターパスワード", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(unlock)
                    .disabled(isWorking)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: unlock) {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("確認中…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("ロック解除").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || password.isEmpty)

                if store.biometricsEnabled {
                    Button {
                        unlockWithBiometrics()
                    } label: {
                        Label("\(BiometricKeyStore.displayName)で解除",
                              systemImage: BiometricKeyStore.biometryType == .faceID ? "faceid" : "touchid")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
                }
            }
        }
        .onAppear {
            fieldFocused = true
            if store.biometricsEnabled { unlockWithBiometrics() }
        }
    }

    private func unlock() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await store.unlock(masterPassword: password)
                password = ""
            } catch {
                errorMessage = error.localizedDescription
                password = ""
            }
            isWorking = false
        }
    }

    private func unlockWithBiometrics() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await store.unlockWithBiometrics()
            } catch let error as BiometricKeyStore.BiometricError {
                // キャンセルはエラー表示するほどのことではない
                if case .cancelled = error {} else { errorMessage = error.localizedDescription }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
