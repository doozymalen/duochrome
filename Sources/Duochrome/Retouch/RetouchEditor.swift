import AppKit

/// Layer editor (심화 보정): a photo retouching editor that stacks layers on the batch-edit develop result.
///
/// Built separately from batch edit, for retouching only (no text, shapes or design tools):
/// - One canvas input at a time: every tool maps to exactly one CanvasView tool, so a click on the photo
///   always goes to the tool that is shown as picked.
/// - Selections belong to the document (StudioSelection.swift); layers made while there is a selection are masked by it.
/// - Layers panel on the left, tool bar on top, inspector on the right (tool options, then the selected layer).
/// The layer data and rendering are the same as batch edit (DevelopSettings.layers), so both modes show the same result.
final class RetouchEditor: NSViewController {
    weak var host: MainWindowController?
    let toolBar = RetouchToolBar()
    let layersPanel = RetouchLayersPanel()
    let inspector = RetouchInspector()
    private let canvasHost = NSView()
    private let work = NSLayoutGuide()
    lazy var layersWidth = layersPanel.widthAnchor.constraint(equalToConstant: 260)
    lazy var optionsWidth = inspector.widthAnchor.constraint(equalToConstant: 300)
    /// Tool bar width: all tools, or the space between the panels when that is narrower (it then scrolls sideways)
    private lazy var toolBarWidth = toolBar.widthAnchor.constraint(equalToConstant: 600)
    /// Instruction bar at the bottom of the canvas (crop, liquify, perspective…) and the brief command name in the middle
    let canvasBar = CanvasBar()
    let flashLabel = FlashLabel()
    func flash(_ text: String) { if isViewLoaded { flashLabel.flash(text) } }

