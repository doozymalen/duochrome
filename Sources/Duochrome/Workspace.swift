import AppKit
import CoreImage

// MARK: - Rulers, guides, snapping, focus loupe, measure and count tools, saved workspaces

/// Rulers (top and left canvas edges). Ticks are photo pixels. Dragging out of a ruler creates a guide
final class RulerView: NSView {
    enum Edge { case top, left }
    let edge: Edge
    weak var canvas: CanvasView?
    /// Dragging creates a guide (true if vertical, photo coordinate value, dragging)
    var onGuide: ((Bool, CGFloat, Bool) -> Void)?
    static let thickness: CGFloat = 18

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 0.92).setFill()
        bounds.fill()
        guard let c = canvas, c.document != nil else { return }
        // Major ticks about every 100 screen pixels: 1·2·5 × powers of 10
        let perPx = 1 / max(c.zoom, 1e-6)
        let raw = perPx * 100
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2.0, 5.0, 10.0].map { $0 * mag }.first { $0 >= raw } ?? raw
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.secondaryLabelColor.setStroke()
        let origin = convert(c.viewPoint(forImage: .zero), from: c)
        let path = NSBezierPath()
        if edge == .top {
            let start = floor(-origin.x * perPx / step) * step
            var v = start
            while true {
                let x = origin.x + v / perPx
                if x > bounds.maxX { break }
                if x >= 0 {
                    path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x, y: bounds.height * 0.55))
                    ("\(Int(v))" as NSString).draw(at: NSPoint(x: x + 2, y: bounds.height - 12), withAttributes: attrs)
                    for k in 1..<5 { let xs = x + CGFloat(k) * step / 5 / perPx; path.move(to: NSPoint(x: xs, y: 0)); path.line(to: NSPoint(x: xs, y: bounds.height * 0.25)) }
                }
                v += step
            }
        } else {
            let start = floor(-origin.y * perPx / step) * step
            var v = start
            while true {
                let y = origin.y + v / perPx
                if y > bounds.maxY { break }
                if y >= 0 {
                    path.move(to: NSPoint(x: bounds.width, y: y)); path.line(to: NSPoint(x: bounds.width * 0.45, y: y))
                    ("\(Int(v))" as NSString).draw(at: NSPoint(x: 1, y: y + 1), withAttributes: attrs)
                    for k in 1..<5 { let ys = y + CGFloat(k) * step / 5 / perPx; path.move(to: NSPoint(x: bounds.width, y: ys)); path.line(to: NSPoint(x: bounds.width * 0.75, y: ys)) }
                }
                v += step
            }
        }
        path.lineWidth = 0.5
        path.stroke()
    }

    private var dragging = false
    override func mouseDown(with event: NSEvent) { dragging = true }
    override func mouseDragged(with event: NSEvent) { report(event, done: false) }
    override func mouseUp(with event: NSEvent) { if dragging { report(event, done: true) }; dragging = false }
    private func report(_ event: NSEvent, done: Bool) {
        guard let c = canvas else { return }
        let p = c.imagePoint(at: c.convert(event.locationInWindow, from: nil))
        // Dragging from the top ruler makes a horizontal guide, from the left a vertical one
        onGuide?(edge == .left, edge == .left ? p.x : p.y, !done)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: edge == .top ? .resizeUpDown : .resizeLeftRight) }
}

