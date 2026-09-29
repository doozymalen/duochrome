import AppKit
import CoreText
import CoreImage

/// Text layer content. Coordinates are source pixels (bottom is 0), so it follows geometry corrections with the photo.
struct LayerText: Equatable, Codable {
    var string: String
    /// PostScript name (system font if none)
    var font: String = "Helvetica"
    /// Font size (source pixels)
    var size: Double = 48
    /// display RGB 0–1
    var color: [Float] = [1, 1, 1]
    /// First baseline position: left end for left alignment, center for centered, right end for right.
    /// For paragraph (box) text, the box's top-left; for vertical text, the top of the first line.
    var x: Double = 0
    var y: Double = 0
    /// 0 left, 1 center, 2 right, 3 justified
    var align = 0
    /// tracking (1/1000 em)
    var tracking: Double = 0
    /// Line spacing (source pixels, 0 means 1.2× the size)
    var leading: Double = 0
    /// rotation (°, counterclockwise +)
    var rotation: Double = 0

    // Character formatting (all optional since older documents lack them)
    /// vertical text
    var vertical: Bool? = nil
    /// Paragraph text: box width/height (source pixels). If set, lines wrap within the box
    var boxWidth: Double? = nil
    var boxHeight: Double? = nil
    /// Text warp: TextWarp index, bend -100–100
    var warp: Int? = nil
    var warpBend: Double? = nil
    /// Text on path: one line following this path (source coordinates), start position 0–1
    var onPath: VectorPath? = nil
    var pathOffset: Double? = nil
    /// Opposite side of the path (direction flipped, inside/below)
    var pathFlip: Bool? = nil
    /// Baseline shift (source pixels, up +), horizontal scale (%)
    var baselineShift: Double? = nil
    var horizontalScale: Double? = nil
}

/// Text warp style
enum TextWarp: Int, CaseIterable {
    case none, arc, arch, bulge, flag, wave, fish, rise, inflate, twist
    var title: String { ["없음", "부채꼴", "아치", "돌출", "깃발", "물결", "물고기", "상승", "부풀리기", "비틀기"][rawValue] }
}

/// Character/paragraph styles (saved by name and applied to text layers)
struct TextStyle: Codable, Equatable {
    var name: String
    var font: String
    var size: Double
    var color: [Float]
    var tracking: Double
    var leading: Double
    var align: Int

    static var saved: [TextStyle] {
        get { (UserDefaults.standard.data(forKey: "textStyles")).flatMap { try? JSONDecoder().decode([TextStyle].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "textStyles") }
    }

    init(name: String, from t: LayerText) {
        self.name = name; font = t.font; size = t.size; color = t.color
        tracking = t.tracking; leading = t.leading; align = t.align
    }

    func apply(to t: inout LayerText) {
        t.font = TextRender.resolveFont(font); t.size = size; t.color = color
        t.tracking = tracking; t.leading = leading; t.align = align
    }
}

enum TextRender {
    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    static func font(_ t: LayerText, scale: CGFloat) -> CTFont {
        let size = max(CGFloat(t.size) * scale, 1)
        var m = CGAffineTransform.identity
        if let h = t.horizontalScale, h != 100 { m = CGAffineTransform(scaleX: CGFloat(h) / 100, y: 1) }
        return CTFontCreateWithName(t.font as CFString, size, &m)
    }

