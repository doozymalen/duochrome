import AppKit
import CoreImage
import simd

/// Selection: computations for pixel-based selections (magic wand, quick selection, focus area, magnetic lasso), and
/// selection combine, invert, expand, contract, feather, border, save, load, quick mask, and the Select and Mask workspace.
///
/// Pixel computations run on a source-coordinate image without geometry (around 1600 px long side). The resulting mask
/// is a grayscale image covering the whole source (mask type image), so it follows the photo's geometry corrections.
final class SelectionEngine {
    let w: Int, h: Int
    /// Source pixels → buffer pixels scale
    let k: CGFloat
    /// Display RGB (0–1), from the top row
    private(set) var rgb: [Float]
    private var edges: [Float]?

    init?(doc: RawDocument, longSide: CGFloat = 1600) {
        let n = doc.nativeSize
        let k = min(longSide / max(n.width, n.height), 1)
        var flat = doc.settings
        flat.adoptGeometry(from: DevelopSettings())
        let saved = doc.settings, full = doc.showFullFrame
        doc.settings = flat
        doc.showFullFrame = true
        let img = doc.image(scale: k)
        doc.settings = saved
        doc.showFullFrame = full
        let r = CGRect(x: 0, y: 0, width: (n.width * k).rounded(.down), height: (n.height * k).rounded(.down))
        w = Int(r.width); h = Int(r.height)
        guard w > 4, h > 4 else { return nil }
        self.k = k
        var buf = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(img.cropped(to: r), toBitmap: &buf, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: Render.displaySpace)
        rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = buf[i * 4]; rgb[i * 3 + 1] = buf[i * 4 + 1]; rgb[i * 3 + 2] = buf[i * 4 + 2] }
    }

    /// Source coordinates → buffer cell (top row is 0)
    func cell(_ p: CGPoint) -> (Int, Int)? {
        let x = Int(p.x * k), y = h - 1 - Int(p.y * k)
        guard x >= 0, x < w, y >= 0, y < h else { return nil }
        return (x, y)
    }
    func native(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: (CGFloat(x) + 0.5) / k, y: (CGFloat(h - 1 - y) + 0.5) / k) }

    private func color(_ i: Int) -> SIMD3<Float> { SIMD3(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]) }

    /// Magic wand: pixels within the tolerance (0–255, max channel difference) of the clicked color. Contiguous only if set
    func wand(at p: CGPoint, tolerance: Float, contiguous: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        guard let (sx, sy) = cell(p) else { return out }
        let c0 = color(sy * w + sx), t = tolerance / 255
        func near(_ i: Int) -> Bool {
            let d = color(i) - c0
            return Swift.max(Swift.abs(d.x), Swift.max(Swift.abs(d.y), Swift.abs(d.z))) <= t
        }
        if !contiguous {
            for i in 0..<(w * h) where near(i) { out[i] = 255 }
            return out
        }
        var stack = [sy * w + sx]
        out[sy * w + sx] = 255
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let j = ny * w + nx
                if out[j] == 0, near(j) { out[j] = 255; stack.append(j) }
            }
        }
        return out
    }

    /// Quick selection: grows areas connected by colors close to the brush-area mean, up to a few brush radii (adds to the selection)
    func quickGrow(_ points: [CGPoint], radius: CGFloat, into base: inout [UInt8], subtract: Bool) {
        let r = max(Int(radius * k), 1), reach = r * 4
        var seeds: [Int] = []
        var sum = SIMD3<Float>(repeating: 0), n: Float = 0
        for p in points {
            guard let (cx, cy) = cell(p) else { continue }
            for dy in -r...r { for dx in -r...r where dx * dx + dy * dy <= r * r {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let i = y * w + x
                seeds.append(i); sum += color(i); n += 1
            } }
        }
        guard n > 0 else { return }
        let mean = sum / n
        // Set tolerance from the color spread within the brush (wider with more texture)
        var spread: Float = 0
        for i in seeds.prefix(4000) { let d = color(i) - mean; spread += (d * d).sum() }
        let tol = max(sqrt(spread / min(n, 4000)) * 2.5, 0.06)
        var mark = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for i in seeds where !mark[i] { mark[i] = true; stack.append(i) }
        let cxs = points.compactMap(cell)
        func inReach(_ x: Int, _ y: Int) -> Bool {
            cxs.contains { abs($0.0 - x) <= reach && abs($0.1 - y) <= reach }
        }
        while let i = stack.popLast() {
            base[i] = subtract ? 0 : 255
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let j = ny * w + nx
                guard !mark[j], inReach(nx, ny) else { continue }
                mark[j] = true
                if simd.length(color(j) - mean) <= tol { stack.append(j) }
            }
        }
    }

    /// Focus area: magnitude of the luminance Laplacian, broadly blurred, above the threshold (0–1)
    func focusArea(threshold: Float) -> [UInt8] {
        var lum = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { let c = color(i); lum[i] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var lap = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            lap[i] = abs(4 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - w] - lum[i + w])
        } }
        let blurred = boxBlur(lap, radius: max(w / 80, 3))
        let mx = blurred.max() ?? 1
        return blurred.map { $0 / max(mx, 1e-6) >= threshold ? 255 : 0 }
    }

    private func boxBlur(_ a: [Float], radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        for y in 0..<h {
            var acc: Float = 0
            for x in -r...r { acc += a[y * w + min(max(x, 0), w - 1)] }
            for x in 0..<w {
                tmp[y * w + x] = acc / Float(2 * r + 1)
                acc += a[y * w + min(x + r + 1, w - 1)] - a[y * w + max(x - r, 0)]
            }
        }
        for x in 0..<w {
            var acc: Float = 0
            for y in -r...r { acc += tmp[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = acc / Float(2 * r + 1)
                acc += tmp[min(y + r + 1, h - 1) * w + x] - tmp[max(y - r, 0) * w + x]
            }
        }
        return out
    }

    /// Edge strength (Sobel)
    private func edgeMap() -> [Float] {
        if let e = edges { return e }
        var lum = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { let c = color(i); lum[i] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var e = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            let gx = lum[i - w + 1] + 2 * lum[i + 1] + lum[i + w + 1] - lum[i - w - 1] - 2 * lum[i - 1] - lum[i + w - 1]
            let gy = lum[i + w - 1] + 2 * lum[i + w] + lum[i + w + 1] - lum[i - w - 1] - 2 * lum[i - w] - lum[i - w + 1]
            e[i] = sqrt(gx * gx + gy * gy)
        } }
        edges = e
        return e
    }

    /// Magnetic lasso: moves a source-coordinate point to the strongest edge within the radius
    func snap(_ p: CGPoint, radius: CGFloat) -> CGPoint {
        guard let (cx, cy) = cell(p) else { return p }
        let e = edgeMap(), r = max(Int(radius * k), 2)
        var best = cy * w + cx, bv: Float = e[best]
        for dy in -r...r { for dx in -r...r where dx * dx + dy * dy <= r * r {
            let x = cx + dx, y = cy + dy
            guard x >= 0, x < w, y >= 0, y < h else { continue }
            // Slight penalty with distance from center (so it follows the mouse)
            let v = e[y * w + x] * (1 - 0.3 * Float(dx * dx + dy * dy) / Float(r * r))
            if v > bv { bv = v; best = y * w + x }
        } }
        return bv > 0.05 ? native(best % w, best / w) : p
    }

    /// Saves a grayscale mask as PNG into the layer image folder (covering the whole source)
    func save(_ mask: [UInt8]) -> String? {
        var data = mask
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return try? LayerImageStore.importData(png, ext: "png")
    }

    /// Saved mask image → buffer (continuing quick selection)
    func load(_ file: String) -> [UInt8]? {
        guard let img = NSImage(contentsOf: LayerImageStore.url(file)),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }
}

