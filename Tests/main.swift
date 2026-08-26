import CryptoKit
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}
func section(_ title: String) { print("\n── \(title) ──") }

// ============================================================
section("保管庫の暗号化")
// ============================================================

let header = VaultHeader.makeNew()
check("salt が 32 バイト", header.salt.count == 32)
check("ヘッダのエンコード長が 44 バイト", header.encoded.count == VaultHeader.byteCount)

let password = "紫の亀が図書館で走る-2026"
let start = Date()
let key = try VaultCrypto.deriveKey(password: password, header: header)
let kdfSeconds = Date().timeIntervalSince(start)
print("     鍵導出にかかった時間: \(String(format: "%.3f", kdfSeconds)) 秒 (\(header.iterations) 回)")
check("鍵導出が 0.05 秒以上（総当たり耐性として意味のある重さ）", kdfSeconds > 0.05)

var login = VaultItem(category: .login)
login.title = "GitHub"
login.fields[0].value = "yamamuro20030926@gmail.com"
login.fields[1].value = "S3cr3t!-値-🔐"
login.fields[2].value = "github.com"
login.notes = "改行を含む\nメモ"
login.tags = ["仕事"]
login.oneTimePasswordSecret = "JBSWY3DPEHPK3PXP"

var card = VaultItem(category: .creditCard)
card.title = "楽天カード"
card.fields[1].value = "4111111111111111"
card.fields[3].value = "123"

let file = try VaultCrypto.seal(payload: VaultPayload(items: [login, card]), key: key, header: header)

let decodedHeader = try VaultHeader.decode(from: file)
check("ヘッダを読み戻せる", decodedHeader == header)

let reopened = try VaultCrypto.open(file: file, key: key, header: decodedHeader)
check("アイテム件数が一致", reopened.items.count == 2)
check("パスワードが完全一致（絵文字・日本語込み）", reopened.items[0].primaryPassword == "S3cr3t!-値-🔐")
check("メモの改行が保持される", reopened.items[0].notes == "改行を含む\nメモ")
check("種別が保持される", reopened.items[1].category == .creditCard)
check("タグが保持される", reopened.items[0].tags == ["仕事"])

check("ファイル内にパスワードの平文が現れない", file.range(of: Data("S3cr3t".utf8)) == nil)
check("ファイル内にカード番号の平文が現れない", file.range(of: Data("4111111111111111".utf8)) == nil)
check("ファイル内にTOTPシークレットの平文が現れない", file.range(of: Data("JBSWY3DPEHPK3PXP".utf8)) == nil)

do {
    _ = try VaultCrypto.open(
        file: file,
        key: try VaultCrypto.deriveKey(password: password + "x", header: decodedHeader),
        header: decodedHeader
    )
    check("間違ったパスワードを拒否", false)
} catch { check("間違ったパスワードを拒否", true) }

var tampered = file
tampered[VaultHeader.byteCount + 20] ^= 0x01
do {
    _ = try VaultCrypto.open(file: tampered, key: key, header: decodedHeader)
    check("暗号文の 1 ビット改ざんを検知", false)
} catch { check("暗号文の 1 ビット改ざんを検知", true) }

var downgraded = file
downgraded[8] = 0; downgraded[9] = 0; downgraded[10] = 0; downgraded[11] = 1
do {
    let evilHeader = try VaultHeader.decode(from: downgraded)
    let weakKey = try VaultCrypto.deriveKey(password: password, header: evilHeader)
    _ = try VaultCrypto.open(file: downgraded, key: weakKey, header: evilHeader)
    check("ヘッダ改ざん（反復回数の切り下げ）を検知", false)
} catch { check("ヘッダ改ざん（反復回数の切り下げ）を検知", true) }

do {
    _ = try VaultHeader.decode(from: Data("NOT A VAULT FILE".utf8))
    check("非対応ファイルを拒否", false)
} catch { check("非対応ファイルを拒否", true) }

check(
    "同じ内容でも暗号文が毎回変わる（nonce 再利用なし）",
    try VaultCrypto.seal(payload: VaultPayload(items: [login]), key: key, header: header) != file
)
check("新しい保管庫ごとに salt が変わる", VaultHeader.makeNew().salt != VaultHeader.makeNew().salt)

// ============================================================
section("v1 保管庫からの移行")
// ============================================================

