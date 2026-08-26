import Combine
import CryptoKit
import Foundation

/// サイドバーで選べる絞り込み
enum SidebarSelection: Hashable {
    case all
    case favorites
    case category(ItemCategory)
    case tag(String)
    case watchtower
    case trash

    var title: String {
        switch self {
        case .all: return "すべて"
        case .favorites: return "お気に入り"
        case .category(let category): return category.displayName
        case .tag(let name): return name
        case .watchtower: return "Watchtower"
        case .trash: return "ゴミ箱"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .category(let category): return category.symbol
        case .tag: return "tag"
        case .watchtower: return "shield.lefthalf.filled"
        case .trash: return "trash"
        }
    }
}

/// アプリ全体の状態を持つ中心。
/// 復号済みの鍵とアイテムはこのオブジェクトのメモリ上にしか存在せず、
/// ロックすると破棄される。
@MainActor
final class VaultStore: ObservableObject {

    enum Status: Equatable {
        case noVault
        case locked
        case unlocked
    }

    @Published private(set) var status: Status = .noVault
    @Published private(set) var items: [VaultItem] = []
    @Published private(set) var findings: [WatchtowerFinding] = []
    /// 完全削除した項目の墓標。同期時に「消した」ことを相手へ伝えるために持つ。
    private(set) var deletions: [Deletion] = []

