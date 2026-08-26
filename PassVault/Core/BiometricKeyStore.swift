import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Touch ID / Face ID でのロック解除。
///
/// マスターパスワードそのものではなく「導出済みの鍵」をキーチェーンに預ける。
/// アクセス制御に `.biometryCurrentSet` を付けているので、指紋や顔を
/// 追加・変更すると OS 側でこの項目が自動的に無効化される。
enum BiometricKeyStore {

    private static let service = "com.yamamuroren.PassVault.masterkey"
    private static let account = "default"
    private static let enabledFlagKey = "PassVault.biometricsEnabled"

    enum BiometricError: LocalizedError {
        case unavailable
        case accessControlFailed
        case keychainFailed(OSStatus)
        case notSigned
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "この端末では生体認証が使えません。"
            case .accessControlFailed:
                return "生体認証つきの保存領域を作成できませんでした。"
            case .cancelled:
                return "生体認証がキャンセルされました。"
            case .notSigned:
                // ad-hoc 署名（署名なしのローカルビルド）では、生体認証つきの
                // キーチェーンに書き込む権限が OS から与えられない。実測で確認済み。
                return """
                    このビルドには生体認証つきキーチェーンを使う権限がありません。
                    Xcode で PassVault ターゲットを選び、Signing & Capabilities タブで \
                    「Automatically manage signing」にチェックを入れ、Team に自分の Apple ID を \
                    選んでからビルドし直してください。（無料の Apple ID で構いません）
                    """
            case .keychainFailed(let status):
                return "キーチェーン操作に失敗しました（code \(status)）。"
            }
        }
    }

    // MARK: - 利用可否

    static var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var displayName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "生体認証"
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledFlagKey)
    }

    // MARK: - 保存 / 取得

    static func store(key: SymmetricKey) throws {
        guard isAvailable else { throw BiometricError.unavailable }

        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &cfError
        ) else {
            throw BiometricError.accessControlFailed
        }

        remove()

        let keyData = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: access,
            // macOS は既定だと旧来のファイルキーチェーンを使い、
            // 生体認証つきのアクセス制御が効かない。明示的に新しい方を指定する。
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw BiometricError.notSigned }
        guard status == errSecSuccess else { throw BiometricError.keychainFailed(status) }

        UserDefaults.standard.set(true, forKey: enabledFlagKey)
    }

    /// 生体認証プロンプトを出して鍵を取り出す。
    /// キーチェーンの認証待ちで呼び出しスレッドが止まるので、必ず非同期で呼ぶこと。
    static func loadKey(reason: String) async throws -> SymmetricKey {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason

                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationContext as String: context,
                    kSecUseDataProtectionKeychain as String: true,
                ]

                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)

                switch status {
                case errSecSuccess:
                    guard let data = item as? Data, data.count == VaultHeader.keyLength else {
                        continuation.resume(throwing: BiometricError.keychainFailed(status))
                        return
                    }
                    continuation.resume(returning: SymmetricKey(data: data))
                case errSecUserCanceled, errSecAuthFailed:
                    continuation.resume(throwing: BiometricError.cancelled)
                case errSecMissingEntitlement:
                    continuation.resume(throwing: BiometricError.notSigned)
                default:
                    continuation.resume(throwing: BiometricError.keychainFailed(status))
                }
            }
        }
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: enabledFlagKey)
    }
}
