import Foundation

/// アイテムの種別。1Password でいうカテゴリにあたる。
enum ItemCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case login
    case secureNote
    case creditCard
    case identity
    case apiCredential
    case wifi
    case license

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .login: return "ログイン"
        case .secureNote: return "セキュアメモ"
        case .creditCard: return "クレジットカード"
        case .identity: return "ID・個人情報"
        case .apiCredential: return "APIキー"
        case .wifi: return "Wi-Fi"
        case .license: return "ライセンス"
        }
    }

    var symbol: String {
        switch self {
        case .login: return "person.badge.key.fill"
        case .secureNote: return "note.text"
        case .creditCard: return "creditcard.fill"
        case .identity: return "person.text.rectangle.fill"
        case .apiCredential: return "key.horizontal.fill"
        case .wifi: return "wifi"
        case .license: return "checkmark.seal.fill"
        }
    }

    /// 新規作成時に並ぶ空欄。1Password と同じく種別ごとに違う入力欄が出る。
    var template: [ItemField] {
        switch self {
        case .login:
            return [
                ItemField(label: "ユーザー名", kind: .username),
                ItemField(label: "パスワード", kind: .password),
                ItemField(label: "ウェブサイト", kind: .url),
            ]
        case .secureNote:
            return []
        case .creditCard:
            return [
                ItemField(label: "名義人", kind: .text),
                ItemField(label: "カード番号", kind: .cardNumber),
                ItemField(label: "有効期限", kind: .monthYear),
                ItemField(label: "セキュリティコード", kind: .pin),
                ItemField(label: "暗証番号", kind: .pin),
                ItemField(label: "カード会社", kind: .text),
            ]
        case .identity:
            return [
                ItemField(label: "氏名", kind: .text),
                ItemField(label: "生年月日", kind: .text),
                ItemField(label: "住所", kind: .multiline),
                ItemField(label: "メールアドレス", kind: .email),
                ItemField(label: "電話番号", kind: .phone),
            ]
        case .apiCredential:
            return [
                ItemField(label: "サービス名", kind: .text),
                ItemField(label: "APIキー", kind: .password),
                ItemField(label: "エンドポイント", kind: .url),
                ItemField(label: "有効期限", kind: .text),
            ]
        case .wifi:
            return [
                ItemField(label: "ネットワーク名（SSID）", kind: .text),
                ItemField(label: "パスワード", kind: .password),
                ItemField(label: "暗号化方式", kind: .text),
            ]
        case .license:
            return [
                ItemField(label: "ライセンス名義", kind: .text),
                ItemField(label: "ライセンスキー", kind: .password),
                ItemField(label: "バージョン", kind: .text),
                ItemField(label: "購入元", kind: .url),
            ]
        }
    }

    /// TOTP を持てる種別かどうか
    var supportsOneTimePassword: Bool {
        self == .login || self == .apiCredential
    }
}