    /// Name of the tool under the pointer, shown right under the tool bar
    let hoverTip = ToolHoverTip()
    private(set) var currentTool = UserDefaults.standard.string(forKey: "retouchTool") ?? "hand"
    /// Brush stroke being painted (RetouchHost.retouchStroke): settings before it, the layer it paints, whether it was shown live
    var strokeBase: DevelopSettings?
    var strokeLayerID: String?
    var strokeLive = false
    /// Panel visibility (⇥ or the toolbar panel buttons)
    var showsLayers = true { didSet { layersPanel.isHidden = !showsLayers; updateCanvasInsets() } }
    var showsOptions = true { didSet { inspector.isHidden = !showsOptions; updateCanvasInsets() } }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = StudioStyle.window.cgColor
        canvasHost.wantsLayer = true
        canvasHost.layer?.backgroundColor = StudioStyle.canvasBack.cgColor
        for v in [canvasHost, layersPanel, toolBar, inspector] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        root.addLayoutGuide(work)
        TitleBand.install(in: root, above: canvasHost)
        let top = root.safeAreaLayoutGuide.topAnchor, gap: CGFloat = 8
        NSLayoutConstraint.activate([
            // The canvas spans the window; panels float over it (the fitted photo sits between them, updateCanvasInsets)
            canvasHost.topAnchor.constraint(equalTo: root.topAnchor),
            canvasHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvasHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layersPanel.topAnchor.constraint(equalTo: top, constant: gap),
            layersPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gap),
            layersPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gap),
            layersWidth,
            inspector.topAnchor.constraint(equalTo: top, constant: gap),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gap),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gap),
            optionsWidth,
            work.topAnchor.constraint(equalTo: top),
            work.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            work.leadingAnchor.constraint(equalTo: layersPanel.trailingAnchor, constant: gap),
            work.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -gap),
            toolBar.topAnchor.constraint(equalTo: top, constant: gap),
            toolBar.centerXAnchor.constraint(equalTo: work.centerXAnchor),
            toolBarWidth,
            toolBar.heightAnchor.constraint(equalToConstant: 44),
        ])
        view = root
        for v in [canvasBar, flashLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvasBar.centerXAnchor.constraint(equalTo: work.centerXAnchor),
            canvasBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            canvasBar.widthAnchor.constraint(lessThanOrEqualTo: work.widthAnchor, constant: -16),
            flashLabel.centerXAnchor.constraint(equalTo: work.centerXAnchor),
            flashLabel.centerYAnchor.constraint(equalTo: work.centerYAnchor),
        ])
        toolBar.onPick = { [weak self] id in self?.selectTool(id) }
        hoverTip.isHidden = true
        root.addSubview(hoverTip)
        toolBar.onHover = { [weak self] tool, button in
            guard let self else { return }
            guard let tool, let button else { self.hoverTip.isHidden = true; return }
            self.hoverTip.show(tool.key.isEmpty ? tool.title : "\(tool.title)  \(tool.key)")
            // Centered under the button, kept inside the window
            let r = button.convert(button.bounds, to: root)
            let size = self.hoverTip.fittingSize
            var x = r.midX - size.width / 2
            x = min(max(x, 8), root.bounds.width - size.width - 8)
            let y = root.isFlipped ? self.toolBar.frame.maxY + 6 : self.toolBar.frame.minY - 6 - size.height
            self.hoverTip.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        toolBar.reload(selected: currentTool)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let room = work.frame.width
        let w = max(min(toolBar.contentWidth, room), 44)
        if abs(toolBarWidth.constant - w) > 0.5 { toolBarWidth.constant = w }
    }

    /// The canvas lies under the panels, so "fit" uses the area between them and below the tool bar
    func updateCanvasInsets() {
        guard let canvas = canvasHost.subviews.first(where: { $0 is CanvasView }) as? CanvasView else { return }
        let gap: CGFloat = 8
        canvas.fitInsets = NSEdgeInsets(top: 44 + gap * 2, left: showsLayers ? gap * 2 + layersWidth.constant : gap,
                                        bottom: gap, right: showsOptions ? gap * 2 + optionsWidth.constant : gap)
    }

    /// Moves the shared canvas in (it goes back to batch edit on leaving)
    func attachCanvas(_ canvas: NSView) {
        _ = view
        canvas.removeFromSuperview()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: canvasHost.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
        ])
        updateCanvasInsets()
    }

    // MARK: Tools

    func selectTool(_ id: String) {
        guard let host, let tool = RetouchTool.named(id) else { return }
        _ = view
        // Free transform and perspective are commands on the selected photo layer:
        // the picked tool stays and comes back when their frame closes
        if id == "transform" || id == "perspective" {
            // These act on a photo layer; the commands turn the background or a background copy into one first
            if id == "transform" { host.freeTransform(nil) } else { host.perspectiveLayer(nil) }
            return
        }
        currentTool = id
        host.traceTool(id)
        UserDefaults.standard.set(id, forKey: "retouchTool")
        toolBar.reload(selected: id)
        host.applyRetouchTool(tool)
        inspector.show(tool: tool, host: host)
        if id == "crop" {
            canvasBar.show("틀의 모서리·변을 끌어 자릅니다", [("초기화", { [weak host] in host?.shape.resetCrop() }),
                                                         ("완료", { [weak self] in self?.selectTool("hand") })])
        } else if tool.group != .distort {
            canvasBar.hide()
        }
    }

    func restoreTool() { selectTool(RetouchTool.named(currentTool) != nil ? currentTool : "hand") }

    /// Layers or their values changed (or the layer selection did): refresh the panels
    func reload() {
        guard isViewLoaded, let host else { return }
        layersPanel.reload(host: host)
        // The color adjustments tool's options depend on whether an adjustment layer is picked
        if currentTool == "adjust", let t = RetouchTool.named("adjust") { inspector.show(tool: t, host: host) } else { inspector.reloadLayer(host: host) }
    }
}

/// One tool of the layer editor
struct RetouchTool: Equatable {
    enum Group { case view, arrange, select, brush, distort, gradient, retouch }
    let id: String
    /// One-shot commands (free transform, perspective): they run from the slot menu but never become the slot's tool,
    /// or a plain click on the slot would run the command again instead of picking the tool
    var isCommand: Bool { id == "transform" || id == "perspective" }
    let title: String
    let symbol: String
    let group: Group
    /// Shortcut shown in the tooltip (the key itself is in KeyMap)
    var key: String = ""

