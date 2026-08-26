import AppKit
import SwiftUI

// macOS 版の画面を画像として書き出す。
//
// 画面収録の許可が下りていない環境でも Mac 版の見た目を確かめるためのもの。
//
// 自分のプロセスでウィンドウを作り、その中身を自分で取り出している。
// 他人のウィンドウを撮るわけではないので画面収録の許可は要らず、
// AppKit の実際のビュー階層が描かれるので List や Form も写る。
// （SwiftUI の ImageRenderer では List / Form / ScrollView が描けなかった）
//
// ウィンドウは画面のはるか外側に置くので、利用者の画面には現れない。
//
//   /tmp/viewshots /出力先ディレクトリ
//
// **保管庫には一切書き込まない。** VaultStore を作るだけで、
// 項目を足したり保存したりする処理は呼ばない。見本はビューへ直接渡している。
// 念のため実行の前後で保管庫ファイルが変化していないことも確かめる。

@main
enum ViewShots {

    static func main() {
        let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let before = vaultFingerprint()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // Dock に出さない
        app.finishLaunching()

        let store = VaultStore()
        let login = sampleLogin()
        let card = sampleCard()
        let items = [login, card, sampleWeakLogin()]

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"

            // 実アプリではこれらは NavigationSplitView の各列に入る。
            // NavigationLink や toolbar はナビゲーション階層の中でないと描かれないので、
            // NavigationStack で包んで実物に近づける。
            capture("detail-login-\(suffix)", CGSize(width: 660, height: 780), scheme, outputDirectory) {
                NavigationStack {
                    ItemDetailView(item: login, onEdit: {}, onToast: { _ in }).environmentObject(store)
                }
            }
            capture("detail-card-\(suffix)", CGSize(width: 660, height: 540), scheme, outputDirectory) {
                NavigationStack {
                    ItemDetailView(item: card, onEdit: {}, onToast: { _ in }).environmentObject(store)
                }
            }
            capture("generator-\(suffix)", CGSize(width: 440, height: 640), scheme, outputDirectory) {
                GeneratorView { _ in }
            }
            capture("list-\(suffix)", CGSize(width: 330, height: 620), scheme, outputDirectory) {
                ItemListView(
                    items: items, selection: .all,
                    selectedItemID: .constant(login.id), onEdit: { _ in }, onToast: { _ in }
                ).environmentObject(store)
            }
            capture("sidebar-\(suffix)", CGSize(width: 250, height: 620), scheme, outputDirectory) {
                NavigationStack {
                    SidebarView(selection: .constant(.all)).environmentObject(store)
                }
            }
            capture("settings-\(suffix)", CGSize(width: 480, height: 640), scheme, outputDirectory) {
                SettingsView().environmentObject(store)
            }
            capture("edit-\(suffix)", CGSize(width: 540, height: 720), scheme, outputDirectory) {
                ItemEditView(item: login) { _ in }.environmentObject(store)
            }
            capture("sync-\(suffix)", CGSize(width: 470, height: 470), scheme, outputDirectory) {
                SyncView(store: store).environmentObject(store)
            }
            capture("create-\(suffix)", CGSize(width: 470, height: 640), scheme, outputDirectory) {
                CreateVaultView().environmentObject(store)
            }
            capture("watchtower-\(suffix)", CGSize(width: 420, height: 620), scheme, outputDirectory) {
                NavigationStack {
                    WatchtowerView(selectedItemID: .constant(nil)).environmentObject(store)
                }
            }
        }

