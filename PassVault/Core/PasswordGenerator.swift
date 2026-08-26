import Foundation
import Security

struct PasswordOptions: Equatable {
    var length: Int = 20
    var useLowercase: Bool = true
    var useUppercase: Bool = true
    var useDigits: Bool = true
    var useSymbols: Bool = true
    /// 0/O、1/l/I など目で見て紛らわしい文字を除く
    var avoidAmbiguous: Bool = true
}

enum PasswordGenerator {

    private static let lowercase = "abcdefghijklmnopqrstuvwxyz"
    private static let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let digits = "0123456789"
    private static let symbols = "!#$%&()*+,-./:;<=>?@[]^_{|}~"
    private static let ambiguous = Set("0O1lI|`'\"~,.;:")

    /// 有効にした種類ごとに必ず 1 文字は入れてから、残りを埋めてシャッフルする。
    static func generate(_ options: PasswordOptions) -> String {
        let sets = characterSets(for: options)
        guard !sets.isEmpty else { return "" }

        let pool = Array(sets.joined())
        guard !pool.isEmpty else { return "" }

        var chars: [Character] = sets.compactMap { set in
            set.isEmpty ? nil : set[randomInt(below: set.count)]
        }

        let target = max(options.length, chars.count)
        while chars.count < target {
            chars.append(pool[randomInt(below: pool.count)])
        }

        // Fisher–Yates。要求種類が必ず先頭に来るのを崩す。
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            chars.swapAt(i, randomInt(below: i + 1))
        }
        return String(chars)
    }

    /// 生成器の設定から計算できる理論エントロピー（ビット）。
    /// 「このパスワードの強さ」ではなく「この設定の強さ」なので、
    /// 手入力したパスワードには使わないこと。
    static func entropyBits(_ options: PasswordOptions) -> Double {
        let poolSize = characterSets(for: options).reduce(0) { $0 + $1.count }
        guard poolSize > 1, options.length > 0 else { return 0 }
        return Double(options.length) * log2(Double(poolSize))
    }

    private static func characterSets(for options: PasswordOptions) -> [[Character]] {
        var sets: [[Character]] = []
        func add(_ s: String, _ enabled: Bool) {
            guard enabled else { return }
            let chars = options.avoidAmbiguous ? s.filter { !ambiguous.contains($0) } : Array(s)
            if !chars.isEmpty { sets.append(Array(chars)) }
        }
        add(lowercase, options.useLowercase)
        add(uppercase, options.useUppercase)
        add(digits, options.useDigits)
        add(symbols, options.useSymbols)
        return sets
    }

    /// 暗号論的乱数から 0..<n の一様な整数を作る。
    /// 単純な `% n` は剰余バイアスが出るので、端数は捨てて引き直す。
    private static func randomInt(below n: Int) -> Int {
        precondition(n > 0)
        let bound = UInt32(n)
        let limit = (UInt32.max / bound) * bound
        while true {
            var raw: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &raw) { buffer -> Int32 in
                SecRandomCopyBytes(kSecRandomDefault, 4, buffer.baseAddress!)
            }
            precondition(status == errSecSuccess, "システムの乱数生成に失敗しました")
            if raw < limit { return Int(raw % bound) }
        }
    }
}