    static let all: [RetouchTool] = [
        .init(id: "hand", title: "손", symbol: "hand.raised", group: .view, key: "H"),
        .init(id: "zoom", title: "확대/축소", symbol: "magnifyingglass", group: .view, key: "Z"),
        .init(id: "move", title: "이동", symbol: "arrow.up.and.down.and.arrow.left.and.right", group: .arrange, key: "V"),
        .init(id: "transform", title: "자유 변형", symbol: "arrow.up.left.and.arrow.down.right", group: .arrange, key: "⌘T"),
        .init(id: "perspective", title: "원근 변형", symbol: "perspective", group: .arrange),
        .init(id: "crop", title: "자르기", symbol: "crop", group: .arrange),
        .init(id: "adjust", title: "색 조정", symbol: "slider.horizontal.3", group: .arrange),
        .init(id: "selRect", title: "사각형 선택", symbol: "rectangle.dashed", group: .select, key: "M"),
        .init(id: "selOval", title: "타원 선택", symbol: "circle.dashed", group: .select),
        .init(id: "selFree", title: "올가미", symbol: "lasso", group: .select, key: "L"),
        .init(id: "selQuick", title: "빠른 선택", symbol: "wand.and.rays", group: .select, key: "W"),
        .init(id: "selWand", title: "자동 선택", symbol: "wand.and.stars", group: .select, key: "⇧W"),
        .init(id: "selSubject", title: "피사체 선택", symbol: "person.crop.rectangle", group: .select),
        .init(id: "selSky", title: "하늘 선택", symbol: "cloud.sun", group: .select),
        .init(id: "dodge", title: "밝게", symbol: "sun.max", group: .brush, key: "O"),
        .init(id: "burn", title: "어둡게", symbol: "moon", group: .brush),
        .init(id: "saturate", title: "채도 높이기", symbol: "drop.fill", group: .brush),
        .init(id: "desaturate", title: "채도 낮추기", symbol: "drop", group: .brush),
        .init(id: "sharpen", title: "선명하게", symbol: "triangle", group: .brush),
        .init(id: "soften", title: "부드럽게", symbol: "aqi.medium", group: .brush),
        .init(id: "denoiseBrush", title: "노이즈 제거", symbol: "circle.dotted", group: .brush),
        .init(id: "blurBrush", title: "흐림", symbol: "drop.halffull", group: .brush),
        .init(id: "skinBrush", title: "피부 매끈하게", symbol: "face.smiling", group: .brush),
        .init(id: "maskBrush", title: "마스크 붓", symbol: "paintbrush", group: .brush, key: "B"),
        .init(id: "liqPush", title: "왜곡: 밀기", symbol: "hand.point.up.left", group: .distort),
        .init(id: "liqBloat", title: "왜곡: 부풀리기", symbol: "circle.circle.fill", group: .distort),
        .init(id: "liqPucker", title: "왜곡: 오므리기", symbol: "smallcircle.filled.circle", group: .distort),
        .init(id: "liqTwirl", title: "왜곡: 돌리기 (⌥ 반대로)", symbol: "tornado", group: .distort),
        .init(id: "liqReconstruct", title: "왜곡: 되돌리기", symbol: "arrow.uturn.backward.circle", group: .distort),
        .init(id: "gradLinear", title: "선형 그라디언트", symbol: "square.bottomhalf.filled", group: .gradient, key: "G"),
        .init(id: "gradRadial", title: "원형 그라디언트", symbol: "circle.circle", group: .gradient),
        .init(id: "heal", title: "복구", symbol: "bandage", group: .retouch, key: "J"),
        .init(id: "clone", title: "복제 도장", symbol: "doc.on.doc", group: .retouch, key: "S"),
        .init(id: "patch", title: "패치", symbol: "square.dashed.inset.filled", group: .retouch),
        .init(id: "smartErase", title: "스마트 지우기", symbol: "eraser", group: .retouch),
        .init(id: "aiRemove", title: "AI 지우기", symbol: "sparkles", group: .retouch),
    ]

    static func named(_ id: String) -> RetouchTool? { all.first { $0.id == id } }

    /// Tool bar slots: similar tools share one button (pick another by holding or right-clicking it), like the reference editor
    static let slots: [[String]] = [
        ["hand", "zoom"], ["move", "transform", "perspective"], ["crop"], ["adjust"],
        ["selRect", "selOval", "selFree"], ["selQuick", "selWand"], ["selSubject", "selSky"],
        ["dodge", "burn"], ["saturate", "desaturate"], ["sharpen", "soften"], ["denoiseBrush", "blurBrush", "skinBrush"], ["maskBrush"],
        ["liqPush", "liqBloat", "liqPucker", "liqTwirl", "liqReconstruct"],
        ["gradLinear", "gradRadial"],
        ["heal", "clone", "patch"], ["smartErase", "aiRemove"],
    ]