/// Layer drawing guides, measure lines, and count points (receives clicks only for the measure/count tools)
final class GuidesOverlayView: NSView {
    weak var canvas: CanvasView?
    /// Guides in photo (view frame) coordinates
    var vertical: [CGFloat] = [] { didSet { needsDisplay = true } }
    var horizontal: [CGFloat] = [] { didSet { needsDisplay = true } }
    /// New guide being dragged (vertical?, value)
    var pending: (Bool, CGFloat)? { didSet { needsDisplay = true } }
    var showGuides = true { didSet { needsDisplay = true } }
    /// Measure tool: two points (photo coordinates)
    var measure: (CGPoint, CGPoint)? { didSet { needsDisplay = true } }
    /// Count tool: points (photo coordinates)
    var counts: [CGPoint] = [] { didSet { needsDisplay = true } }
    enum Tool { case none, measure, count }
    var tool: Tool = .none { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onMeasure: ((CGPoint, CGPoint, Bool) -> Void)?
    var onCount: ((CGPoint, Bool) -> Void)?   // (point, ⌥ delete)

    override func hitTest(_ point: NSPoint) -> NSView? { tool == .none || isHidden ? nil : super.hitTest(point) }
    override func resetCursorRects() { if tool != .none { addCursorRect(bounds, cursor: .crosshair) } }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = canvas else { return }
        let guide = NSBezierPath()
        if showGuides {
            for x in vertical { let v = c.viewPoint(forImage: CGPoint(x: x, y: 0)).x; guide.move(to: NSPoint(x: v, y: 0)); guide.line(to: NSPoint(x: v, y: bounds.height)) }
            for y in horizontal { let v = c.viewPoint(forImage: CGPoint(x: 0, y: y)).y; guide.move(to: NSPoint(x: 0, y: v)); guide.line(to: NSPoint(x: bounds.width, y: v)) }
        }
        if let (isV, val) = pending {
            let v = c.viewPoint(forImage: CGPoint(x: val, y: val))
            if isV { guide.move(to: NSPoint(x: v.x, y: 0)); guide.line(to: NSPoint(x: v.x, y: bounds.height)) }
            else { guide.move(to: NSPoint(x: 0, y: v.y)); guide.line(to: NSPoint(x: bounds.width, y: v.y)) }
        }
        guide.lineWidth = 1
        NSColor.systemCyan.withAlphaComponent(0.85).setStroke()
        guide.stroke()
        if let (a, b) = measure {
            let va = c.viewPoint(forImage: a), vb = c.viewPoint(forImage: b)
            let l = NSBezierPath(); l.move(to: va); l.line(to: vb); l.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.6).setStroke(); l.stroke()
            l.lineWidth = 1; l.setLineDash([5, 3], count: 2, phase: 0); NSColor.white.setStroke(); l.stroke()
            for p in [va, vb] { let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8); NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill() }
            let text = Self.measureText(a, b) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
                                                        .backgroundColor: NSColor.black.withAlphaComponent(0.6)]
            text.draw(at: NSPoint(x: (va.x + vb.x) / 2 + 8, y: (va.y + vb.y) / 2 + 8), withAttributes: attrs)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        for (i, p) in counts.enumerated() {
            let v = c.viewPoint(forImage: p)
            let r = NSRect(x: v.x - 9, y: v.y - 9, width: 18, height: 18)
            NSColor.systemRed.withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: r).fill()
            let s = "\(i + 1)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: v.x - sz.width / 2, y: v.y - sz.height / 2), withAttributes: attrs)
        }
    }

    /// Distance, angle, width/height (photo pixels)
    static func measureText(_ a: CGPoint, _ b: CGPoint) -> String {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy), ang = atan2(dy, dx) * 180 / .pi
        return String(format: " 길이 %.1f px · 각도 %.1f° · 가로 %.0f · 세로 %.0f ", d, ang, dx, dy)
    }

    private var start: CGPoint?
    override func mouseDown(with event: NSEvent) {
        guard let c = canvas else { return }
        let p = c.imagePoint(at: convert(event.locationInWindow, from: nil))
        switch tool {
        case .measure: start = p; onMeasure?(p, p, true)
        case .count: onCount?(p, event.modifierFlags.contains(.option))
        case .none: break
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard tool == .measure, let c = canvas, let s = start else { return }
        var p = c.imagePoint(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) {   // ⇧: 45° steps
            let ang = (atan2(p.y - s.y, p.x - s.x) / (.pi / 4)).rounded() * (.pi / 4), d = hypot(p.x - s.x, p.y - s.y)
            p = CGPoint(x: s.x + cos(ang) * d, y: s.y + sin(ang) * d)
        }
        onMeasure?(s, p, true)
    }
    override func mouseUp(with event: NSEvent) {
        guard tool == .measure, let (a, b) = measure else { return }
        onMeasure?(a, b, false)
        start = nil
    }
}

