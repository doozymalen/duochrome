import AppKit
import CoreText
import CoreImage

/// 글자 레이어의 내용. 좌표는 원본 픽셀(아래가 0)이라 사진과 같이 형태 보정을 따라간다.
struct LayerText: Equatable, Codable {
    var string: String
    /// 포스트스크립트 이름 (없으면 시스템 글꼴)
    var font: String = "Helvetica"
    /// 글자 크기 (원본 픽셀)
    var size: Double = 48
    /// 화면 값 RGB 0~1
    var color: [Float] = [1, 1, 1]
    /// 첫 줄 기준선의 자리: 왼쪽 정렬이면 왼쪽 끝, 가운데면 가운데, 오른쪽이면 오른쪽 끝.
    /// 단락(상자) 글자면 상자의 왼쪽 위, 세로 글자면 첫 줄의 위 끝.
    var x: Double = 0
    var y: Double = 0
    /// 0 왼쪽, 1 가운데, 2 오른쪽, 3 양쪽 맞춤
    var align = 0
    /// 자간 (1/1000 em)
    var tracking: Double = 0
    /// 줄 간격 (원본 픽셀, 0이면 크기의 1.2배)
    var leading: Double = 0
    /// 회전 (°, 반시계 +)
    var rotation: Double = 0

    // 글자 모양 (예전 문서에는 없어서 모두 선택 항목)
    /// 세로쓰기
    var vertical: Bool? = nil
    /// 단락 글자: 상자 너비·높이 (원본 픽셀). 있으면 상자 안에서 줄을 바꾼다
    var boxWidth: Double? = nil
    var boxHeight: Double? = nil
    /// 텍스트 뒤틀기: TextWarp 번호, 구부리기 -100~100
    var warp: Int? = nil
    var warpBend: Double? = nil
    /// 패스 위 글자: 이 패스를 따라 한 줄로 (원본 좌표), 시작 자리 0~1
    var onPath: VectorPath? = nil
    var pathOffset: Double? = nil
    /// 패스 반대쪽 (방향을 뒤집어 안쪽·아래쪽으로)
    var pathFlip: Bool? = nil
    /// 기준선 이동 (원본 픽셀, 위로 +), 가로 비율(%)
    var baselineShift: Double? = nil
    var horizontalScale: Double? = nil
}

/// 텍스트 뒤틀기 모양
enum TextWarp: Int, CaseIterable {
    case none, arc, arch, bulge, flag, wave, fish, rise, inflate, twist
    var title: String { ["없음", "부채꼴", "아치", "돌출", "깃발", "물결", "물고기", "상승", "부풀리기", "비틀기"][rawValue] }
}