    /// Brush strength 0–1 (0.5 is the preset as defined) and tonal range, per tool, like the reference editor's brush tools
    static func strength(_ tool: String) -> Double { UserDefaults.standard.object(forKey: "brush.strength.\(tool)") as? Double ?? 0.5 }
    static func setStrength(_ v: Double, _ tool: String) { UserDefaults.standard.set(v, forKey: "brush.strength.\(tool)") }
    /// 0 all, 1 shadows, 2 midtones, 3 highlights
    static var range: Int {
        get { UserDefaults.standard.integer(forKey: "brush.range") }
        set { UserDefaults.standard.set(newValue, forKey: "brush.range") }
    }

    /// Sets a brush layer's adjustment from its preset at the current strength, and its mask's brightness band from the range
    static func applyPreset(_ tool: String, to l: inout AdjustLayer) {
        guard let p = presets[tool] else { return }
        var a = LocalAdjust()
        p.adjust(&a)
        let k = Float(strength(tool) / 0.5)
        a.exposure *= k; a.saturation *= k; a.clarity *= k; a.blur *= k
        if let d = a.denoise { a.denoise = d * k }
        if let v = a.skinSmooth { a.skinSmooth = v * k }
        l.adjust = a
        let bands: [(Float, Float)] = [(0, 1), (0, 0.35), (0.25, 0.75), (0.65, 1)]
        let (lo, hi) = bands[max(0, min(range, 3))]
        l.mask.lumaMin = lo
        l.mask.lumaMax = hi
        l.mask.lumaSoft = range == 0 ? 0.1 : 0.15
    }

    /// Brush tools painting an adjustment preset: layer name and its adjustment
    static let presets: [String: (name: String, adjust: (inout LocalAdjust) -> Void)] = [
        "dodge": ("밝게 (닷지)", { $0.exposure = 0.7 }),
        "burn": ("어둡게 (번)", { $0.exposure = -0.7 }),
        "saturate": ("채도 높이기", { $0.saturation = 40 }),
        "desaturate": ("채도 낮추기", { $0.saturation = -60 }),
        "sharpen": ("선명하게", { $0.clarity = 50 }),
        "soften": ("부드럽게", { $0.clarity = -50 }),
        "denoiseBrush": ("노이즈 제거", { $0.denoise = 60 }),
        "blurBrush": ("흐림", { $0.blur = 20 }),
        "skinBrush": ("피부 매끈하게", { $0.skinSmooth = 50 }),
    ]
}

/// Floating tool bar over the canvas
final class RetouchToolBar: NSView {
    var onPick: ((String) -> Void)?
    /// Pointer entered a tool button (nil when it leaves)
    var onHover: ((RetouchTool?, NSView?) -> Void)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self, radius: 22, interactive: true)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // In a narrow window the bar gets narrower than its tools and scrolls sideways (trackpad or wheel)
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        var last: RetouchTool.Group?
        for (k, ids) in RetouchTool.slots.enumerated() {
            let tools = ids.compactMap(RetouchTool.named)
            guard let first = tools.first else { continue }
            if let last, last != first.group { stack.addArrangedSubview(GroupDivider()) }
            last = first.group
            let saved = UserDefaults.standard.string(forKey: "retouchSlot.\(ids[0])")
            let current = tools.first { $0.id == saved && !$0.isCommand } ?? first
            let b = SlotButton(image: Self.image(current), target: self, action: #selector(picked(_:)))
            b.alternatives = tools
            b.onHover = { [weak self, weak b] inside in
                guard let self, let b else { return }
                self.onHover?(inside ? b.current : nil, inside ? b : nil)
            }
            b.onChoose = { [weak self] t in self?.onPick?(t.id) }
            b.setButtonType(.pushOnPushOff)
            b.isBordered = false
            b.current = current
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            slots.append((k, b))
            stack.addArrangedSubview(b)
        }
    }

    private var slots: [(Int, SlotButton)] = []

    static func image(_ t: RetouchTool) -> NSImage {
        NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: t.title)!
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked(_ b: NSButton) {
        guard let b = b as? SlotButton, let t = b.current else { return }
        onPick?(t.id)
    }

    /// Width that shows every tool
    var contentWidth: CGFloat { stack.fittingSize.width }

    func reload(selected: String) {
        for (_, b) in slots {
            if let t = b.alternatives.first(where: { $0.id == selected }) {
                b.current = t
                UserDefaults.standard.set(t.id, forKey: "retouchSlot.\(b.alternatives[0].id)")
                b.state = .on
            } else {
                b.state = .off
            }
        }
    }
}

