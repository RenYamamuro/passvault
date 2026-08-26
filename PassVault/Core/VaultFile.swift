import Foundation

/// 保管庫ファイルの置き場所と、安全な読み書き。
enum VaultFile {

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PassVault", isDirectory: true)
    }

    static var vaultURL: URL {
        directoryURL.appendingPathComponent("vault.pvlt")
    }

    static var backupURL: URL {
        directoryURL.appendingPathComponent("vault.pvlt.bak")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    static func read() throws -> Data {
        try Data(contentsOf: vaultURL)
    }

    /// 上書き前に必ず 1 世代バックアップを取る。
    /// 書き込み中のクラッシュで保管庫を丸ごと失うのが一番怖いので、
    /// ここは多少冗長でも安全側に倒す。
    static func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if exists {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: vaultURL, to: backupURL)
        }

        try data.write(to: vaultURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }

    static func deleteEverything() throws {
        try? FileManager.default.removeItem(at: vaultURL)
        try? FileManager.default.removeItem(at: backupURL)
    }
}
