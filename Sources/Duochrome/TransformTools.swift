import AppKit
import CoreImage
import Vision

/// Point-drag layer for reshaping: free transform corners, warp grid, puppet pins, perspective crop, vanishing point planes, adaptive wide angle lines, liquify brush.
/// All points are in the caller's coordinates (source or displayed image); toView/fromView convert to view coordinates.
final class PointsOverlayView: NSView {
    enum Style { case quad, grid4, pins, strokes }
    var style: Style = .quad { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var points: [CGPoint] = [] { didSet { needsDisplay = true } }
    /// Original pin positions (dimmed dots in pin mode)
    var anchors: [CGPoint] = []
    var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    var hint = ""
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    var onChange: ((Int, CGPoint, Bool) -> Void)?
    var onAdd: ((CGPoint) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onStroke: (([CGPoint], NSEvent.ModifierFlags) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Brush radius (view pixels, brush-mode cursor)
    var brushRadius: CGFloat = 0 { didSet { window?.invalidateCursorRects(for: self) } }
    /// Brush strokes (liquify) get the brush circle as the pointer, point handles the crosshair
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: style == .strokes ? BrushCursor.make(viewRadius: brushRadius) : .crosshair)
    }

    private var grabbed: Int?
    private var current: [CGPoint] = []
    /// Brush mode: pressure at each position of the last stroke (1 for a mouse)
    private(set) var lastPressures: [Double] = []
    private var pressures: [Double] = []
    private func pressure(_ e: NSEvent) -> Double { e.subtype == .tabletPoint ? Double(max(e.pressure, 0.02)) : 1 }
    private var mouse: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { mouse = convert(event.locationInWindow, from: nil); if style == .strokes { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let toView else { return }
        let v = points.map(toView)
        let line = NSBezierPath()
        switch style {
        case .quad where v.count == 4:
            line.move(to: v[0]); v.dropFirst().forEach { line.line(to: $0) }; line.close()
        case .grid4 where v.count == 16:
            for r in 0 ..< 4 { line.move(to: v[r * 4]); for c in 1 ..< 4 { line.line(to: v[r * 4 + c]) } }
            for c in 0 ..< 4 { line.move(to: v[c]); for r in 1 ..< 4 { line.line(to: v[r * 4 + c]) } }
        default: break
        }
        line.lineWidth = 1
        NSColor.white.setStroke(); line.stroke()
        line.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke(); line.stroke()
        for (i, a) in anchors.map(toView).enumerated() where i < v.count {
            let l = NSBezierPath(); l.move(to: a); l.line(to: v[i]); NSColor.systemYellow.withAlphaComponent(0.7).setStroke(); l.stroke()
            NSColor.white.withAlphaComponent(0.4).setFill(); NSBezierPath(ovalIn: NSRect(x: a.x - 3, y: a.y - 3, width: 6, height: 6)).fill()
        }
        for p in v {
            let r = NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
            NSColor.black.withAlphaComponent(0.7).setStroke(); NSBezierPath(ovalIn: r).stroke()
        }
        for s in strokes + (current.isEmpty ? [] : [current]) {
            let pv = s.map(toView)
            guard let f = pv.first else { continue }
            let l = NSBezierPath(); l.move(to: f); pv.dropFirst().forEach { l.line(to: $0) }
            l.lineWidth = 2; NSColor.systemOrange.setStroke(); l.stroke()
        }
        if style == .strokes, brushRadius > 256, let m = mouse {   // smaller brushes: the pointer is the circle
            let c = NSBezierPath(ovalIn: NSRect(x: m.x - brushRadius, y: m.y - brushRadius, width: brushRadius * 2, height: brushRadius * 2))
            NSColor.white.setStroke(); c.stroke()
        }
        if !hint.isEmpty {
            (hint as NSString).draw(at: NSPoint(x: 12, y: bounds.maxY - 24), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let toView, let fromView else { return }
        let p = convert(event.locationInWindow, from: nil)
        if style == .strokes { current = [fromView(p)]; pressures = [pressure(event)]; return }
        let near = points.map(toView).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 10 }
        if let i = near, event.modifierFlags.contains(.option), style == .pins { onRemove?(i); return }
        if let i = near { grabbed = i; return }
        if style == .pins { onAdd?(fromView(p)); grabbed = points.count - 1 }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fromView else { return }
        let p = fromView(convert(event.locationInWindow, from: nil))
        mouse = convert(event.locationInWindow, from: nil)
        if style == .strokes { current.append(p); pressures.append(pressure(event)); needsDisplay = true; return }
        guard let i = grabbed else { return }
        onChange?(i, p, true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let fromView else { return }
        let p = fromView(convert(event.locationInWindow, from: nil))
        if style == .strokes {
            lastPressures = pressures
            if current.count >= 1 { onStroke?(current, event.modifierFlags) }
            current = []; needsDisplay = true; return
        }
        if let i = grabbed { onChange?(i, p, false) }
        grabbed = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onCommit?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}

extension MainWindowController {
    // MARK: - Shared: showing the point layer

    /// Point layer in source coordinates
    func beginPoints(style: PointsOverlayView.Style, points: [CGPoint], hint: String, native: Bool = true) -> PointsOverlayView {
        let o = canvas.pointsOverlay
        o.style = style
        o.points = points
        o.anchors = []
        o.strokes = []
        o.hint = hint
        o.onChange = nil; o.onAdd = nil; o.onRemove = nil; o.onStroke = nil
        if native {
            o.toView = { [weak self] p in guard let self, let d = self.photo else { return p }; return self.canvas.viewPoint(forImage: d.toDisplay(p)) }
            o.fromView = { [weak self] p in guard let self, let d = self.photo else { return p }; return d.toNative(self.canvas.imagePoint(at: p)) }
        } else {
            o.toView = { [weak self] p in self?.canvas.viewPoint(forImage: p) ?? p }
            o.fromView = { [weak self] p in self?.canvas.imagePoint(at: p) ?? p }
        }
        enterTool(.points)
        window?.makeFirstResponder(o)
        if mode == .studio {
            // Layer editor: the instruction goes to the bar at the bottom of the canvas, with cancel · done
            retouchEditor.canvasBar.show(hint, [("취소", { [weak o] in o?.onCancel?() }), ("완료", { [weak o] in o?.onCommit?() })])
            o.hint = ""
        }
        return o
    }

    func endPoints() {
        canvas.pointsOverlay.onCommit = nil
        canvas.pointsOverlay.onCancel = nil
        if mode == .studio { retouchEditor.canvasBar.hide() }
        // Layer editor: back to the picked tool (so the canvas input matches the tool bar)
        if mode == .studio { retouchEditor.restoreTool() } else { enterTool(.pan) }
    }

    private func selectedImageLayer() -> (Int, AdjustLayer, Double)? {
        guard let s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }),
              let im = s.layers[i].image, !s.layers[i].locked, let src = Layers.sourceImage(im.file) else { return nil }
        return (i, s.layers[i], Double(src.extent.height / max(src.extent.width, 1)))
    }

    /// Changes without recording while editing; records "before → after" once on confirm
    private func liveEdit(_ before: DevelopSettings, _ f: (inout DevelopSettings) -> Void, dragging: Bool) {
        guard let doc = photo else { return }
        var s = doc.settings
        f(&s)
        doc.draft = dragging
        doc.settings = s
        canvas.needsDisplay = true
    }

    private func finish(_ before: DevelopSettings, keep: Bool, label: String) {
        guard let doc = photo else { return }
        let after = doc.settings
        doc.settings = before
        endPoints()
        if keep { replaceSettings(after, recordUndo: true, label: label) } else { apply(before, dragging: false) }
    }

    // MARK: - Free transform: skew · distort · perspective

    /// mode: 0 distort (free corners), 1 perspective (opposite corners mirrored), 2 skew (slides along edges)
    @objc func distortLayer(_ sender: Any?) { quadTransform(0) }
    @objc func perspectiveLayer(_ sender: Any?) { quadTransform(1) }
    @objc func skewLayer(_ sender: Any?) { quadTransform(2) }

    func quadTransform(_ mode: Int) {
        guard let doc = photo, let (i, layer, aspect) = selectedImageLayer(), let im = layer.image else { NSSound.beep(); return }
        let before = doc.settings
        var quad = Warp.corners(im, aspect: aspect)
        let names = ["왜곡", "원근", "기울이기"]
        let o = beginPoints(style: .quad, points: quad, hint: "\(names[mode]): 모서리를 끄세요 · 리턴 확정 · esc 취소")
        o.onChange = { [weak self] k, p, dragging in
            guard let self else { return }
            let old = quad[k]
            let d = CGPoint(x: p.x - old.x, y: p.y - old.y)
            switch mode {
            case 1:
                // mirror the other corner of the same horizontal edge (trapezoid)
                let pair = [1, 0, 3, 2][k]
                quad[k] = p
                quad[pair] = CGPoint(x: quad[pair].x - d.x, y: quad[pair].y + d.y)
            case 2:
                // move the neighboring corner of the same edge equally (parallelogram)
                let pair = [3, 2, 1, 0][k]
                quad[k] = p
                quad[pair] = CGPoint(x: quad[pair].x + d.x, y: quad[pair].y + d.y)
            default:
                quad[k] = p
            }
            o.points = quad
            self.liveEdit(before, { s in s.layers[i].image?.quad = quad.flatMap { [$0.x, $0.y] }; s.layers[i].image?.mesh = nil }, dragging: dragging)
        }
        o.onCommit = { [weak self] in self?.finish(before, keep: true, label: names[mode]) }
        o.onCancel = { [weak self] in self?.finish(before, keep: false, label: "") }
    }

    // MARK: - Warp (4×4 grid)

    @objc func warpLayer(_ sender: Any?) {
        guard let doc = photo, let (i, layer, aspect) = selectedImageLayer(), let im = layer.image else { NSSound.beep(); return }
        let before = doc.settings
        var mesh = im.mesh ?? Warp.identityMesh(im, aspect: aspect)
        let pts = { stride(from: 0, to: mesh.count, by: 2).map { CGPoint(x: mesh[$0], y: mesh[$0 + 1]) } }
        let o = beginPoints(style: .grid4, points: pts(), hint: "뒤틀기: 격자 점을 끄세요 · 리턴 확정 · esc 취소")
        o.onChange = { [weak self] k, p, dragging in
            mesh[k * 2] = p.x; mesh[k * 2 + 1] = p.y
            o.points = pts()
            self?.liveEdit(before, { s in s.layers[i].image?.mesh = mesh }, dragging: dragging)
        }
        o.onCommit = { [weak self] in self?.finish(before, keep: true, label: "뒤틀기") }
        o.onCancel = { [weak self] in self?.finish(before, keep: false, label: "") }
    }

    // MARK: - Puppet warp (pins)

    @objc func puppetWarp(_ sender: Any?) {
        guard let doc = photo, let (i, layer, _) = selectedImageLayer(), let im = layer.image else { NSSound.beep(); return }
        let before = doc.settings
        var pins = im.pins ?? []
        func targets() -> [CGPoint] { stride(from: 0, to: pins.count, by: 4).map { CGPoint(x: pins[$0 + 2], y: pins[$0 + 3]) } }
        func anchors() -> [CGPoint] { stride(from: 0, to: pins.count, by: 4).map { CGPoint(x: pins[$0], y: pins[$0 + 1]) } }
        let o = beginPoints(style: .pins, points: targets(), hint: "퍼펫: 눌러 핀 꽂기 · 핀 끌기 · ⌥ 누르기로 핀 빼기 · 리턴 확정")
        o.anchors = anchors()
        let push: (Bool) -> Void = { [weak self] dragging in
            o.points = targets(); o.anchors = anchors()
            self?.liveEdit(before, { s in s.layers[i].image?.pins = pins.isEmpty ? nil : pins }, dragging: dragging)
        }
        o.onAdd = { p in pins += [p.x, p.y, p.x, p.y]; push(false) }
        o.onRemove = { k in pins.removeSubrange(k * 4 ..< k * 4 + 4); push(false) }
        o.onChange = { k, p, dragging in pins[k * 4 + 2] = p.x; pins[k * 4 + 3] = p.y; push(dragging) }
        o.onCommit = { [weak self] in self?.finish(before, keep: true, label: "퍼펫 뒤틀기") }
        o.onCancel = { [weak self] in self?.finish(before, keep: false, label: "") }
    }

    // MARK: - Perspective crop

    @objc func perspectiveCrop(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let before = doc.settings
        // Undo perspective, show the whole frame, and pick four points (frame coordinates = displayed image coordinates)
        var bare = doc.settings
        bare.perspective = nil
        doc.settings = bare
        doc.showFullFrame = true
        canvas.zoomToFit()
        let f = doc.frameSize
        var quad = Geometry.perspectiveQuad(before) ?? [CGPoint(x: f.width * 0.1, y: f.height * 0.1), CGPoint(x: f.width * 0.9, y: f.height * 0.1),
                                                         CGPoint(x: f.width * 0.9, y: f.height * 0.9), CGPoint(x: f.width * 0.1, y: f.height * 0.9)]
        let o = beginPoints(style: .quad, points: quad, hint: "원근 자르기: 네 점을 반듯해야 할 면의 모서리에 · 리턴 확정 · esc 취소", native: false)
        o.onChange = { k, p, _ in quad[k] = p; o.points = quad }
        let done: (Bool) -> Void = { [weak self] keep in
            guard let self, let doc = self.photo else { return }
            doc.showFullFrame = false
            doc.settings = before
            self.endPoints()
            if keep {
                var s = before
                s.perspective = quad.flatMap { [$0.x, $0.y] }
                s.crop = CropRect()
                self.replaceSettings(s, recordUndo: true, label: "원근 자르기")
            } else { self.apply(before, dragging: false) }
            self.canvas.zoomToFit()
        }
        o.onCommit = { done(true) }
        o.onCancel = { done(false) }
    }

    @objc func clearPerspectiveCrop(_ sender: Any?) {
        guard var s = photo?.settings, s.perspective != nil else { NSSound.beep(); return }
        s.perspective = nil
        replaceSettings(s, recordUndo: true, label: "원근 자르기 풀기")
        canvas.zoomToFit()
    }

    // MARK: - Canvas size · trim · image size

    @objc func canvasSize(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        var s = doc.settings
        let f = doc.frameSize
        let w = (f.width * s.crop.w).rounded(), h = (f.height * s.crop.h).rounded()
        let a = NSAlert()
        a.messageText = "캔버스 크기"
        a.informativeText = String(format: "지금 %.0f × %.0f px. 늘린 만큼 둘레에 여백을 둡니다 (크롭은 그대로).", w, h)
        let p = s.canvasPad ?? [0, 0, 0, 0]
        let fields = ["왼쪽", "아래", "오른쪽", "위"].enumerated().map { i, t -> (NSTextField, NSStackView) in
            let f = NSTextField(string: String(format: "%.0f", p[i] * (i % 2 == 0 ? w : h)))
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return (f, NSStackView(views: [NSTextField(labelWithString: t + " (px)"), f]))
        }
        let color = NSPopUpButton(); color.addItems(withTitles: ["투명", "흰색", "검정", "회색"])
        let st = NSStackView(views: fields.map(\.1) + [color]); st.orientation = .vertical; st.alignment = .trailing
        st.frame = NSRect(x: 0, y: 0, width: 220, height: 150)
        a.accessoryView = st
        a.addButton(withTitle: "적용"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = fields.enumerated().map { i, f in max(0, Double(f.0.stringValue) ?? 0) / (i % 2 == 0 ? w : h) }
        s.canvasPad = v.allSatisfy { $0 == 0 } ? nil : v
        s.canvasColor = [nil, [1, 1, 1], [0, 0, 0], [0.5, 0.5, 0.5]][color.indexOfSelectedItem]
        replaceSettings(s, recordUndo: true, label: "캔버스 크기")
        canvas.zoomToFit()
    }

    /// Trim: crops away transparent edges (or edges matching the top-left corner color if none)
    @objc func trimCanvas(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        var s = doc.settings
        s.canvasPad = nil
        let saved = doc.settings
        var full = s; full.crop = CropRect()
        doc.settings = full
        let img = doc.image(scale: 0.25)
        doc.settings = saved
        let r = img.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 2, h > 2 else { return }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(img, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
        let transparent = stride(from: 3, to: px.count, by: 4).contains { px[$0] < 0.01 }
        let c0 = SIMD4(px[0], px[1], px[2], px[3])
        func empty(_ i: Int) -> Bool {
            let c = SIMD4(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3])
            return transparent ? c.w < 0.01 : abs(c - c0).max() < 0.02
        }
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for y in 0 ..< h { for x in 0 ..< w where !empty(y * w + x) { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= x0, y1 >= y0 else { NSSound.beep(); return }
        // bitmap rows from the top
        s.crop = CropRect(CGRect(x: Double(x0) / Double(w), y: Double(h - 1 - y1) / Double(h),
                                 width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h)))
        replaceSettings(s, recordUndo: true, label: "캔버스 다듬기")
        canvas.zoomToFit()
    }

    @objc func imageSize(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        var s = doc.settings
        let cur = doc.pixelSize
        let a = NSAlert()
        a.messageText = "이미지 크기"
        a.informativeText = String(format: "지금 %.0f × %.0f px. 내보낼 때 이 크기로 다시 계산합니다 (비율 유지). 0이면 그대로.", cur.width, cur.height)
        let wf = NSTextField(string: String(format: "%.0f", s.outputSize?.first ?? 0))
        let rs = NSPopUpButton(); rs.addItems(withTitles: ["란초스 (부드럽게 줄이기)", "바이큐빅", "세부 유지 (키울 때)", "최근접 (픽셀 그대로)"])
        rs.selectItem(at: s.resample ?? 0)
        let st = NSStackView(views: [NSStackView(views: [NSTextField(labelWithString: "가로 (px)"), wf]), rs]); st.orientation = .vertical
        st.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        a.accessoryView = st
        a.addButton(withTitle: "적용"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let w = Double(wf.stringValue) ?? 0
        s.outputSize = w > 0 ? [w, (w * Double(cur.height / cur.width)).rounded()] : nil
        s.resample = rs.indexOfSelectedItem
        replaceSettings(s, recordUndo: true, label: "이미지 크기")
    }

    // MARK: - Content-aware scale

    @objc func contentAwareScale(_ sender: Any?) {
        guard photo != nil else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "내용 인식 비율"
        a.informativeText = "중요한 곳(가장자리가 많은 곳)은 두고 빈 곳을 줄여 새 이미지 레이어로 만듭니다."
        let wf = NSTextField(string: "80"), hf = NSTextField(string: "100")
        let st = NSStackView(views: [NSStackView(views: [NSTextField(labelWithString: "가로 %"), wf]), NSStackView(views: [NSTextField(labelWithString: "세로 %"), hf])])
        st.orientation = .vertical; st.frame = NSRect(x: 0, y: 0, width: 200, height: 56)
        a.accessoryView = st
        a.addButton(withTitle: "만들기"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn, var s = photo?.settings else { return }
        let target: AdjustLayer? = layersTab.selectedID.flatMap { id in s.layers.first { $0.id == id && $0.isImage } }
        guard let src = target.map({ var l = $0; l.mask = LayerMask(); l.opacity = 1; l.group = nil; return rasterize([l], withPhoto: false) }) ?? rasterize(s.layers, withPhoto: true) else { return }
        window?.subtitle = "내용 인식 비율 계산 중…"
        guard let out = SeamCarver.scale(src, widthFactor: (Double(wf.stringValue) ?? 100) / 100, heightFactor: (Double(hf.stringValue) ?? 100) / 100),
              var l = imageLayer(from: out.composited(over: CIImage(color: .clear).cropped(to: src.extent)), name: "내용 인식 비율") else { return }
        // center at the new size
        let n = photo!.nativeSize
        l.image?.width = out.extent.width
        l.image?.height = out.extent.height
        l.image?.cx = n.width / 2; l.image?.cy = n.height / 2
        if let file = l.image?.file, let cg = Render.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Render.displaySpace),
           let f2 = PSDImport.writeImage(cg) {
            try? FileManager.default.removeItem(at: LayerImageStore.url(file))
            l.image?.file = f2
        }
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "내용 인식 비율")
        layersTab.select(l.id)
        window?.subtitle = ""
    }

    // MARK: - Adaptive wide angle: trace lines that should be straight to find lens distortion

    @objc func adaptiveWideAngle(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let before = doc.settings
        var lines: [[CGPoint]] = []
        let o = beginPoints(style: .strokes, points: [], hint: "적응형 광각: 곧아야 할 가장자리를 따라 그리세요 (2개 이상) · ⇧로 그리면 세로선 · 리턴 계산 · esc 취소")
        var verticals: [Int] = []
        o.onStroke = { pts, flags in
            guard pts.count >= 3 else { return }
            if flags.contains(.shift) { verticals.append(lines.count) }
            lines.append(pts)
            o.strokes = lines
        }
        o.onCommit = { [weak self] in
            guard let self, lines.count >= 1 else { self?.finish(before, keep: false, label: ""); return }
            var s = before
            s.lensDistortion = Self.solveDistortion(lines, s, native: doc.nativeSize)
            self.endPoints()
            // With vertical lines, keystone too (line end points)
            if !verticals.isEmpty {
                let segs = verticals.map { i -> (CGPoint, CGPoint) in
                    let l = lines[i].map { Self.undistort($0, from: before.lensDistortion, to: s.lensDistortion, native: doc.nativeSize) }
                    return (doc.toDisplay(l.first!), doc.toDisplay(l.last!))
                }
                let r = Geometry.solveVerticals(segs, s, native: doc.nativeSize, fullFrame: false)
                s.keystoneV = r.keystoneV; s.rotation = r.rotation
            }
            self.replaceSettings(s, recordUndo: true, label: "적응형 광각")
        }
        o.onCancel = { [weak self] in self?.finish(before, keep: false, label: "") }
    }

    /// Source-coordinate point corrected with the current distortion (k0) → its position when corrected with another distortion (k1)
    static func undistort(_ p: CGPoint, from k0: Float, to k1: Float, native: CGSize) -> CGPoint {
        let c = CGPoint(x: native.width / 2, y: native.height / 2), R = hypot(native.width, native.height) / 2
        func params(_ k: Float) -> (Double, Double) { let kk = Double(k) / 100 * 0.15; return (kk, kk > 0 ? 1 / (1 + kk) : 1) }
        // corrected position q → captured (distorted) position g = c + d(1 + k r²)·norm
        let (ka, na) = params(k0)
        let d = CGPoint(x: (p.x - c.x) / R, y: (p.y - c.y) / R)
        let r2 = Double(d.x * d.x + d.y * d.y)
        let g = CGPoint(x: Double(d.x) * (1 + ka * r2) * na, y: Double(d.y) * (1 + ka * r2) * na)
        // Solve g = e(1 + kb |e|²)·nb for e (a few Newton steps)
        let (kb, nb) = params(k1)
        let gr = hypot(g.x, g.y)
        guard gr > 1e-9 else { return p }
        var er = gr
        for _ in 0 ..< 8 {
            let f = er * (1 + kb * er * er) * nb - gr, df = (1 + 3 * kb * er * er) * nb
            er -= f / max(df, 1e-6)
        }
        let s = er / gr
        return CGPoint(x: c.x + g.x * s * R, y: c.y + g.y * s * R)
    }

    /// Distortion value that makes the lines straightest (searches −100–100 coarse → fine)
    static func solveDistortion(_ lines: [[CGPoint]], _ s: DevelopSettings, native: CGSize) -> Float {
        func cost(_ k: Float) -> Double {
            var total = 0.0
            for l in lines {
                let p = l.map { undistort($0, from: s.lensDistortion, to: k, native: native) }
                // mean squared distance from the line joining the end points (divided by length)
                guard let a = p.first, let b = p.last else { continue }
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                for q in p { let d = ((b.x - a.x) * (a.y - q.y) - (a.x - q.x) * (b.y - a.y)) / len; total += Double(d * d) / Double(len * len) }
            }
            return total
        }
        var best: Float = s.lensDistortion, bc = cost(best), step: Float = 10
        var lo: Float = -100, hi: Float = 100
        for _ in 0 ..< 4 {
            var k = lo
            while k <= hi { let c = cost(k); if c < bc { bc = c; best = k }; k += step }
            lo = max(-100, best - step); hi = min(100, best + step); step /= 5
        }
        return best
    }

    // MARK: - Vanishing point: perspective-correct cloning within a plane

    @objc func vanishingPoint(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let n = doc.nativeSize
        let before = doc.settings
        var plane = Geometry.pointsFrom(doc.settings.vanishingPlane) ?? [CGPoint(x: n.width * 0.3, y: n.height * 0.3), CGPoint(x: n.width * 0.7, y: n.height * 0.3),
                                                                         CGPoint(x: n.width * 0.7, y: n.height * 0.7), CGPoint(x: n.width * 0.3, y: n.height * 0.7)]
        let o = beginPoints(style: .quad, points: plane, hint: "소실점 1/2: 벽면(평면)의 네 모서리를 맞추세요 · 리턴 다음")
        o.onChange = { k, p, _ in plane[k] = p; o.points = plane }
        o.onCancel = { [weak self] in self?.finish(before, keep: false, label: "") }
        o.onCommit = { [weak self] in
            guard let self else { return }
            var s = before
            s.vanishingPlane = plane.flatMap { [$0.x, $0.y] }
            self.photo?.settings = s
            // Two steps: source position (⌥-click) and destination (click)
            var source: CGPoint?
            let o2 = self.beginPoints(style: .pins, points: [], hint: "소실점 2/2: ⌥ 눌러 복제할 원본 자리 → 눌러 붙일 자리 (붓 크기 = 레이어 탭 붓 크기) · 리턴 끝")
            o2.onAdd = { [weak self] p in
                guard let self else { return }
                if NSEvent.modifierFlags.contains(.option) || source == nil {
                    source = p; o2.anchors = [p]; o2.points = [p]; return
                }
                guard let src = source else { return }
                self.vanishingClone(from: src, to: p, plane: plane, radius: self.layersTab.brushRadius)
                o2.points = [src]
            }
            o2.onCommit = { [weak self] in
                guard let self, let doc = self.photo else { return }
                let after = doc.settings
                doc.settings = before
                self.endPoints()
                self.replaceSettings(after, recordUndo: true, label: "소실점")
            }
            o2.onCancel = o2.onCommit
        }
    }

    /// Moves the source patch to the destination in the rectified plane space, then back into perspective, pasted as an image layer
    func vanishingClone(from a: CGPoint, to b: CGPoint, plane: [CGPoint], radius: Double) {
        guard let doc = photo, let base = rasterize(doc.settings.layers, withPhoto: true) else { return }
        let n = doc.nativeSize
        // plane → unit square space (size S)
        let S: CGFloat = 2000
        let toFlat = Homography(from: plane, to: [CGPoint(x: 0, y: 0), CGPoint(x: S, y: 0), CGPoint(x: S, y: S), CGPoint(x: 0, y: S)])
        let fa = toFlat.apply(a), fb = toFlat.apply(b)
        let fromFlat = toFlat.inverse
        // Plane-space translation T = (fb - fa) → composite homography in source space: fromFlat · T · toFlat
        let shift = Homography(m: [1, 0, Double(fb.x - fa.x), 0, 1, Double(fb.y - fa.y), 0, 0, 1])
        func mul(_ x: Homography, _ y: Homography) -> Homography {
            var m = [Double](repeating: 0, count: 9)
            for r in 0 ..< 3 { for c in 0 ..< 3 { m[r * 3 + c] = (0 ..< 3).reduce(0) { $0 + x.m[r * 3 + $1] * y.m[$1 * 3 + c] } } }
            return Homography(m: m)
        }
        let H = mul(fromFlat, mul(shift, toFlat))
        let e = CGRect(origin: .zero, size: n)
        let c = [CGPoint(x: 0, y: 0), CGPoint(x: n.width, y: 0), CGPoint(x: n.width, y: n.height), CGPoint(x: 0, y: n.height)].map(H.apply)
        let moved = base.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputBottomLeft": CIVector(cgPoint: c[0]), "inputBottomRight": CIVector(cgPoint: c[1]),
            "inputTopRight": CIVector(cgPoint: c[2]), "inputTopLeft": CIVector(cgPoint: c[3])]).cropped(to: e)
        // Only around the destination (a circle distorted by perspective: a plane-space circle mapped to the source)
        let rf = radius * Double(S) / Double(max(hypot(plane[1].x - plane[0].x, plane[1].y - plane[0].y), 1))
        let ring = (0 ..< 48).map { i -> CGPoint in
            let t = Double(i) / 48 * 2 * .pi
            return fromFlat.apply(CGPoint(x: fb.x + CGFloat(cos(t) * rf), y: fb.y + CGFloat(sin(t) * rf)))
        }
        var l = AdjustLayer(name: "소실점 복제")
        l.kind = "image"
        guard let full = imageLayer(from: moved.composited(over: CIImage(color: .clear).cropped(to: e)), name: "소실점 복제") else { return }
        l = full
        l.mask = LayerMask(kind: .polygon, polygon: ring.flatMap { [Double($0.x), Double($0.y)] }, feather: radius * 0.25)
        guard var s = photo?.settings else { return }
        s.layers.append(l)
        photo?.settings = s
        canvas.needsDisplay = true
    }

    // MARK: - Liquify

    /// tool: 0 forward warp, 1 bloat, 2 pucker, 3 twirl clockwise, 4 counterclockwise, 5 reconstruct
    func liquify(tool: Int) {
        guard photo != nil else { NSSound.beep(); return }
        let names = ["밀기", "부풀리기", "오목", "돌리기", "반시계 돌리기", "되돌리기"]
        let o = beginPoints(style: .strokes, points: [], hint: "유동화 (\(names[tool])): 끌어 칠하기 · 붓 크기 [ ] · 리턴·esc 끝")
        o.brushRadius = CGFloat(layersTab.brushRadius) * canvas.zoom
        o.onStroke = { [weak self] pts, flags in
            guard let self, var s = self.photo?.settings else { return }
            // On the first stroke: if the selected layer isn't an image layer, make the current look into one
            if self.layersTab.selectedID.flatMap({ id in s.layers.first { $0.id == id && $0.isImage } }) == nil {
                guard let img = self.rasterize(s.layers, withPhoto: true), let l = self.imageLayer(from: img, name: "유동화") else { return }
                s.layers.append(l)
                self.replaceSettings(s, recordUndo: true, label: "유동화 레이어")
                self.layersTab.select(l.id)
            }
            guard var s2 = self.photo?.settings, let id = self.layersTab.selectedID, let i = s2.layers.firstIndex(where: { $0.id == id }) else { return }
            let t = flags.contains(.option) && tool == 3 ? 4 : tool
            var st = LiquifyStroke(tool: t, points: pts.flatMap { [Double($0.x), Double($0.y)] }, radius: self.layersTab.brushRadius)
            st.strength = self.layersTab.brushFlow * 0.8
            s2.layers[i].liquify = (s2.layers[i].liquify ?? []) + [st]
            self.replaceSettings(s2, recordUndo: true, label: "유동화 \(names[t])")
            o.strokes = []
        }
        o.onCommit = { [weak self] in self?.endPoints() }
        o.onCancel = { [weak self] in self?.endPoints() }
    }

    @objc func liquifyPush(_ sender: Any?) { liquify(tool: 0) }
    @objc func liquifyBloat(_ sender: Any?) { liquify(tool: 1) }
    @objc func liquifyPucker(_ sender: Any?) { liquify(tool: 2) }
    @objc func liquifyTwirl(_ sender: Any?) { liquify(tool: 3) }
    @objc func liquifyReconstruct(_ sender: Any?) { liquify(tool: 5) }

    /// Face-aware liquify: builds strokes for eye size, face width, chin, and smile from Vision face landmarks
    @objc func faceAwareLiquify(_ sender: Any?) {
        guard let doc = photo, var s = photo?.settings else { NSSound.beep(); return }
        let img = doc.nativePreview(scale: 0.25)
        let e = img.extent
        guard let cg = Render.context.createCGImage(img, from: e) else { return }
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        let faces = req.results ?? []
        guard !faces.isEmpty else {
            let a = NSAlert(); a.messageText = "얼굴을 찾지 못했습니다"; a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "얼굴 인식 유동화 (얼굴 \(faces.count)개)"
        let sliders = ["눈 크기", "얼굴 폭", "턱 높이", "미소"].map { t -> (NSSlider, NSStackView) in
            let sl = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
            sl.widthAnchor.constraint(equalToConstant: 180).isActive = true
            return (sl, NSStackView(views: [NSTextField(labelWithString: t), sl]))
        }
        let st = NSStackView(views: sliders.map(\.1)); st.orientation = .vertical; st.alignment = .trailing
        st.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
        a.accessoryView = st
        a.addButton(withTitle: "적용"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = sliders.map { $0.0.doubleValue / 100 }
        let n = doc.nativeSize
        func nat(_ p: CGPoint, _ box: CGRect) -> CGPoint {
            // landmarks are 0–1 inside the face box; the box is 0–1 inside the image (bottom is 0)
            CGPoint(x: (box.minX + p.x * box.width) * n.width, y: (box.minY + p.y * box.height) * n.height)
        }
        var strokes: [LiquifyStroke] = []
        for f in faces {
            let box = f.boundingBox
            let fw = box.width * n.width
            guard let lm = f.landmarks else { continue }
            func center(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
                guard let pts = r?.normalizedPoints, !pts.isEmpty else { return nil }
                let c = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return nat(CGPoint(x: c.x / CGFloat(pts.count), y: c.y / CGFloat(pts.count)), box)
            }
            if v[0] != 0 {
                for eye in [lm.leftEye, lm.rightEye] {
                    if let c = center(eye) { strokes.append(LiquifyStroke(tool: v[0] > 0 ? 1 : 2, points: [c.x, c.y], radius: fw * 0.12, strength: abs(v[0]) * 0.5)) }
                }
            }
            if v[1] != 0, let contour = lm.faceContour?.normalizedPoints, contour.count > 4 {
                // Push both cheeks toward the center (narrower) or outward (wider)
                let mid = nat(CGPoint(x: 0.5, y: 0.45), box)
                for p in [contour[contour.count / 5], contour[contour.count * 4 / 5]] {
                    let q = nat(p, box)
                    let dir: CGFloat = v[1] < 0 ? 1 : -1
                    let to = CGPoint(x: q.x + (mid.x - q.x) * 0.12 * CGFloat(abs(v[1])) * dir, y: q.y)
                    strokes.append(LiquifyStroke(tool: 0, points: [q.x, q.y, to.x, to.y], radius: fw * 0.22, strength: 0.8))
                }
            }
            if v[2] != 0, let contour = lm.faceContour?.normalizedPoints, !contour.isEmpty {
                let chin = nat(contour[contour.count / 2], box)
                let to = CGPoint(x: chin.x, y: chin.y - CGFloat(v[2]) * box.height * n.height * 0.06)
                strokes.append(LiquifyStroke(tool: 0, points: [chin.x, chin.y, to.x, to.y], radius: fw * 0.25, strength: 0.8))
            }
            if v[3] != 0, let lips = lm.outerLips?.normalizedPoints, lips.count > 4 {
                let xs = lips.map(\.x)
                if let li = xs.firstIndex(of: xs.min()!), let ri = xs.firstIndex(of: xs.max()!) {
                    for k in [li, ri] {
                        let c = nat(lips[k], box)
                        let to = CGPoint(x: c.x, y: c.y + CGFloat(v[3]) * box.height * n.height * 0.03)
                        strokes.append(LiquifyStroke(tool: 0, points: [c.x, c.y, to.x, to.y], radius: fw * 0.08, strength: 0.8))
                    }
                }
            }
        }
        guard !strokes.isEmpty, let img2 = rasterize(s.layers, withPhoto: true), var l = imageLayer(from: img2, name: "얼굴 유동화") else { return }
        l.liquify = strokes
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "얼굴 인식 유동화")
        layersTab.select(l.id)
    }
}

extension Geometry {
    static func pointsFrom(_ v: [Double]?) -> [CGPoint]? {
        guard let v, v.count == 8 else { return nil }
        return (0 ..< 4).map { CGPoint(x: v[$0 * 2], y: v[$0 * 2 + 1]) }
    }
}

// MARK: - Seam carving (content-aware scale)

enum SeamCarver {
    /// Finds seams on a small image (1200 long side) to build a map of columns to keep; full resolution is re-read through that map
    static func scale(_ img: CIImage, widthFactor wf: Double, heightFactor hf: Double) -> CIImage? {
        var out = img
        if wf < 0.999 { guard let r = carve(out, factor: wf) else { return nil }; out = r }
        if hf < 0.999 {
            // Vertical is rotated 90° to work like horizontal
            let rot = out.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            let moved = rot.transformed(by: .init(translationX: -rot.extent.minX, y: -rot.extent.minY))
            guard let r = carve(moved, factor: hf) else { return nil }
            let back = r.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            out = back.transformed(by: .init(translationX: -back.extent.minX, y: -back.extent.minY))
        }
        return out
    }

    static let remapK = try? CIKernel(source: """
        kernel vec4 k(sampler s, sampler m, float k, float mw) {
            vec2 p = destCoord();
            // original column this column reads in the small map (small coordinates)
            float sx = sample(m, samplerTransform(m, vec2(clamp(p.x * k, 0.5, mw - 0.5), p.y * k))).r;
            return sample(s, samplerTransform(s, vec2(sx / k, p.y)));
        }
        """)

    static func carve(_ img: CIImage, factor: Double) -> CIImage? {
        let e = img.extent
        let k = min(1, 1200 / max(e.width, e.height))
        let small = img.transformed(by: .init(scaleX: k, y: k))
        let sr = small.extent.integral
        let w = Int(sr.width), h = Int(sr.height)
        guard w > 8, h > 8 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: sr, format: .RGBAf, colorSpace: Render.displaySpace)
        var lum = [Float](repeating: 0, count: w * h)
        for i in 0 ..< w * h { lum[i] = 0.3 * px[i * 4] + 0.59 * px[i * 4 + 1] + 0.11 * px[i * 4 + 2] }
        // original index of the remaining columns per row
        // Importance: broadly spread luminance gradient (protects areas near edges too) + the gradient itself
        var grad = [Float](repeating: 0, count: w * h)
        for y in 1 ..< h - 1 { for x in 1 ..< w - 1 {
            grad[y * w + x] = abs(lum[y * w + x + 1] - lum[y * w + x - 1]) + abs(lum[(y + 1) * w + x] - lum[(y - 1) * w + x])
        } }
        let rad = max(10, w / 30)
        var spread = grad
        for _ in 0 ..< 2 {   // two horizontal/vertical box blurs ≈ smooth spread
            var t = spread
            for y in 0 ..< h { var acc: Float = 0
                for x in 0 ..< w + rad { if x < w { acc += spread[y * w + x] }; if x - 2 * rad - 1 >= 0 { acc -= spread[y * w + x - 2 * rad - 1] }
                    let cx = x - rad; if cx >= 0 && cx < w { t[y * w + cx] = acc / Float(2 * rad + 1) } } }
            spread = t
            for x in 0 ..< w { var acc: Float = 0
                for y in 0 ..< h + rad { if y < h { acc += t[y * w + x] }; if y - 2 * rad - 1 >= 0 { acc -= t[(y - 2 * rad - 1) * w + x] }
                    let cy = y - rad; if cy >= 0 && cy < h { spread[cy * w + x] = acc / Float(2 * rad + 1) } } }
        }
        let importance = (0 ..< w * h).map { grad[$0] + spread[$0] * 4 }
        var cols = [[Int]](repeating: Array(0 ..< w), count: h)
        let remove = Int(Double(w) * (1 - factor))
        var cw = w
        for _ in 0 ..< remove {
            // energy: neighbor differences
            var energy = [Float](repeating: 0, count: cw * h)
            for y in 0 ..< h { for x in 0 ..< cw {
                let c = lum[y * w + cols[y][x]]
                let l = lum[y * w + cols[y][max(x - 1, 0)]], r = lum[y * w + cols[y][min(x + 1, cw - 1)]]
                let u = y > 0 ? lum[(y - 1) * w + cols[y - 1][min(x, cw - 1)]] : c, d = y < h - 1 ? lum[(y + 1) * w + cols[y + 1][min(x, cw - 1)]] : c
                energy[y * cw + x] = abs(l - r) + abs(u - d) + importance[y * w + cols[y][x]]
            } }
            // dynamic programming
            var cost = energy
            var back = [Int](repeating: 0, count: cw * h)
            for y in 1 ..< h { for x in 0 ..< cw {
                var best = cost[(y - 1) * cw + x], bi = x
                if x > 0, cost[(y - 1) * cw + x - 1] < best { best = cost[(y - 1) * cw + x - 1]; bi = x - 1 }
                if x < cw - 1, cost[(y - 1) * cw + x + 1] < best { best = cost[(y - 1) * cw + x + 1]; bi = x + 1 }
                cost[y * cw + x] += best; back[y * cw + x] = bi
            } }
            var x = (0 ..< cw).min { cost[(h - 1) * cw + $0] < cost[(h - 1) * cw + $1] } ?? 0
            for y in stride(from: h - 1, through: 0, by: -1) {
                cols[y].remove(at: x)
                if y > 0 { x = back[y * cw + x] }
            }
            cw -= 1
        }
        // Map image (top row first = same order as the small bitmap) → in CI the top row is large y
        var map = [Float](repeating: 0, count: cw * h * 4)
        for y in 0 ..< h { for x in 0 ..< cw { map[(y * cw + x) * 4] = Float(cols[y][x]) + 0.5; map[(y * cw + x) * 4 + 3] = 1 } }
        let data = map.withUnsafeBufferPointer { Data(buffer: $0) }
        let mapImg = CIImage(bitmapData: data, bytesPerRow: cw * 16, size: CGSize(width: cw, height: h), format: .RGBAf, colorSpace: nil)
        let outW = (Double(e.width) * Double(cw) / Double(w)).rounded()
        let out = CGRect(x: 0, y: 0, width: outW, height: e.height)
        let src = img.transformed(by: .init(translationX: -e.minX, y: -e.minY))
        return remapK?.apply(extent: out, roiCallback: { i, r in i == 0 ? src.extent : mapImg.extent },
                             arguments: [src.clampedToExtent(), mapImg.samplingNearest(), k, Float(cw)])?.cropped(to: out)
    }
}
