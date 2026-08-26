import SwiftUI

struct ItemListView: View {
    @EnvironmentObject private var store: VaultStore

    let items: [VaultItem]
    let selection: SidebarSelection
    @Binding var selectedItemID: VaultItem.ID?
    var onEdit: (VaultItem) -> Void
    var onToast: (String) -> Void

    private var isTrash: Bool {
        if case .trash = selection { return true }
        return false
    }

    var body: some View {
        List(selection: $selectedItemID) {
            ForEach(items) { item in
                ItemRow(item: item, findingCount: store.findings(for: item.id).count)
                    .tag(item.id)
                    .contextMenu { menu(for: item) }
            }
        }
        .navigationTitle(selection.title)
        .overlay {
            if items.isEmpty { emptyState }
        }
        .toolbar {
            if isTrash && !store.trashedItems.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button("ゴミ箱を空にする", role: .destructive) {
                        perform { try store.emptyTrash() }
                        onToast("ゴミ箱を空にしました")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isTrash {
            ContentUnavailableView("ゴミ箱は空です", systemImage: "trash")
        } else {
            ContentUnavailableView(
                "項目がありません",
                systemImage: "tray",
                description: Text("右上の ＋ から追加できます。")
            )
        }
    }

    @ViewBuilder
    private func menu(for item: VaultItem) -> some View {
        if item.isTrashed {
            Button("元に戻す") {
                perform { try store.restore(item) }
                onToast("元に戻しました")
            }
            Divider()
            Button("完全に削除", role: .destructive) {
                perform { try store.deletePermanently(item) }
                if selectedItemID == item.id { selectedItemID = nil }
                onToast("完全に削除しました")
            }
        } else {
            if let password = item.primaryPassword {
                Button("パスワードをコピー") {
                    Clipboard.copySecret(password)
                    onToast("パスワードをコピーしました（\(Int(Clipboard.clearAfter))秒で消去）")
                }
            }
            if let username = item.primaryUsername {
                Button("ユーザー名をコピー") {
                    Clipboard.copyPlain(username)
                    onToast("ユーザー名をコピーしました")
                }
            }
            Divider()
            Button(item.isFavorite ? "お気に入りから外す" : "お気に入りに追加") {
                perform { try store.toggleFavorite(item) }
            }
            Button("編集") { onEdit(item) }
            Divider()
            Button("ゴミ箱に入れる", role: .destructive) {
                perform { try store.moveToTrash(item) }
                if selectedItemID == item.id { selectedItemID = nil }
                onToast("ゴミ箱に入れました")
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { onToast("失敗: \(error.localizedDescription)") }
    }
}

struct ItemRow: View {
    let item: VaultItem
    var findingCount: Int = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if item.hasOneTimePassword {
                Image(systemName: "clock.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("ワンタイムパスワードあり")
            }
            if findingCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Watchtower の指摘あり")
            }
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 2)
    }

    /// タイトルから色を決めて、一覧を目で追いやすくする
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .brown]
        let hash = abs(item.displayTitle.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) })
        return palette[hash % palette.count]
    }
}
