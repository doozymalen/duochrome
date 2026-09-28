import AppKit
import CoreImage
import simd

/// 칠하기: 칠 레이어(kind "paint")에 붓질을 쌓는다. 붓질은 원본 좌표 벡터라 형태 보정을 따라가고,
/// 그릴 때 붓 끝을 간격마다 찍는다 (브러시 엔진: 크기·경도·흐름·불투명도·압력·간격·모양 변화·산포·텍스처·
/// 이중 브러시·색 변화). 연필(계단 있는 선), 픽셀 칠하기, 지우개, 혼합 브러시(아래 색을 묻혀 섞기)도 같은 틀이다.
struct PaintBrush: Codable, Equatable {
    /// 0 칠하기, 1 지우개(칠 레이어 안에서), 2 연필(안티앨리어싱 없음), 3 혼합 브러시, 4 픽셀 칠하기
    var mode = 0
    var color: [Float] = [0.9, 0.2, 0.2]
    var size: Double = 40            // 지름 (원본 픽셀)
    var hardness: Double = 0.8
    var opacity: Double = 1
    var flow: Double = 1
    var spacing: Double = 0.2        // 지름 비율
    var sizeJitter: Double = 0
    var angleJitter: Double = 0      // 0~1 (한 바퀴)
    var roundness: Double = 1        // 1 원, 작을수록 납작
    var angle: Double = 0            // 도
    var scatter: Double = 0          // 지름 비율
    var count = 1                    // 한 자리에 찍는 수 (산포와 같이)
    var hueJitter: Double = 0        // 0~1
    var brightnessJitter: Double = 0
    var pressureSize = true
    var pressureOpacity = false
    var tip: String? = nil           // 가져온 브러시 끝 (프리셋 폴더)
    var dualTip: String? = nil       // 이중 브러시: 두 번째 끝으로 가린다
    var texture: String? = nil       // 텍스처(패턴) 파일: 붓질에 곱한다
    var textureDepth: Double = 0.5
    var wet: Double = 0.5            // 혼합 브러시: 아래 색을 얼마나 묻힐지

    static var current: PaintBrush {
        get { (UserDefaults.standard.data(forKey: "paint.brush").flatMap { try? JSONDecoder().decode(PaintBrush.self, from: $0) }) ?? PaintBrush() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "paint.brush") }
    }
}

struct PaintStroke: Equatable, Hashable, Codable {
    var brush: PaintBrush
    /// x, y, 압력 반복 (원본 좌표)
    var points: [Double]
    var seed: UInt64 = UInt64.random(in: 0 ... UInt64(UInt32.max))
    /// 혼합 브러시: 자리마다 묻힌 색 (r, g, b 반복, 붓 자리와 같은 수)
    var mixed: [Float]? = nil

    static func == (a: PaintStroke, b: PaintStroke) -> Bool { a.points == b.points && a.seed == b.seed && a.brush == b.brush && a.mixed == b.mixed }
    func hash(into h: inout Hasher) { h.combine(points); h.combine(seed); h.combine(mixed); h.combine(try? JSONEncoder().encode(brush)) }
}