/// Saved selections (alpha channels)
struct SavedSelection: Equatable, Codable {
    var name: String
    var mask: LayerMask
}

extension MainWindowController {
    // MARK: - Selection target and combining

    /// Combine mode from modifiers: ⇧ add, ⌥ subtract, ⇧⌥ intersect. Otherwise the mode chosen in options.
    func selectionOp(_ flags: NSEvent.ModifierFlags) -> MaskCombo.Op? {
        let sh = flags.contains(.shift), op = flags.contains(.option)
        if sh && op { return .intersect }
        if sh { return .add }
        if op { return .subtract }
        return MaskCombo.Op(rawValue: UserDefaults.standard.string(forKey: "selection.mode") ?? "")
    }

    /// Layer receiving the selection: the selected adjustment layer, else a new "선택" layer
    func selectionTarget() -> Int? {
        guard var s = photo?.settings else { return nil }
        if let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), !s.layers[i].isGroup { return i }
        var l = AdjustLayer(name: "선택 \(s.layers.count + 1)")
        l.mask.kind = .full
        s.layers.append(l)
        apply(s, dragging: false)
        layersTab.select(l.id)
        return photo?.settings.layers.firstIndex { $0.id == l.id }
    }

    /// Puts a new shape into the selection. Replaces if no combine or the selection was empty; otherwise add/subtract/intersect
    func commitSelection(_ newMask: LayerMask, flags: NSEvent.ModifierFlags, label: String) {
        if mode == .studio { addToSelection(newMask, flags: flags); return }
        guard let i = selectionTarget(), var s = photo?.settings else { return }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        let op = selectionOp(flags)
        var m = s.layers[i].mask
        let empty = m.kind == .full && (m.combos ?? []).isEmpty
        if let op, !empty {
            m.combos = (m.combos ?? []) + [MaskCombo(op: op, mask: newMask)]
        } else {
            var n = newMask
            // Refinement values (feather, expand, etc.) are kept
            n.feather = m.feather; n.grow = m.grow; n.border = m.border; n.smooth = m.smooth
            n.contrast = m.contrast; n.shiftEdge = m.shiftEdge; n.refine = m.refine
            n.lumaMin = m.lumaMin; n.lumaMax = m.lumaMax; n.lumaSoft = m.lumaSoft
            m = n
        }
        s.layers[i].mask = m
        replaceSettings(s, recordUndo: true, label: label)
    }

    // MARK: - Pixel-based selections

    var selectionEngine: SelectionEngine? {
        guard let doc = photo else { return nil }
        let key = "\(doc.url.path)#\(doc.settings.hashValueForSelection)"
        if let (k, e) = selectionEngineCache, k == key { return e }
        let e = SelectionEngine(doc: doc)
        selectionEngineCache = e.map { (key, $0) }
        return e
    }

    func wandSelect(at p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let eng = selectionEngine else { NSSound.beep(); return }
        let tol = Float(UserDefaults.standard.object(forKey: "wand.tolerance") as? Double ?? 32)
        let contiguous = UserDefaults.standard.object(forKey: "wand.contiguous") as? Bool ?? true
        guard let file = eng.save(eng.wand(at: p, tolerance: tol, contiguous: contiguous)) else { return }
        var m = LayerMask(); m.kind = .image; m.maskFile = file
        commitSelection(m, flags: flags, label: "자동 선택")
    }

    func quickSelect(_ pts: [CGPoint], flags: NSEvent.ModifierFlags) {
        if mode == .studio { studioQuickSelect(pts, flags: flags); return }
        guard let eng = selectionEngine, let i = selectionTarget(), var s = photo?.settings else { NSSound.beep(); return }
        var base = [UInt8](repeating: 0, count: eng.w * eng.h)
        let cur = s.layers[i].mask
        if cur.kind == .image, let old = eng.load(cur.maskFile), (cur.combos ?? []).isEmpty { base = old }
        eng.quickGrow(pts, radius: CGFloat(layersTab.brushRadius), into: &base, subtract: flags.contains(.option))
        guard let file = eng.save(base) else { return }
        s.layers[i].mask.kind = .image
        s.layers[i].mask.maskFile = file
        replaceSettings(s, recordUndo: true, label: "빠른 선택")
    }

    @objc func selectFocusArea(_ sender: Any?) {
        guard let eng = selectionEngine else { NSSound.beep(); return }
        let t = Float(UserDefaults.standard.object(forKey: "focus.threshold") as? Double ?? 0.25)
        guard let file = eng.save(eng.focusArea(threshold: t)) else { return }
        var m = LayerMask(); m.kind = .image; m.maskFile = file; m.smooth = 20
        commitSelection(m, flags: [], label: "초점 영역")
    }

    func colorRangeSelect(at p: CGPoint, flags: NSEvent.ModifierFlags) {
        if mode == .studio { studioColorRange(at: p, flags: flags); return }
        guard let eng = selectionEngine, let (x, y) = eng.cell(p) else { NSSound.beep(); return }
        let i = y * eng.w + x
        let c = [eng.rgb[i * 3], eng.rgb[i * 3 + 1], eng.rgb[i * 3 + 2]]
        let fuzz = Float(UserDefaults.standard.object(forKey: "colorRange.fuzz") as? Double ?? 0.25)
        guard let t = selectionTarget(), var s = photo?.settings else { return }
        s.layers[t].mask.colorRange = c + [fuzz]
        replaceSettings(s, recordUndo: true, label: "색상 범위")
    }

    func rowColumnSelect(at p: CGPoint, column: Bool, flags: NSEvent.ModifierFlags) {
        guard let doc = photo else { return }
        let n = doc.nativeSize
        var m = LayerMask(); m.kind = .rect
        let y = p.y.rounded(.down), x = p.x.rounded(.down)
        m.box = column ? [x, 0, x + 1, n.height] : [0, y, n.width, y + 1]
        commitSelection(m, flags: flags, label: column ? "열 선택" : "행 선택")
    }

    // MARK: - Select menu

    func editSelected(_ label: String, _ f: (inout LayerMask) -> Void) {
        if mode == .studio {
            guard var m = studioSelection else { NSSound.beep(); return }
            f(&m)
            studioSelection = m
            return
        }
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        f(&s.layers[i].mask)
        replaceSettings(s, recordUndo: true, label: label)
    }

    func askNumber(_ title: String, _ def: Double) -> Double? {
        if ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] != nil { return def }
        let a = NSAlert()
        a.messageText = title
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        f.doubleValue = def
        a.accessoryView = f
        a.addButton(withTitle: "확인"); a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn ? f.doubleValue : nil
    }

    @objc func invertSelection(_ sender: Any?) { editSelected("선택 반전") { $0.invert.toggle() } }
    @objc func deselectAll(_ sender: Any?) {
        if mode == .studio { studioSelection = nil; return }
        editSelected("선택 해제") { m in
            m.kind = .full; m.combos = nil; m.invert = false; m.colorRange = nil
        }
    }
    @objc func expandSelection(_ sender: Any?) {
        guard let v = askNumber("선택 확장 (원본 픽셀)", 10) else { return }
        editSelected("선택 확장") { $0.grow = ($0.grow ?? 0) + abs(v) }
    }
    @objc func contractSelection(_ sender: Any?) {
        guard let v = askNumber("선택 축소 (원본 픽셀)", 10) else { return }
        editSelected("선택 축소") { $0.grow = ($0.grow ?? 0) - abs(v) }
    }
    @objc func featherSelection(_ sender: Any?) {
        guard let v = askNumber("선택 페더 (원본 픽셀)", 20) else { return }
        editSelected("선택 페더") { $0.feather = max(v, 0) }
    }
    @objc func borderSelection(_ sender: Any?) {
        guard let v = askNumber("테두리 폭 (원본 픽셀)", 20) else { return }
        editSelected("선택 테두리") { $0.border = max(v, 0) }
    }
    @objc func smoothSelection(_ sender: Any?) {
        guard let v = askNumber("매끄럽게 (원본 픽셀)", 10) else { return }
        editSelected("선택 매끄럽게") { $0.smooth = max(v, 0) }
    }

    // MARK: - Save / load selection (alpha channels)

    @objc func saveSelection(_ sender: Any?) {
        if mode == .studio {
            guard let sel = studioSelection, var s = photo?.settings else { NSSound.beep(); return }
            s.channels = (s.channels ?? []) + [SavedSelection(name: "알파 \((s.channels?.count ?? 0) + 1)", mask: sel)]
            replaceSettings(s, recordUndo: true, label: "선택 저장")
            return
        }
        guard var s = photo?.settings, let id = layersTab.selectedID, let l = s.layers.first(where: { $0.id == id }) else { NSSound.beep(); return }
        let name = "알파 \((s.channels?.count ?? 0) + 1)"
        s.channels = (s.channels ?? []) + [SavedSelection(name: name, mask: l.mask)]
        replaceSettings(s, recordUndo: true, label: "선택 저장")
    }

    /// Loads a saved selection onto the selected layer (op: nil replaces, otherwise combines)
    func loadSelection(_ i: Int, op: MaskCombo.Op?) {
        guard let ch = photo?.settings.channels, ch.indices.contains(i) else { return }
        var m = ch[i].mask
        m.combos = nil   // Combined shapes can't have combines → if it has combines, replace
        if (ch[i].mask.combos ?? []).isEmpty, let op {
            let f: NSEvent.ModifierFlags = op == .add ? .shift : (op == .subtract ? .option : [.shift, .option])
            commitSelection(m, flags: f, label: "선택 불러오기")
        } else {
            guard let t = selectionTarget(), var s = photo?.settings else { return }
            s.layers[t].mask = ch[i].mask
            replaceSettings(s, recordUndo: true, label: "선택 불러오기")
        }
    }

    func channelsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("지금 선택을 알파 채널로 저장", modifiers: []) { [weak self] in self?.saveSelection(nil) })
        let ch = photo?.settings.channels ?? []
        if !ch.isEmpty { m.addItem(.separator()) }
        for (i, c) in ch.enumerated() {
            let item = NSMenuItem(title: c.name, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem("불러오기 (바꾸기)", modifiers: []) { [weak self] in self?.loadSelection(i, op: nil) })
            sub.addItem(ClosureMenuItem("더하기", modifiers: []) { [weak self] in self?.loadSelection(i, op: .add) })
            sub.addItem(ClosureMenuItem("빼기", modifiers: []) { [weak self] in self?.loadSelection(i, op: .subtract) })
            sub.addItem(ClosureMenuItem("교차", modifiers: []) { [weak self] in self?.loadSelection(i, op: .intersect) })
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem("지우기", modifiers: []) { [weak self] in
                guard let self, var s = self.photo?.settings, var c = s.channels else { return }
                c.remove(at: i); s.channels = c.isEmpty ? nil : c
                self.replaceSettings(s, recordUndo: true, label: "알파 채널 지우기")
            })
            item.submenu = sub
            m.addItem(item)
        }
        return m
    }

    // MARK: - Quick mask, Select and Mask

    /// Quick mask (Q): shows the selected layer's mask as a red overlay and edits it with a brush (outside the selection is red)
    @objc func toggleQuickMask(_ sender: Any?) {
        guard let id = layersTab.selectedID else { NSSound.beep(); return }
        if canvas.maskLayerID == id, canvas.maskStyle == 4 {
            canvas.maskLayerID = nil; canvas.maskStyle = 0
            enterTool(.pan)
        } else {
            canvas.maskLayerID = id; canvas.maskStyle = 4
            enterTool(.mask)
        }
    }

    @objc func showSelectAndMask(_ sender: Any?) {
        guard layersTab.selectedID != nil else { NSSound.beep(); return }
        let panel = selectAndMaskPanel ?? SelectAndMaskPanel(host: self)
        selectAndMaskPanel = panel
        panel.sync()
        panel.showWindow(nil)
    }
}