let legacyJSON = """
{"entries":[{"id":"11111111-1111-1111-1111-111111111111","title":"旧アプリの項目",\
"username":"old@example.com","password":"oldpass","url":"example.com",\
"notes":"メモ","folder":"プライベート",\
"createdAt":"2025-03-01T00:00:00Z","updatedAt":"2025-03-02T00:00:00Z"}]}
"""
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601
let migrated = try legacyDecoder.decode(VaultPayload.self, from: Data(legacyJSON.utf8))
check("v1 の保管庫を読める", migrated.items.count == 1)
check("v1 のタイトルが残る", migrated.items[0].title == "旧アプリの項目")
check("v1 のパスワードが残る", migrated.items[0].primaryPassword == "oldpass")
check("v1 のユーザー名が残る", migrated.items[0].primaryUsername == "old@example.com")
check("v1 のフォルダがタグになる", migrated.items[0].tags == ["プライベート"])
check("v1 の項目はログイン種別になる", migrated.items[0].category == .login)
check("v1 の ID が保たれる（重複しない）",
      migrated.items[0].id.uuidString == "11111111-1111-1111-1111-111111111111")
check("v1 から読んだことが記録され、書き戻しが走る", migrated.schemaVersion == 1)

// 書き戻したあとは現行スキーマとして読める
let reEncoder = JSONEncoder()
reEncoder.dateEncodingStrategy = .iso8601
let rewritten = try legacyDecoder.decode(VaultPayload.self, from: reEncoder.encode(migrated))
check("書き戻したあとは現行スキーマ（v\(VaultPayload.currentSchemaVersion)）になる",
      rewritten.schemaVersion == VaultPayload.currentSchemaVersion)
check("書き戻しても中身は変わらない", rewritten.items[0].primaryPassword == "oldpass")
check("古い保管庫には墓標が無い状態で始まる", rewritten.deletions.isEmpty)

// ============================================================
section("ワンタイムパスワード（RFC 6238 公式テストベクタ）")
// ============================================================

// RFC 6238 Appendix B のシークレット
let seed1 = Data("12345678901234567890".utf8)
let seed256 = Data("12345678901234567890123456789012".utf8)
let seed512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

let vectors: [(time: TimeInterval, sha1: String, sha256: String, sha512: String)] = [
    (59, "94287082", "46119246", "90693936"),
    (1_111_111_109, "07081804", "68084774", "25091201"),
    (1_111_111_111, "14050471", "67062674", "99943326"),
    (1_234_567_890, "89005924", "91819424", "93441116"),
    (2_000_000_000, "69279037", "90698825", "38618901"),
    (20_000_000_000, "65353130", "77737706", "47863826"),
]

var totpOK = true
for vector in vectors {
    let date = Date(timeIntervalSince1970: vector.time)
    let a = OneTimePassword(secret: seed1, digits: 8, algorithm: .sha1).code(at: date)
    let b = OneTimePassword(secret: seed256, digits: 8, algorithm: .sha256).code(at: date)
    let c = OneTimePassword(secret: seed512, digits: 8, algorithm: .sha512).code(at: date)
    if a != vector.sha1 || b != vector.sha256 || c != vector.sha512 {
        totpOK = false
        print("     ずれ t=\(Int(vector.time)): SHA1 \(a)/\(vector.sha1)  SHA256 \(b)/\(vector.sha256)  SHA512 \(c)/\(vector.sha512)")
    }
}
check("RFC 6238 のテストベクタ 18 件すべてに一致（SHA1/256/512）", totpOK)

check("Base32 の往復", Base32.decode(Base32.encode(seed1)) == seed1)
check("Base32 は小文字・空白・ハイフンを許容",
      Base32.decode("jbsw y3dp-ehpk3pxp") == Base32.decode("JBSWY3DPEHPK3PXP"))
check("Base32 に無い文字は拒否", Base32.decode("JBSW1889!!") == nil)

let uri = "otpauth://totp/GitHub:yamamuro?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=6&period=30&algorithm=SHA1"
let parsed = OneTimePassword.parse(uri)
check("otpauth:// URI を解釈できる", parsed != nil)
check("URI から発行元を読める", parsed?.issuer == "GitHub")
check("URI からアカウント名を読める", parsed?.account == "yamamuro")
check("URI の桁数・周期を読める", parsed?.digits == 6 && parsed?.period == 30)
check("素の Base32 も受け付ける", OneTimePassword.parse("JBSWY3DPEHPK3PXP") != nil)
check("でたらめな文字列は弾く", OneTimePassword.parse("これはシークレットではない") == nil)
check("空文字は弾く", OneTimePassword.parse("   ") == nil)

