import AppKit
import CoreImage
import simd

/// Painting: stacks strokes on a paint layer (kind "paint"). Strokes are source-coordinate vectors, so they follow geometry;
/// when drawn, the brush tip is stamped at each spacing step (brush engine: size, hardness, flow, opacity, pressure, spacing, shape dynamics, scattering, texture,
/// dual brush, color dynamics). Pencil (aliased lines), pixel painting, eraser, and mixer brush (picking up and blending the color below) share the framework.
struct PaintBrush: Codable, Equatable {
    /// 0 paint, 1 eraser (within the paint layer), 2 pencil (no antialiasing), 3 mixer brush, 4 pixel paint
    var mode = 0
    var color: [Float] = [0.9, 0.2, 0.2]
    var size: Double = 40            // diameter (source pixels)
    var hardness: Double = 0.8
    var opacity: Double = 1
    var flow: Double = 1
    var spacing: Double = 0.2        // fraction of diameter
    var sizeJitter: Double = 0
    var angleJitter: Double = 0      // 0–1 (one full turn)
    var roundness: Double = 1        // 1 is round, smaller is flatter
    var angle: Double = 0            // degrees
    var scatter: Double = 0          // fraction of diameter
    var count = 1                    // stamps per position (with scattering)
    var hueJitter: Double = 0        // 0~1
    var brightnessJitter: Double = 0
    var pressureSize = true
    var pressureOpacity = false
    var tip: String? = nil           // imported brush tip (preset folder)
    var dualTip: String? = nil       // dual brush: masked by a second tip
    var texture: String? = nil       // texture (pattern) file: multiplied into the stroke
    var textureDepth: Double = 0.5
    var wet: Double = 0.5            // mixer brush: how much of the color below to pick up

    static var current: PaintBrush {
        get { (UserDefaults.standard.data(forKey: "paint.brush").flatMap { try? JSONDecoder().decode(PaintBrush.self, from: $0) }) ?? PaintBrush() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "paint.brush") }
    }
}

struct PaintStroke: Equatable, Hashable, Codable {
    var brush: PaintBrush
    /// x, y, pressure repeated (source coordinates)
    var points: [Double]
    var seed: UInt64 = UInt64.random(in: 0 ... UInt64(UInt32.max))
    /// Mixer brush: picked-up color per position (r, g, b repeated, same count as positions)
    var mixed: [Float]? = nil

    static func == (a: PaintStroke, b: PaintStroke) -> Bool { a.points == b.points && a.seed == b.seed && a.brush == b.brush && a.mixed == b.mixed }
    func hash(into h: inout Hasher) { h.combine(points); h.combine(seed); h.combine(mixed); h.combine(try? JSONEncoder().encode(brush)) }
}

enum PaintRender {
    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    /// Deterministic random (same result per stroke)
    struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    /// Round brush tip (edge softness from hardness)
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

    /// Grayscale (white is painted) → alpha mask image
    static func maskFrom(_ gray: CGImage) -> CGImage? {
        CGImage(maskWidth: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gray.width,
                provider: gray.dataProvider!, decode: [1, 0], shouldInterpolate: true)
    }

    static func tipGray(_ file: String?) -> CGImage? {
        guard let f = file, let src = CGImageSourceCreateWithURL(PresetFiles.url(f) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Bounds of the strokes (source coordinates)
    static func bounds(_ strokes: [PaintStroke], native: CGSize) -> CGRect {
        var r = CGRect.null
        for s in strokes {
            let pad = s.brush.size * (1 + s.brush.scatter + s.brush.sizeJitter) / 2 + 2
            for i in stride(from: 0, to: s.points.count - 2, by: 3) { r = r.union(CGRect(x: s.points[i] - pad, y: s.points[i + 1] - pad, width: pad * 2, height: pad * 2)) }
        }
        return r.intersection(CGRect(origin: .zero, size: native))
    }

    /// Paint layer image (source coordinates × scale, transparent outside)
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
            // source coordinates → this bitmap's coordinates
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

    /// Stamps one stroke (ctx in source coordinates)
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
        // Draw all strokes on one layer (accumulating by flow) and composite once with opacity
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
    /// Paint layer: stroke image → geometry corrections. Texture and opacity are applied here.
    static func painted(_ layer: AdjustLayer, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage, frame: CGRect) -> CIImage {
        var img = PaintRender.image(layer.paint ?? [], native: native, scale: scale)
        // Texture: tile and multiply the last brush's texture
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
    /// Paint tool: adds a stroke to the selected paint layer (new if none). mode is PaintBrush.mode
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

    /// One stroke on a paint layer. Outside a paint layer, the eraser erases the layer mask.
    func paintStroke(_ pts: [CGPoint], pressures: [Double], erase: Bool) {
        guard let doc = photo, var s = photo?.settings else { return }
        var b = PaintBrush.current
        if erase { b.mode = 1 }
        let selected = layersTab.selectedID.flatMap { id in s.layers.firstIndex { $0.id == id } }
        // Eraser: on a non-paint layer it erases the mask (as a brush mask starting from white)
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
            // Mixer brush: at each position pick up the color below (current look) and mix with the brush color (picked color carries to the next position)
            st.mixed = mixColors(pts, brush: b, doc: doc, layersBelow: Array(s.layers.prefix(i)))
        }
        s.layers[i].paint = (s.layers[i].paint ?? []) + [st]
        s.layers[i].opacity = s.layers[i].paint!.count == 1 ? Float(b.opacity) : s.layers[i].opacity
        replaceSettings(s, recordUndo: true, label: ["칠하기", "지우개", "연필", "혼합 브러시", "픽셀 칠하기"][b.mode])
        // Select the new layer after it's in the document (selecting first dropped the selection since it wasn't in the list yet)
        if let created {
            layersTab.select(created)
            if mode == .studio { retouchEditor.reload() }
        }
    }

    /// Mixed colors, one per brush position (mixer brush)
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
        // Brush positions at the same spacing as PaintRender.draw
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

    // MARK: - Background eraser: erases only areas similar to the clicked color (baked into the layer mask image)

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
        // current mask (white if none)
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

    // MARK: - History brush

    /// Puts the look at the chosen history point (or snapshot) in an image layer with a black brush mask → painted areas revert to then
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

    // MARK: - Red-eye removal

    @objc func redEyeTool(_ sender: Any?) {
        guard photo != nil else { NSSound.beep(); return }
        let o = beginPoints(style: .pins, points: [], hint: "적목 현상 제거: 빨간 눈동자를 누르세요 · 리턴 끝")
        o.onAdd = { [weak self] p in self?.fixRedEye(at: p); o.points = [] }
        o.onCommit = { [weak self] in self?.endPoints() }
        o.onCancel = { [weak self] in self?.endPoints() }
    }

    /// Finds strongly red pixels around the click and makes a layer that desaturates and darkens them
    func fixRedEye(at p: CGPoint, radius: Double? = nil) {
        guard let doc = photo, var s = photo?.settings, let base = rasterize(s.layers, withPhoto: true) else { return }
        let n = doc.nativeSize
        let R = radius ?? max(n.width, n.height) / 60
        let rect = CGRect(x: p.x - R, y: p.y - R, width: R * 2, height: R * 2).integral.intersection(CGRect(origin: .zero, size: n))
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 2, h > 2 else { return }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(base, toBitmap: &px, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // Fill only this rect of a whole-canvas mask (1/2 resolution)
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

    // MARK: - Paint bucket: similar colors connected to the click, as a fill layer

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
