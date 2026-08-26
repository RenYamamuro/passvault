import Foundation

enum FieldKind: String, Codable, Hashable, CaseIterable {
    case text
    case username
    case password
    case email
    case url
    case phone
    case pin
    case cardNumber
    case monthYear
    case multiline

    /// 既定で伏せ字にする欄
    var isConcealed: Bool {
        switch self {
        case .password, .pin, .cardNumber: return true
        default: return false
        }
    }

    /// コピーしたときにクリップボードを自動消去する欄
    var isSecret: Bool { isConcealed }

    var displayName: String {
        switch self {
        case .text: return "テキスト"
        case .username: return "ユーザー名"
        case .password: return "パスワード"
        case .email: return "メールアドレス"
        case .url: return "URL"
        case .phone: return "電話番号"
        case .pin: return "暗証番号"
        case .cardNumber: return "カード番号"
        case .monthYear: return "有効期限"
        case .multiline: return "複数行テキスト"
        }
    }
}

struct ItemField: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String
    var value: String = ""
    var kind: FieldKind = .text
    /// ユーザーが自分で足した欄かどうか（テンプレート由来と区別する）
    var isCustom: Bool = false

    var isEmpty: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// カード番号を 4 桁ごとに区切って読みやすくする
    var displayValue: String {
        guard kind == .cardNumber else { return value }
        let digits = value.filter(\.isNumber)
        guard digits.count > 4 else { return value }
        return stride(from: 0, to: digits.count, by: 4)
            .map { offset -> String in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                let end = digits.index(start, offsetBy: min(4, digits.count - offset))
                return String(digits[start..<end])
            }
            .joined(separator: " ")
    }
}
