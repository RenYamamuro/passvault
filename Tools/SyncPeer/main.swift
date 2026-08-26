import Foundation
import Network

// 同期の相手役を Mac 側で動かすための道具。
//
// Mac 版アプリの画面を自動で操作する手段がないため、
// 「Mac と iPhone の間で本当に通信できるのか」を確かめるのに使う。
// アプリと同じ SyncCrypto / SyncFraming / SyncMerge を使っているので、
// これが通れば通信路とプロトコルは正しいと言える。
//
//   swiftc -o /tmp/syncpeer Tools/SyncPeer/main.swift \
//     PassVault/Core/{SyncCrypto,SyncMerge,VaultItem,ItemField,ItemCategory}.swift
//   /tmp/syncpeer wait     # 待ち受ける（iPhone 側で「相手を探す」）
//   /tmp/syncpeer find     # 探しに行く（iPhone 側で「この端末で待つ」）

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "wait"
let serviceType = "_passvault._tcp"
let queue = DispatchQueue(label: "syncpeer")

// 相手に渡す中身。同期されたことが一目で分かる名前にしておく。
var probeItem = VaultItem(category: .login)
probeItem.title = "Macから来た項目"
probeItem.fields[0].value = "cli@example.com"
probeItem.fields[1].value = "MacSide-Secret-42!"
let localPayload = VaultPayload(items: [probeItem])

var handshake = SyncHandshake()
var session: SyncSession?
var buffer = Data()
var didSendPayload = false
var peerConfirmed = false
var connection: NWConnection?

func log(_ message: String) {
    print("[syncpeer] \(message)")
    fflush(stdout)
}

func finish(_ code: Int32) -> Never {
    connection?.cancel()
    exit(code)
}

func send(_ envelope: SyncEnvelope) {
    guard let session, let connection else { return }
    do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sealed = try session.seal(try encoder.encode(envelope))
        connection.send(content: SyncFraming.frame(sealed), completion: .contentProcessed { _ in })
    } catch {
        log("送信に失敗: \(error)")
        finish(1)
    }
}

func sendPayloadIfReady() {
    guard peerConfirmed, !didSendPayload else { return }
    didSendPayload = true
    log("保管庫を送ります（1 件）")
    send(SyncEnvelope(kind: .payload,
                      message: SyncMessage(deviceName: "Mac (CLI)", payload: localPayload)))
}

func handle(_ frame: Data) {
    // 最初の 1 通は相手の公開鍵
    guard let established = session else {
        do {
            let newSession = try handshake.session(withPeerPublicKey: frame)
            session = newSession
            log("鍵交換が成立しました")
            log("確認コード: \(newSession.formattedVerificationCode)  ← iPhone の画面と見比べる")
            // 検証用の道具なので、コードを表示したうえで自動的に承認する
            send(SyncEnvelope(kind: .confirm))
            sendPayloadIfReady()
        } catch {
            log("鍵交換に失敗: \(error)")
            finish(1)
        }
        return
    }

    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SyncEnvelope.self, from: try established.open(frame))
        switch envelope.kind {
        case .confirm:
            log("相手が承認しました")
            peerConfirmed = true
            sendPayloadIfReady()
        case .payload:
            guard let message = envelope.message else { return }
            let result = SyncMerge.merge(local: localPayload, remote: message.payload)
            log("「\(message.deviceName)」から \(message.payload.items.count) 件を受信")
            for item in message.payload.items.sorted(by: { $0.displayTitle < $1.displayTitle }) {
                let otp = item.hasOneTimePassword ? " [ワンタイムパスワードあり]" : ""
                log("  ・\(item.displayTitle)\(otp)")
            }
            log("統合結果: \(result.payload.items.count) 件（\(result.summary.description)）")
            log("成功")
            // 相手が受け取り終えるまで少し待つ
            queue.asyncAfter(deadline: .now() + 2) { finish(0) }
        }
    } catch {
        log("受信データを扱えませんでした: \(error)")
        finish(1)
    }
}

func receiveLoop() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if let error {
            log("受信エラー: \(error)")
            finish(1)
        }
        if let data, !data.isEmpty {
            buffer.append(data)
            do {
                while let frame = try SyncFraming.nextFrame(from: &buffer) { handle(frame) }
            } catch {
                log("フレームが壊れています: \(error)")
                finish(1)
            }
        }
        if isComplete {
            log("相手が接続を閉じました")
            finish(didSendPayload ? 0 : 1)
        }
        receiveLoop()
    }
}

func adopt(_ newConnection: NWConnection) {
    guard connection == nil else {
        newConnection.cancel()
        return
    }
    connection = newConnection
    newConnection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            log("接続しました")
            newConnection.send(content: SyncFraming.frame(handshake.publicKeyData),
                               completion: .contentProcessed { _ in })
            receiveLoop()
        case .failed(let error):
            log("接続に失敗: \(error)")
            finish(1)
        default:
            break
        }
    }
    newConnection.start(queue: queue)
}

let parameters = NWParameters.tcp
parameters.includePeerToPeer = true

switch mode {
case "wait":
    do {
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: "Mac (CLI)", type: serviceType)
        listener.newConnectionHandler = { adopt($0) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("「Mac (CLI)」として待ち受けています。iPhone 側で「相手を探す」を選んでください。")
            case .failed(let error):
                log("待ち受けに失敗: \(error)")
                finish(1)
            default: break
            }
        }
        listener.start(queue: queue)
    } catch {
        log("待ち受けを開始できません: \(error)")
        finish(1)
    }

case "find":
    let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
    browser.browseResultsChangedHandler = { results, _ in
        guard connection == nil, let first = results.first else { return }
        if case .service(let name, _, _, _) = first.endpoint {
            log("「\(name)」を見つけました。接続します。")
        }
        browser.cancel()
        adopt(NWConnection(to: first.endpoint, using: parameters))
    }
    browser.stateUpdateHandler = { state in
        if case .failed(let error) = state {
            log("検索に失敗: \(error)")
            finish(1)
        }
    }
    browser.start(queue: queue)
    log("待っている端末を探しています…")

default:
    log("使い方: syncpeer wait|find")
    exit(2)
}

// 相手が来ないまま放置されないよう、上限を決めておく。
// 画面側で確認コードを見比べて承認するまで人手の時間がかかるので、長めにとる。
let timeoutSeconds = 600.0
queue.asyncAfter(deadline: .now() + timeoutSeconds) {
    log("時間切れ（\(Int(timeoutSeconds)) 秒）")
    finish(1)
}

RunLoop.main.run()
