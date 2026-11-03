import AppKit

/// メニューバー用のアイコン。アプリアイコン（scripts/make-icon.swift）から黄色の地を外した形。
/// 座標は make-icon.swift と同じ 1024 の座標で、黄色の縁は透明の隙間にする。
/// テンプレート画像なので、色は macOS がメニューバーの明暗に合わせて塗る。
enum MenuBarIcon {
    /// アイコンのうち描く範囲（1024 の座標）
    private static let frame = CGRect(x: 170, y: 180, width: 684, height: 684)

    static func make(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let k = rect.width / frame.width
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            draw(ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Deskman"
        return image
    }

    private static func stroke(_ ctx: CGContext, _ pts: [CGPoint], width: CGFloat, clear: Bool = false) {
        ctx.saveGState()
        if clear { ctx.setBlendMode(.clear) }
        ctx.setStrokeColor(.black)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addLines(between: pts)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 透明の縁を付けてから塗る角丸の四角
    private static func outlinedRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(path)
        ctx.setLineWidth(26)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setFillColor(.black)
        ctx.fillPath()
    }

    private static func draw(_ ctx: CGContext) {
        // 人
        stroke(ctx, [CGPoint(x: 500, y: 420), CGPoint(x: 430, y: 500), CGPoint(x: 395, y: 580)], width: 70)
        stroke(ctx, [CGPoint(x: 470, y: 600), CGPoint(x: 405, y: 715), CGPoint(x: 320, y: 795)], width: 96)
        stroke(ctx, [CGPoint(x: 505, y: 390), CGPoint(x: 470, y: 595)], width: 120)
        stroke(ctx, [CGPoint(x: 470, y: 600), CGPoint(x: 570, y: 690), CGPoint(x: 615, y: 800),
                     CGPoint(x: 675, y: 800)], width: 96)
        ctx.setFillColor(.black)
        ctx.fillEllipse(in: CGRect(x: 520 - 66, y: 268 - 66, width: 132, height: 132))

        // 机: 脚2本と天板
        outlinedRect(ctx, CGRect(x: 238, y: 500, width: 46, height: 225), radius: 10)
        outlinedRect(ctx, CGRect(x: 740, y: 500, width: 46, height: 225), radius: 10)
        outlinedRect(ctx, CGRect(x: 200, y: 452, width: 624, height: 80), radius: 12)

        // 天板に掛ける腕。隙間は机の上端より下だけに付けて、肩は胴とつなげる
        let arm = [CGPoint(x: 505, y: 415), CGPoint(x: 545, y: 440), CGPoint(x: 655, y: 438)]
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 439, width: 1024, height: 600))
        stroke(ctx, arm, width: 124, clear: true)
        ctx.restoreGState()
        stroke(ctx, arm, width: 70)
    }
}
