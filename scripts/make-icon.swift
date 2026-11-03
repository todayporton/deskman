// Resources/AppIcon.icns を作る。使い方: swift scripts/make-icon.swift
// デザイン: 黄色の地に黒の人影。真横から見た人が机を脇に抱えて一歩踏み出す。
// 座標は 1024 の SVG と同じ向き（左上が原点、y は下向き）で書く。
import AppKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let yellow = color(0xFFC800)
let ink = color(0x161514)

/// 丸い端と角の線を引く
func stroke(_ ctx: CGContext, _ pts: [CGPoint], width: CGFloat, color c: CGColor) {
    ctx.saveGState()
    ctx.setStrokeColor(c)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addLines(between: pts)
    ctx.strokePath()
    ctx.restoreGState()
}

/// 黄色の縁を付けてから黒で塗る角丸の四角（SVG の paint-order="stroke" と同じ）
func outlinedRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(yellow)
    ctx.setLineWidth(26)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.addPath(path)
    ctx.setFillColor(ink)
    ctx.fillPath()
}

func draw(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // 地: macOS のアイコングリッド（824px、角丸 185px）と影
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: color(0x000000, 0.28))
    ctx.addPath(tile)
    ctx.setFillColor(yellow)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.clip()

    // 人
    stroke(ctx, [CGPoint(x: 500, y: 420), CGPoint(x: 430, y: 500), CGPoint(x: 395, y: 580)], width: 70, color: ink)
    stroke(ctx, [CGPoint(x: 470, y: 600), CGPoint(x: 405, y: 715), CGPoint(x: 320, y: 795)], width: 96, color: ink)
    stroke(ctx, [CGPoint(x: 505, y: 390), CGPoint(x: 470, y: 595)], width: 120, color: ink)
    stroke(ctx, [CGPoint(x: 470, y: 600), CGPoint(x: 570, y: 690), CGPoint(x: 615, y: 800), CGPoint(x: 675, y: 800)],
           width: 96, color: ink)
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 520 - 66, y: 268 - 66, width: 132, height: 132))

    // 机: 脚2本と天板。中心はアイコンの中央
    outlinedRect(ctx, CGRect(x: 238, y: 500, width: 46, height: 225), radius: 10)
    outlinedRect(ctx, CGRect(x: 740, y: 500, width: 46, height: 225), radius: 10)
    outlinedRect(ctx, CGRect(x: 200, y: 452, width: 624, height: 80), radius: 12)

    // 天板に掛ける腕。黄色の縁は机の上端より下だけに付けて、肩は胴とつなげる
    let arm = [CGPoint(x: 505, y: 415), CGPoint(x: 545, y: 440), CGPoint(x: 655, y: 438)]
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 439, width: 1024, height: 600))
    stroke(ctx, arm, width: 124, color: yellow)
    ctx.restoreGState()
    stroke(ctx, arm, width: 70, color: ink)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(1) }
// PREVIEW_DIR を指定すると、確認用の PNG をそこに残す
if let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] {
    for name in ["icon_512x512@2x.png", "icon_32x32.png"] {
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: iconset.appendingPathComponent(name), to: dest)
    }
}
print(out.path)
