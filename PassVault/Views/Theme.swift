import SwiftUI

extension Color {
    /// アクセントカラー。アセットカタログを使わずコードで定義しているので、
    /// 追加のリソースなしにライト/ダーク両方へ対応できる。
    static let appAccent = Color(
        light: Color(red: 0.180, green: 0.361, blue: 0.667),
        dark: Color(red: 0.400, green: 0.588, blue: 0.898)
    )

    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}