    private static func attributes(_ t: LayerText, _ ctFont: CTFont, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let size = CTFontGetSize(ctFont)
        let c = t.color + [1, 1, 1]
        let color = CGColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = [.left, .center, .right, .justified][max(0, min(3, t.align))]
        let lead = t.leading > 0 ? CGFloat(t.leading) * scale : size * 1.2
        para.minimumLineHeight = lead
        para.maximumLineHeight = lead
        var a: [NSAttributedString.Key: Any] = [
            .font: ctFont, .foregroundColor: color, .paragraphStyle: para,
            .kern: CGFloat(t.tracking) / 1000 * size,
        ]
        if let b = t.baselineShift, b != 0 { a[.baselineOffset] = CGFloat(b) * scale }
        if t.vertical == true { a[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }
        return a
    }

    /// Image of the text rendered at `scale`. Placed at source coordinates × scale.
    static func image(_ t: LayerText, scale: CGFloat) -> CIImage? {
        let key = ((try? JSONEncoder().encode(t)).map { String(decoding: $0, as: UTF8.self) } ?? t.string) + "|\(scale)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard !t.string.isEmpty else { return nil }
        var img: CIImage?
        if let p = t.onPath, !p.isEmpty {
            img = onPath(t, t.pathFlip == true ? p.reversed : p, scale: scale)
        } else {
            img = block(t, scale: scale)
            if let w = t.warp.flatMap(TextWarp.init), w != .none, let b = t.warpBend, b != 0, let i = img {
                img = warp(i, w, bend: CGFloat(b) / 100, pivot: CGPoint(x: CGFloat(t.x) * scale, y: CGFloat(t.y) * scale), rotation: t.rotation)
            }
        }
        guard let img else { return nil }
        lock.lock()
        if cache.count > 32 { cache.removeAll() }
        cache[key] = img
        lock.unlock()
        return img
    }

    /// A block of text (horizontal, vertical, paragraph)
    private static func block(_ t: LayerText, scale: CGFloat) -> CIImage? {
        let ctFont = font(t, scale: scale)
        let size = CTFontGetSize(ctFont)
        let text = t.string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let str = NSAttributedString(string: text, attributes: attributes(t, ctFont, scale: scale))
        let setter = CTFramesetterCreateWithAttributedString(str)
        let vertical = t.vertical == true
        let frameAttrs: CFDictionary? = vertical
            ? [kCTFrameProgressionAttributeName: NSNumber(value: CTFrameProgression.rightToLeft.rawValue)] as CFDictionary : nil
        let isBox = (t.boxWidth ?? 0) > 0
        var constraint = CGSize(width: 1e6, height: 1e6)
        if isBox {
            constraint = vertical ? CGSize(width: 1e6, height: CGFloat(t.boxHeight ?? t.boxWidth!) * scale)
                                  : CGSize(width: CGFloat(t.boxWidth!) * scale, height: 1e6)
        }
        var fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), frameAttrs, constraint, nil)
        if isBox {
            if vertical { fit.height = CGFloat(t.boxHeight ?? t.boxWidth!) * scale }
            else {
                fit.width = CGFloat(t.boxWidth!) * scale
                if let bh = t.boxHeight, bh > 0 { fit.height = CGFloat(bh) * scale }   // Text beyond the box height is clipped
            }
        }
        let pad = ceil(size * 0.6)
        let w = Int(ceil(fit.width + pad * 2)), h = Int(ceil(fit.height + pad * 2))
        guard w > 0, h > 0, w < 30000, h < 30000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: pad, y: pad, width: ceil(fit.width) + 1, height: ceil(fit.height) + (vertical ? 1 : 0))
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), frameAttrs)
        ctx.setShouldAntialias(true)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        // Anchor: paragraph at the box's top-left, vertical at the top of the first line (top right), single horizontal line at the first baseline
        var ax: CGFloat, ay: CGFloat
        if isBox && !vertical {
            ax = rect.minX; ay = rect.maxY
        } else if vertical {
            ax = rect.maxX; ay = rect.maxY
        } else {
            var origins = [CGPoint](repeating: .zero, count: 1)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &origins)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            ax = pad + origins[0].x
            if let first = lines.first {
                let lw = CGFloat(CTLineGetTypographicBounds(first, nil, nil, nil))
                if t.align == 1 { ax += lw / 2 } else if t.align == 2 { ax += lw }
            }
            ay = pad + origins[0].y
        }
        let move = CGAffineTransform(translationX: -ax, y: -ay)
            .concatenating(.init(rotationAngle: CGFloat(t.rotation) * .pi / 180))
            .concatenating(.init(translationX: CGFloat(t.x) * scale, y: CGFloat(t.y) * scale))
        return CIImage(cgImage: cg).transformed(by: move)
    }

    /// Text on path: rotates the glyphs of a single line one by one along the path
    private static func onPath(_ t: LayerText, _ p: VectorPath, scale: CGFloat) -> CIImage? {
        let ctFont = font(t, scale: scale)
        let size = CTFontGetSize(ctFont)
        let text = t.string.replacingOccurrences(of: "\n", with: " ")
        var attrs = attributes(t, ctFont, scale: scale)
        attrs[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = nil
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        // Flatten the path in scale coordinates and measure its length
        let pts = p.flattened(step: 2).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard pts.count > 1 else { return nil }
        var acc: [CGFloat] = [0]
        for i in 1..<pts.count { acc.append(acc[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = acc.last!
        func at(_ d: CGFloat) -> (CGPoint, CGFloat)? {
            guard d >= 0, d <= total else { return nil }
            var i = 1
            while i < acc.count - 1 && acc[i] < d { i += 1 }
            let seg = max(acc[i] - acc[i - 1], 1e-6), f = (d - acc[i - 1]) / seg
            let a = pts[i - 1], b = pts[i]
            return (CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), atan2(b.y - a.y, b.x - a.x))
        }
        let bb = CGPath(rect: .zero, transform: nil).boundingBox.union(p.cgPath(scale: scale).boundingBoxOfPath).insetBy(dx: -size * 1.5, dy: -size * 1.5).integral
        guard bb.width > 0, bb.height > 0, bb.width < 30000, bb.height < 30000,
              let ctx = CGContext(data: nil, width: Int(bb.width), height: Int(bb.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: -bb.minX, y: -bb.minY)
        ctx.setShouldAntialias(true)
        let c = t.color + [1, 1, 1]
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var start = CGFloat(t.pathOffset ?? 0) * total
        if t.align == 1 { start += (total - lineWidth) / 2 } else if t.align == 2 { start += total - lineWidth }
        let base = CGFloat(t.baselineShift ?? 0) * scale
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n), adv = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &pos); CTRunGetAdvances(run, CFRange(), &adv)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<n {
                // Glyph center on the path (rotated along the slope)
                guard let (pt, ang) = at(start + pos[i].x + adv[i].width / 2) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: pt.x, y: pt.y)
                ctx.rotate(by: ang)
                var g = glyphs[i], o = CGPoint(x: -adv[i].width / 2, y: base)
                CTFontDrawGlyphs(runFont, &g, &o, 1, ctx)
                ctx.restoreGState()
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: .init(translationX: bb.minX, y: bb.minY))
    }

    /// Text warp: moves coordinates relative to the text image's box
    private static let warpKernel = CIWarpKernel(source: """
    kernel vec2 textWarp(vec4 box, float style, float b) {
        vec2 d = destCoord();
        float u = (d.x - box.x) / box.z;
        float v = (d.y - box.y) / box.w;
        float cu = u * 2.0 - 1.0;
        float cv = v * 2.0 - 1.0;
        vec2 s = d;
        if (style < 1.5) {            // Arc: the middle rises and the top widens
            float lift = b * box.w * 0.5 * (1.0 - cu * cu);
            float grow = 1.0 + b * 0.35 * v;
            s.y = d.y - lift;
            s.x = box.x + box.z * 0.5 + (d.x - box.x - box.z * 0.5) / grow;
        } else if (style < 2.5) {     // Arch: the whole thing bows
            s.y = d.y - b * box.w * 0.5 * (1.0 - cu * cu);
        } else if (style < 3.5) {     // Bulge: the middle thickens
            float f = 1.0 + b * (1.0 - cu * cu);
            s.y = box.y + box.w * 0.5 + (d.y - box.y - box.w * 0.5) / max(f, 0.05);
        } else if (style < 4.5) {     // Flag
            s.y = d.y - b * box.w * 0.25 * sin(6.2831853 * u);
        } else if (style < 5.5) {     // Wave: top and bottom alternate
            s.y = d.y - b * box.w * 0.2 * sin(6.2831853 * u + 3.1415926 * v);
        } else if (style < 6.5) {     // Fish: the front swells, the tail narrows
            float f = 1.0 + b * sin(3.1415926 * u) * (1.2 - u);
            s.y = box.y + box.w * 0.5 + (d.y - box.y - box.w * 0.5) / max(f, 0.05);
        } else if (style < 7.5) {     // Rise: climbs toward the right
            s.y = d.y - b * box.w * 0.6 * (u - 0.5);
        } else if (style < 8.5) {     // Inflate: rounded from the center
            float r = length(vec2(cu, cv));
            float f = 1.0 + b * max(0.0, 1.0 - r * r) * 0.6;
            s = vec2(box.x + box.z * 0.5, box.y + box.w * 0.5) + (d - vec2(box.x + box.z * 0.5, box.y + box.w * 0.5)) / max(f, 0.05);
        } else {                      // Twist: rotates the middle
            vec2 c = vec2(box.x + box.z * 0.5, box.y + box.w * 0.5);
            vec2 q = d - c;
            float r = length(vec2(cu, cv));
            float a = -b * 3.1415926 * 0.5 * max(0.0, 1.0 - r);
            s = c + vec2(q.x * cos(a) - q.y * sin(a), q.x * sin(a) + q.y * cos(a));
        }
        return s;
    }
    """)

    private static func warp(_ img: CIImage, _ style: TextWarp, bend b: CGFloat, pivot: CGPoint, rotation: Double) -> CIImage {
        guard let k = warpKernel else { return img }
        // Rotated text is unrotated, warped, and rotated back (so it warps along the text direction)
        let r = CGFloat(rotation) * .pi / 180
        let undo = CGAffineTransform(translationX: -pivot.x, y: -pivot.y).concatenating(.init(rotationAngle: -r))
        let flat = img.transformed(by: undo)
        let e = flat.extent
        let grow = abs(b) * e.height * 0.8 + 4
        let out = e.insetBy(dx: -grow, dy: -grow)
        let warped = k.apply(extent: out, roiCallback: { _, _ in e }, image: flat,
                             arguments: [CIVector(x: e.minX, y: e.minY, z: e.width, w: e.height), CGFloat(style.rawValue), b]) ?? flat
        return warped.cropped(to: out).transformed(by: undo.inverted())
    }

    /// Finds a usable font's PostScript name (the closest if the file's font isn't on this Mac) — font substitution
    static func resolveFont(_ name: String) -> String {
        if NSFont(name: name, size: 12) != nil { return name }
        let base = name.split(separator: "-").first.map(String.init) ?? name
        if let f = NSFontManager.shared.availableMembers(ofFontFamily: base)?.first?.first as? String { return f }
        // Apple SD Gothic Neo for Korean fonts, otherwise Helvetica
        if name.range(of: "Gothic|Myeongjo|Batang|Dotum|Gulim|Nanum|Noto.*KR|KR", options: .regularExpression) != nil { return "AppleSDGothicNeo-Regular" }
        return "Helvetica"
    }

    /// Whether this font was substituted (to alert when a PSD's font isn't on this Mac)
    static func isSubstituted(_ name: String) -> Bool { NSFont(name: name, size: 12) == nil }
}

extension Layers {
    /// Text layer: draws text in source coordinates and passes it through the photo's geometry corrections
    static func placedText(_ t: LayerText, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage, frame: CGRect) -> CIImage? {
        guard let img = TextRender.image(t, scale: scale) else { return nil }
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        let canvas = img.cropped(to: nativeRect).composited(over: CIImage(color: .clear).cropped(to: nativeRect))
        return shape(canvas, scale).cropped(to: frame)
    }
}
