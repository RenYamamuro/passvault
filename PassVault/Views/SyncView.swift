import SwiftUI

struct SyncView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: VaultStore
    @StateObject private var service: SyncService

    init(store: VaultStore) {
        _service = StateObject(wrappedValue: SyncService(store: store))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch service.phase {
                case .idle: chooseRole
                case .waitingForPeer: waiting
                case .searching: searching
                case .connecting: progress("接続しています…")
                case .verifying(let code): verification(code)
                case .exchanging: progress("保管庫を突き合わせています…")
                case .finished(let summary): finished(summary)
                case .failed(let message): failed(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .navigationTitle("この端末どうしで同期")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        service.stop()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 460)
        #endif
        // 同期中は画面を触らない時間が続くので、その間だけ自動ロックを止める
        .onAppear { store.beginActivityHold() }
        .onDisappear {
            service.stop()
            store.endActivityHold()
        }
    }

    // MARK: - 各段階

    private var chooseRole: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 40))
                .foregroundStyle(Color.appAccent)

            Text("同じ Wi-Fi につながった 2 台で、片方を「待つ」、もう片方を「探す」にしてください。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Button {
                    service.startWaiting()
                } label: {
                    Label("この端末で待つ", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    service.startSearching()
                } label: {
                    Label("相手を探す", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("やりとりは暗号化され、保管庫の中身がそのままネットワークに流れることはありません。マスターパスワードは送られません。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var waiting: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("もう 1 台からの接続を待っています")
                .font(.headline)
            Text("もう片方の端末で「相手を探す」を選び、この端末（\(service.deviceName)）を選んでください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            cancelButton
        }
    }

    private var searching: some View {
        VStack(spacing: 16) {
            if service.peers.isEmpty {
                ProgressView()
                Text("待っている端末を探しています…").font(.headline)
                Text("もう片方で「この端末で待つ」を選んでください。同じ Wi-Fi につながっている必要があります。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("見つかった端末").font(.headline)
                ForEach(service.peers) { peer in
                    Button {
                        service.connect(to: peer)
                    } label: {
                        Label(peer.name, systemImage: "desktopcomputer.and.arrow.down")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            cancelButton
        }
    }

    private func verification(_ code: String) -> some View {
        VStack(spacing: 18) {
            Text("確認コード").font(.headline)

            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            Text("もう 1 台の画面にも同じコードが出ていることを確かめてから、両方で承認してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("コードが違う場合は、通信に第三者が割り込んでいる可能性があります。その場合は中止してください。")
                .font(.caption2)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)

            Button("コードは一致しています") { service.confirmCode() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(service.verificationCode == nil && !service.peerConfirmed)

            if service.peerConfirmed {
                Label("相手は承認済みです", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            cancelButton
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message).font(.headline)
        }
    }

    private func finished(_ summary: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("同期が完了しました").font(.headline)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("閉じる") {
                service.stop()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("同期できませんでした").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("やり直す") { service.stop() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private var cancelButton: some View {
        Button("中止", role: .cancel) { service.stop() }
            .buttonStyle(.borderless)
            .font(.callout)
    }
}
