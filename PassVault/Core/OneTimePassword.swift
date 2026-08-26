import CryptoKit
import Foundation

/// RFC 6238 の TOTP（時刻ベースのワンタイムパスワード）。
/// 認証アプリが表示する 6 桁のあれ。
struct OneTimePassword: Equatable {

    enum Algorithm: String, Equatable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    var secret: Data
    var digits: Int = 6
    var period: Int = 30
    var algorithm: Algorithm = .sha1
    var issuer: String?
    var account: String?

    // MARK: - 入力の解釈

    /// QR コードの中身（otpauth://totp/...）でも、素の Base32 文字列でも受け付ける。
    static func parse(_ raw: String) -> OneTimePassword? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("otpauth://") {
            return parseURI(trimmed)
        }
        guard let secret = Base32.decode(trimmed), !secret.isEmpty else { return nil }
        return OneTimePassword(secret: secret)
    }

    private static func parseURI(_ uri: String) -> OneTimePassword? {
        guard let components = URLComponents(string: uri),
              components.host?.lowercased() == "totp"
        else { return nil }

        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value
        }

        guard let secretString = value("secret"),
              let secret = Base32.decode(secretString),
              !secret.isEmpty
        else { return nil }

        var otp = OneTimePassword(secret: secret)
        if let digits = value("digits").flatMap(Int.init), (6...8).contains(digits) {
            otp.digits = digits
        }
        if let period = value("period").flatMap(Int.init), period > 0 {
            otp.period = period
        }
        if let algorithm = value("algorithm").flatMap({ Algorithm(rawValue: $0.uppercased()) }) {
            otp.algorithm = algorithm
        }
        otp.issuer = value("issuer")

        // パスは "/Issuer:account" の形になっている
        let label = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !label.isEmpty {
            let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                otp.issuer = otp.issuer ?? parts[0]
                otp.account = parts[1].trimmingCharacters(in: .whitespaces)
            } else {
                otp.account = label
            }
        }
        return otp
    }

    // MARK: - コードの生成

    func code(at date: Date = Date()) -> String {
        let counter = UInt64(floor(date.timeIntervalSince1970 / Double(period)))
        return code(counter: counter)
    }

    func code(counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)

        let mac: Data
        switch algorithm {
        case .sha1:
            mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // RFC 4226 の動的切り出し: 最終バイト下位 4 ビットを開始位置に使う
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated =
            (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])

        let modulus = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)u", truncated % modulus)
    }

    /// 次のコードに切り替わるまでの秒数
    func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period)))
    }

    /// 3 桁ずつ空けて読みやすくする（1Password と同じ見せ方）
    func formattedCode(at date: Date = Date()) -> String {
        let raw = code(at: date)
        guard raw.count == 6 else { return raw }
        let middle = raw.index(raw.startIndex, offsetBy: 3)
        return raw[raw.startIndex..<middle] + " " + raw[middle...]
    }
}

/// RFC 4648 の Base32。認証アプリのシークレットはこの形式で配られる。
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { $0 != "=" && !$0.isWhitespace && $0 != "-" }
        guard !cleaned.isEmpty else { return nil }

        var output = Data()
        var buffer = 0
        var bitsInBuffer = 0

        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                output.append(UInt8((buffer >> (bitsInBuffer - 8)) & 0xFF))
                bitsInBuffer -= 8
            }
        }
        return output.isEmpty ? nil : output
    }

    static func encode(_ data: Data) -> String {
        var result = ""
        var buffer = 0
        var bitsInBuffer = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                result.append(alphabet[(buffer >> (bitsInBuffer - 5)) & 0x1F])
                bitsInBuffer -= 5
            }
        }
        if bitsInBuffer > 0 {
            result.append(alphabet[(buffer << (5 - bitsInBuffer)) & 0x1F])
        }
        return result
    }
}
