import Foundation

struct PasswordChange: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var value: String
    var changedAt: Date = Date()
}

struct VaultItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var category: ItemCategory = .login
    var title: String = ""
    var fields: [ItemField] = []
    var notes: String = ""
    var tags: [String] = []
    var isFavorite: Bool = false
    /// otpauth:// URI か、素の Base32 シークレット
    var oneTimePasswordSecret: String = ""
    var passwordHistory: [PasswordChange] = []
    /// ゴミ箱に入れた日時。nil なら通常のアイテム。
    var trashedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(category: ItemCategory = .login) {
        self.category = category
        self.fields = category.template
    }

    var isTrashed: Bool { trashedAt != nil }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "名称未設定" : title
    }

    var initial: String { String(displayTitle.prefix(1)).uppercased() }

    // MARK: - よく使う欄への近道

    var primaryPassword: String? {
        fields.first { $0.kind == .password && !$0.isEmpty }?.value
    }

    var primaryUsername: String? {
        fields.first { ($0.kind == .username || $0.kind == .email) && !$0.isEmpty }?.value
    }

    var primaryURL: String? {
        fields.first { $0.kind == .url && !$0.isEmpty }?.value
    }

    /// 一覧の 2 行目に出す補助テキスト
    var subtitle: String {
        switch category {
        case .creditCard:
            let number = fields.first { $0.kind == .cardNumber && !$0.isEmpty }?.value.filter(\.isNumber)
            if let number, number.count >= 4 { return "•••• " + String(number.suffix(4)) }
            return fields.first { $0.kind == .text && !$0.isEmpty }?.value ?? ""
        case .secureNote:
            return notes.split(separator: "\n").first.map(String.init) ?? ""
        default:
            return primaryUsername ?? primaryURL ?? ""
        }
    }

    var hasOneTimePassword: Bool {
        !oneTimePasswordSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        if tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        if notes.lowercased().contains(q) { return true }
        // 値そのものは検索対象にするが、伏せ字の欄（パスワード等）は除く。
        // 検索結果からパスワードの中身が推測できてしまうのを避けるため。
        return fields.contains { field in
            guard !field.kind.isConcealed else { return field.label.lowercased().contains(q) }
            return field.label.lowercased().contains(q) || field.value.lowercased().contains(q)
        }
    }
}

// MARK: - 保存される中身

/// 完全に削除した項目の墓標。
///
/// これがないと、片方の端末で消した項目が、もう片方と同期したときに復活してしまう。
/// 「消えた」という事実そのものを、いつ消したかと一緒に持ち回る必要がある。
struct Deletion: Codable, Hashable, Identifiable {
    var id: UUID
    var deletedAt: Date = Date()
}

struct VaultPayload: Codable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int = currentSchemaVersion
    var items: [VaultItem] = []
    var deletions: [Deletion] = []

    init(items: [VaultItem] = [], deletions: [Deletion] = []) {
        self.items = items
        self.deletions = deletions
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, items, deletions
        case entries  // v1 のキー
    }

    /// 古い形式の保管庫も読める。
    /// v1 = `entries` に平坦な項目が並ぶ形、v2 = `items` のみで墓標なし。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([VaultItem].self, forKey: .items) {
            self.items = items
            self.deletions = try container.decodeIfPresent([Deletion].self, forKey: .deletions) ?? []
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        } else if let legacy = try container.decodeIfPresent([LegacyVaultEntry].self, forKey: .entries) {
            self.items = legacy.map(VaultItem.init(legacy:))
            self.deletions = []
            // 「古い形式から読んだ」ことを残す。これを見て VaultStore が現行形式に書き戻す。
            schemaVersion = 1
        } else {
            self.items = []
            self.deletions = []
            schemaVersion = Self.currentSchemaVersion
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(items, forKey: .items)
        try container.encode(deletions, forKey: .deletions)
    }
}

// MARK: - v1 からの移行

/// v1 の保管庫に入っていた形。読み込み専用。
struct LegacyVaultEntry: Codable {
    var id: UUID
    var title: String
    var username: String
    var password: String
    var url: String
    var notes: String
    var folder: String
    var createdAt: Date
    var updatedAt: Date
}

extension VaultItem {
    init(legacy: LegacyVaultEntry) {
        self.init(category: .login)
        id = legacy.id
        title = legacy.title
        notes = legacy.notes
        tags = legacy.folder.isEmpty ? [] : [legacy.folder]
        createdAt = legacy.createdAt
        updatedAt = legacy.updatedAt
        fields = [
            ItemField(label: "ユーザー名", value: legacy.username, kind: .username),
            ItemField(label: "パスワード", value: legacy.password, kind: .password),
            ItemField(label: "ウェブサイト", value: legacy.url, kind: .url),
        ]
    }
}
