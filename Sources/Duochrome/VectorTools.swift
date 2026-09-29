import AppKit

// MARK: - Pen, shape, and text tools. The canvas layer is PathOverlayView in Vector.swift.

/// Values carried across tools (selected path, pen mode, shape options)
final class VectorToolState {
    static let shared = VectorToolState()
    /// Pen mode: 0 pen, 1 freeform pen, 2 curvature pen, 3 direct selection
    var penKind = 0
    /// Pen output: 0 path, 1 shape layer, 2 vector mask
    var penTarget = 0
    /// Path id selected in the Paths panel
    var pathID: String?
    // shape tool
    var preset = VectorPath.Preset.rect
    /// Custom shape: this path fitted to the box (instead of a preset)
    var customPathID: String?
    var fillOn = true
    var fill: [Float] = [0.92, 0.92, 0.92]
    var strokeOn = false
    var stroke: [Float] = [0.1, 0.1, 0.1]
    var strokeWidth = 8.0
    var strokeAlign = 0
    var dashed = false
    var radius = 40.0
    var sides = 6
    var inner = 0.45
    // text tool
    var font = "AppleSDGothicNeo-Bold"
    var color: [Float] = [1, 1, 1]
}

extension MainWindowController {
    private var vs: VectorToolState { .shared }

