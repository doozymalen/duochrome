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
    private(set) var currentTool = UserDefaults.standard.string(forKey: "retouchTool") ?? "hand"

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
            toolBar.leadingAnchor.constraint(greaterThanOrEqualTo: work.leadingAnchor),
            toolBar.trailingAnchor.constraint(lessThanOrEqualTo: work.trailingAnchor),
            toolBar.heightAnchor.constraint(equalToConstant: 44),
        ])
        view = root
        toolBar.onPick = { [weak self] id in self?.selectTool(id) }
        toolBar.reload(selected: currentTool)
    }

    /// The canvas lies under the panels, so "fit" uses the area between them and below the tool bar
    func updateCanvasInsets() {
        guard let canvas = canvasHost.subviews.first(where: { $0 is CanvasView }) as? CanvasView else { return }
        let gap: CGFloat = 8
        canvas.fitInsets = NSEdgeInsets(top: 44 + gap * 2, left: gap * 2 + layersWidth.constant,
                                        bottom: gap, right: gap * 2 + optionsWidth.constant)
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
        currentTool = id
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
    enum Group { case view, select, brush, retouch }
    let id: String
    let title: String
    let symbol: String
    let group: Group
    /// Shortcut shown in the tooltip (the key itself is in KeyMap)
    var key: String = ""

    static let all: [RetouchTool] = [
        .init(id: "hand", title: "손 (옮겨 보기)", symbol: "hand.raised", group: .view, key: "H"),
        .init(id: "zoom", title: "확대/축소", symbol: "magnifyingglass", group: .view, key: "Z"),
        .init(id: "selRect", title: "사각형 선택", symbol: "rectangle.dashed", group: .select, key: "M"),
        .init(id: "selOval", title: "타원 선택", symbol: "circle.dashed", group: .select),
        .init(id: "selFree", title: "올가미", symbol: "lasso", group: .select, key: "L"),
        .init(id: "selQuick", title: "빠른 선택", symbol: "wand.and.rays", group: .select, key: "W"),
        .init(id: "selWand", title: "자동 선택 (비슷한 색)", symbol: "wand.and.stars", group: .select, key: "⇧W"),
        .init(id: "selSubject", title: "피사체 선택 (AI)", symbol: "person.crop.rectangle", group: .select),
        .init(id: "dodge", title: "밝게 (닷지)", symbol: "sun.max", group: .brush, key: "O"),
        .init(id: "burn", title: "어둡게 (번)", symbol: "moon", group: .brush),
        .init(id: "saturate", title: "채도 높이기", symbol: "drop.fill", group: .brush),
        .init(id: "desaturate", title: "채도 낮추기", symbol: "drop", group: .brush),
        .init(id: "sharpen", title: "선명하게", symbol: "triangle", group: .brush),
        .init(id: "soften", title: "부드럽게", symbol: "aqi.medium", group: .brush),
        .init(id: "maskBrush", title: "마스크 붓 (고른 레이어)", symbol: "paintbrush", group: .brush, key: "B"),
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
    ]
}

/// Floating tool bar over the canvas
final class RetouchToolBar: NSView {
    var onPick: ((String) -> Void)?
    private let stack = NSStackView()
    private var buttons: [String: NSButton] = [:]

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self, radius: 22, interactive: true)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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
            let b = NSButton(image: img, target: self, action: #selector(picked(_:)))
            b.bezelStyle = .recessed
            b.setButtonType(.pushOnPushOff)
            b.isBordered = true
            b.identifier = NSUserInterfaceItemIdentifier(t.id)
            b.toolTip = t.key.isEmpty ? t.title : "\(t.title) (\(t.key))"
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

    func reload(selected: String) {
        for (id, b) in buttons { b.state = id == selected ? .on : .off }
    }
}