if let otp = OneTimePassword.parse("JBSWY3DPEHPK3PXP") {
    // 枠の境目は 30 の倍数。1_700_000_010 がちょうど境目にあたる。
    let windowStart = Date(timeIntervalSince1970: 1_700_000_010)
    check("枠の先頭と末尾で同じコードになる",
          otp.code(at: windowStart) == otp.code(at: windowStart.addingTimeInterval(29)))
    check("枠をまたぐとコードが変わる",
          otp.code(at: windowStart.addingTimeInterval(29))
              != otp.code(at: windowStart.addingTimeInterval(30)))

    // 連続する 10 枠がほぼすべて違う値になる（偶然の一致は 100 万分の 1）
    let windowCodes = (0..<10).map { otp.code(at: Date(timeIntervalSince1970: Double($0) * 30)) }
    check("30 秒ごとに別のコードが出る", Set(windowCodes).count >= 9)

    check("残り秒数が 1...30 に収まる", (1...30).contains(otp.secondsRemaining(at: windowStart)))
    check("枠の先頭では残り 30 秒", otp.secondsRemaining(at: windowStart) == 30)
    check("表示用は 3 桁ずつ区切られる", otp.formattedCode(at: windowStart).count == 7)
}

// ============================================================
section("パスワード生成")
// ============================================================

var options = PasswordOptions()
options.length = 24
let generated = (0..<300).map { _ in PasswordGenerator.generate(options) }
check("指定した長さになる", generated.allSatisfy { $0.count == 24 })
check("300 回生成して重複なし", Set(generated).count == 300)

let ambiguous = Set("0O1lI|`'\"~,.;:")
check("紛らわしい文字が除かれている", generated.allSatisfy { $0.allSatisfy { !ambiguous.contains($0) } })
check(
    "有効にした 4 種類すべてが必ず含まれる",
    generated.allSatisfy { pw in
        pw.contains(where: \.isLowercase) && pw.contains(where: \.isUppercase)
            && pw.contains(where: \.isNumber) && pw.contains { !$0.isLetter && !$0.isNumber }
    }
)

var digitsOnly = PasswordOptions()
digitsOnly.length = 6
digitsOnly.useLowercase = false; digitsOnly.useUppercase = false; digitsOnly.useSymbols = false
digitsOnly.avoidAmbiguous = false
let pins = (0..<2000).map { _ in PasswordGenerator.generate(digitsOnly) }
check("数字だけの設定で数字しか出ない", pins.allSatisfy { $0.allSatisfy(\.isNumber) })

var counts: [Character: Int] = [:]
for pin in pins { for c in pin { counts[c, default: 0] += 1 } }
let expected = Double(pins.count * 6) / 10.0
let maxDeviation = counts.values.map { abs(Double($0) - expected) / expected }.max() ?? 1
check("0-9 すべてが出現", counts.count == 10)
check("0-9 の出現が概ね均等（最大ずれ \(Int(maxDeviation * 100))%）", maxDeviation < 0.10)

// ============================================================
section("パスワード強度の見積もり")
// ============================================================

check("空文字は 0 ビット", PasswordStrength.estimateBits("") == 0)
check("password は弱いと判定", PasswordStrength.level(of: "password") <= .weak)
check("123456 は弱いと判定", PasswordStrength.level(of: "123456") <= .weak)
check("aaaaaaaaaaaaaaaa は繰り返しとして減点される", PasswordStrength.level(of: "aaaaaaaaaaaaaaaa") <= .weak)
check("qwertyuiop は並びとして減点される", PasswordStrength.level(of: "qwertyuiop") <= .weak)
check("生成した 24 文字は強いと判定", PasswordStrength.level(of: generated[0]) >= .good)
check(
    "長いほうが強く出る",
    PasswordStrength.estimateBits("Tr0ub4dor&3xK9pQ") > PasswordStrength.estimateBits("Tr0ub4d")
)
check(
    "同じ長さなら文字種が多いほうが強く出る",
    PasswordStrength.estimateBits("aB3!xY7@qW2#") > PasswordStrength.estimateBits("abcdxyzqwrst")
)

