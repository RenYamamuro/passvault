import SwiftUI

@main
struct PassVaultApp: App {
    @StateObject private var store = VaultStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(.appAccent)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS ではアプリを離れた時点で必ず施錠する。
            // macOS はウィンドウを閉じただけでも background になるので、
            // ここでは施錠せず無操作タイマーに任せる。
            #if !os(macOS)
            if phase == .background { store.lock() }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("いますぐロック") { store.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}
