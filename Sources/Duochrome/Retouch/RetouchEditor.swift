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
    /// Name of the tool under the pointer, shown right under the tool bar
    let hoverTip = ToolHoverTip()
    private(set) var currentTool = UserDefaults.standard.string(forKey: "retouchTool") ?? "hand"
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
        if id == "transform" { host.freeTransform(nil); return }
        if id == "perspective" { host.perspectiveLayer(nil); return }
        currentTool = id
        host.traceTool(id)
        UserDefaults.standard.set(id, forKey: "retouchTool")
        toolBar.reload(selected: id)
        host.applyRetouchTool(tool)
        inspector.show(tool: tool, host: host)
    }

    func restoreTool() { selectTool(RetouchTool.named(currentTool) != nil ? currentTool : "hand") }

    /// Layers or their values changed (or the layer selection did): refresh the panels
    func reload() {
        guard isViewLoaded, let host else { return }
        layersPanel.reload(host: host)
        inspector.reloadLayer(host: host)
    }
}

/// One tool of the layer editor
struct RetouchTool: Equatable {
    enum Group { case view, arrange, select, brush, gradient, retouch }
    let id: String
    let title: String
    let symbol: String
    let group: Group
    /// Shortcut shown in the tooltip (the key itself is in KeyMap)
    var key: String = ""

    static let all: [RetouchTool] = [
        .init(id: "hand", title: "손 (옮겨 보기)", symbol: "hand.raised", group: .view, key: "H"),
        .init(id: "zoom", title: "확대/축소", symbol: "magnifyingglass", group: .view, key: "Z"),
        .init(id: "move", title: "이동 (고른 사진 레이어)", symbol: "arrow.up.and.down.and.arrow.left.and.right", group: .arrange, key: "V"),
        .init(id: "transform", title: "자유 변형 (크기·회전)", symbol: "arrow.up.left.and.arrow.down.right", group: .arrange, key: "⌘T"),
        .init(id: "perspective", title: "원근 변형", symbol: "perspective", group: .arrange),
        .init(id: "selRect", title: "사각형 선택", symbol: "rectangle.dashed", group: .select, key: "M"),
        .init(id: "selOval", title: "타원 선택", symbol: "circle.dashed", group: .select),
        .init(id: "selFree", title: "올가미", symbol: "lasso", group: .select, key: "L"),
        .init(id: "selQuick", title: "빠른 선택", symbol: "wand.and.rays", group: .select, key: "W"),
        .init(id: "selWand", title: "자동 선택 (비슷한 색)", symbol: "wand.and.stars", group: .select, key: "⇧W"),
        .init(id: "selSubject", title: "피사체 선택 (AI)", symbol: "person.crop.rectangle", group: .select),
        .init(id: "selSky", title: "하늘 선택 (AI)", symbol: "cloud.sun", group: .select),
        .init(id: "dodge", title: "밝게 (닷지)", symbol: "sun.max", group: .brush, key: "O"),
        .init(id: "burn", title: "어둡게 (번)", symbol: "moon", group: .brush),
        .init(id: "saturate", title: "채도 높이기", symbol: "drop.fill", group: .brush),
        .init(id: "desaturate", title: "채도 낮추기", symbol: "drop", group: .brush),
        .init(id: "sharpen", title: "선명하게", symbol: "triangle", group: .brush),
        .init(id: "soften", title: "부드럽게", symbol: "aqi.medium", group: .brush),
        .init(id: "denoiseBrush", title: "노이즈 제거 붓", symbol: "circle.dotted", group: .brush),
        .init(id: "blurBrush", title: "흐림 붓 (배경 흐리게)", symbol: "drop.halffull", group: .brush),
        .init(id: "skinBrush", title: "피부 붓 (매끈하게)", symbol: "face.smiling", group: .brush),
        .init(id: "maskBrush", title: "마스크 붓 (고른 레이어)", symbol: "paintbrush", group: .brush, key: "B"),
        .init(id: "gradLinear", title: "선형 그라디언트 (끌어서 긋기)", symbol: "square.bottomhalf.filled", group: .gradient, key: "G"),
        .init(id: "gradRadial", title: "원형 그라디언트 (끌어서 원)", symbol: "circle.circle", group: .gradient),
        .init(id: "heal", title: "복구 (누르면 스팟, 끌면 붓)", symbol: "bandage", group: .retouch, key: "J"),
        .init(id: "clone", title: "복제 도장", symbol: "doc.on.doc", group: .retouch, key: "S"),
        .init(id: "patch", title: "패치 (고칠 곳을 두르기)", symbol: "square.dashed.inset.filled", group: .retouch),
        .init(id: "smartErase", title: "스마트 지우기 (둘레 색으로)", symbol: "eraser", group: .retouch),
        .init(id: "aiRemove", title: "AI 지우기", symbol: "sparkles", group: .retouch),
    ]

    static func named(_ id: String) -> RetouchTool? { all.first { $0.id == id } }

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
    private var buttons: [String: NSButton] = [:]

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
        for t in RetouchTool.all {
            if let last, last != t.group {
                let gap = NSView()
                gap.widthAnchor.constraint(equalToConstant: 10).isActive = true
                stack.addArrangedSubview(gap)
            }
            last = t.group
            let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: t.title)!
            let b = HoverButton(image: img, target: self, action: #selector(picked(_:)))
            b.onHover = { [weak self, weak b] inside in self?.onHover?(inside ? t : nil, inside ? b : nil) }
            b.bezelStyle = .recessed
            b.setButtonType(.pushOnPushOff)
            b.isBordered = true
            b.identifier = NSUserInterfaceItemIdentifier(t.id)
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            buttons[t.id] = b
            stack.addArrangedSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        onPick?(id)
    }

    /// Width that shows every tool
    var contentWidth: CGFloat { stack.fittingSize.width }

    func reload(selected: String) {
        for (id, b) in buttons { b.state = id == selected ? .on : .off }
    }
}

/// Tool button that reports the pointer entering and leaving
final class HoverButton: NSButton {
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