    @Published var autoLockMinutes: Int {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: Self.autoLockKey) }
    }

    private static let autoLockKey = "PassVault.autoLockMinutes"

    private var key: SymmetricKey?
    private var header: VaultHeader?
    private var lastActivity = Date()
    private var idleTimer: Timer?
    /// 0 より大きい間は自動ロックしない
    private var activityHolds = 0

    init() {
        autoLockMinutes = UserDefaults.standard.object(forKey: Self.autoLockKey) as? Int ?? 5
        status = VaultFile.exists ? .locked : .noVault
        startIdleTimer()
    }

    var biometricsEnabled: Bool { BiometricKeyStore.isEnabled && BiometricKeyStore.isAvailable }

    // MARK: - 一覧の絞り込み

    var activeItems: [VaultItem] { items.filter { !$0.isTrashed } }
    var trashedItems: [VaultItem] { items.filter(\.isTrashed) }

    var tags: [String] {
        let all = Set(activeItems.flatMap(\.tags)).filter { !$0.isEmpty }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func count(for selection: SidebarSelection) -> Int {
        items(for: selection, search: "").count
    }

    func items(for selection: SidebarSelection, search: String) -> [VaultItem] {
        let base: [VaultItem]
        switch selection {
        case .all:
            base = activeItems
        case .favorites:
            base = activeItems.filter(\.isFavorite)
        case .category(let category):
            base = activeItems.filter { $0.category == category }
        case .tag(let name):
            base = activeItems.filter { $0.tags.contains(name) }
        case .watchtower:
            let flagged = Set(findings.map(\.itemID))
            base = activeItems.filter { flagged.contains($0.id) }
        case .trash:
            base = trashedItems
        }
        return base
            .filter { $0.matches(search) }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    func findings(for itemID: UUID) -> [WatchtowerFinding] {
        findings.filter { $0.itemID == itemID }
    }

    func item(withID id: UUID?) -> VaultItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - 保管庫の作成 / 解錠

    func createVault(masterPassword: String) async throws {
        let newHeader = VaultHeader.makeNew()
        let derived = try await Self.deriveOffMainThread(password: masterPassword, header: newHeader)

        let file = try VaultCrypto.seal(payload: VaultPayload(), key: derived, header: newHeader)
        try VaultFile.write(file)

        key = derived
        header = newHeader
        items = []
        deletions = []
        refreshFindings()
        status = .unlocked
        noteActivity()
    }

    func unlock(masterPassword: String) async throws {
        let file = try VaultFile.read()
        let fileHeader = try VaultHeader.decode(from: file)
        let derived = try await Self.deriveOffMainThread(password: masterPassword, header: fileHeader)
        try adopt(file: file, header: fileHeader, key: derived)
    }

    func unlockWithBiometrics() async throws {
        let derived = try await BiometricKeyStore.loadKey(reason: "保管庫のロックを解除します")
        let file = try VaultFile.read()
        let fileHeader = try VaultHeader.decode(from: file)
        try adopt(file: file, header: fileHeader, key: derived)
    }

    private func adopt(file: Data, header fileHeader: VaultHeader, key derived: SymmetricKey) throws {
        let payload = try VaultCrypto.open(file: file, key: derived, header: fileHeader)
        key = derived
        header = fileHeader
        items = payload.items
        deletions = payload.deletions
        refreshFindings()
        status = .unlocked
        noteActivity()

        // 古い形式の保管庫を読んだ場合はここで現行形式に書き戻しておく
        if payload.schemaVersion < VaultPayload.currentSchemaVersion { try? save() }
    }

    func lock() {
        key = nil
        header = nil
        items = []
        deletions = []
        findings = []
        if VaultFile.exists { status = .locked }
    }

    // MARK: - 生体認証

    func enableBiometrics() throws {
        guard let key else { return }
        try BiometricKeyStore.store(key: key)
        objectWillChange.send()
    }

    func disableBiometrics() {
        BiometricKeyStore.remove()
        objectWillChange.send()
    }

    // MARK: - アイテム操作

    func upsert(_ item: VaultItem) throws {
        var updated = item
        updated.updatedAt = Date()

        if let index = items.firstIndex(where: { $0.id == item.id }) {
            // パスワードが変わったら、古いものを履歴に残す。
            // 「変更したつもりが反映されていない」事故と、
            // 「前のパスワードが必要になった」場面の両方に効く。
            let previous = items[index].primaryPassword
            if let previous, !previous.isEmpty, previous != updated.primaryPassword {
                updated.passwordHistory.insert(PasswordChange(value: previous), at: 0)
                updated.passwordHistory = Array(updated.passwordHistory.prefix(20))
            }
            items[index] = updated
        } else {
            items.append(updated)
        }
        try save()
    }

    func toggleFavorite(_ item: VaultItem) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle()
        try save()
    }

    /// ゴミ箱へ移動（すぐには消さない）
    func moveToTrash(_ item: VaultItem) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].trashedAt = Date()
        try save()
    }

    func restore(_ item: VaultItem) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].trashedAt = nil
        try save()
    }

    func deletePermanently(_ item: VaultItem) throws {
        items.removeAll { $0.id == item.id }
        deletions.append(Deletion(id: item.id))
        try save()
    }

    func emptyTrash() throws {
        let removed = items.filter(\.isTrashed)
        items.removeAll(where: \.isTrashed)
        deletions.append(contentsOf: removed.map { Deletion(id: $0.id) })
        try save()
    }

    // MARK: - 同期

    /// いま持っている中身を、相手へ送れる形で取り出す
    func snapshotForSync() -> VaultPayload {
        VaultPayload(items: items, deletions: deletions)
    }

    /// 相手から受け取った中身を取り込む
    @discardableResult
    func applySync(remote: VaultPayload) throws -> SyncMerge.Summary {
        let result = SyncMerge.merge(local: snapshotForSync(), remote: remote)
        items = result.payload.items
        deletions = result.payload.deletions
        try save()
        return result.summary
    }

    // MARK: - マスターパスワード変更

    func changeMasterPassword(current: String, new: String) async throws {
        guard let header else { throw VaultCryptoError.malformedFile }

        let file = try VaultFile.read()
        let currentKey = try await Self.deriveOffMainThread(password: current, header: header)
        _ = try VaultCrypto.open(file: file, key: currentKey, header: header)

        let newHeader = VaultHeader.makeNew()
        let newKey = try await Self.deriveOffMainThread(password: new, header: newHeader)
        let payload = VaultPayload(items: items, deletions: deletions)
        let sealed = try VaultCrypto.seal(payload: payload, key: newKey, header: newHeader)
        try VaultFile.write(sealed)

        key = newKey
        self.header = newHeader

        if BiometricKeyStore.isEnabled {
            try? BiometricKeyStore.store(key: newKey)
        }
        noteActivity()
    }

    // MARK: - 保存

    private func save() throws {
        guard let key, let header else { return }
        let payload = VaultPayload(items: items, deletions: deletions)
        let sealed = try VaultCrypto.seal(payload: payload, key: key, header: header)
        try VaultFile.write(sealed)
        refreshFindings()
        noteActivity()
    }

    private func refreshFindings() {
        findings = Watchtower.audit(items)
    }

    // MARK: - 自動ロック

    func noteActivity() { lastActivity = Date() }

    /// 同期のように「画面を触っていないが進行中」の処理の間、自動ロックを止める。
    /// これがないと、相手を待っている最中に施錠されて処理ごと中断されてしまう。
    func beginActivityHold() {
        activityHolds += 1
        noteActivity()
    }

    func endActivityHold() {
        activityHolds = max(0, activityHolds - 1)
        noteActivity()
    }

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.lockIfIdle() }
        }
    }

    private func lockIfIdle() {
        guard status == .unlocked, autoLockMinutes > 0, activityHolds == 0 else { return }
        if Date().timeIntervalSince(lastActivity) >= Double(autoLockMinutes) * 60 {
            lock()
        }
    }

    private static func deriveOffMainThread(password: String, header: VaultHeader) async throws -> SymmetricKey {
        try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.deriveKey(password: password, header: header)
        }.value
    }
}
