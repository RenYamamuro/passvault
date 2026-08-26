import Foundation

/// 手入力されたパスワードの強さを見積もる。
///
/// これはあくまで**目安**であって、実際の解読しやすさを保証するものではない。
/// zxcvbn のような本格的な推定器は辞書を丸ごと持つ必要があるので、
/// ここでは「文字種・長さ・繰り返し・並び・ありがちな単語」だけを見ている。
enum PasswordStrength {

    /// これに一致したら、どれだけ長くても弱いと判断する
    private static let commonPasswords: Set<String> = [
        "password", "passw0rd", "letmein", "welcome", "admin", "root", "qwerty",
        "monkey", "dragon", "iloveyou", "sunshine", "princess", "football",
        "baseball", "abc", "test", "guest", "master", "login", "hello",
        "freedom", "whatever", "trustno", "starwars", "pokemon", "computer",
    ]

    private static let keyboardRuns = ["qwerty", "asdf", "zxcv", "1234", "qwertz", "azerty"]

    static func estimateBits(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }

        let poolSize = characterPoolSize(password)
        guard poolSize > 1 else { return 0 }

        // 繰り返しや連番は、長さのわりに情報量が少ない
        let effectiveLength = effectiveLength(password)
        var bits = effectiveLength * log2(Double(poolSize))

        // 同じ文字ばかりだと組み合わせは減る
        let uniqueRatio = Double(Set(password).count) / Double(password.count)
        bits *= 0.55 + 0.45 * uniqueRatio

        // ありがちな単語やキーボードの並びを含むなら大幅に減点
        let normalized = password.lowercased()
        let lettersOnly = normalized.filter(\.isLetter)
        if commonPasswords.contains(lettersOnly) || commonPasswords.contains(normalized) {
            return min(bits, 8)
        }
        if commonPasswords.contains(where: { $0.count >= 5 && normalized.contains($0) }) {
            bits *= 0.5
        }
        if keyboardRuns.contains(where: { normalized.contains($0) }) {
            bits *= 0.7
        }

        return max(bits, 1)
    }

    /// 連続した同じ文字や、abc / 123 のような並びは 1 文字分として数えない
    private static func effectiveLength(_ password: String) -> Double {
        var total = 0.0
        var runLength = 0
        var previous: Character?

        for character in password {
            if let previous, isContinuation(from: previous, to: character) {
                runLength += 1
                total += max(0.25, 1.0 - Double(runLength) * 0.25)
            } else {
                runLength = 0
                total += 1
            }
            previous = character
        }
        return total
    }

    private static func isContinuation(from previous: Character, to current: Character) -> Bool {
        if previous == current { return true }
        guard let a = previous.unicodeScalars.first?.value,
              let b = current.unicodeScalars.first?.value,
              previous.isASCII, current.isASCII
        else { return false }
        return b == a + 1 || b + 1 == a
    }

    private static func characterPoolSize(_ password: String) -> Int {
        var pool = 0
        if password.contains(where: { $0.isLowercase && $0.isASCII }) { pool += 26 }
        if password.contains(where: { $0.isUppercase && $0.isASCII }) { pool += 26 }
        if password.contains(where: { $0.isNumber && $0.isASCII }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber && $0.isASCII }) { pool += 33 }
        if password.contains(where: { !$0.isASCII }) { pool += 200 }  // 日本語など
        return pool
    }

    // MARK: - 表示用

    enum Level: Int, Comparable {
        case veryWeak, weak, fair, good, excellent

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .veryWeak: return "とても弱い"
            case .weak: return "弱い"
            case .fair: return "まずまず"
            case .good: return "強い"
            case .excellent: return "とても強い"
            }
        }
    }

    static func level(bits: Double) -> Level {
        switch bits {
        case ..<28: return .veryWeak
        case ..<50: return .weak
        case ..<80: return .fair
        case ..<110: return .good
        default: return .excellent
        }
    }

    static func level(of password: String) -> Level {
        level(bits: estimateBits(password))
    }
}