// ============================================================
section("Watchtower")
// ============================================================

func makeLogin(_ title: String, password: String, url: String = "", created: Date = Date()) -> VaultItem {
    var item = VaultItem(category: .login)
    item.title = title
    item.fields[1].value = password
    item.fields[2].value = url
    item.createdAt = created
    return item
}

let strong1 = PasswordGenerator.generate(options)
let strong2 = PasswordGenerator.generate(options)
let now = Date()

let audited = Watchtower.audit([
    makeLogin("A社", password: "sharedPassword!42Xy", url: "https://a.example"),
    makeLogin("B社", password: "sharedPassword!42Xy", url: "https://b.example"),
    makeLogin("弱いところ", password: "password", url: "https://c.example"),
    makeLogin("古いところ", password: strong1, created: now.addingTimeInterval(-400 * 24 * 3600)),
    makeLogin("平文サイト", password: strong2, url: "http://d.example"),
], now: now)

let reused = audited.filter { $0.kind == .reused }
check("使い回しを両方のアイテムで検出", reused.count == 2)
check("使い回しの説明に相手の名前が入る", reused.contains { $0.detail.contains("B社") })
check("弱いパスワードを検出", audited.contains { $0.kind == .weak && $0.itemTitle == "弱いところ" })
check("強いパスワードは弱いと判定されない", !audited.contains { $0.kind == .weak && $0.itemTitle == "平文サイト" })
check("1年以上前のパスワードを検出", audited.contains { $0.kind == .old && $0.itemTitle == "古いところ" })
check("http:// のサイトを検出", audited.contains { $0.kind == .insecureURL && $0.itemTitle == "平文サイト" })
check("https:// のサイトは指摘されない", !audited.contains { $0.kind == .insecureURL && $0.itemTitle == "A社" })
check("深刻な順（使い回しが先頭）に並ぶ", audited.first?.kind == .reused)

let clean = Watchtower.audit([
    makeLogin("問題なし1", password: strong1, url: "https://ok.example"),
    makeLogin("問題なし2", password: strong2, url: "https://ok2.example"),
], now: now)
check("問題のない保管庫では指摘ゼロ", clean.isEmpty)

var trashed = makeLogin("捨てたもの", password: "password")
trashed.trashedAt = now
check("ゴミ箱の中は監査対象外", Watchtower.audit([trashed], now: now).isEmpty)

// ============================================================
section("検索とアイテムの表示")
// ============================================================

check("タイトルで検索できる", login.matches("git"))
check("タグで検索できる", login.matches("仕事"))
check("ユーザー名で検索できる", login.matches("yamamuro"))
check("無関係な語では引っかからない", !login.matches("ぜんぜん違う語"))
check("パスワードの中身は検索対象にしない", !login.matches("S3cr3t"))
check("カード番号の中身も検索対象にしない", !card.matches("4111"))
check("カード番号は下 4 桁だけ一覧に出る", card.subtitle == "•••• 1111")
check("カード番号は 4 桁ごとに区切って表示", card.fields[1].displayValue == "4111 1111 1111 1111")

// ============================================================
section("マスターパスワード変更")
// ============================================================

let newHeader = VaultHeader.makeNew()
let newKey = try VaultCrypto.deriveKey(password: "別の新しいパスワード", header: newHeader)
let resealed = try VaultCrypto.seal(payload: reopened, key: newKey, header: newHeader)
check(
    "変更後も中身が保たれる",
    try VaultCrypto.open(file: resealed, key: newKey, header: newHeader).items[0].primaryPassword
        == "S3cr3t!-値-🔐"
)
do {
    _ = try VaultCrypto.open(file: resealed, key: key, header: newHeader)
    check("変更後に古い鍵では開けない", false)
} catch { check("変更後に古い鍵では開けない", true) }

// ============================================================
section("同期: 鍵交換と確認コード")
// ============================================================

let alice = SyncHandshake()
let bob = SyncHandshake()
let aliceSession = try alice.session(withPeerPublicKey: bob.publicKeyData)
let bobSession = try bob.session(withPeerPublicKey: alice.publicKeyData)

check("両端末が同じセッション鍵にたどり着く",
      aliceSession.key == bobSession.key)
check("両端末の確認コードが一致する",
      aliceSession.verificationCode == bobSession.verificationCode)