enum PaintRender {
    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    /// 결정적 난수 (붓질마다 같은 결과)
    struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    /// 둥근 붓 끝 (경도로 가장자리 부드러움)
    static func roundTip(hardness: Double) -> CGImage {
        let n = 128
        var px = [UInt8](repeating: 0, count: n * n)
        for y in 0 ..< n { for x in 0 ..< n {
            let dx = (Double(x) + 0.5) / Double(n) * 2 - 1, dy = (Double(y) + 0.5) / Double(n) * 2 - 1
            let r = sqrt(dx * dx + dy * dy)
            let h = min(max(hardness, 0), 0.99)
            let a = r >= 1 ? 0 : (r <= h ? 1 : 1 - (r - h) / (1 - h))
            px[y * n + x] = UInt8(max(0, min(255, a * a * (3 - 2 * a) * 255)))
        } }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    /// 흑백(흰 곳이 칠해짐) → 알파 마스크 그림
    static func maskFrom(_ gray: CGImage) -> CGImage? {
        CGImage(maskWidth: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gray.width,
                provider: gray.dataProvider!, decode: [1, 0], shouldInterpolate: true)
    }

    static func tipGray(_ file: String?) -> CGImage? {
        guard let f = file, let src = CGImageSourceCreateWithURL(PresetFiles.url(f) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 붓질들의 영역 (원본 좌표)
    static func bounds(_ strokes: [PaintStroke], native: CGSize) -> CGRect {
        var r = CGRect.null
        for s in strokes {
            let pad = s.brush.size * (1 + s.brush.scatter + s.brush.sizeJitter) / 2 + 2
            for i in stride(from: 0, to: s.points.count - 2, by: 3) { r = r.union(CGRect(x: s.points[i] - pad, y: s.points[i + 1] - pad, width: pad * 2, height: pad * 2)) }
        }
        return r.intersection(CGRect(origin: .zero, size: native))
    }

    /// 칠 레이어 그림 (원본 좌표 × scale, 바깥은 투명)
    static func image(_ strokes: [PaintStroke], native: CGSize, scale: CGFloat) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        guard !strokes.isEmpty else { return CIImage(color: .clear).cropped(to: full) }
        let rs = min(scale, 1)
        let key = "\(strokes.hashValue)|\(rs)|\(native)"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        var img: CIImage
        if let hit { img = hit } else {
            let b = bounds(strokes, native: native)
            guard !b.isNull, b.width > 0, b.height > 0 else { return CIImage(color: .clear).cropped(to: full) }
            let bw = Int((b.width * rs).rounded(.up)) + 2, bh = Int((b.height * rs).rounded(.up)) + 2
            guard bw < 20000, bh < 20000,
                  let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage(color: .clear).cropped(to: full) }
            // 원본 좌표 → 이 비트맵 좌표
            ctx.translateBy(x: -b.minX * rs + 1, y: -b.minY * rs + 1)
            ctx.scaleBy(x: rs, y: rs)
            for s in strokes { draw(s, into: ctx, rs: rs) }
            guard let cg = ctx.makeImage() else { return CIImage(color: .clear).cropped(to: full) }
            img = CIImage(cgImage: cg).transformed(by: .init(translationX: b.minX * rs - 1, y: b.minY * rs - 1))
            lock.lock()
            if cache.count > 12 { cache.removeAll() }
            cache[key] = img
            lock.unlock()
        }
        let k = scale / rs
        if k != 1 { img = img.transformed(by: .init(scaleX: k, y: k)) }
        return img.cropped(to: full).composited(over: CIImage(color: .clear).cropped(to: full))
    }

    /// 붓질 하나를 찍는다 (ctx는 원본 좌표)
    static func draw(_ s: PaintStroke, into ctx: CGContext, rs: CGFloat) {
        let b = s.brush
        var rng = RNG(s: s.seed | 1)
        let pts = stride(from: 0, to: s.points.count - 2, by: 3).map { (CGPoint(x: s.points[$0], y: s.points[$0 + 1]), s.points[$0 + 2]) }
        guard let first = pts.first else { return }
        let pixel = b.mode == 4, pencil = b.mode == 2 || pixel
        let baseTip = tipGray(b.tip) ?? roundTip(hardness: pencil ? 1 : b.hardness)
        guard let tipMask = maskFrom(baseTip) else { return }
        let dual = tipGray(b.dualTip).flatMap(maskFrom)
        ctx.saveGState()
        ctx.setShouldAntialias(!pencil)
        ctx.interpolationQuality = pencil ? .none : .high
        if b.mode == 1 { ctx.setBlendMode(.destinationOut) }
        // 붓질 전체를 한 층에 그리고(흐름으로 쌓임) 불투명도로 한 번에 얹는다
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        var dabs: [(CGPoint, Double)] = [first]
        let step = max(b.size * max(b.spacing, 0.01), pixel ? 1 : 0.5)
        var carry = 0.0
        for i in 1 ..< pts.count {
            let (p0, pr0) = pts[i - 1], (p1, pr1) = pts[i]
            let d = hypot(Double(p1.x - p0.x), Double(p1.y - p0.y))
            var t = step - carry
            while t <= d {
                let f = t / max(d, 1e-9)
                dabs.append((CGPoint(x: Double(p0.x) + Double(p1.x - p0.x) * f, y: Double(p0.y) + Double(p1.y - p0.y) * f), pr0 + (pr1 - pr0) * f))
                t += step
            }
            carry = d - (t - step)
        }
        let c = b.color + [0, 0, 0]
        for (k, (p, pressure)) in dabs.enumerated() {
            for _ in 0 ..< max(b.count, 1) {
                var size = b.size * (b.pressureSize ? max(pressure, 0.05) : 1) * (1 - b.sizeJitter * rng.next())
                if pixel { size = max(size.rounded(), 1) }
                var q = p
                if b.scatter > 0 {
                    let a = rng.next() * 2 * .pi, r = rng.next() * b.scatter * b.size
                    q = CGPoint(x: p.x + CGFloat(cos(a) * r), y: p.y + CGFloat(sin(a) * r))
                }
                if pixel { q = CGPoint(x: q.x.rounded(.down) + 0.5, y: q.y.rounded(.down) + 0.5) }
                var col = SIMD3<Float>(c[0], c[1], c[2])
                if let m = s.mixed, m.count >= (k + 1) * 3 { col = SIMD3(m[k * 3], m[k * 3 + 1], m[k * 3 + 2]) }
                if b.hueJitter > 0 || b.brightnessJitter > 0 {
                    let ns = NSColor(srgbRed: CGFloat(col.x), green: CGFloat(col.y), blue: CGFloat(col.z), alpha: 1)
                    var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                    ns.getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
                    h = (h + CGFloat((rng.next() - 0.5) * b.hueJitter)).truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
                    v = min(max(v + CGFloat((rng.next() - 0.5) * b.brightnessJitter), 0), 1)
                    let o = NSColor(hue: h, saturation: sat, brightness: v, alpha: 1)
                    col = SIMD3(Float(o.redComponent), Float(o.greenComponent), Float(o.blueComponent))
                }
                let alpha = b.flow * (b.pressureOpacity ? max(pressure, 0.05) : 1)
                ctx.saveGState()
                ctx.translateBy(x: q.x, y: q.y)
                ctx.rotate(by: CGFloat((b.angle + b.angleJitter * 360 * rng.next()) * .pi / 180))
                let rect = CGRect(x: -size / 2, y: -size * b.roundness / 2, width: size, height: size * b.roundness)
                ctx.clip(to: rect, mask: tipMask)
                if let dual { ctx.clip(to: rect.insetBy(dx: -size * 0.1, dy: -size * 0.1), mask: dual) }
                ctx.setFillColor(CGColor(srgbRed: CGFloat(col.x), green: CGFloat(col.y), blue: CGFloat(col.z), alpha: CGFloat(alpha)))
                ctx.fill(rect)
                ctx.restoreGState()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        _ = b.opacity
    }
}

extension Layers {
    /// 칠 레이어: 붓질을 그린 그림 → 형태 보정. 텍스처와 불투명도는 여기서.
    static func painted(_ layer: AdjustLayer, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage, frame: CGRect) -> CIImage {
        var img = PaintRender.image(layer.paint ?? [], native: native, scale: scale)
        // 텍스처: 마지막 붓의 텍스처를 바둑판으로 곱한다
        if let st = layer.paint?.last(where: { $0.brush.texture != nil }), let f = st.brush.texture, let tile = sourceImage(f) {
            let t = tile.transformed(by: .init(translationX: -tile.extent.minX, y: -tile.extent.minY)).transformed(by: .init(scaleX: scale, y: scale))
                .applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()]).cropped(to: img.extent)
            let depth = CGFloat(st.brush.textureDepth)
            let mask = t.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputRVector": CIVector(x: depth, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: depth, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: depth, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1 - depth, y: 1 - depth, z: 1 - depth, w: 1)])
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: img.extent), kCIInputMaskImageKey: mask])
        }
        return shape(img, scale).cropped(to: frame)
    }
}