extension DevelopSettings {
    /// Values deciding whether pixel selection must be recomputed (geometry excluded)
    var hashValueForSelection: Int {
        var flat = self
        flat.adoptGeometry(from: DevelopSettings())
        return (try? JSONEncoder().encode(flat)).map { $0.hashValue } ?? 0
    }
}

/// Select and Mask workspace: view mode + refine edge values
final class SelectAndMaskPanel: NSWindowController {
    private weak var host: MainWindowController?
    private let view = NSPopUpButton()
    private var rows: [(WritableKeyPath<LayerMask, Double?>, SliderRow)] = []

    init(host: MainWindowController) {
        self.host = host
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420), styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = "선택 및 마스크"
        w.isFloatingPanel = true
        super.init(window: w)
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view.addItems(withTitles: ["보기: 빨간 막 (선택 영역)", "보기: 흑백", "보기: 검정 위", "보기: 흰색 위", "보기: 빨간 막 (선택 밖, 퀵 마스크)"])
        view.target = self; view.action = #selector(viewChanged)
        stack.addArrangedSubview(view)
        let specs: [(String, WritableKeyPath<LayerMask, Double?>, Double, Double)] = [
            ("가장자리 다듬기 반경 (머리카락)", \.refine, 0, 200), ("매끄럽게", \.smooth, 0, 100),
            ("대비", \.contrast, 0, 100), ("가장자리 이동 (%)", \.shiftEdge, -100, 100), ("확장(+)·축소(−)", \.grow, -200, 200),
        ]
        for (t, key, lo, hi) in specs {
            let row = SliderRow(label: t, min: lo, max: hi, format: "%.0f", defaultValue: 0)
            row.onChange = { [weak self] v, d in self?.set(key, v, d) }
            rows.append((key, row))
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        let feather = SliderRow(label: "페더", min: 0, max: 300, format: "%.0f", defaultValue: 0)
        feather.onChange = { [weak self] v, d in
            guard let h = self?.host, var s = h.photo?.settings, let id = h.layersTab.selectedID,
                  let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
            s.layers[i].mask.feather = v
            if d { h.apply(s, dragging: true) } else { h.replaceSettings(s, recordUndo: true, label: "페더") }
        }
        featherRow = feather
        stack.addArrangedSubview(feather)
        feather.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        w.contentView = stack
    }
    required init?(coder: NSCoder) { fatalError() }
    private var featherRow: SliderRow?