check("確認コードは 6 桁", aliceSession.verificationCode.count == 6)
check("確認コードは数字だけ", aliceSession.verificationCode.allSatisfy(\.isNumber))
check("表示用は 3 桁ずつ区切られる", aliceSession.formattedVerificationCode.count == 7)

// 中間者攻撃の再現: 攻撃者が両者との間でそれぞれ別の鍵交換を行う。
// 通信自体は成立してしまうが、確認コードが食い違うので利用者が気づける。
let attacker = SyncHandshake()
let aliceVsAttacker = try alice.session(withPeerPublicKey: attacker.publicKeyData)
let bobVsAttacker = try bob.session(withPeerPublicKey: attacker.publicKeyData)
check("中間者がいると両端末の確認コードが食い違う",
      aliceVsAttacker.verificationCode != bobVsAttacker.verificationCode)
check("中間者は正規のセッション鍵を得られない",
      aliceVsAttacker.key != aliceSession.key)

// 毎回作り捨てなので、同じ相手でも回ごとに別の鍵になる
let aliceAgain = SyncHandshake()
let secondSession = try aliceAgain.session(withPeerPublicKey: bob.publicKeyData)
check("同期のたびに別のセッション鍵になる", secondSession.key != aliceSession.key)

check("でたらめな公開鍵は拒否される",
      (try? alice.session(withPeerPublicKey: Data(repeating: 0xAB, count: 10))) == nil)

// ============================================================
section("同期: 通信内容の保護")
// ============================================================

let syncMessage = SyncMessage(deviceName: "Mac", payload: VaultPayload(items: [login, card]))
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

let plaintextMessage = try encoder.encode(syncMessage)
let sealedMessage = try aliceSession.seal(plaintextMessage)

check("送信データにパスワードの平文が現れない",
      sealedMessage.range(of: Data("S3cr3t".utf8)) == nil)
check("送信データにカード番号の平文が現れない",
      sealedMessage.range(of: Data("4111111111111111".utf8)) == nil)
check("送信データにタイトルの平文すら現れない",
      sealedMessage.range(of: Data("GitHub".utf8)) == nil)

let received = try decoder.decode(SyncMessage.self, from: try bobSession.open(sealedMessage))
check("相手が正しく復号できる", received.payload.items.count == 2)
check("復号した中身が完全一致する", received.payload.items[0].primaryPassword == "S3cr3t!-値-🔐")

var corrupted = sealedMessage
corrupted[corrupted.count - 20] ^= 0x01
check("改ざんされた通信は復号に失敗する", (try? bobSession.open(corrupted)) == nil)
check("鍵の違う相手は復号できない", (try? aliceVsAttacker.open(sealedMessage)) == nil)

// ============================================================
section("同期: フレーム分割")
// ============================================================

let frameA = Data("ひとつめ".utf8)
let frameB = Data("2 つめはすこし長い内容".utf8)
var stream = SyncFraming.frame(frameA) + SyncFraming.frame(frameB)

check("1 通目を取り出せる", try SyncFraming.nextFrame(from: &stream) == frameA)
check("2 通目を取り出せる", try SyncFraming.nextFrame(from: &stream) == frameB)
check("残りは空になる", stream.isEmpty)
check("空のバッファからは何も出ない", try SyncFraming.nextFrame(from: &stream) == nil)

// 途中まで届いた状態では取り出さず、続きが来るまで待つ
var partial = SyncFraming.frame(frameB).prefix(6)
var partialBuffer = Data(partial)
check("途中までのデータでは取り出さない", try SyncFraming.nextFrame(from: &partialBuffer) == nil)
partialBuffer.append(SyncFraming.frame(frameB).dropFirst(6))
check("続きが届けば取り出せる", try SyncFraming.nextFrame(from: &partialBuffer) == frameB)

// 2 通が 1 回のパケットにまとまって届いても分けられる
var combined = SyncFraming.frame(frameA) + SyncFraming.frame(frameA) + SyncFraming.frame(frameB)
var count = 0
while let _ = try SyncFraming.nextFrame(from: &combined) { count += 1 }
check("まとめて届いた 3 通を分割できる", count == 3)

// 長さだけ巨大な値を送りつけられても、メモリを確保しに行かない
var bogus = Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0, count: 10)
var rejected = false
do { _ = try SyncFraming.nextFrame(from: &bogus) } catch { rejected = true }
check("異常に大きな長さ指定を拒否する", rejected)