/// Focus loupe: a small window showing the area under the mouse at 100%
final class FocusLoupe: NSPanel {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    static let side: CGFloat = 260

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side + 20),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        title = "초점 확인 (100%)"
        isFloatingPanel = true
        hidesOnDeactivate = true
        imageView.imageScaling = .scaleNone
        imageView.frame = NSRect(x: 0, y: 20, width: Self.side, height: Self.side)
        label.frame = NSRect(x: 6, y: 2, width: Self.side - 12, height: 16)
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side + 20))
        v.addSubview(imageView); v.addSubview(label)
        contentView = v
    }

    /// Shows the area around a photo-coordinate point at 100% (a tile of the photo at 100% zoom). True on success
    @discardableResult
    func show(_ doc: RawDocument, at p: CGPoint) -> Bool {
        // The focus loupe must show actual pixels, so full size (only a small tile is rendered)
        let img = doc.withFullResolution { doc.image(scale: 1) }
        let half = Self.side
        let r = CGRect(x: (p.x - half / 2).rounded(), y: (p.y - half / 2).rounded(), width: half, height: half).intersection(img.extent)
        guard r.width > 4, r.height > 4,
              let cg = Render.context.createCGImage(img, from: r, format: .RGBA8, colorSpace: Render.displaySpace) else { return false }
        let ns = NSImage(cgImage: cg, size: NSSize(width: r.width / (backingScaleFactor), height: r.height / backingScaleFactor))
        imageView.image = ns
        label.stringValue = String(format: "x %.0f  y %.0f", p.x, p.y)
        return true
    }
}

extension MainWindowController {
    // MARK: Guides · rulers · snapping

    /// Document guides (photo view frame coordinates)
    func syncGuides() {
        let o = canvas.guidesOverlay
        o.vertical = (photo?.settings.guidesV ?? []).map { CGFloat($0) }
        o.horizontal = (photo?.settings.guidesH ?? []).map { CGFloat($0) }
        o.showGuides = UserDefaults.standard.object(forKey: "view.guides") as? Bool ?? true
    }

    /// Guide dragged from a ruler: not created if dropped back outside the photo (toward the ruler)
    func guideDragged(vertical: Bool, at v: CGFloat, dragging: Bool) {
        guard let doc = photo else { return }
        let size = doc.pixelSize
        let inside = v >= 0 && v <= (vertical ? size.width : size.height)
        canvas.guidesOverlay.pending = dragging && inside ? (vertical, v) : nil
        guard !dragging, inside else { return }
        addGuide(vertical: vertical, at: Double(v))
    }

    func addGuide(vertical: Bool, at v: Double) {
        guard var s = photo?.settings else { return }
        if vertical { s.guidesV = (s.guidesV ?? []) + [v] } else { s.guidesH = (s.guidesH ?? []) + [v] }
        replaceSettings(s, recordUndo: true, label: "안내선")
        syncGuides()
    }

    @objc func newGuideAtCenter(_ sender: Any?) {
        guard let doc = photo else { return }
        addGuide(vertical: true, at: Double(doc.pixelSize.width / 2))
        addGuide(vertical: false, at: Double(doc.pixelSize.height / 2))
    }

    @objc func clearGuides(_ sender: Any?) {
        guard var s = photo?.settings, s.guidesV != nil || s.guidesH != nil else { return }
        s.guidesV = nil; s.guidesH = nil
        replaceSettings(s, recordUndo: true, label: "안내선 지우기")
        syncGuides()
    }

    @objc func toggleGuides(_ sender: Any?) {
        let on = !(UserDefaults.standard.object(forKey: "view.guides") as? Bool ?? true)
        UserDefaults.standard.set(on, forKey: "view.guides")
        syncGuides()
    }

    @objc func toggleRulers(_ sender: Any?) {
        canvas.showRulers.toggle()
        UserDefaults.standard.set(canvas.showRulers, forKey: "view.rulers")
    }

    @objc func toggleSnap(_ sender: Any?) {
        UserDefaults.standard.set(!snapOn, forKey: "view.snap")
    }

    var snapOn: Bool { UserDefaults.standard.object(forKey: "view.snap") as? Bool ?? true }

    /// Snaps a source-coordinate point to guides, photo edges, and center (within 8 screen pixels). Unchanged if snapping is off
    func snapNative(_ p: CGPoint) -> CGPoint {
        guard snapOn, let doc = photo else { return p }
        let d = doc.toDisplay(p)
        let size = doc.pixelSize
        let tol = 8 / max(canvas.zoom, 1e-6)
        let xs = (doc.settings.guidesV ?? []).map { CGFloat($0) } + [0, size.width / 2, size.width]
        let ys = (doc.settings.guidesH ?? []).map { CGFloat($0) } + [0, size.height / 2, size.height]
        var q = d
        if let x = xs.min(by: { abs($0 - d.x) < abs($1 - d.x) }), abs(x - d.x) < tol { q.x = x }
        if let y = ys.min(by: { abs($0 - d.y) < abs($1 - d.y) }), abs(y - d.y) < tol { q.y = y }
        return q == d ? p : doc.toNative(q)
    }

