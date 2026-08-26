import SwiftUI

/// 解錠後の画面。1Password と同じ 3 カラム構成:
/// カテゴリ（サイドバー） → アイテム一覧 → 詳細
struct MainView: View {
    @EnvironmentObject private var store: VaultStore

    @State private var selection: SidebarSelection? = .all
    @State private var selectedItemID: VaultItem.ID?
    @State private var search = ""
    @State private var editingItem: VaultItem?
    @State private var showingGenerator = false
    @State private var showingSettings = false
    @State private var toast: String?

    /// サイドバーで何も選ばれていない状態（iOS の初回表示など）は「すべて」とみなす
    private var activeSelection: SidebarSelection { selection ?? .all }

    private var visibleItems: [VaultItem] {
        store.items(for: activeSelection, search: search)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } content: {
            Group {
                if case .watchtower = activeSelection {
                    WatchtowerView(selectedItemID: $selectedItemID)
                } else {
                    ItemListView(
                        items: visibleItems,
                        selection: activeSelection,
                        selectedItemID: $selectedItemID,
                        onEdit: { editingItem = $0 },
                        onToast: showToast
                    )
                }
            }
            .searchable(text: $search, prompt: "検索")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            #endif
            .toolbar { contentToolbar }
        } detail: {
            if let item = store.item(withID: selectedItemID) {
                ItemDetailView(
                    item: item,
                    onEdit: { editingItem = item },
                    onToast: showToast
                )
                .id(item.id)
            } else {
                ContentUnavailableView(
                    "項目を選択してください",
                    systemImage: "lock.shield",
                    description: Text("左の一覧から選ぶと、ここに中身が表示されます。")
                )
            }
        }
        .sheet(item: $editingItem) { item in
            ItemEditView(item: item) { saved in
                do {
                    try store.upsert(saved)
                    selectedItemID = saved.id
                    showToast("保存しました")
                } catch {
                    showToast("保存に失敗: \(error.localizedDescription)")
                }
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showingGenerator) {
            GeneratorView { generated in
                Clipboard.copySecret(generated)
                showToast("生成してコピーしました（\(Int(Clipboard.clearAfter))秒で消去）")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(store)
        }
        .overlay(alignment: .bottom) { toastView }
        .onChange(of: selection) { _, _ in
            store.noteActivity()
            // 別のカテゴリに切り替えたのに、そこに無いアイテムが選ばれたままにならないように
            if let id = selectedItemID, !visibleItems.contains(where: { $0.id == id }) {
                selectedItemID = nil
            }
        }
    }

    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(ItemCategory.allCases) { category in
                    Button {
                        editingItem = VaultItem(category: category)
                    } label: {
                        Label(category.displayName, systemImage: category.symbol)
                    }
                }
            } label: {
                Label("新規", systemImage: "plus")
            } primaryAction: {
                editingItem = VaultItem(category: defaultCategoryForNewItem)
            }
            .help("新しい項目を追加")
        }
        ToolbarItem(placement: .automatic) {
            Button { showingGenerator = true } label: {
                Label("パスワード生成", systemImage: "die.face.5")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { showingSettings = true } label: {
                Label("設定", systemImage: "gearshape")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { store.lock() } label: {
                Label("ロック", systemImage: "lock.fill")
            }
        }
    }

    /// カテゴリを選んでいるときは、その種別で新規作成するのが自然
    private var defaultCategoryForNewItem: ItemCategory {
        if case .category(let category) = activeSelection { return category }
        return .login
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ message: String) {
        store.noteActivity()
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == message { toast = nil } }
        }
    }
}