// ============================================================
section("同期: マージ")
// ============================================================

func syncItem(_ title: String, id: UUID = UUID(), updated: Date, password: String = "pw") -> VaultItem {
    var item = VaultItem(category: .login)
    item.id = id
    item.title = title
    item.fields[1].value = password
    item.updatedAt = updated
    return item
}

let base = Date(timeIntervalSince1970: 1_700_000_000)
let sharedID = UUID()
let onlyLocalID = UUID()
let onlyRemoteID = UUID()

// 片方にしかない項目は、両方に行き渡る
var merged = SyncMerge.merge(
    local: VaultPayload(items: [syncItem("Macだけ", id: onlyLocalID, updated: base)]),
    remote: VaultPayload(items: [syncItem("iPhoneだけ", id: onlyRemoteID, updated: base)]),
    now: base
)
check("双方の項目が合流する", merged.payload.items.count == 2)
check("相手から来た件数を数えている", merged.summary.added == 1)

// 同じ項目を両方で編集した場合は、新しい方が勝つ
merged = SyncMerge.merge(
    local: VaultPayload(items: [syncItem("古い", id: sharedID, updated: base, password: "old")]),
    remote: VaultPayload(items: [syncItem("新しい", id: sharedID, updated: base.addingTimeInterval(60), password: "new")]),
    now: base
)
check("競合したら更新時刻の新しい方が残る", merged.payload.items.first?.primaryPassword == "new")
check("項目は重複しない", merged.payload.items.count == 1)
check("更新として数える", merged.summary.updated == 1)

// 逆向きでも同じ結果になる（どちらから同期しても揃う）
let reversed = SyncMerge.merge(
    local: VaultPayload(items: [syncItem("新しい", id: sharedID, updated: base.addingTimeInterval(60), password: "new")]),
    remote: VaultPayload(items: [syncItem("古い", id: sharedID, updated: base, password: "old")]),
    now: base
)
check("どちら側から同期しても同じ結果になる",
      reversed.payload.items.map(\.id) == merged.payload.items.map(\.id)
          && reversed.payload.items.first?.primaryPassword == "new")

// 墓標: 片方で完全削除した項目は復活しない
merged = SyncMerge.merge(
    local: VaultPayload(items: [], deletions: [Deletion(id: sharedID, deletedAt: base.addingTimeInterval(120))]),
    remote: VaultPayload(items: [syncItem("消したはず", id: sharedID, updated: base)]),
    now: base.addingTimeInterval(120)
)
check("完全削除した項目が相手から復活しない", merged.payload.items.isEmpty)
check("墓標は保持される", merged.payload.deletions.count == 1)

// 削除より後に編集していたなら、編集が勝つ（消し間違いを救う）
merged = SyncMerge.merge(
    local: VaultPayload(items: [], deletions: [Deletion(id: sharedID, deletedAt: base)]),
    remote: VaultPayload(items: [syncItem("削除後に編集", id: sharedID, updated: base.addingTimeInterval(60))]),
    now: base.addingTimeInterval(60)
)
check("削除より後の編集は復活する", merged.payload.items.count == 1)
check("相手からの追加として数える", merged.summary.added == 1)

// 古い墓標は掃除される
merged = SyncMerge.merge(
    local: VaultPayload(items: [], deletions: [Deletion(id: UUID(), deletedAt: base)]),
    remote: VaultPayload(),
    now: base.addingTimeInterval(SyncMerge.tombstoneLifetime + 1)
)
check("期限切れの墓標は捨てられる", merged.payload.deletions.isEmpty)

// 同じ内容どうしを同期しても何も起きない（繰り返し同期しても安定する）
let stable = VaultPayload(items: [syncItem("同じ", id: sharedID, updated: base)])
merged = SyncMerge.merge(local: stable, remote: stable, now: base)
check("同一内容の同期では変更が出ない", merged.summary.isEmpty)
check("2 回目の同期でも件数が増えない", merged.payload.items.count == 1)

let twice = SyncMerge.merge(local: merged.payload, remote: stable, now: base)
check("何度同期しても結果が変わらない", twice.payload.items.count == 1 && twice.summary.isEmpty)

print("\n\(failures == 0 ? "すべて成功" : "\(failures) 件失敗")")
exit(failures == 0 ? 0 : 1)
