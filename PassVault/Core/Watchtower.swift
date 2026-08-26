import Foundation

/// 保管庫全体を見渡して、危ないパスワードを洗い出す。
/// 1Password の Watchtower にあたる機能。すべて端末内で完結し、通信は一切しない。
struct WatchtowerFinding: Identifiable, Hashable {

    enum Kind: String, CaseIterable {
        case reused
        case weak
        case old
        case insecureURL

        var title: String {
            switch self {
            case .reused: return "使い回している"
            case .weak: return "推測されやすい"
            case .old: return "長く変えていない"
            case .insecureURL: return "保護されていないサイト"
            }
        }

        var symbol: String {
            switch self {
            case .reused: return "arrow.triangle.2.circlepath"
            case .weak: return "exclamationmark.shield.fill"
            case .old: return "clock.arrow.circlepath"
            case .insecureURL: return "lock.open.trianglebadge.exclamationmark"
            }
        }

        /// 深刻な順に並べるための重み
        var severity: Int {
            switch self {
            case .reused: return 0
            case .weak: return 1
            case .old: return 2
            case .insecureURL: return 3
            }
        }

        var explanation: String {
            switch self {
            case .reused:
                return "1つのサービスが漏れると、同じパスワードを使った他のサービスも芋づる式に破られます。"
            case .weak:
                return "総当たりや辞書攻撃で破られやすいパスワードです。生成機能で作り直すのが確実です。"
            case .old:
                return "1年以上変えていないパスワードです。気づかないうちに漏れている可能性があります。"
            case .insecureURL:
                return "http:// のサイトは通信が暗号化されません。https:// が使えないか確認してください。"
            }
        }
    }

    var itemID: UUID
    var itemTitle: String
    var kind: Kind
    var detail: String

    var id: String { "\(itemID.uuidString)-\(kind.rawValue)" }
}

enum Watchtower {

    /// これより古いパスワードは「長く変えていない」とみなす
    static let ageThreshold: TimeInterval = 365 * 24 * 60 * 60

    /// これ未満のビット数を「推測されやすい」とみなす
    static let weakThreshold: Double = 50

    static func audit(_ items: [VaultItem], now: Date = Date()) -> [WatchtowerFinding] {
        let active = items.filter { !$0.isTrashed }
        var findings: [WatchtowerFinding] = []

        // 使い回し: 同じパスワードを持つアイテムが 2 つ以上ある
        var byPassword: [String: [VaultItem]] = [:]
        for item in active {
            guard let password = item.primaryPassword, !password.isEmpty else { continue }
            byPassword[password, default: []].append(item)
        }
        for (_, group) in byPassword where group.count > 1 {
            for item in group {
                let others = group.filter { $0.id != item.id }
                    .map(\.displayTitle)
                    .sorted()
                findings.append(
                    WatchtowerFinding(
                        itemID: item.id,
                        itemTitle: item.displayTitle,
                        kind: .reused,
                        detail: "同じパスワードを \(others.joined(separator: "、")) でも使っています"
                    )
                )
            }
        }

        for item in active {
            if let password = item.primaryPassword, !password.isEmpty {
                let bits = PasswordStrength.estimateBits(password)
                if bits < weakThreshold {
                    findings.append(
                        WatchtowerFinding(
                            itemID: item.id,
                            itemTitle: item.displayTitle,
                            kind: .weak,
                            detail: "推定 \(Int(bits)) ビット相当（\(PasswordStrength.level(bits: bits).label)）"
                        )
                    )
                }

                let changedAt = lastPasswordChange(of: item)
                if now.timeIntervalSince(changedAt) > ageThreshold {
                    let years = now.timeIntervalSince(changedAt) / (365 * 24 * 60 * 60)
                    findings.append(
                        WatchtowerFinding(
                            itemID: item.id,
                            itemTitle: item.displayTitle,
                            kind: .old,
                            detail: String(format: "最後に変更してから約 %.1f 年", years)
                        )
                    )
                }
            }

            for field in item.fields where field.kind == .url && !field.isEmpty {
                if field.value.lowercased().hasPrefix("http://") {
                    findings.append(
                        WatchtowerFinding(
                            itemID: item.id,
                            itemTitle: item.displayTitle,
                            kind: .insecureURL,
                            detail: field.value
                        )
                    )
                }
            }
        }

        return findings.sorted { lhs, rhs in
            if lhs.kind.severity != rhs.kind.severity { return lhs.kind.severity < rhs.kind.severity }
            return lhs.itemTitle.localizedStandardCompare(rhs.itemTitle) == .orderedAscending
        }
    }

    /// 現在のパスワードを使い始めた日。
    /// 履歴の最新は「1つ前のパスワードを捨てた日」＝今のパスワードを設定した日にあたる。
    static func lastPasswordChange(of item: VaultItem) -> Date {
        item.passwordHistory.map(\.changedAt).max() ?? item.createdAt
    }
}