        let after = vaultFingerprint()
        if before == after {
            print("保管庫は変化していません（\(before)）")
            exit(0)
        } else {
            print("！保管庫が変化しました: \(before) → \(after)")
            exit(1)
        }
    }

    // MARK: - 描画

    private static func capture<Content: View>(
        _ name: String, _ size: CGSize, _ scheme: ColorScheme,
        _ directory: String, @ViewBuilder content: () -> Content
    ) {
        let root = content()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.titlebarAppearsTransparent = true
        // 利用者の画面に映らないよう、はるか外側に置く
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()

        // 中身が描き終わる時期は一定しないので、白紙でなくなるまで何度か試す。
        // 取り出し方も 2 通り試す。どちらが通るかは中身次第:
        //  - レイヤ描画: VStack や Form のような素直な中身はこれで取れる
        //  - PDF 経由: List や ScrollView は実画面に出るまで描画を遅らせるので、
        //    AppKit の PDF 生成で描画を強制する必要がある
        var result: NSBitmapImageRep?
        var method = ""

        for attempt in 1...6 {
            RunLoop.main.run(until: Date().addingTimeInterval(attempt == 1 ? 0.6 : 0.4))
            forceDisplay(hosting)
            CATransaction.flush()

            if let viaLayer = layerBitmap(hosting, size: size), !isBlank(viaLayer) {
                result = viaLayer
                method = "レイヤ/\(attempt)回目"
                break
            }
            if let viaPDF = pdfBitmap(hosting, size: size, scheme: scheme), !isBlank(viaPDF) {
                result = viaPDF
                method = "PDF/\(attempt)回目"
                break
            }
            // 最後まで白紙なら、それを書き出して分かるようにする
            if attempt == 6 { result = layerBitmap(hosting, size: size) }
        }

        guard let rep = result, let png = rep.representation(using: .png, properties: [:]) else {
            print("× \(name): 描画できませんでした")
            window.close()
            return
        }

        do {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            let coverage = Int(inkCoverage(rep) * 100)
            if isBlank(rep) {
                print("△ \(name).png（描画できていない: 中身 \(coverage)%）")
            } else {
                print("○ \(name).png（\(method), 中身 \(coverage)%）")
            }
        } catch {
            print("× \(name): 書き出しに失敗 \(error)")
        }
        window.close()
    }

    /// スクロールビューの中身は放っておくと描かれないので、隅々まで描画を促す
    private static func forceDisplay(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.layer?.setNeedsDisplay()
        view.layer?.displayIfNeeded()
        view.displayIfNeeded()
        for subview in view.subviews { forceDisplay(subview) }
    }

    private static func makeRep(_ size: CGSize, _ scale: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
    }

    private static let renderScale = 2

    private static func layerBitmap(_ view: NSView, size: CGSize) -> NSBitmapImageRep? {
        guard let rep = makeRep(size, renderScale),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: rep),
              let layer = view.layer
        else { return nil }

        let cgContext = graphicsContext.cgContext
        // CoreGraphics の原点は左下、レイヤは左上を原点に描く。合わせないと上下が反転する。
        cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        cgContext.scaleBy(x: CGFloat(renderScale), y: -CGFloat(renderScale))
        layer.render(in: cgContext)
        return rep
    }

    private static func pdfBitmap(_ view: NSView, size: CGSize, scheme: ColorScheme) -> NSBitmapImageRep? {
        let pdfData = view.dataWithPDF(inside: view.bounds)
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1),
              let rep = makeRep(size, renderScale),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        let cgContext = graphicsContext.cgContext
        // PDF は透明なので、下地を敷かないと文字が読めない。
        // ダークモードの文字は明るいので、下地も暗くしないと真っ白に見えてしまう。
        cgContext.setFillColor(
            scheme == .dark
                ? CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        cgContext.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        cgContext.scaleBy(x: CGFloat(renderScale), y: CGFloat(renderScale))
        cgContext.drawPDFPage(page)
        return rep
    }

    /// 背景と違う色の画素がどれだけあるかを測る。
    ///
    /// 「全部同じ色か」だけを見ていると、行の背景や区切り線だけが描かれて
    /// 文字が抜け落ちた画像を「描画成功」と誤って判定してしまう。実際にそうなった。
    /// 割合で見れば、それを見分けられる。
    private static func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var differing = 0
        var total = 0
        let stepX = max(1, rep.pixelsWide / 150)
        let stepY = max(1, rep.pixelsHigh / 150)

        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                let distance = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if distance > 0.12 { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    /// 中身が描けているとみなす下限。
    ///
    /// この数値は目安であって判定ではない。中央にアイコンと数行だけの画面は
    /// 正しく描けていても数 % にしかならず、逆に行の背景だけが描かれた
    /// 「文字のない」画像も数 % になる。ここを超えたものは自分の目で見るしかない。
    private static let minimumCoverage = 0.01

    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        inkCoverage(rep) < minimumCoverage
    }

    // MARK: - 安全確認

    /// 保管庫が触られていないことを確かめるための、大きさと更新日時
    private static func vaultFingerprint() -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: VaultFile.vaultURL.path)
        let size = (attributes?[.size] as? Int).map(String.init) ?? "なし"
        let date = (attributes?[.modificationDate] as? Date).map { "\($0.timeIntervalSince1970)" } ?? "なし"
        return "size=\(size) mtime=\(date)"
    }

    // MARK: - 見本の中身（ビューへ直接渡すだけ。保存はしない）

    private static func sampleLogin() -> VaultItem {
        var item = VaultItem(category: .login)
        item.title = "GitHub"
        item.fields[0].value = "yamamuro20030926@gmail.com"
        item.fields[1].value = "kQ7#vRm2$wLp9!zXn4Td"
        item.fields[2].value = "https://github.com"
        item.oneTimePasswordSecret = "JBSWY3DPEHPK3PXP"
        item.tags = ["仕事", "開発"]
        item.notes = "二要素認証あり。復旧コードは別の場所に保管してある。"
        item.isFavorite = true
        item.passwordHistory = [
            PasswordChange(value: "oldPassword-2024", changedAt: Date().addingTimeInterval(-86400 * 200))
        ]
        return item
    }

    private static func sampleCard() -> VaultItem {
        var item = VaultItem(category: .creditCard)
        item.title = "楽天カード"
        item.fields[0].value = "YAMAMURO REN"
        item.fields[1].value = "4111111111111111"
        item.fields[2].value = "09/28"
        item.fields[3].value = "123"
        item.fields[5].value = "楽天カード株式会社"
        return item
    }

    private static func sampleWeakLogin() -> VaultItem {
        var item = VaultItem(category: .login)
        item.title = "古い掲示板"
        item.fields[0].value = "ren"
        item.fields[1].value = "password"
        item.fields[2].value = "http://example.com"
        return item
    }
}
