import AppKit
import CoreGraphics
import Foundation

// アプリアイコンを描いて PNG に書き出す。
// iOS 版は角丸なしの正方形（OS 側でマスクされる）、
// macOS 版は角丸＋余白つき（OS はマスクしないので自前で形を作る）。

enum Design: String {
    case padlock, shield, vault
}

// アプリのアクセントカラー #2E5CAA を基準にした配色
let deepBlue = CGColor(red: 0.106, green: 0.231, blue: 0.451, alpha: 1)
let midBlue = CGColor(red: 0.180, green: 0.361, blue: 0.667, alpha: 1)
let lightBlue = CGColor(red: 0.298, green: 0.510, blue: 0.816, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func makeContext(_ size: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

/// 背景（グラデーション）を塗る。macOS 用は角丸の中だけを塗る。
func fillBackground(_ context: CGContext, size: CGFloat, rounded: Bool) -> CGRect {
    let plate: CGRect
    if rounded {
        let inset = size * 0.055
        plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path = CGPath(
            roundedRect: plate, cornerWidth: plate.width * 0.222,
            cornerHeight: plate.width * 0.222, transform: nil
        )
        context.saveGState()
        context.addPath(path)
        context.clip()
    } else {
        plate = CGRect(x: 0, y: 0, width: size, height: size)
    }

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [lightBlue, midBlue, deepBlue] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    if rounded { context.restoreGState() }
    return plate
}

// MARK: - 図案

func drawPadlock(_ context: CGContext, in rect: CGRect) {
    let w = rect.width, h = rect.height
    let cx = rect.midX

    // 上のつる（U 字）
    let shackleRadius = w * 0.155
    let shackleCenterY = rect.minY + h * 0.615
    context.setStrokeColor(white)
    context.setLineWidth(w * 0.088)
    context.setLineCap(.round)
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: cx - shackleRadius, y: rect.minY + h * 0.50))
    shackle.addLine(to: CGPoint(x: cx - shackleRadius, y: shackleCenterY))
    shackle.addArc(
        center: CGPoint(x: cx, y: shackleCenterY), radius: shackleRadius,
        startAngle: .pi, endAngle: 0, clockwise: true
    )
    shackle.addLine(to: CGPoint(x: cx + shackleRadius, y: rect.minY + h * 0.50))
    context.addPath(shackle)
    context.strokePath()

    // 本体
    let bodyWidth = w * 0.52, bodyHeight = h * 0.345
    let body = CGRect(
        x: cx - bodyWidth / 2, y: rect.minY + h * 0.185,
        width: bodyWidth, height: bodyHeight
    )
    context.setFillColor(white)
    context.addPath(CGPath(
        roundedRect: body, cornerWidth: w * 0.075, cornerHeight: w * 0.075, transform: nil
    ))
    context.fillPath()

    // 鍵穴（本体を背景色でくり抜いたように見せる）
    let keyholeCenter = CGPoint(x: cx, y: body.minY + bodyHeight * 0.60)
    let keyholeRadius = w * 0.052
    context.setFillColor(midBlue)
    let keyhole = CGMutablePath()
    keyhole.addArc(
        center: keyholeCenter, radius: keyholeRadius,
        startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    keyhole.move(to: CGPoint(x: cx - keyholeRadius * 0.52, y: keyholeCenter.y))
    keyhole.addLine(to: CGPoint(x: cx - keyholeRadius * 0.80, y: body.minY + bodyHeight * 0.20))
    keyhole.addLine(to: CGPoint(x: cx + keyholeRadius * 0.80, y: body.minY + bodyHeight * 0.20))
    keyhole.addLine(to: CGPoint(x: cx + keyholeRadius * 0.52, y: keyholeCenter.y))
    keyhole.closeSubpath()
    context.addPath(keyhole)
    context.fillPath()
}

func drawShield(_ context: CGContext, in rect: CGRect) {
    let w = rect.width, h = rect.height
    let cx = rect.midX
    let top = rect.minY + h * 0.82
    let shoulder = rect.minY + h * 0.50
    let bottom = rect.minY + h * 0.14
    let halfWidth = w * 0.295

    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: cx - halfWidth, y: top))
    shield.addLine(to: CGPoint(x: cx + halfWidth, y: top))
    shield.addLine(to: CGPoint(x: cx + halfWidth, y: shoulder))
    shield.addCurve(
        to: CGPoint(x: cx, y: bottom),
        control1: CGPoint(x: cx + halfWidth, y: rect.minY + h * 0.28),
        control2: CGPoint(x: cx + halfWidth * 0.62, y: rect.minY + h * 0.19)
    )
    shield.addCurve(
        to: CGPoint(x: cx - halfWidth, y: shoulder),
        control1: CGPoint(x: cx - halfWidth * 0.62, y: rect.minY + h * 0.19),
        control2: CGPoint(x: cx - halfWidth, y: rect.minY + h * 0.28)
    )
    shield.closeSubpath()

    context.setFillColor(white)
    context.addPath(shield)
    context.fillPath()

    // 鍵穴
    let keyholeCenter = CGPoint(x: cx, y: rect.minY + h * 0.555)
    let keyholeRadius = w * 0.072
    context.setFillColor(midBlue)
    let keyhole = CGMutablePath()
    keyhole.addArc(
        center: keyholeCenter, radius: keyholeRadius,
        startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    keyhole.move(to: CGPoint(x: cx - keyholeRadius * 0.50, y: keyholeCenter.y))
    keyhole.addLine(to: CGPoint(x: cx - keyholeRadius * 0.82, y: rect.minY + h * 0.335))
    keyhole.addLine(to: CGPoint(x: cx + keyholeRadius * 0.82, y: rect.minY + h * 0.335))
    keyhole.addLine(to: CGPoint(x: cx + keyholeRadius * 0.50, y: keyholeCenter.y))
    keyhole.closeSubpath()
    context.addPath(keyhole)
    context.fillPath()
}