    /// Selected layer (if any)
    private var selectedLayer: (Int, AdjustLayer)? {
        guard let s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return nil }
        return (i, s.layers[i])
    }

    // MARK: Activating tools

    /// Activates the pen/shape/text tools
    func startVectorTool(_ id: String) {
        guard photo != nil else { enterTool(.pan); return }
        let o = canvas.pathOverlay
        o.toView = { [weak self] p in guard let self, let d = self.photo else { return p }; return self.canvas.viewPoint(forImage: d.toDisplay(p)) }
        o.fromView = { [weak self] p in guard let self, let d = self.photo else { return p }; return d.toNative(self.canvas.imagePoint(at: p)) }
        switch id {
        case "shape": o.mode = .shapeDrag
        case "text": o.mode = .textBox
        default: o.mode = [PathOverlayView.Mode.pen, .freePen, .curvature, .direct][max(0, min(3, vs.penKind))]
        }
        o.onChange = { [weak self] p, dragging in self?.storeEditedPath(p, dragging: dragging) }
        o.onFinish = { [weak self] in self?.finishPath() }
        o.onBox = { [weak self] r0 in
            guard let self else { return }
            // Snap box corners to guides, edges, and center
            let a = self.snapNative(CGPoint(x: r0.minX, y: r0.minY)), b = self.snapNative(CGPoint(x: r0.maxX, y: r0.maxY))
            let r = r0.width < 1 && r0.height < 1 ? CGRect(origin: a, size: .zero)
                : CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            if id == "shape" { self.createShape(in: r) } else if id == "text" { self.createText(in: r) }
        }
        refreshPathOverlay()
        enterTool(.path)
        window?.makeFirstResponder(o)
    }

    /// Shows the current target path and other paths on the editing layer
    func refreshPathOverlay() {
        let o = canvas.pathOverlay
        let s = photo?.settings
        o.path = editTargetPath() ?? VectorPath(name: "작업 패스")
        o.others = (s?.paths ?? []).filter { $0.id != o.path.id }
        penOptions.reloadPaths()
    }

    /// Path being edited: the selected shape layer for direct selection/shape targets, the selected layer's vector mask for mask targets, otherwise the Paths panel
    private func editTargetPath() -> VectorPath? {
        if let (_, l) = selectedLayer {
            if l.kind == "shape", let v = l.vector, vs.penTarget == 1 || vs.penKind == 3 || canvas.pathOverlay.mode == .shapeDrag { return v.path }
            if vs.penTarget == 2 { return l.mask.vector ?? VectorPath(name: "벡터 마스크") }
        }
        let paths = photo?.settings.paths ?? []
        return paths.first { $0.id == vs.pathID } ?? paths.first
    }

    /// Puts the editing layer's path into the document
    private func storeEditedPath(_ p: VectorPath, dragging: Bool) {
        guard var s = photo?.settings else { return }
        if let (i, l) = selectedLayer {
            if l.kind == "shape", l.vector?.path.id == p.id {
                s.layers[i].vector?.path = p
                apply(s, dragging: dragging); return
            }
            if vs.penTarget == 2, !p.isEmpty {
                guard !l.locked else { NSSound.beep(); return }
                s.layers[i].mask.vector = p
                apply(s, dragging: dragging); return
            }
        }
        if vs.penTarget == 1 {
            // As a shape layer: create the layer once two points exist, then edit that layer
            guard p.anchors.count >= 2 else { return }
            var l = AdjustLayer(name: "모양 \(s.layers.count + 1)")
            l.kind = "shape"
            l.vector = currentShapeStyle(p)
            s.layers.append(l)
            apply(s, dragging: dragging)
            layersTab.select(l.id)
            if mode == .studio { studioMode.layersPanel.reload() }
            return
        }
        var paths = s.paths ?? []
        if let k = paths.firstIndex(where: { $0.id == p.id }) { paths[k] = p } else {
            guard !p.anchors.isEmpty else { return }
            var n = p
            if n.name == "작업 패스", paths.contains(where: { $0.name == "작업 패스" }) { n.name = "패스 \(paths.count + 1)" }
            paths.append(n)
            vs.pathID = n.id
            canvas.pathOverlay.path.name = n.name
        }
        s.paths = paths
        apply(s, dragging: dragging)
        if !dragging { penOptions.reloadPaths() }
    }

    private func finishPath() {
        // Leave the finished path, and the next click starts a new path
        if canvas.pathOverlay.mode == .pen || canvas.pathOverlay.mode == .freePen || canvas.pathOverlay.mode == .curvature {
            if vs.penTarget == 0 { vs.pathID = canvas.pathOverlay.path.id }
        }
        penOptions.reloadPaths()
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// Starts a new path (Paths panel "새 패스")
    func newPath() {
        let p = VectorPath(name: "패스 \((photo?.settings.paths?.count ?? 0) + 1)")
        vs.pathID = p.id
        canvas.pathOverlay.path = p
        if canvas.tool != .path { studioMode.selectTool("pen") }
    }

    // MARK: Shapes

    func currentShapeStyle(_ p: VectorPath) -> VectorShape {
        var v = VectorShape(path: p)
        v.fill = vs.fillOn ? vs.fill : nil
        v.stroke = vs.strokeOn ? vs.stroke : nil
        v.strokeWidth = vs.strokeWidth
        v.strokeAlign = vs.strokeAlign
        v.dash = vs.dashed ? [vs.strokeWidth * 3, vs.strokeWidth * 2] : []
        return v
    }

    /// Creates a shape layer in the box dragged with the shape tool (a plain click gives 1/5 of the photo's long side)
    func createShape(in rect: CGRect) {
        guard let doc = photo, var s = photo?.settings else { return }
        var r = rect
        if r.width < 4 || r.height < 4 {
            let d = max(doc.nativeSize.width, doc.nativeSize.height) / 5
            r = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        }
        var path: VectorPath
        if let cid = vs.customPathID, let src = s.paths?.first(where: { $0.id == cid }), !src.isEmpty {
            // custom shape: fit the path to the box
            path = src
            path.id = UUID().uuidString
            let b = src.bounds
            let kx = r.width / max(b.width, 1), ky = r.height / max(b.height, 1)
            for i in path.anchors.indices {
                var a = path.anchors[i]
                func f(_ x: Double, _ y: Double) -> (Double, Double) { (Double(r.minX + (CGFloat(x) - b.minX) * kx), Double(r.minY + (CGFloat(y) - b.minY) * ky)) }
                (a.x, a.y) = f(a.x, a.y); (a.inX, a.inY) = f(a.inX, a.inY); (a.outX, a.outY) = f(a.outX, a.outY)
                path.anchors[i] = a
            }
            path.closed = true
        } else {
            path = VectorPath.preset(vs.preset, in: r, sides: vs.sides, radius: vs.radius, inner: vs.inner, weight: vs.strokeWidth)
        }
        var l = AdjustLayer(name: "\(vs.customPathID != nil ? "사용자 모양" : vs.preset.title) \(s.layers.count + 1)")
        l.kind = "shape"
        l.vector = currentShapeStyle(path)
        if vs.preset == .line && vs.customPathID == nil { l.vector?.fill = vs.strokeOn ? vs.stroke : vs.fill; l.vector?.stroke = nil }
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "모양 레이어")
        layersTab.select(l.id)
        if mode == .studio { studioMode.layersPanel.reload() }
        canvas.pathOverlay.path = path
        shapeOptions.sync()
    }

    /// Applies shape options to the selected shape layer
    func applyShapeOptionsToSelection() {
        guard var s = photo?.settings, let (i, l) = selectedLayer, l.kind == "shape", let v = l.vector else { return }
        var n = currentShapeStyle(v.path)
        if n == v { return }
        n.path = v.path
        s.layers[i].vector = n
        apply(s, dragging: false)
    }

    // MARK: Paths panel actions

    func selectedPath() -> VectorPath? {
        photo?.settings.paths?.first { $0.id == vs.pathID } ?? (canvas.pathOverlay.path.anchors.isEmpty ? nil : canvas.pathOverlay.path)
    }

    func deletePath(_ id: String) {
        guard var s = photo?.settings else { return }
        s.paths?.removeAll { $0.id == id }
        if vs.pathID == id { vs.pathID = s.paths?.first?.id }
        replaceSettings(s, recordUndo: true, label: "패스 지우기")
        refreshPathOverlay()
    }

    func renamePath(_ id: String, to name: String) {
        guard var s = photo?.settings, let k = s.paths?.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        s.paths?[k].name = name
        replaceSettings(s, recordUndo: true, label: "패스 이름")
        penOptions.reloadPaths()
    }

    /// Make selection: an adjustment layer with the path interior as a lasso mask
    func pathToSelection() {
        guard let p = selectedPath(), p.anchors.count >= 3, let doc = photo else { NSSound.beep(); return }
        layersTab.addLayer(.polygon, native: doc.nativeSize)
        guard var s = photo?.settings, let i = s.layers.indices.last else { return }
        s.layers[i].mask.polygon = p.flattened(step: 6).flatMap { [Double($0.x), Double($0.y)] }
        s.layers[i].name = "\(p.name) 선택"
        replaceSettings(s, recordUndo: true, label: "패스를 선택으로")
        layersTab.sync(s)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// Fill: a shape layer filling the path shape (no stroke)
    func fillPath() {
        guard let p = selectedPath(), p.anchors.count >= 3, var s = photo?.settings else { NSSound.beep(); return }
        var q = p; q.id = UUID().uuidString; q.closed = true
        var l = AdjustLayer(name: "\(p.name) 칠")
        l.kind = "shape"
        l.vector = VectorShape(path: q, fill: vs.fill, stroke: nil)
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "패스 칠하기")
        layersTab.select(l.id)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// Stroke: paints along the path with the current brush (paint layer)
    func strokePath() {
        guard let p = selectedPath(), p.anchors.count >= 2 else { NSSound.beep(); return }
        var pts = p.flattened(step: 3)
        if p.closed, let f = pts.first { pts.append(f) }
        layersTab.select(nil)
        paintStroke(pts, pressures: pts.map { _ in 1 }, erase: false)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// To shape layer: a shape layer with the shape options (fill, stroke)
    func pathToShapeLayer() {
        guard let p = selectedPath(), p.anchors.count >= 2, var s = photo?.settings else { NSSound.beep(); return }
        var q = p; q.id = UUID().uuidString
        var l = AdjustLayer(name: "\(p.name) 모양")
        l.kind = "shape"
        l.vector = currentShapeStyle(q)
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "패스를 모양 레이어로")
        layersTab.select(l.id)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// To vector mask: the path as the selected layer's vector mask
    func pathToVectorMask() {
        guard let p = selectedPath(), p.anchors.count >= 3, var s = photo?.settings, let (i, l) = selectedLayer else { NSSound.beep(); return }
        guard !l.locked else { NSSound.beep(); return }
        var q = p; q.closed = true
        s.layers[i].mask.vector = q
        replaceSettings(s, recordUndo: true, label: "벡터 마스크")
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    func removeVectorMask() {
        guard var s = photo?.settings, let (i, l) = selectedLayer, l.mask.vector != nil else { NSSound.beep(); return }
        s.layers[i].mask.vector = nil
        replaceSettings(s, recordUndo: true, label: "벡터 마스크 지우기")
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    // MARK: Text

    /// Text tool: click for single-line text, drag for paragraph (box) text
    func createText(in rect: CGRect) {
        guard let doc = photo, var s = photo?.settings else { return }
        // Drags shorter than 12 screen pixels count as clicks
        let minBox = 12 / max(canvas.zoom, 0.001)
        let size = Double(max(doc.nativeSize.width, doc.nativeSize.height)) / 20
        var t = LayerText(string: "글자", font: TextRender.resolveFont(vs.font), size: size, color: vs.color,
                          x: Double(rect.minX), y: Double(rect.minY), align: 0)
        if rect.width > minBox && rect.height > minBox {
            t.boxWidth = Double(rect.width); t.boxHeight = Double(rect.height)
            t.x = Double(rect.minX); t.y = Double(rect.maxY)
            t.string = "단락 글자를 여기에 씁니다."
        }
        var l = AdjustLayer(name: "글자 \(s.layers.count + 1)")
        l.kind = "text"
        l.text = t
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "글자 레이어")
        layersTab.select(l.id)
        if mode == .studio { studioMode.layersPanel.reload() }
        textOptions.sync(focus: true)
    }

    /// Edits the text of the selected text layer
    func editSelectedText(_ dragging: Bool = false, _ f: (inout LayerText) -> Void) {
        guard var s = photo?.settings, let (i, l) = selectedLayer, l.isText, var t = l.text else { return }
        guard !l.locked else { NSSound.beep(); return }
        f(&t)
        if t == l.text { return }
        s.layers[i].text = t
        // Text from PSD is drawn directly once edited instead of using the embedded image
        s.layers[i].image = nil
        if !dragging, l.name.hasPrefix("글자") || l.name == l.text?.string.prefix(20).description {
            s.layers[i].name = String(t.string.prefix(20)).replacingOccurrences(of: "\n", with: " ")
        }
        apply(s, dragging: dragging)
        if !dragging, mode == .studio { studioMode.layersPanel.reload() }
    }

    var selectedText: LayerText? { selectedLayer.flatMap { $0.1.isText ? $0.1.text : nil } }
}


// MARK: - Options panels

private func optionTitle(_ s: String) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .systemFont(ofSize: 13, weight: .semibold)
    return t
}

private func small(_ s: String) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .systemFont(ofSize: 11)
    t.textColor = .secondaryLabelColor
    return t
}

