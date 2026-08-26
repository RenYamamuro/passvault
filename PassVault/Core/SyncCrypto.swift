import CryptoKit
import Foundation

enum SyncCryptoError: LocalizedError {
    case badPeerKey
    case badFrame
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .badPeerKey: return "相手の鍵を読み取れませんでした。"
        case .badFrame: return "受信データの形式が不正です。"
        case .decryptionFailed: return "受信データを復号できませんでした。改ざんされた可能性があります。"
        }
    }
}

/// 同期のたびに作り捨てる鍵ペア。
/// 使い回さないので、あとから鍵が漏れても過去の通信は解けない。
struct SyncHandshake {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKeyData: Data

    init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        publicKeyData = privateKey.publicKey.rawRepresentation
    }

    func session(withPeerPublicKey peerKeyData: Data) throws -> SyncSession {
        guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData) else {
            throw SyncCryptoError.badPeerKey
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)

        // 両端末で同じ値になるよう、2 つの公開鍵を辞書順に並べて塩にする。
        // 公開鍵を材料に含めることが肝心で、これによって
        // 割り込まれた場合に両端末の確認コードが必ず食い違う。
        let salt = [publicKeyData, peerKeyData]
            .sorted { $0.lexicographicallyPrecedes($1) }
            .reduce(Data(), +)

        let sessionKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("PassVault sync v1 session".utf8),
            outputByteCount: 32
        )
        let verificationMaterial = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("PassVault sync v1 verification".utf8),
            outputByteCount: 4
        )

        return SyncSession(key: sessionKey, verificationMaterial: verificationMaterial)
    }
}

struct SyncSession {
    let key: SymmetricKey
    private let verificationMaterial: SymmetricKey

    init(key: SymmetricKey, verificationMaterial: SymmetricKey) {
        self.key = key
        self.verificationMaterial = verificationMaterial
    }

    /// 両端末の画面に出す 6 桁。利用者がこれを見比べることで、
    /// 途中に誰も割り込んでいないことを確かめられる。
    var verificationCode: String {
        let bytes = verificationMaterial.withUnsafeBytes { Array($0) }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    /// 表示用に 3 桁ずつ区切る
    var formattedVerificationCode: String {
        let code = verificationCode
        let middle = code.index(code.startIndex, offsetBy: 3)
        return code[code.startIndex..<middle] + " " + code[middle...]
    }

    func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw SyncCryptoError.badFrame }
        return combined
    }

    func open(_ ciphertext: Data) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext),
              let plaintext = try? AES.GCM.open(box, using: key)
        else { throw SyncCryptoError.decryptionFailed }
        return plaintext
    }
}

// MARK: - 通信に流すもの

/// 同期でやりとりする中身。
/// 保管庫の平文がそのまま乗るので、必ず SyncSession で包んでから送ること。
struct SyncMessage: Codable {
    var deviceName: String
    var payload: VaultPayload
}

/// 1 通の中身。承認の合図か、保管庫そのものか。
struct SyncEnvelope: Codable {
    enum Kind: String, Codable {
        case confirm
        case payload
    }
    var kind: Kind
    var message: SyncMessage?
}

/// TCP はバイトの流れでしかないので、どこまでが 1 通かを自分で決める必要がある。
/// 先頭 4 バイトに長さを書く方式にした。
enum SyncFraming {
    /// 1 通あたりの上限。これを超える長さが来たら不正とみなす。
    static let maximumFrameSize = 32 * 1024 * 1024

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = withUnsafeBytes(of: &length) { Data($0) }
        out.append(payload)
        return out
    }

    /// バッファの先頭から 1 通を取り出す。
    /// まだ足りなければ nil を返し、バッファはそのままにする。
    static func nextFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }

        // Data は切り出し方によって startIndex が 0 とは限らないので、
        // 添字は必ず startIndex を起点に計算する。
        let start = buffer.startIndex
        let length = (0..<4).reduce(Int(0)) { ($0 << 8) | Int(buffer[start + $1]) }
        guard length <= maximumFrameSize else { throw SyncCryptoError.badFrame }
        guard buffer.count >= 4 + length else { return nil }

        let bodyStart = start + 4
        let frame = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeSubrange(start..<(bodyStart + length))
        return frame
    }
}