extension MainWindowController {
    /// 칠하기 도구: 고른 칠 레이어(없으면 새로)에 붓질을 더한다. mode는 PaintBrush.mode
    func startPainting(mode: Int) {
        guard photo != nil else { NSSound.beep(); return }
        var b = PaintBrush.current
        b.mode = mode
        PaintBrush.current = b
        let titles = ["칠하기", "지우개", "연필", "혼합 브러시", "픽셀 칠하기"]
        let o = beginPoints(style: .strokes, points: [], hint: "\(titles[mode]): 끌어 칠하기 · 옵션은 레이어 탭 \"칠하기\" 카드 · 리턴·esc 끝")
        o.brushRadius = CGFloat(b.size / 2) * canvas.zoom
        o.onStroke = { [weak self] pts, flags in self?.paintStroke(pts, pressures: o.lastPressures, erase: flags.contains(.option)) }
        o.onCommit = { [weak self] in self?.endPoints() }
        o.onCancel = { [weak self] in self?.endPoints() }
    }

    /// 칠 레이어에 붓질 하나. 지우개는 칠 레이어가 아니면 레이어 마스크를 지운다.
    func paintStroke(_ pts: [CGPoint], pressures: [Double], erase: Bool) {
        guard let doc = photo, var s = photo?.settings else { return }
        var b = PaintBrush.current
        if erase { b.mode = 1 }
        let selected = layersTab.selectedID.flatMap { id in s.layers.firstIndex { $0.id == id } }
        // 지우개: 칠 레이어가 아닌 레이어면 마스크를 지운다 (흰색에서 시작하는 브러시 마스크로)
        if b.mode == 1, let i = selected, s.layers[i].kind != "paint" {
            if s.layers[i].mask.kind != .brush { s.layers[i].mask = LayerMask(kind: .brush); s.layers[i].mask.brushWhite = true }
            s.layers[i].mask.strokes.append(MaskStroke(points: pts.flatMap { [$0.x, $0.y] }, radius: b.size / 2, hardness: b.hardness, flow: b.flow, erase: true))
            replaceSettings(s, recordUndo: true, label: "지우개")
            return
        }
        var i: Int
        var created: String?
        if let si = selected, s.layers[si].kind == "paint" { i = si } else {
            var l = AdjustLayer(name: "칠하기 \(s.layers.count + 1)")
            l.kind = "paint"
            l.paint = []
            s.layers.append(l)
            i = s.layers.count - 1
            created = l.id
        }
        var flat: [Double] = []
        for (k, p) in pts.enumerated() { flat += [Double(p.x), Double(p.y), k < pressures.count ? pressures[k] : 1] }
        var st = PaintStroke(brush: b, points: flat)
        if b.mode == 3 {
            // 혼합 브러시: 자리마다 아래(지금 모습) 색을 묻혀 붓 색과 섞는다 (묻은 색은 다음 자리로 이어진다)
            st.mixed = mixColors(pts, brush: b, doc: doc, layersBelow: Array(s.layers.prefix(i)))
        }
        s.layers[i].paint = (s.layers[i].paint ?? []) + [st]
        s.layers[i].opacity = s.layers[i].paint!.count == 1 ? Float(b.opacity) : s.layers[i].opacity
        replaceSettings(s, recordUndo: true, label: ["칠하기", "지우개", "연필", "혼합 브러시", "픽셀 칠하기"][b.mode])
        // 새 레이어는 문서에 들어간 뒤에 고른다 (먼저 고르면 목록에 아직 없어 선택이 풀렸다)
        if let created {
            layersTab.select(created)
            if mode == .studio { studioMode.layersPanel.reload() }
        }
    }