/// 문자·단락 스타일 (이름 붙여 저장해 두고 글자 레이어에 입힌다)
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

    /// 글자를 `scale` 배율로 그린 그림. 원본 좌표 × scale 자리에 놓아 둔다.
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

    /// 한 덩어리 글자 (가로·세로·단락)
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
                if let bh = t.boxHeight, bh > 0 { fit.height = CGFloat(bh) * scale }   // 상자 높이를 넘는 글자는 잘린다
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
        // 기준점: 단락은 상자 왼쪽 위, 세로는 첫 줄 위 끝(오른쪽 위), 가로 한 줄은 첫 줄 기준선
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

    /// 패스 위 글자: 한 줄 글자의 글리프를 패스를 따라 하나씩 돌려 놓는다
    private static func onPath(_ t: LayerText, _ p: VectorPath, scale: CGFloat) -> CIImage? {
        let ctFont = font(t, scale: scale)
        let size = CTFontGetSize(ctFont)
        let text = t.string.replacingOccurrences(of: "\n", with: " ")
        var attrs = attributes(t, ctFont, scale: scale)
        attrs[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = nil
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        // 패스를 scale 좌표로 펼치고 길이를 잰다
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
                // 글리프 가운데를 패스 위에 (기울기를 따라 돌림)
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

    /// 텍스트 뒤틀기: 글자 그림의 상자를 기준으로 좌표를 옮긴다
    private static let warpKernel = CIWarpKernel(source: """
    kernel vec2 textWarp(vec4 box, float style, float b) {
        vec2 d = destCoord();
        float u = (d.x - box.x) / box.z;
        float v = (d.y - box.y) / box.w;
        float cu = u * 2.0 - 1.0;
        float cv = v * 2.0 - 1.0;
        vec2 s = d;
        if (style < 1.5) {            // 부채꼴: 가운데가 올라가고 위쪽이 넓어진다
            float lift = b * box.w * 0.5 * (1.0 - cu * cu);
            float grow = 1.0 + b * 0.35 * v;
            s.y = d.y - lift;
            s.x = box.x + box.z * 0.5 + (d.x - box.x - box.z * 0.5) / grow;
        } else if (style < 2.5) {     // 아치: 전체가 활처럼
            s.y = d.y - b * box.w * 0.5 * (1.0 - cu * cu);
        } else if (style < 3.5) {     // 돌출: 가운데가 두꺼워진다
            float f = 1.0 + b * (1.0 - cu * cu);
            s.y = box.y + box.w * 0.5 + (d.y - box.y - box.w * 0.5) / max(f, 0.05);
        } else if (style < 4.5) {     // 깃발
            s.y = d.y - b * box.w * 0.25 * sin(6.2831853 * u);
        } else if (style < 5.5) {     // 물결: 위아래가 엇갈린다
            s.y = d.y - b * box.w * 0.2 * sin(6.2831853 * u + 3.1415926 * v);
        } else if (style < 6.5) {     // 물고기: 앞쪽이 부풀고 꼬리가 좁아진다
            float f = 1.0 + b * sin(3.1415926 * u) * (1.2 - u);
            s.y = box.y + box.w * 0.5 + (d.y - box.y - box.w * 0.5) / max(f, 0.05);
        } else if (style < 7.5) {     // 상승: 오른쪽으로 갈수록 올라간다
            s.y = d.y - b * box.w * 0.6 * (u - 0.5);
        } else if (style < 8.5) {     // 부풀리기: 가운데에서 둥글게
            float r = length(vec2(cu, cv));
            float f = 1.0 + b * max(0.0, 1.0 - r * r) * 0.6;
            s = vec2(box.x + box.z * 0.5, box.y + box.w * 0.5) + (d - vec2(box.x + box.z * 0.5, box.y + box.w * 0.5)) / max(f, 0.05);
        } else {                      // 비틀기: 가운데를 돌린다
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
        // 회전한 글자는 되돌려 뒤틀고 다시 돌린다 (글자 방향 기준으로 뒤틀리게)
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

    /// 쓸 수 있는 글꼴의 포스트스크립트 이름을 찾는다 (파일의 글꼴 이름이 맥에 없으면 가까운 것) — 글꼴 대체
    static func resolveFont(_ name: String) -> String {
        if NSFont(name: name, size: 12) != nil { return name }
        let base = name.split(separator: "-").first.map(String.init) ?? name
        if let f = NSFontManager.shared.availableMembers(ofFontFamily: base)?.first?.first as? String { return f }
        // 한글 글꼴이면 애플 SD 산돌고딕, 아니면 헬베티카
        if name.range(of: "Gothic|Myeongjo|Batang|Dotum|Gulim|Nanum|Noto.*KR|KR", options: .regularExpression) != nil { return "AppleSDGothicNeo-Regular" }
        return "Helvetica"
    }

    /// 이 글꼴이 대체되었는지 (PSD 파일의 글꼴이 맥에 없을 때 알림용)
    static func isSubstituted(_ name: String) -> Bool { NSFont(name: name, size: 12) == nil }
}

extension Layers {
    /// 글자 레이어: 원본 좌표에 글자를 그리고 사진과 같은 형태 보정을 거친다
    static func placedText(_ t: LayerText, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage, frame: CGRect) -> CIImage? {
        guard let img = TextRender.image(t, scale: scale) else { return nil }
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        let canvas = img.cropped(to: nativeRect).composited(over: CIImage(color: .clear).cropped(to: nativeRect))
        return shape(canvas, scale).cropped(to: frame)
    }
}