func drawVault(_ context: CGContext, in rect: CGRect) {
    let w = rect.width
    let center = CGPoint(x: rect.midX, y: rect.midY)

    // 扉の外周
    context.setStrokeColor(white)
    context.setLineWidth(w * 0.062)
    context.addArc(
        center: center, radius: w * 0.305,
        startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.strokePath()

    // ハンドルのスポーク
    context.setLineWidth(w * 0.055)
    context.setLineCap(.round)
    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4
        let inner = w * 0.105, outer = w * 0.225
        context.move(to: CGPoint(
            x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner
        ))
        context.addLine(to: CGPoint(
            x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer
        ))
    }
    context.strokePath()

    // 中央のダイヤル
    context.setFillColor(white)
    context.addArc(
        center: center, radius: w * 0.088,
        startAngle: 0, endAngle: .pi * 2, clockwise: false
    )
    context.fillPath()
}

func render(_ design: Design, size: Int, rounded: Bool) -> CGImage {
    let context = makeContext(size)
    let side = CGFloat(size)
    let plate = fillBackground(context, size: side, rounded: rounded)

    // 図案は背景板の内側 80% に収める
    let inset = plate.width * 0.10
    let content = plate.insetBy(dx: inset, dy: inset)

    switch design {
    case .padlock: drawPadlock(context, in: content)
    case .shield: drawShield(context, in: content)
    case .vault: drawVault(context, in: content)
    }
    return context.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// MARK: - 実行

let arguments = CommandLine.arguments
let outputDirectory = arguments.count > 1 ? arguments[1] : "."

if arguments.count > 2, arguments[2] == "preview" {
    // 3 案を並べた比較用の画像を作る（大きい表示と小さい表示の両方）
    for design in [Design.padlock, .shield, .vault] {
        write(render(design, size: 512, rounded: true),
              to: "\(outputDirectory)/preview-\(design.rawValue)-512.png")
        write(render(design, size: 48, rounded: true),
              to: "\(outputDirectory)/preview-\(design.rawValue)-48.png")
    }
    print("プレビューを書き出しました")
} else {
    let design = Design(rawValue: arguments.count > 2 ? arguments[2] : "padlock") ?? .padlock

    // iOS: 角丸なしの 1024
    write(render(design, size: 1024, rounded: false), to: "\(outputDirectory)/icon-ios-1024.png")

    // macOS: 角丸つきの各サイズ
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let suffix = scale == 1 ? "" : "@2x"
            write(render(design, size: pixels, rounded: true),
                  to: "\(outputDirectory)/icon-mac-\(points)x\(points)\(suffix).png")
        }
    }
    print("\(design.rawValue) のアイコンを書き出しました")
}
