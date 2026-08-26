import Combine
import Foundation
import Network

#if os(iOS)
import UIKit
#endif

/// 同じネットワーク上のもう 1 台と保管庫を突き合わせる。
///
/// 手順:
/// 1. 片方が「待ち受ける」、もう片方が相手を選んで接続する
/// 2. 使い捨ての鍵を交換し、両画面に 6 桁の確認コードを出す
/// 3. 利用者が両画面のコードが同じことを確かめて、双方で承認する
/// 4. 承認が揃ってから、暗号化した保管庫の中身を送り合って統合する
///
/// 3 を省くと、同じネットワークにいる第三者に割り込まれても気づけない。
@MainActor
final class SyncService: ObservableObject {

    static let serviceType = "_passvault._tcp"

    enum Phase: Equatable {
        case idle
        case waitingForPeer
        case searching
        case connecting
        case verifying(code: String)
        case exchanging
        case finished(summary: String)
        case failed(String)
    }

    struct Peer: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peers: [Peer] = []
    /// 相手が承認済みかどうか（自分だけ押しても進まないことを画面で示すため）
    @Published private(set) var peerConfirmed = false

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "PassVault.sync")

    private var handshake: SyncHandshake?
    private var session: SyncSession?
    private var buffer = Data()
    private var localConfirmed = false
    private var didSendPayload = false
    private var didApplyPayload = false

    private unowned let store: VaultStore

    init(store: VaultStore) {
        self.store = store
    }

    var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    var verificationCode: String? {
        if case .verifying(let code) = phase { return code }
        return nil
    }

    // MARK: - 開始と終了

    /// 相手からの接続を待つ側
    func startWaiting() {
        stop()
        let handshake = SyncHandshake()
        self.handshake = handshake

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: deviceName, type: Self.serviceType)

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.adopt(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { @MainActor in self?.fail("待ち受けに失敗しました: \(error.localizedDescription)") }
            }
            listener.start(queue: queue)
            self.listener = listener
            phase = .waitingForPeer
        } catch {
            fail("待ち受けを開始できません: \(error.localizedDescription)")
        }
    }

    /// 待っている相手を探す側
    func startSearching() {
        stop()
        handshake = SyncHandshake()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil), using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.peers = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Peer(id: name, name: name, endpoint: result.endpoint)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor in self?.fail("検索に失敗しました: \(error.localizedDescription)") }
        }
        browser.start(queue: queue)
        self.browser = browser
        phase = .searching
    }

    func connect(to peer: Peer) {
        browser?.cancel()
        browser = nil
        phase = .connecting

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        adopt(NWConnection(to: peer.endpoint, using: parameters))
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
        handshake = nil
        session = nil
        buffer = Data()
        localConfirmed = false
        peerConfirmed = false
        didSendPayload = false
        didApplyPayload = false
        peers = []
        phase = .idle
    }

    /// 利用者が「コードは一致している」と承認したとき
    func confirmCode() {
        guard case .verifying = phase, let session, !localConfirmed else { return }
        localConfirmed = true
        send(SyncEnvelope(kind: .confirm), with: session)
        sendPayloadIfReady()
    }

    // MARK: - 接続の扱い

    private func adopt(_ connection: NWConnection) {
        // 待ち受け側が同時に複数つながれると話が混ざるので、最初の 1 本だけ受ける
        guard self.connection == nil else {
            connection.cancel()
            return
        }
        self.connection = connection
        listener?.cancel()
        listener = nil

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.sendPublicKey()
                    self?.receiveLoop()
                case .failed(let error):
                    self?.fail("接続が切れました: \(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func sendPublicKey() {
        guard let handshake, let connection else { return }
        // 鍵交換の 1 通目だけは、まだ共有鍵が無いので平文で送る。
        // 公開鍵なので見られても問題はない。
        connection.send(
            content: SyncFraming.frame(handshake.publicKeyData),
            completion: .contentProcessed { _ in }
        )
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.fail("受信に失敗しました: \(error.localizedDescription)")
                    return
                }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
                if isComplete {
                    // 相手が閉じた。取り込みが済んでいれば正常終了。
                    if !self.didApplyPayload, case .exchanging = self.phase {
                        self.fail("同期の途中で接続が終了しました。")
                    }
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func drainBuffer() {
        do {
            while let frame = try SyncFraming.nextFrame(from: &buffer) {
                try handle(frame)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handle(_ frame: Data) throws {
        // まだ鍵交換が済んでいなければ、この 1 通目が相手の公開鍵
        guard let session else {
            guard let handshake else { return }
            let established = try handshake.session(withPeerPublicKey: frame)
            session = established
            phase = .verifying(code: established.formattedVerificationCode)
            return
        }

        let envelope = try JSONDecoder.sync.decode(
            SyncEnvelope.self, from: try session.open(frame)
        )
        switch envelope.kind {
        case .confirm:
            peerConfirmed = true
            sendPayloadIfReady()
        case .payload:
            guard let message = envelope.message else { throw SyncCryptoError.badFrame }
            try apply(message)
        }
    }

    /// 自分と相手の両方が承認して初めて中身を送る
    private func sendPayloadIfReady() {
        guard localConfirmed, peerConfirmed, !didSendPayload, let session else { return }
        didSendPayload = true
        phase = .exchanging
        let message = SyncMessage(deviceName: deviceName, payload: store.snapshotForSync())
        send(SyncEnvelope(kind: .payload, message: message), with: session)
    }

    private func apply(_ message: SyncMessage) throws {
        guard !didApplyPayload else { return }
        didApplyPayload = true

        let summary = try store.applySync(remote: message.payload)
        phase = .finished(summary: "\(message.deviceName) と同期しました。\(summary.description)")

        // 送信し終えるだけの猶予を置いてから閉じる
        let connection = self.connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connection?.cancel() }
    }

    private func send(_ envelope: SyncEnvelope, with session: SyncSession) {
        guard let connection else { return }
        do {
            let sealed = try session.seal(try JSONEncoder.sync.encode(envelope))
            connection.send(
                content: SyncFraming.frame(sealed),
                completion: .contentProcessed { _ in }
            )
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        // すでに終わっているなら、切断のような後続のエラーで上書きしない
        if case .finished = phase { return }
        phase = .failed(message)
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
    }
}

extension JSONEncoder {
    static var sync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var sync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