    func sync() {
        guard let h = host, let id = h.layersTab.selectedID, let l = h.photo?.settings.layers.first(where: { $0.id == id }) else { return }
        for (key, row) in rows { row.value = l.mask[keyPath: key] ?? 0 }
        featherRow?.value = l.mask.feather
        h.canvas.maskLayerID = id
        if h.canvas.maskStyle == 0 { h.canvas.maskStyle = 0 }
        view.selectItem(at: h.canvas.maskStyle)
    }

    private func set(_ key: WritableKeyPath<LayerMask, Double?>, _ v: Double, _ dragging: Bool) {
        guard let h = host, var s = h.photo?.settings, let id = h.layersTab.selectedID,
              let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        s.layers[i].mask[keyPath: key] = abs(v) < 0.001 ? nil : v
        if dragging { h.apply(s, dragging: true) } else { h.replaceSettings(s, recordUndo: true, label: "선택 다듬기") }
    }

    @objc private func viewChanged() {
        guard let h = host else { return }
        h.canvas.maskLayerID = h.layersTab.selectedID
        h.canvas.maskStyle = view.indexOfSelectedItem
    }
}

/// Layer-edit selection tool options: combine mode, per-tool values, refine selection buttons
final class SelectionOptionsView: NSStackView {
    private weak var host: MainWindowController?
    private let modePopup = NSPopUpButton()
    private let toolBox = NSStackView()
    private let hint = NSTextField(wrappingLabelWithString: "")