    /// 붓 자리 수만큼 섞인 색 (혼합 브러시)
    func mixColors(_ pts: [CGPoint], brush b: PaintBrush, doc: RawDocument, layersBelow: [AdjustLayer]) -> [Float] {
        guard let base = rasterize(layersBelow, withPhoto: true) else { return [] }
        let k: CGFloat = 0.25
        let small = base.transformed(by: .init(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        func under(_ p: CGPoint) -> SIMD3<Float> {
            let x = min(max(Int(p.x * k), 0), w - 1), y = min(max(h - 1 - Int(p.y * k), 0), h - 1)
            let i = (y * w + x) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
        // 붓 자리는 PaintRender.draw와 같은 간격
        var dabs: [CGPoint] = pts.isEmpty ? [] : [pts[0]]
        let step = max(b.size * max(b.spacing, 0.01), 0.5)
        var carry = 0.0
        for i in 1 ..< max(pts.count, 1) {
            let d = hypot(Double(pts[i].x - pts[i - 1].x), Double(pts[i].y - pts[i - 1].y))
            var t = step - carry
            while t <= d {
                let f = t / max(d, 1e-9)
                dabs.append(CGPoint(x: Double(pts[i - 1].x) + Double(pts[i].x - pts[i - 1].x) * f, y: Double(pts[i - 1].y) + Double(pts[i].y - pts[i - 1].y) * f))
                t += step
            }
            carry = d - (t - step)
        }
        var load = SIMD3<Float>(b.color[0], b.color[1], b.color[2])
        var out: [Float] = []
        let wet = Float(b.wet)
        for p in dabs {
            load = load + (under(p) - load) * wet * 0.5
            out += [load.x, load.y, load.z]
        }
        return out
    }

    @objc func paintBrushMenu(_ sender: Any?) { startPainting(mode: 0) }
    @objc func pencilMenu(_ sender: Any?) { startPainting(mode: 2) }
    @objc func mixerBrushMenu(_ sender: Any?) { startPainting(mode: 3) }
    @objc func pixelPaintMenu(_ sender: Any?) { startPainting(mode: 4) }
    @objc func eraserMenu(_ sender: Any?) { startPainting(mode: 1) }

    // MARK: - 배경 지우개: 누른 자리 색과 비슷한 곳만 지운다 (레이어 마스크 그림에 굽는다)

    func backgroundErase(_ pts: [CGPoint], tolerance: Float = 0.12) {
        guard let doc = photo, var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }),
              let first = pts.first else { NSSound.beep(); return }
        var solo = s.layers[i]; solo.mask = LayerMask(); solo.opacity = 1; solo.blend = "normal"; solo.group = nil
        let content = (s.layers[i].isImage || s.layers[i].kind == "paint") ? rasterize([solo], withPhoto: false) : rasterize([], withPhoto: true)
        guard let content else { return }
        let n = doc.nativeSize
        let k: CGFloat = min(1, 2400 / max(n.width, n.height))
        let rect = CGRect(x: 0, y: 0, width: (n.width * k).rounded(), height: (n.height * k).rounded())
        let w = Int(rect.width), h = Int(rect.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(content.transformed(by: .init(scaleX: k, y: k)), toBitmap: &px, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // 지금 마스크 (없으면 흰색)
        var mask = [Float](repeating: 1, count: w * h)
        if s.layers[i].mask.kind != .full {
            let m = Layers.maskImage(s.layers[i].mask, scale: k, native: n, shape: { img, _ in img }, base: content.transformed(by: .init(scaleX: k, y: k)))
            var mp = [Float](repeating: 0, count: w * h * 4)
            Render.context.render(m, toBitmap: &mp, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
            for j in 0 ..< w * h { mask[j] = mp[j * 4] }
        }
        func idx(_ p: CGPoint) -> Int { min(max(h - 1 - Int(p.y * k), 0), h - 1) * w + min(max(Int(p.x * k), 0), w - 1) }
        let si = idx(first) * 4
        let sample = SIMD3(px[si], px[si + 1], px[si + 2])
        let r = Int(layersTab.brushRadius * Double(k))
        for p in pts {
            let cx = Int(p.x * k), cy = h - 1 - Int(p.y * k)
            for y in max(cy - r, 0) ... min(cy + r, h - 1) { for x in max(cx - r, 0) ... min(cx + r, w - 1) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                let j = y * w + x
                let c = SIMD3(px[j * 4], px[j * 4 + 1], px[j * 4 + 2])
                let d = simd_abs(c - sample).max()
                if d < tolerance { mask[j] = 0 } else if d < tolerance * 1.5 { mask[j] = min(mask[j], (d - tolerance) / (tolerance * 0.5)) }
            } }
        }
        var gray = mask.map { UInt8(max(0, min(255, $0 * 255))) }
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage(), let file = PSDImport.writeImage(cg) else { return }
        s.layers[i].mask = LayerMask(kind: .image, maskFile: file)
        replaceSettings(s, recordUndo: true, label: "배경 지우개")
    }

    @objc func backgroundEraserTool(_ sender: Any?) {
        guard photo != nil else { NSSound.beep(); return }
        let o = beginPoints(style: .strokes, points: [], hint: "배경 지우개: 처음 누른 자리 색과 비슷한 곳을 지웁니다 (붓 크기 = 레이어 탭) · 리턴 끝")
        o.brushRadius = CGFloat(layersTab.brushRadius) * canvas.zoom
        o.onStroke = { [weak self] pts, _ in self?.backgroundErase(pts) }
        o.onCommit = { [weak self] in self?.endPoints() }
        o.onCancel = { [weak self] in self?.endPoints() }
    }

    // MARK: - 작업 내역 브러시

    /// 고른 작업 내역 시점(또는 스냅샷)의 모습을 이미지 레이어로 두고 검은 브러시 마스크를 준다 → 칠한 곳만 그때로
    @objc func historyBrush(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let entries = history.snapshots.map { ("스냅샷: " + $0.label, $0.settings) } + history.states.map { ($0.label, $0.settings) }
        guard !entries.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "작업 내역 브러시"
        a.informativeText = "칠한 곳만 고른 시점의 모습으로 되돌립니다."
        let pop = NSPopUpButton(); pop.addItems(withTitles: entries.map(\.0)); pop.selectItem(at: 0)
        a.accessoryView = pop
        a.addButton(withTitle: "칠하기"); a.addButton(withTitle: "취소")
        guard ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] != nil || a.runModal() == .alertFirstButtonReturn else { return }
        let src = entries[max(pop.indexOfSelectedItem, 0)].1
        let cur = doc.settings
        var flat = src; flat.adoptGeometry(from: DevelopSettings())
        doc.settings = flat
        doc.showFullFrame = true
        let n = doc.nativeSize
        let img = doc.withFullResolution { doc.image(scale: 1) }.cropped(to: CGRect(origin: .zero, size: n))
        doc.showFullFrame = false
        doc.settings = cur
        guard var l = imageLayer(from: img, name: "작업 내역 브러시") else { return }
        l.mask = LayerMask(kind: .brush)
        var s = cur
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "작업 내역 브러시")
        layersTab.select(l.id)
        layersTab.erase = false
        enterTool(.mask)
    }

    // MARK: - 적목 현상 제거

    @objc func redEyeTool(_ sender: Any?) {
        guard photo != nil else { NSSound.beep(); return }
        let o = beginPoints(style: .pins, points: [], hint: "적목 현상 제거: 빨간 눈동자를 누르세요 · 리턴 끝")
        o.onAdd = { [weak self] p in self?.fixRedEye(at: p); o.points = [] }
        o.onCommit = { [weak self] in self?.endPoints() }
        o.onCancel = { [weak self] in self?.endPoints() }
    }

    /// 누른 자리 둘레에서 붉은 기가 센 픽셀을 찾아 채도를 빼고 어둡게 하는 레이어를 만든다
    func fixRedEye(at p: CGPoint, radius: Double? = nil) {
        guard let doc = photo, var s = photo?.settings, let base = rasterize(s.layers, withPhoto: true) else { return }
        let n = doc.nativeSize
        let R = radius ?? max(n.width, n.height) / 60
        let rect = CGRect(x: p.x - R, y: p.y - R, width: R * 2, height: R * 2).integral.intersection(CGRect(origin: .zero, size: n))
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 2, h > 2 else { return }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(base, toBitmap: &px, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // 전체 캔버스 마스크 중 이 네모만 채운다 (1/2 해상도)
        let k: CGFloat = 0.5
        let mw = Int(n.width * k), mh = Int(n.height * k)
        var gray = [UInt8](repeating: 0, count: mw * mh)
        var found = 0
        for y in 0 ..< h { for x in 0 ..< w {
            let i = (y * w + x) * 4
            let r = px[i], g = px[i + 1], b = px[i + 2]
            let red = r / max((g + b) / 2, 0.02)
            let dx = Double(x) - Double(w) / 2, dy = Double(y) - Double(h) / 2
            guard red > 1.6, r > 0.15, dx * dx + dy * dy < R * R else { continue }
            let nx = Int((rect.minX + CGFloat(x)) * k), ny = mh - 1 - Int((rect.minY + CGFloat(h - 1 - y)) * k)
            guard nx >= 0, nx < mw, ny >= 0, ny < mh else { continue }
            gray[ny * mw + nx] = UInt8(min(255, (red - 1.6) * 400 + 100))
            found += 1
        } }
        guard found > 3, let ctx = CGContext(data: &gray, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage(), let file = PSDImport.writeImage(cg) else { NSSound.beep(); return }
        var l = AdjustLayer(name: "적목 현상 제거")
        l.mask = LayerMask(kind: .image, maskFile: file, feather: 1.5)
        l.adjust.saturation = -100
        l.adjust.exposure = -1.3
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "적목 현상 제거")
    }

    // MARK: - 페인트 통: 누른 자리와 이어진 비슷한 색을 칠 레이어로

    func paintBucket(at p: CGPoint) {
        guard let eng = selectionEngine, var s = photo?.settings else { NSSound.beep(); return }
        let tol = Float(UserDefaults.standard.object(forKey: "wand.tolerance") as? Double ?? 32)
        guard let file = eng.save(eng.wand(at: p, tolerance: tol, contiguous: true)) else { return }
        var l = AdjustLayer(name: "페인트 통")
        l.kind = "fill"
        l.fillColor = PaintBrush.current.color
        l.mask = LayerMask(kind: .image, maskFile: file)
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "페인트 통")
        layersTab.select(l.id)
    }

    @objc func paintBucketTool(_ sender: Any?) {
        let o = beginPoints(style: .pins, points: [], hint: "페인트 통: 칠할 곳을 누르세요 (색 = 칠하기 색, 허용치 = 자동 선택) · 리턴 끝")
        o.onAdd = { [weak self] p in self?.paintBucket(at: p); o.points = [] }
        o.onCommit = { [weak self] in self?.endPoints() }
        o.onCancel = { [weak self] in self?.endPoints() }
    }
}