/// Tool bar button holding one tool or a few similar ones: shows the current one; hold or right-click to pick another.
/// A small triangle at the bottom right marks buttons with alternatives.
final class SlotButton: HoverButton {
    var alternatives: [RetouchTool] = []
    var onChoose: ((RetouchTool) -> Void)?
    var current: RetouchTool? {
        didSet {
            guard let t = current else { return }
            image = RetouchToolBar.image(t)
            identifier = NSUserInterfaceItemIdentifier(t.id)
            setAccessibilityLabel(t.title)
        }
    }

    private var hovered = false { didSet { needsDisplay = true } }
    // Same box for every tool (the glyph's own insets made the buttons differ in height)
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 34) }
    override func mouseEntered(with event: NSEvent) { hovered = true; super.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = false; super.mouseExited(with: event) }

    /// Drawn like the reference editor's tool bar: a plain glyph, a soft square under the pointer,
    /// the accent square behind the picked tool, a small corner mark when the button holds more tools
    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let box = bounds.insetBy(dx: 2, dy: 2)
        let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        if on { NSColor.controlAccentColor.setFill(); shape.fill() }
        else if isHighlighted { NSColor.white.withAlphaComponent(0.2).setFill(); shape.fill() }
        else if hovered { NSColor.white.withAlphaComponent(0.1).setFill(); shape.fill() }
        if let t = current, let glyph = Self.glyph(t, color: on ? .white : NSColor.white.withAlphaComponent(0.82)) {
            let s = glyph.size
            glyph.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
        guard alternatives.count > 1 else { return }
        let p = NSBezierPath()
        let x = box.maxX - 3, y = isFlipped ? box.maxY - 3 : box.minY + 3
        p.move(to: NSPoint(x: x, y: y))
        p.line(to: NSPoint(x: x - 4, y: y))
        p.line(to: NSPoint(x: x, y: isFlipped ? y - 4 : y + 4))
        p.close()
        NSColor.white.withAlphaComponent(on ? 0.85 : 0.45).setFill()
        p.fill()
    }

    private static var glyphs: [String: NSImage] = [:]
    /// The tool's symbol at tool bar size, tinted
    static func glyph(_ t: RetouchTool, color: NSColor) -> NSImage? {
        let key = "\(t.id)|\(color.alphaComponent)"
        if let g = glyphs[key] { return g }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let g = RetouchToolBar.image(t).withSymbolConfiguration(config)
        glyphs[key] = g
        return g
    }

    override func mouseDown(with event: NSEvent) {
        guard alternatives.count > 1 else { super.mouseDown(with: event); return }
        onHover?(false)
        // A short click picks the current tool; holding opens the alternatives. Decided here rather than inside
        // the button's own tracking loop, which would still wait for a mouse-up the menu already took
        highlight(true)
        let up = window?.nextEvent(matching: [.leftMouseUp], until: Date(timeIntervalSinceNow: 0.35), inMode: .eventTracking, dequeue: true)
        highlight(false)
        if up != nil { sendAction(action, to: target) } else { showMenu() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if alternatives.count > 1 { showMenu() } else { super.rightMouseDown(with: event) }
    }

    private func showMenu() {
        let menu = NSMenu()
        for t in alternatives {
            let item = NSMenuItem(title: t.key.isEmpty ? t.title : "\(t.title)  \(t.key)", action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.image = RetouchToolBar.image(t)
            item.representedObject = t.id
            item.state = t.id == current?.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }

    @objc private func chose(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let t = alternatives.first(where: { $0.id == id }) else { return }
        if !t.isCommand { current = t }
        onChoose?(t)
    }
}

/// Thin line between tool groups
final class GroupDivider: NSView {
    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 9).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.midY - 10, width: 1, height: 20).fill()
    }
}

/// Tool button that reports the pointer entering and leaving
class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onHover?(false); super.mouseDown(with: event) }
}

/// Small dark label with the hovered tool's name and shortcut (shows at once, unlike a tooltip)
final class ToolHoverTip: NSView {
    private let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Clicks go through to the canvas below
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
    }
}