private func rgb(_ c: NSColor) -> [Float] {
    let s = c.usingColorSpace(.sRGB) ?? c
    return [Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)]
}

private func color(_ v: [Float]) -> NSColor {
    let c = v + [1, 1, 1]
    return NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
}

/// Shared by options panels: stacked vertically, filling the width
class VectorOptionsBase: NSStackView {
    weak var host: MainWindowController?
    init(host: MainWindowController) {
        self.host = host
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
    }
    required init?(coder: NSCoder) { fatalError() }
    func add(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    func button(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .appPush
        b.controlSize = .small
        b.toolTip = tip
        return b
    }
}

/// Pen tool options + Paths panel
final class PenOptionsView: VectorOptionsBase {
    private let kind = NSSegmentedControl(labels: ["펜", "자유 펜", "곡률 펜", "직접 선택"], trackingMode: .selectOne, target: nil, action: nil)
    private let target = NSPopUpButton()
    private let list = NSStackView()
    private let nameField = NSTextField()

    override init(host: MainWindowController) {
        super.init(host: host)
        add(optionTitle("펜"))
        kind.segmentDistribution = .fillEqually
        kind.controlSize = .small
        kind.target = self
        kind.action = #selector(kindChanged)
        add(kind)
        target.addItems(withTitles: ["결과: 패스", "결과: 모양 레이어", "결과: 벡터 마스크 (고른 레이어)"])
        target.controlSize = .small
        target.target = self
        target.action = #selector(targetChanged)
        add(target)
        let hint = NSTextField(wrappingLabelWithString: "펜: 누르면 모난 점, 누른 채 끌면 곡선 점. 첫 점을 누르면 닫힙니다. 리턴·esc 끝, ⌫ 마지막 점 지우기.\n곡률 펜: 지나갈 점만 누릅니다. 직접 선택: 점·조절점을 끌고, ⌥누르기로 모난 점 ↔ 매끄러운 점.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        add(hint)

        add(optionTitle("패스"))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        add(list)
        nameField.placeholderString = "고른 패스 이름"
        nameField.controlSize = .small
        nameField.target = self
        nameField.action = #selector(renamed)
        add(nameField)
        let row1 = NSStackView(views: [button("새 패스", "새 패스를 그립니다", #selector(newPath)), button("지우기", "고른 패스 지우기", #selector(deletePath))])
        let row2 = NSStackView(views: [button("선택으로", "패스 안을 선택(올가미 마스크 레이어)으로", #selector(toSelection)),
                                       button("칠하기", "패스 모양을 채운 모양 레이어", #selector(fill))])
        let row3 = NSStackView(views: [button("획", "지금 붓으로 패스를 따라 칠합니다", #selector(stroke)),
                                       button("모양 레이어로", "모양 옵션을 입힌 모양 레이어", #selector(toShape))])
        let row4 = NSStackView(views: [button("벡터 마스크로", "고른 레이어에 벡터 마스크로", #selector(toMask)),
                                       button("마스크 빼기", "고른 레이어의 벡터 마스크 지우기", #selector(removeMask))])
        for r in [row1, row2, row3, row4] { r.spacing = 6; r.distribution = .fillEqually; add(r) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func sync() {
        let st = VectorToolState.shared
        kind.selectedSegment = st.penKind
        target.selectItem(at: st.penTarget)
        reloadPaths()
    }

    func reloadPaths() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let paths = host?.photo?.settings.paths ?? []
        let cur = VectorToolState.shared.pathID
        if paths.isEmpty {
            let t = small("아직 패스가 없습니다. 펜으로 그리면 여기에 쌓입니다.")
            list.addArrangedSubview(t)
        }
        for p in paths {
            let b = NSButton(title: "", target: self, action: #selector(pick(_:)))
            b.attributedTitle = NSAttributedString(string: (p.id == cur ? "● " : "○ ") + p.name + "  ·  점 \(p.anchors.count)\(p.closed ? " · 닫힘" : "")",
                                                   attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: p.id == cur ? NSColor.labelColor : NSColor.secondaryLabelColor])
            b.isBordered = false
            b.alignment = .left
            b.identifier = NSUserInterfaceItemIdentifier(p.id)
            list.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        nameField.stringValue = paths.first { $0.id == cur }?.name ?? ""
    }

    @objc private func kindChanged() {
        VectorToolState.shared.penKind = kind.selectedSegment
        host?.startVectorTool("pen")
    }
    @objc private func targetChanged() {
        VectorToolState.shared.penTarget = target.indexOfSelectedItem
        host?.startVectorTool("pen")
    }
    @objc private func pick(_ b: NSButton) {
        VectorToolState.shared.pathID = b.identifier?.rawValue
        host?.refreshPathOverlay()
    }
    @objc private func renamed() { if let id = VectorToolState.shared.pathID { host?.renamePath(id, to: nameField.stringValue) } }
    @objc private func newPath() { host?.newPath() }
    @objc private func deletePath() { if let id = VectorToolState.shared.pathID { host?.deletePath(id) } }
    @objc private func toSelection() { host?.pathToSelection() }
    @objc private func fill() { host?.fillPath() }
    @objc private func stroke() { host?.strokePath() }
    @objc private func toShape() { host?.pathToShapeLayer() }
    @objc private func toMask() { host?.pathToVectorMask() }
    @objc private func removeMask() { host?.removeVectorMask() }
}

/// Shape tool options
final class ShapeOptionsView: VectorOptionsBase {
    private let preset = NSPopUpButton()
    private let fillOn = NSButton(checkboxWithTitle: "채우기", target: nil, action: nil)
    private let fillWell = NSColorWell(style: .minimal)
    private let strokeOn = NSButton(checkboxWithTitle: "획", target: nil, action: nil)
    private let strokeWell = NSColorWell(style: .minimal)
    private let align = NSPopUpButton()
    private let dashed = NSButton(checkboxWithTitle: "점선", target: nil, action: nil)
    private let width = SliderRow(label: "획 두께 (원본 픽셀)", min: 0, max: 200, format: "%.0f", defaultValue: 8)
    private let radius = SliderRow(label: "모서리 반경", min: 0, max: 500, format: "%.0f", defaultValue: 40)
    private let sides = SliderRow(label: "변·꼭짓점 수", min: 3, max: 24, format: "%.0f", defaultValue: 6)
    private let inner = SliderRow(label: "별 안쪽 비율", min: 0.1, max: 0.95, format: "%.0f%%", display: 100, defaultValue: 0.45)

    override init(host: MainWindowController) {
        super.init(host: host)
        add(optionTitle("도형"))
        preset.controlSize = .small
        preset.target = self
        preset.action = #selector(presetChanged)
        add(preset)
        for w in [fillWell, strokeWell] {
            w.target = self; w.action = #selector(changed)
            w.widthAnchor.constraint(equalToConstant: 38).isActive = true
            w.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        for c in [fillOn, strokeOn, dashed] { c.controlSize = .small; c.target = self; c.action = #selector(changed) }
        align.addItems(withTitles: ["획: 가운데", "획: 안쪽", "획: 바깥쪽"])
        align.controlSize = .small
        align.target = self
        align.action = #selector(changed)
        let r1 = NSStackView(views: [fillOn, fillWell, NSView(), strokeOn, strokeWell])
        add(r1)
        add(NSStackView(views: [align, dashed]))
        for r in [width, radius, sides, inner] {
            r.onChange = { [weak self] _, d in if !d { self?.changed() } else { self?.store() } }
            add(r)
        }
        let hint = NSTextField(wrappingLabelWithString: "캔버스에서 끌어 모양 레이어를 만듭니다 (⇧ 정사각·정원). 모양을 고른 채 값을 바꾸면 그 레이어에 걸립니다. 점을 고치려면 펜 도구의 직접 선택을 쓰세요. 사용자 모양은 패스 패널의 패스를 씁니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        add(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    func sync() {
        let st = VectorToolState.shared
        preset.removeAllItems()
        for p in VectorPath.Preset.allCases { preset.addItem(withTitle: p.title) }
        let paths = host?.photo?.settings.paths ?? []
        if !paths.isEmpty {
            preset.menu?.addItem(.separator())
            for p in paths { preset.addItem(withTitle: "사용자 모양: \(p.name)"); preset.lastItem?.representedObject = p.id }
        }
        if let cid = st.customPathID, let item = preset.itemArray.first(where: { $0.representedObject as? String == cid }) {
            preset.select(item)
        } else { st.customPathID = nil; preset.selectItem(at: st.preset.rawValue) }
        // show the values of the selected shape layer if any
        if let host, let v = host.photo?.settings.layers.first(where: { $0.id == host.layersTab.selectedID && $0.kind == "shape" })?.vector {
            st.fillOn = v.fill != nil; if let f = v.fill { st.fill = f }
            st.strokeOn = v.stroke != nil; if let s = v.stroke { st.stroke = s }
            st.strokeWidth = v.strokeWidth; st.strokeAlign = v.strokeAlign; st.dashed = !v.dash.isEmpty
        }
        fillOn.state = st.fillOn ? .on : .off
        strokeOn.state = st.strokeOn ? .on : .off
        dashed.state = st.dashed ? .on : .off
        fillWell.color = color(st.fill)
        strokeWell.color = color(st.stroke)
        align.selectItem(at: st.strokeAlign)
        width.value = st.strokeWidth
        radius.value = st.radius
        sides.value = Double(st.sides)
        inner.value = st.inner
    }

    private func store() {
        let st = VectorToolState.shared
        st.fillOn = fillOn.state == .on
        st.strokeOn = strokeOn.state == .on
        st.dashed = dashed.state == .on
        st.fill = rgb(fillWell.color)
        st.stroke = rgb(strokeWell.color)
        st.strokeAlign = align.indexOfSelectedItem
        st.strokeWidth = width.value
        st.radius = radius.value
        st.sides = Int(sides.value.rounded())
        st.inner = inner.value
    }

    @objc private func presetChanged() {
        let st = VectorToolState.shared
        if let id = preset.selectedItem?.representedObject as? String { st.customPathID = id } else {
            st.customPathID = nil
            st.preset = VectorPath.Preset(rawValue: preset.indexOfSelectedItem) ?? .rect
        }
    }

    @objc private func changed() {
        store()
        host?.applyShapeOptionsToSelection()
    }
}

/// Text tool options (acting as the Character/Paragraph panels)
final class TextOptionsView: VectorOptionsBase, NSTextViewDelegate {
    private let textView = NSTextView()
    private let family = NSPopUpButton()
    private let style = NSPopUpButton()
    private let colorWell = NSColorWell(style: .minimal)
    private let alignSeg = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "왼쪽")!,
        NSImage(systemSymbolName: "text.aligncenter", accessibilityDescription: "가운데")!,
        NSImage(systemSymbolName: "text.alignright", accessibilityDescription: "오른쪽")!,
        NSImage(systemSymbolName: "text.justify", accessibilityDescription: "양쪽")!,
    ], trackingMode: .selectOne, target: nil, action: nil)
    private let vertical = NSButton(checkboxWithTitle: "세로쓰기", target: nil, action: nil)
    private let size = SliderRow(label: "크기 (원본 픽셀)", min: 4, max: 2000, format: "%.0f", defaultValue: 200)
    private let tracking = SliderRow(label: "자간", min: -200, max: 800, format: "%.0f", defaultValue: 0)
    private let leading = SliderRow(label: "줄 간격 (0 자동)", min: 0, max: 3000, format: "%.0f", defaultValue: 0)
    private let baseline = SliderRow(label: "기준선 이동", min: -500, max: 500, format: "%.0f", defaultValue: 0)
    private let hscale = SliderRow(label: "가로 비율", min: 20, max: 300, format: "%.0f%%", defaultValue: 100)
    private let rotation = SliderRow(label: "회전", min: -180, max: 180, format: "%.0f°", defaultValue: 0)
    private let boxW = SliderRow(label: "상자 너비 (0 한 줄)", min: 0, max: 10000, format: "%.0f", defaultValue: 0)
    private let warp = NSPopUpButton()
    private let bend = SliderRow(label: "구부리기", min: -100, max: 100, format: "%+.0f%%", defaultValue: 50)
    private let pathPopup = NSPopUpButton()
    private let pathOffset = SliderRow(label: "패스 위 시작 자리", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0)
    private let pathFlip = NSButton(checkboxWithTitle: "패스 반대쪽", target: nil, action: nil)
    private let styles = NSPopUpButton()
    private let styleName = NSTextField()
    private let substituted = small("")
    private var syncing = false

    override init(host: MainWindowController) {
        super.init(host: host)
        add(optionTitle("텍스트"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.delegate = self
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        // Put the scroll inside a box (the options panel doesn't wrap content that has its own scroll, so the window stretched)
        let holder = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: holder.topAnchor), scroll.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: holder.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            holder.heightAnchor.constraint(equalToConstant: 70),
        ])
        add(holder)
        family.controlSize = .small
        family.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        family.target = self
        family.action = #selector(familyChanged)
        style.controlSize = .small
        style.target = self
        style.action = #selector(styleChanged)
        add(family)
        colorWell.target = self
        colorWell.action = #selector(controlChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        add(NSStackView(views: [style, colorWell]))
        substituted.textColor = .systemOrange
        add(substituted)
        alignSeg.controlSize = .small
        alignSeg.target = self
        alignSeg.action = #selector(controlChanged)
        vertical.controlSize = .small
        vertical.target = self
        vertical.action = #selector(controlChanged)
        add(NSStackView(views: [alignSeg, vertical]))
        for r in [size, tracking, leading, baseline, hscale, rotation, boxW] {
            r.onChange = { [weak self] _, d in self?.changed(dragging: d) }
            add(r)
        }
        add(optionTitle("뒤틀기"))
        warp.controlSize = .small
        warp.addItems(withTitles: TextWarp.allCases.map(\.title))
        warp.target = self
        warp.action = #selector(controlChanged)
        add(warp)
        bend.onChange = { [weak self] _, d in self?.changed(dragging: d) }
        add(bend)
        add(optionTitle("패스 위 글자"))
        pathPopup.controlSize = .small
        pathPopup.target = self
        pathPopup.action = #selector(controlChanged)
        pathFlip.controlSize = .small
        pathFlip.target = self
        pathFlip.action = #selector(controlChanged)
        add(NSStackView(views: [pathPopup, pathFlip]))
        pathOffset.onChange = { [weak self] _, d in self?.changed(dragging: d) }
        add(pathOffset)
        add(optionTitle("문자·단락 스타일"))
        styles.controlSize = .small
        styles.target = self
        styles.action = #selector(applyStyle)
        add(styles)
        styleName.placeholderString = "새 스타일 이름"
        styleName.controlSize = .small
        let save = button("지금 모양 저장", "고른 글자의 글꼴·크기·색·자간·줄 간격·정렬을 스타일로", #selector(saveStyle))
        add(NSStackView(views: [styleName, save]))
        let hint = NSTextField(wrappingLabelWithString: "캔버스를 누르면 한 줄 글자, 끌면 단락 글자 상자를 만듭니다. 글자 레이어를 고르면 여기서 고칩니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        add(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the selected text layer's values
    func sync(focus: Bool = false) {
        syncing = true
        defer { syncing = false }
        let t = host?.selectedText
        let st = VectorToolState.shared
        textView.string = t?.string ?? ""
        textView.isEditable = t != nil
        let fontName = t?.font ?? st.font
        let fam = NSFont(name: fontName, size: 12)?.familyName ?? "Helvetica"
        family.selectItem(withTitle: fam)
        fillStyles(fam, select: fontName)
        substituted.stringValue = t.map { TextRender.isSubstituted($0.font) ? "글꼴 대체: \($0.font) → \(TextRender.resolveFont($0.font))" : "" } ?? ""
        substituted.isHidden = substituted.stringValue.isEmpty
        colorWell.color = color(t?.color ?? st.color)
        alignSeg.selectedSegment = t?.align ?? 0
        vertical.state = t?.vertical == true ? .on : .off
        size.value = t?.size ?? 200
        tracking.value = t?.tracking ?? 0
        leading.value = t?.leading ?? 0
        baseline.value = t?.baselineShift ?? 0
        hscale.value = t?.horizontalScale ?? 100
        rotation.value = t?.rotation ?? 0
        boxW.value = t?.boxWidth ?? 0
        warp.selectItem(at: t?.warp ?? 0)
        bend.value = t?.warpBend ?? 50
        pathPopup.removeAllItems()
        pathPopup.addItem(withTitle: "패스 없음")
        for p in host?.photo?.settings.paths ?? [] { pathPopup.addItem(withTitle: p.name); pathPopup.lastItem?.representedObject = p.id }
        if let op = t?.onPath, let item = pathPopup.itemArray.first(where: { ($0.representedObject as? String) == op.id }) { pathPopup.select(item) }
        pathOffset.value = t?.pathOffset ?? 0
        pathFlip.state = t?.pathFlip == true ? .on : .off
        styles.removeAllItems()
        styles.addItem(withTitle: "스타일 입히기…")
        for s in TextStyle.saved { styles.addItem(withTitle: s.name) }
        if focus, t != nil {
            window?.makeFirstResponder(textView)
            textView.selectAll(nil)
        }
    }

    private func fillStyles(_ fam: String, select name: String) {
        style.removeAllItems()
        for m in NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? [] {
            guard let ps = m.first as? String else { continue }
            style.addItem(withTitle: (m.count > 1 ? m[1] as? String : nil) ?? ps)
            style.lastItem?.representedObject = ps
        }
        if let item = style.itemArray.first(where: { $0.representedObject as? String == name }) { style.select(item) }
    }

    func textDidChange(_ notification: Notification) {
        // Don't edit the text layer while Hangul is composing (ㅎ→하→한) — composing characters were left on the canvas
        guard !syncing, !textView.hasMarkedText() else { return }
        let s = textView.string
        host?.editSelectedText { $0.string = s }
    }

    @objc private func familyChanged() {
        guard let fam = family.titleOfSelectedItem else { return }
        fillStyles(fam, select: "")
        style.selectItem(at: 0)
        styleChanged()
    }

    @objc private func styleChanged() {
        guard let ps = style.selectedItem?.representedObject as? String else { return }
        VectorToolState.shared.font = ps
        host?.editSelectedText { $0.font = ps }
        substituted.isHidden = true
    }

    @objc private func controlChanged() { changed(dragging: false) }

    private func changed(dragging: Bool) {
        guard !syncing else { return }
        let c = rgb(colorWell.color)
        VectorToolState.shared.color = c
        let path = (pathPopup.selectedItem?.representedObject as? String).flatMap { id in host?.photo?.settings.paths?.first { $0.id == id } }
        host?.editSelectedText(dragging) { t in
            t.color = c
            t.align = max(alignSeg.selectedSegment, 0)
            t.vertical = vertical.state == .on ? true : nil
            t.size = size.value
            t.tracking = tracking.value
            t.leading = leading.value
            t.baselineShift = baseline.value == 0 ? nil : baseline.value
            t.horizontalScale = hscale.value == 100 ? nil : hscale.value
            t.rotation = rotation.value
            t.boxWidth = boxW.value > 0 ? boxW.value : nil
            if t.boxWidth == nil { t.boxHeight = nil }
            t.warp = warp.indexOfSelectedItem > 0 ? warp.indexOfSelectedItem : nil
            t.warpBend = t.warp != nil ? bend.value : nil
            t.onPath = path
            t.pathOffset = path != nil ? pathOffset.value : nil
            t.pathFlip = path != nil && pathFlip.state == .on ? true : nil
        }
    }

    @objc private func applyStyle() {
        let i = styles.indexOfSelectedItem - 1
        let saved = TextStyle.saved
        guard saved.indices.contains(i) else { return }
        host?.editSelectedText { saved[i].apply(to: &$0) }
        sync()
    }

    @objc private func saveStyle() {
        guard let t = host?.selectedText else { NSSound.beep(); return }
        var list = TextStyle.saved
        let name = styleName.stringValue.isEmpty ? "스타일 \(list.count + 1)" : styleName.stringValue
        list.removeAll { $0.name == name }
        list.append(TextStyle(name: name, from: t))
        TextStyle.saved = list
        styleName.stringValue = ""
        sync()
    }
}