    // MARK: Measure · count

    func startMeasure() {
        guard photo != nil else { return }
        let o = canvas.guidesOverlay
        o.tool = .measure
        o.onMeasure = { [weak self] a, b, dragging in
            self?.canvas.guidesOverlay.measure = (a, b)
            self?.measureOptions.show(a, b)
        }
        enterTool(.pan)
        canvas.guidesOverlay.tool = .measure
    }

    func startCount() {
        guard photo != nil else { return }
        let o = canvas.guidesOverlay
        o.onCount = { [weak self] p, remove in
            guard let self, var s = self.photo?.settings else { return }
            var pts = s.countMarks ?? []
            if remove {
                // ⌥-click: delete the nearest point
                let tol = 12 / max(self.canvas.zoom, 1e-6)
                if let i = stride(from: 0, to: pts.count, by: 2).min(by: { hypot(pts[$0] - Double(p.x), pts[$0 + 1] - Double(p.y)) < hypot(pts[$1] - Double(p.x), pts[$1 + 1] - Double(p.y)) }),
                   hypot(pts[i] - Double(p.x), pts[i + 1] - Double(p.y)) < Double(tol) { pts.removeSubrange(i...(i + 1)) }
            } else {
                pts += [Double(p.x), Double(p.y)]
            }
            s.countMarks = pts.isEmpty ? nil : pts
            self.replaceSettings(s, recordUndo: true, label: "계수")
            self.syncCounts()
        }
        enterTool(.pan)
        canvas.guidesOverlay.tool = .count
        syncCounts()
    }

    func syncCounts() {
        let pts = photo?.settings.countMarks ?? []
        canvas.guidesOverlay.counts = stride(from: 0, to: pts.count - 1, by: 2).map { CGPoint(x: pts[$0], y: pts[$0 + 1]) }
        measureOptions.showCount(canvas.guidesOverlay.counts.count)
    }

    @objc func clearCounts(_ sender: Any?) {
        guard var s = photo?.settings, s.countMarks != nil else { return }
        s.countMarks = nil
        replaceSettings(s, recordUndo: true, label: "계수 지우기")
        syncCounts()
    }

    // MARK: Focus loupe

