import CommonCrypto
import CryptoKit
import Foundation

enum VaultCryptoError: LocalizedError {
    case malformedFile
    case unsupportedVersion(UInt16)
    case unsupportedKDF(UInt16)
    case wrongPassword
    case keyDerivationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .malformedFile:
            return "保管庫ファイルが壊れているか、形式が違います。"
        case .unsupportedVersion(let v):
            return "対応していないファイル形式です（version \(v)）。"
        case .unsupportedKDF(let k):
            return "対応していない鍵導出方式です（id \(k)）。"
        case .wrongPassword:
            return "マスターパスワードが違います。"
        case .keyDerivationFailed(let s):
            return "鍵の導出に失敗しました（code \(s)）。"
        }
    }
}

/// 保管庫ファイルの平文ヘッダ。
///
/// ここは暗号化しない（復号に必要なパラメータなので当然）が、AES-GCM の
/// 「追加認証データ」に含めることで改ざんは検知できる。これがないと、
/// 攻撃者が iterations を 1 に書き換えて総当たりを楽にする、といった
/// ダウングレード攻撃が成立してしまう。
struct VaultHeader: Equatable {
    static let magic: [UInt8] = Array("PVLT".utf8)
    static let currentVersion: UInt16 = 1
    static let kdfPBKDF2SHA512: UInt16 = 1
    static let saltLength = 32
    static let keyLength = 32  // AES-256
    static let byteCount = 4 + 2 + 2 + 4 + saltLength  // = 44

    /// OWASP の推奨下限（PBKDF2-HMAC-SHA512 で 210,000）を十分上回りつつ、
    /// iPhone でも解錠が数秒で終わる値。Mac で約 0.8 秒。
    /// ファイルに記録されるので、将来ここを上げても古い保管庫はそのまま読める。
    static let defaultIterations: UInt32 = 400_000

    var version: UInt16 = VaultHeader.currentVersion
    var kdfID: UInt16 = VaultHeader.kdfPBKDF2SHA512
    var iterations: UInt32 = VaultHeader.defaultIterations
    var salt: Data

    static func makeNew() -> VaultHeader {
        VaultHeader(salt: VaultCrypto.randomBytes(count: saltLength))
    }

    var encoded: Data {
        var out = Data(VaultHeader.magic)
        out.append(contentsOf: withUnsafeBytes(of: version.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: kdfID.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian, Array.init))
        out.append(salt)
        return out
    }

    static func decode(from data: Data) throws -> VaultHeader {
        guard data.count >= byteCount else { throw VaultCryptoError.malformedFile }
        let bytes = [UInt8](data.prefix(byteCount))
        guard Array(bytes[0..<4]) == magic else { throw VaultCryptoError.malformedFile }

        let version = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard version == currentVersion else { throw VaultCryptoError.unsupportedVersion(version) }

        let kdfID = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard kdfID == kdfPBKDF2SHA512 else { throw VaultCryptoError.unsupportedKDF(kdfID) }

        var iterations: UInt32 = 0
        for byte in bytes[8..<12] { iterations = iterations << 8 | UInt32(byte) }
        guard iterations > 0 else { throw VaultCryptoError.malformedFile }

        return VaultHeader(
            version: version,
            kdfID: kdfID,
            iterations: iterations,
            salt: Data(bytes[12..<byteCount])
        )
    }
}

enum VaultCrypto {

    // MARK: - 乱数

    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "システムの乱数生成に失敗しました")
        return data
    }

    // MARK: - 鍵導出

    /// マスターパスワード + salt から 32 バイトの鍵を作る。
    /// わざと重い処理（60万回反復）。総当たり攻撃を遅くするのが目的なので、
    /// 1 回あたり 0.3〜1 秒かかるのは仕様通り。
    static func deriveKey(password: String, header: VaultHeader) throws -> SymmetricKey {
        var passwordBytes = Array(password.utf8)
        defer { for i in passwordBytes.indices { passwordBytes[i] = 0 } }

        var derived = Data(count: VaultHeader.keyLength)
        let status = derived.withUnsafeMutableBytes { out -> Int32 in
            header.salt.withUnsafeBytes { salt -> Int32 in
                passwordBytes.withUnsafeBufferPointer { pw -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self),
                        pw.count,
                        salt.bindMemory(to: UInt8.self).baseAddress!,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        header.iterations,
                        out.bindMemory(to: UInt8.self).baseAddress!,
                        out.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultCryptoError.keyDerivationFailed(status) }

        defer { derived.resetBytes(in: 0..<derived.count) }
        return SymmetricKey(data: derived)
    }

    // MARK: - 暗号化 / 復号

    /// ヘッダ + AES-GCM(nonce ‖ 暗号文 ‖ 認証タグ) を 1 本の Data にして返す。
    static func seal(payload: VaultPayload, key: SymmetricKey, header: VaultHeader) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)

        let headerData = header.encoded
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: headerData)
        guard let combined = sealed.combined else { throw VaultCryptoError.malformedFile }
        return headerData + combined
    }

    /// 復号。認証タグが合わなければ CryptoKit が投げるので、
    /// 「パスワード違い」と「ファイル改ざん」は同じ経路で弾かれる。
    static func open(file: Data, key: SymmetricKey, header: VaultHeader) throws -> VaultPayload {
        let body = file.dropFirst(VaultHeader.byteCount)
        guard !body.isEmpty else { throw VaultCryptoError.malformedFile }

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: Data(body))
            plaintext = try AES.GCM.open(box, using: key, authenticating: header.encoded)
        } catch {
            throw VaultCryptoError.wrongPassword
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VaultPayload.self, from: plaintext)
    }
}
