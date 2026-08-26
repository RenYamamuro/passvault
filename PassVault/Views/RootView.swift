import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        Group {
            switch store.status {
            case .noVault:
                CreateVaultView()
            case .locked:
                UnlockView()
            case .unlocked:
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.status)
    }
}

/// 施錠画面と作成画面で共通の見た目
struct GateScaffold<Content: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: 380)
            .padding(32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(.background)
        #else
        .background(Color(.systemGroupedBackground))
        #endif
    }
}
