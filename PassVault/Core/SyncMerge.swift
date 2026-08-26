import Foundation

/// 2 台の保管庫を突き合わせて 1 つにまとめる。
///
/// 方針は「項目ごとに新しい方を採る」。何をもって新しいとするかは:
/// - 項目そのものは `updatedAt`
/// - 完全削除は墓標の `deletedAt`
///
/// 同じ ID について両方が存在する場合、時刻の新しい操作が勝つ。
/// つまり「A で編集したあと B で消した」なら消えるし、
/// 「A で消したあと B で編集した」なら編集が残る。
enum SyncMerge {

    /// 墓標を保持しておく期間。これを過ぎたものは、
    /// もうすべての端末に伝わっているとみなして捨てる。
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 60 * 60

    struct Summary: Equatable {
        var added = 0
        var updated = 0
        var deleted = 0
        var unchanged = 0

        var isEmpty: Bool { added == 0 && updated == 0 && deleted == 0 }

        var description: String {
            if isEmpty { return "変更はありませんでした" }
            var parts: [String] = []
            if added > 0 { parts.append("追加 \(added)") }
            if updated > 0 { parts.append("更新 \(updated)") }
            if deleted > 0 { parts.append("削除 \(deleted)") }
            return parts.joined(separator: "、")
        }
    }

    struct Result {
        var payload: VaultPayload
        var summary: Summary
    }

    /// `local` に `remote` を取り込んだ結果を返す。
    /// summary は local から見た変化（相手から何件入ってきたか）。
    static func merge(local: VaultPayload, remote: VaultPayload, now: Date = Date()) -> Result {
        var summary = Summary()

        // ID ごとに引けるようにしておく。
        // 同じ ID が重複していても落ちないよう、新しい方を残す。
        let localItems = Dictionary(local.items.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }
        let remoteItems = Dictionary(remote.items.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }

        var deletionsByID: [UUID: Deletion] = [:]
        for deletion in local.deletions + remote.deletions {
            if let existing = deletionsByID[deletion.id], existing.deletedAt >= deletion.deletedAt {
                continue
            }
            deletionsByID[deletion.id] = deletion
        }

        var mergedItems: [VaultItem] = []
        let allIDs = Set(localItems.keys).union(remoteItems.keys).union(deletionsByID.keys)

        for id in allIDs {
            let localItem = localItems[id]
            let remoteItem = remoteItems[id]
            let deletion = deletionsByID[id]

            // その ID について最も新しい「項目」を選ぶ
            let winningItem: VaultItem?
            switch (localItem, remoteItem) {
            case let (localValue?, remoteValue?):
                winningItem = remoteValue.updatedAt > localValue.updatedAt ? remoteValue : localValue
            case let (localValue?, nil):
                winningItem = localValue
            case let (nil, remoteValue?):
                winningItem = remoteValue
            case (nil, nil):
                winningItem = nil
            }

            guard let item = winningItem else {
                // 項目は無く墓標だけ。数えるものはない。
                continue
            }

            // 墓標のほうが新しければ、この項目は消えたものとして扱う
            if let deletion, deletion.deletedAt > item.updatedAt {
                if localItem != nil { summary.deleted += 1 }
                continue
            }

            mergedItems.append(item)

            if localItem == nil {
                summary.added += 1
            } else if item != localItem {
                summary.updated += 1
            } else {
                summary.unchanged += 1
            }
        }

        // 古すぎる墓標は捨てる（際限なく増えるのを防ぐ）
        let liveDeletions = deletionsByID.values
            .filter { now.timeIntervalSince($0.deletedAt) < tombstoneLifetime }
            .sorted { $0.deletedAt < $1.deletedAt }

        // 保存されるバイト列が端末によってぶれないよう順序を固定する
        mergedItems.sort { $0.id.uuidString < $1.id.uuidString }

        return Result(
            payload: VaultPayload(items: mergedItems, deletions: Array(liveDeletions)),
            summary: summary
        )
    }
}
