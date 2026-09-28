// Duochrome 앱 아이콘 그리기 (macOS 27 리퀴드 글래스 양식): 1024 캔버스에 그려 iconset을 만든다.
// 쓰는 법: swift scripts/make-icon.swift <출력 .iconset 폴더>
// 모양: 연속 곡률 둥근 사각형(가장자리 여백 100) · 흑연색 바탕 · 호박색·청록색 반투명 유리 원판 두 장(겹친 곳은 밝게) · 위쪽 빛 반사 · 유리 테두리
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
/// 애플 시스템 색 (sRGB 16진수, 다크 모드 값)
func apple(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// 애플 아이콘 모양 (연속 곡률 사각형 근사: 모서리 반경 185/824)
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = r.width * 0.2237
    p.addRoundedRect(in: r, cornerWidth: k, cornerHeight: k)
    return p
}

func draw(size: Int) -> CGImage {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: S / 1024, y: S / 1024)
    ctx.interpolationQuality = .high
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(tile)

    // 바닥 그림자 (아이콘이 떠 있게)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0.08, 0.08, 0.1)); ctx.fillPath()
    ctx.restoreGState()

    // 바탕: 흑연색 세로 그라디언트
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [apple(0x3A3A3C), apple(0x1C1C1E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // 바탕 가운데 은은한 빛
    let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600), endRadius: 460, options: [])

    // 유리 원판 두 장
    func disc(center c: CGPoint, radius R: CGFloat, stops: [CGColor]) {
        let r = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        // 원판 아래 그림자
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.45))
        ctx.addEllipse(in: r); ctx.setFillColor(color(0, 0, 0, 0.001)); ctx.fillPath()
        ctx.restoreGState()
        // 몸체: 반투명 색 그라디언트 (화면 합성으로 겹친 곳이 밝아진다)
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        ctx.addEllipse(in: r); ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x, y: c.y + R), end: CGPoint(x: c.x, y: c.y - R), options: [])
        ctx.restoreGState()
        // 위쪽 빛 반사 (유리)
        ctx.saveGState()
        ctx.addEllipse(in: r); ctx.clip()
        let hi = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.55), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(hi, startCenter: CGPoint(x: c.x - R * 0.25, y: c.y + R * 0.55), startRadius: 0,
                               endCenter: CGPoint(x: c.x - R * 0.25, y: c.y + R * 0.55), endRadius: R * 0.75, options: [])
        ctx.restoreGState()
        // 테두리: 위는 밝고 아래는 옅은 유리 가장자리
        ctx.saveGState()
        ctx.addEllipse(in: r.insetBy(dx: 3, dy: 3))
        ctx.setLineWidth(6)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        let rim = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.85), color(1, 1, 1, 0.15)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: c.x, y: c.y + R), end: CGPoint(x: c.x, y: c.y - R), options: [])
        ctx.restoreGState()
    }
    let R: CGFloat = 228
    // 따뜻한 쪽: 시스템 노랑·주황·핑크 / 차가운 쪽: 시스템 청록·파랑·인디고
    disc(center: CGPoint(x: 412, y: 540), radius: R, stops: [apple(0xFFB340, 0.95), apple(0xFF9F0A, 0.95), apple(0xFF375F, 0.95)])
    disc(center: CGPoint(x: 612, y: 470), radius: R, stops: [apple(0x64D2FF, 0.92), apple(0x0A84FF, 0.92), apple(0x5E5CE6, 0.92)])

    // 겹친 곳 가운데에 작은 조리개 빛점 (사진 앱임을)
    ctx.saveGState()
    let spark = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.9), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spark, startCenter: CGPoint(x: 512, y: 505), startRadius: 0, endCenter: CGPoint(x: 512, y: 505), endRadius: 70, options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    // 아이콘 전체 유리 테두리와 위쪽 반사
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.18), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle(tile.insetBy(dx: 2, dy: 2)))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let edge = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.55), color(1, 1, 1, 0.08)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(edge, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(size: px)
    let rep = NSBitmapImageRep(cgImage: img)
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
}
print("아이콘 그림 완료: \(out.path)")
