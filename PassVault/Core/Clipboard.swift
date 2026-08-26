import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// パスワードのコピー。放置されたクリップボードは事故のもとなので、
/// 一定時間で必ず消す。
enum Clipboard {

    static let clearAfter: TimeInterval = 30

    /// 機密扱いでコピーする。パスワード管理ツールを見張っている
    /// クリップボード履歴アプリに「保存するな」と伝える印も付ける。
    static func copySecret(_ text: String) {
        #if os(macOS)
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: concealed)

        let stamp = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .seconds(clearAfter))
            // 自分が置いた内容がまだ載っているときだけ消す。
            // 後から別のものをコピーしていたら、それを消してはいけない。
            if NSPasteboard.general.changeCount == stamp {
                NSPasteboard.general.clearContents()
            }
        }
        #else
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.expirationDate: Date().addingTimeInterval(clearAfter)]
        )
        #endif
    }

    /// URL やユーザー名など、消さなくてよいもの
    static func copyPlain(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