    @objc func toggleFocusLoupe(_ sender: Any?) {
        if let l = focusLoupe, l.isVisible { l.orderOut(nil); return }
        let l = focusLoupe ?? FocusLoupe()
        focusLoupe = l
        if let w = window { l.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - FocusLoupe.side - 330, y: w.frame.maxY - 90)) }
        l.orderFront(nil)
        canvas.onHover = { [weak self] p in
            guard let self, let l = self.focusLoupe, l.isVisible, let doc = self.photo else { return }
            l.show(doc, at: p)
        }
    }

    // MARK: Workspaces

    /// Saves the current arrangement (mode, panels, panel widths, tool strip, selected tabs, window frame) under a name
    func saveWorkspace(_ name: String) {
        var ws = Self.workspaces
        let d: [String: Any] = [
            "mode": mode.rawValue,
            "frame": NSStringFromRect(window?.frame ?? .zero),
            "left": split.showsLeft, "right": split.showsRight,
            "leftWidth": split.leftWidth, "rightWidth": split.rightWidth,
            "studioLayers": studioMode.showsLayers, "studioOptions": studioMode.showsOptions,
            "strip": StudioTool.strip,
            "tab": tools.selected,
        ]
        ws[name] = d
        Self.workspaces = ws
    }

    func applyWorkspace(_ name: String) {
        guard let d = Self.workspaces[name] else { NSSound.beep(); return }
        if let s = d["strip"] as? [String] { StudioTool.strip = s; studioMode.strip.reload(selected: studioMode.currentTool) }
        if let m = (d["mode"] as? Int).flatMap(AppMode.init) { setMode(m) }
        if let f = d["frame"] as? String { let r = NSRectFromString(f); if r.width > 400 { window?.setFrame(r, display: true) } }
        if let v = d["left"] as? Bool { split.showsLeft = v }
        if let v = d["right"] as? Bool { split.showsRight = v }
        if let v = d["leftWidth"] as? Double { split.leftWidth = CGFloat(v) }
        if let v = d["rightWidth"] as? Double { split.rightWidth = CGFloat(v) }
        if let v = d["studioLayers"] as? Bool { studioMode.showsLayers = v }
        if let v = d["studioOptions"] as? Bool { studioMode.showsOptions = v }
        if let t = d["tab"] as? Int { tools.select(t) }
    }

    static var workspaces: [String: [String: Any]] {
        get { UserDefaults.standard.dictionary(forKey: "workspaces") as? [String: [String: Any]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "workspaces") }
    }

    @objc func saveWorkspaceFromMenu(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "작업 공간 저장"
        a.informativeText = "지금 모드·패널·패널 폭·도구 막대·고른 탭·창 크기를 저장합니다."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = "작업 공간 \(Self.workspaces.count + 1)"
        a.accessoryView = f
        a.addButton(withTitle: "저장"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
        saveWorkspace(f.stringValue)
    }

    @objc func applyWorkspaceFromMenu(_ sender: NSMenuItem) { if let n = sender.representedObject as? String { applyWorkspace(n) } }
    @objc func deleteWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        var ws = Self.workspaces; ws[n] = nil; Self.workspaces = ws
    }

    func workspaceMenuItems(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "지금 배치 저장…", action: #selector(saveWorkspaceFromMenu(_:)), keyEquivalent: "").target = self
        let names = Self.workspaces.keys.sorted()
        if !names.isEmpty { menu.addItem(.separator()) }
        for n in names { let it = menu.addItem(withTitle: n, action: #selector(applyWorkspaceFromMenu(_:)), keyEquivalent: ""); it.representedObject = n; it.target = self }
        if !names.isEmpty {
            let del = menu.addItem(withTitle: "작업 공간 지우기", action: nil, keyEquivalent: "")
            let dm = NSMenu()
            for n in names { let it = dm.addItem(withTitle: n, action: #selector(deleteWorkspaceFromMenu(_:)), keyEquivalent: ""); it.representedObject = n; it.target = self }
            del.submenu = dm
        }
    }
}

final class WorkspaceMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = WorkspaceMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first?.workspaceMenuItems(menu)
    }
}

/// Measure/count tool options
final class MeasureOptionsView: NSStackView {
    private let text = NSTextField(wrappingLabelWithString: "캔버스에서 끌어 길이·각도를 잽니다 (⇧ 45°씩).")
    private let count = NSTextField(labelWithString: "")
    weak var host: MainWindowController?

    init(host: MainWindowController) {
        self.host = host
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let title = NSTextField(labelWithString: "측정 · 계수")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.font = .systemFont(ofSize: 12)
        let seg = NSSegmentedControl(labels: ["측정", "계수"], trackingMode: .selectOne, target: self, action: #selector(kind(_:)))
        seg.selectedSegment = 0
        let clear = NSButton(title: "계수 점 지우기", target: self, action: #selector(clearCounts))
        clear.bezelStyle = .appPush; clear.controlSize = .small
        let straighten = NSButton(title: "이 선으로 수평 맞추기", target: self, action: #selector(level))
        straighten.bezelStyle = .appPush; straighten.controlSize = .small
        let hint = NSTextField(wrappingLabelWithString: "계수: 누르면 번호 점, ⌥누르기로 지웁니다. 점은 문서에 저장됩니다.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        for v in [title, seg, text, straighten, count, clear, hint] as [NSView] { addArrangedSubview(v); v.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var last: (CGPoint, CGPoint)?
    func show(_ a: CGPoint, _ b: CGPoint) { last = (a, b); text.stringValue = GuidesOverlayView.measureText(a, b).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " · ", with: "\n") }
    func showCount(_ n: Int) { count.stringValue = "계수 \(n)개" }

    @objc private func kind(_ s: NSSegmentedControl) { if s.selectedSegment == 0 { host?.startMeasure() } else { host?.startCount() } }
    @objc private func clearCounts() { host?.clearCounts(nil) }
    /// Fine-rotates so the measure line becomes level (or plumb)
    @objc private func level() {
        guard let (a, b) = last, let host, var s = host.photo?.settings else { return }
        var ang = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        if abs(ang) > 45 && abs(ang) < 135 { ang += ang > 0 ? -90 : 90 }   // nearly vertical → treat as vertical
        if abs(ang) > 90 { ang += ang > 0 ? -180 : 180 }
        s.rotation = min(max(s.rotation - Float(ang), -45), 45)
        host.replaceSettings(s, recordUndo: true, label: "측정선으로 수평")
        host.canvas.guidesOverlay.measure = nil
    }
}