    init(host: MainWindowController) {
        self.host = host
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        modePopup.addItems(withTitles: ["새 선택", "선택에 더하기", "선택에서 빼기", "선택과 교차"])
        modePopup.controlSize = .small
        modePopup.target = self; modePopup.action = #selector(modeChanged)
        let mode = UserDefaults.standard.string(forKey: "selection.mode") ?? ""
        modePopup.selectItem(at: ["", "add", "subtract", "intersect"].firstIndex(of: mode) ?? 0)
        toolBox.orientation = .vertical
        toolBox.alignment = .leading
        toolBox.spacing = 8
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "⇧ 누르고 하면 더하기, ⌥ 빼기, ⇧⌥ 교차. ⌘A 전체, ⌘D 해제, ⇧⌘I 반전.\n선택한 뒤 ⌫는 고른 레이어에서 그 부분을 지우고, ⌘J는 그 부분을 새 레이어로 복제합니다. 새 조정·칠 레이어는 선택 영역에만 걸립니다."
        for v in [modePopup, toolBox, hint, buttons()] as [NSView] {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func modeChanged() {
        UserDefaults.standard.set(["", "add", "subtract", "intersect"][modePopup.indexOfSelectedItem], forKey: "selection.mode")
    }

    private func slider(_ t: String, key: String, _ lo: Double, _ hi: Double, _ def: Double, fmt: String = "%.0f", display: Double = 1) -> SliderRow {
        let r = SliderRow(label: t, min: lo, max: hi, format: fmt, display: display, defaultValue: def)
        r.value = UserDefaults.standard.object(forKey: key) as? Double ?? def
        r.onChange = { v, _ in UserDefaults.standard.set(v, forKey: key) }
        return r
    }

    func show(tool: String) {
        toolBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var views: [NSView] = []
        switch tool {
        case "selWand":
            views.append(slider("허용치", key: "wand.tolerance", 0, 255, 32))
            let c = NSButton(checkboxWithTitle: "인접 영역만", target: self, action: #selector(contiguousChanged(_:)))
            c.state = (UserDefaults.standard.object(forKey: "wand.contiguous") as? Bool ?? true) ? .on : .off
            views.append(c)
        case "selColor":
            views.append(slider("허용량", key: "colorRange.fuzz", 0.02, 1, 0.25, display: 100))
            views.append(note("고를 색을 누릅니다. 그 색에 가까운 곳이 선택됩니다 (고른 레이어의 마스크에 곱한다)."))
        case "selQuick", "aiRemove", "smartErase", "selObject":
            let r = SliderRow(label: "붓 크기 (원본 픽셀)", min: 5, max: 1500, format: "%.0f", defaultValue: 120)
            r.value = host?.layersTab.brushRadius ?? 120
            r.onChange = { [weak self] v, _ in self?.host?.layersTab.brushRadius = v; self?.host?.canvas.maskOverlay.brushRadius = v }
            views.append(r)
            let notes = [
                "aiRemove": "지울 것을 붓으로 덮어 칠하세요. 손을 떼면 AI가 둘레에 맞춰 지운 레이어를 만듭니다 (원본은 그대로, 이 맥 안에서만).",
                "smartErase": "지울 것을 대충 칠하세요. 칠한 곳과 색이 비슷한 둘레까지 넓혀 함께 지웁니다.",
                "selObject": "고를 개체를 둘러 칠하세요. 칠한 범위 안의 개체를 AI가 찾아 선택 레이어로 만듭니다.",
            ]
            views.append(note(notes[tool] ?? "칠하면 비슷한 곳까지 선택이 번집니다. ⌥를 누르고 칠하면 뺍니다."))
        case "selMagnetic":
            views.append(note("가장자리를 따라 끌면 선이 가장자리에 달라붙습니다. 손을 떼면 닫힙니다."))
        case "selPolygon":
            views.append(note("누를 때마다 꼭짓점을 찍습니다. 첫 점을 누르거나 두 번 누르면 닫힙니다."))
        case "selRow", "selColumn":
            views.append(note("누른 자리의 가로(세로) 1픽셀 줄을 고릅니다."))
        default:
            views.append(note("끌어서 고릅니다."))
        }
        views.append(slider("초점 영역 한계값", key: "focus.threshold", 0.02, 0.9, 0.25, fmt: "%.0f", display: 100))
        let focus = NSButton(title: "초점 영역 선택", target: host, action: #selector(MainWindowController.selectFocusArea(_:)))
        focus.bezelStyle = .appPush; focus.controlSize = .small
        views.append(focus)
        for v in views {
            toolBox.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: toolBox.widthAnchor).isActive = true
        }
    }

    @objc private func contiguousChanged(_ b: NSButton) { UserDefaults.standard.set(b.state == .on, forKey: "wand.contiguous") }

    private func note(_ t: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: t)
        n.font = .systemFont(ofSize: 11)
        n.textColor = .secondaryLabelColor
        return n
    }

    private func buttons() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        let items: [(String, Selector)] = [("전체 선택", #selector(MainWindowController.selectAllStudio(_:))),
                                           ("해제", #selector(MainWindowController.deselectAll(_:))),
                                           ("반전", #selector(MainWindowController.invertSelection(_:))),
                                           ("새 레이어로", #selector(MainWindowController.duplicateLayerOrBackground(_:))),
                                           ("확장…", #selector(MainWindowController.expandSelection(_:))),
                                           ("축소…", #selector(MainWindowController.contractSelection(_:))),
                                           ("페더…", #selector(MainWindowController.featherSelection(_:))),
                                           ("매끄럽게…", #selector(MainWindowController.smoothSelection(_:)))]
        var row: NSStackView?
        for (i, (t, sel)) in items.enumerated() {
            if i % 2 == 0 { row = NSStackView(); row?.distribution = .fillEqually; grid.addArrangedSubview(row!)
                row!.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
            let b = NSButton(title: t, target: host, action: sel)
            b.bezelStyle = .appPush; b.controlSize = .small
            row?.addArrangedSubview(b)
        }
        let ch = NSPopUpButton(frame: .zero, pullsDown: true)
        ch.addItem(withTitle: "알파 채널 (선택 저장·불러오기)")
        ch.controlSize = .small
        ch.menu?.delegate = ChannelsMenuDelegate.shared
        grid.addArrangedSubview(ch)
        ch.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        return grid
    }
}

/// Fills the alpha channel menu when it opens (the first item is the pull-down title)
final class ChannelsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ChannelsMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Keep only the pull-down button's title item (no action or submenu). It's absent from the menu bar submenu
        let title = menu.items.first.flatMap { $0.action == nil && $0.submenu == nil ? $0 : nil }
        menu.removeAllItems()
        if let title { menu.addItem(title) }
        guard let w = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        for item in w.channelsMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }
}
