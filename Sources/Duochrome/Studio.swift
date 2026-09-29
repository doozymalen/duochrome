import AppKit

/// Layer-edit mode view.
/// Floating layers panel on the left, floating tool strip on top, tool options panel on the right, canvas in the center.
/// The canvas and the adjust/retouch/geometry/layer detail panels are moved over from batch-edit mode (same photo, same undo).
final class StudioModeController: NSViewController {
    weak var host: MainWindowController?
    let layersPanel = StudioLayersPanel()
    let strip = StudioToolStrip()
    let options = StudioOptionsPanel()
    /// Multiple photo tabs (floating below the canvas, StudioExtras.swift)
    let tabs = StudioTabsBar()
    /// Left layers panel width. Inherits the left panel width of batch edit/tethering when switching modes (Modes.swift).
    lazy var layersWidth = layersPanel.widthAnchor.constraint(equalToConstant: GlassLayoutController.sharedLeft)
    /// Right tool options panel width (same as the right panel in batch edit/tethering)
    lazy var optionsWidth = options.widthAnchor.constraint(equalToConstant: GlassLayoutController.sharedRight)
    private let canvasHost = NSView()
    private(set) var currentTool = UserDefaults.standard.string(forKey: "studioTool") ?? "hand"

    private var leftShown: [NSLayoutConstraint] = []
    private var leftHidden: [NSLayoutConstraint] = []
    private var rightShown: [NSLayoutConstraint] = []
    private var rightHidden: [NSLayoutConstraint] = []
    var showsLayers = UserDefaults.standard.object(forKey: "studioLeft") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsLayers, forKey: "studioLeft"); applyPanels() }
    }
    var showsOptions = UserDefaults.standard.object(forKey: "studioRight") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsOptions, forKey: "studioRight"); applyPanels() }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = StudioStyle.window.cgColor
        canvasHost.wantsLayer = true
        canvasHost.layer?.backgroundColor = StudioStyle.canvasBack.cgColor
        for v in [canvasHost, layersPanel, strip, options, tabs] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let top = root.safeAreaLayoutGuide.topAnchor
        let gap: CGFloat = 8
        root.addLayoutGuide(work)
        TitleBand.install(in: root, above: canvasHost)
        NSLayoutConstraint.activate([
            layersPanel.topAnchor.constraint(equalTo: top, constant: gap),
            layersPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gap),
            layersPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gap),
            layersWidth,
            options.topAnchor.constraint(equalTo: top, constant: gap),
            options.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gap),
            options.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gap),
            optionsWidth,
            strip.topAnchor.constraint(equalTo: top, constant: gap),
            strip.centerXAnchor.constraint(equalTo: work.centerXAnchor),
            strip.leadingAnchor.constraint(greaterThanOrEqualTo: work.leadingAnchor, constant: gap),
            strip.trailingAnchor.constraint(lessThanOrEqualTo: work.trailingAnchor, constant: -gap),
            strip.heightAnchor.constraint(equalToConstant: 44),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gap),
            tabs.centerXAnchor.constraint(equalTo: work.centerXAnchor),
            tabs.leadingAnchor.constraint(greaterThanOrEqualTo: work.leadingAnchor, constant: gap),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: work.trailingAnchor, constant: -gap),
            // Liquid Glass: the canvas spans the window, and panels and the tool strip float over it as glass.
            // The fitted photo sits between the panels (work) (updateCanvasInsets).
            canvasHost.topAnchor.constraint(equalTo: root.topAnchor),   // under the toolbar
            canvasHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvasHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            work.topAnchor.constraint(equalTo: top),
            work.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        leftShown = [work.leadingAnchor.constraint(equalTo: layersPanel.trailingAnchor, constant: gap)]
        leftHidden = [work.leadingAnchor.constraint(equalTo: root.leadingAnchor)]
        rightShown = [work.trailingAnchor.constraint(equalTo: options.leadingAnchor, constant: -gap)]
        rightHidden = [work.trailingAnchor.constraint(equalTo: root.trailingAnchor)]
        view = root
        applyPanels()

        strip.onPick = { [weak self] id in self?.selectTool(id) }
        strip.onCustomize = { [weak self] in self?.customize() }
        strip.reload(selected: currentTool)
        options.onCompare = { [weak self] in self?.host?.toggleOriginal(nil) }
        options.onSplit = { [weak self] in self?.host?.canvas.splitCompare.toggle() }
        tabs.isHidden = true
        tabs.onPick = { [weak self] i in self?.host?.pickTab(i) }
        tabs.onClose = { [weak self] i in self?.host?.closeTab(i) }
        options.onReset = { [weak self] in self?.resetCurrentTool() }
    }

    /// Work area between panels (center of the tool strip, where the fitted photo goes)
    private let work = NSLayoutGuide()

    private func applyPanels() {
        guard isViewLoaded else { return }
        layersPanel.isHidden = !showsLayers
        options.isHidden = !showsOptions
        NSLayoutConstraint.deactivate(leftShown + leftHidden + rightShown + rightHidden)
        NSLayoutConstraint.activate((showsLayers ? leftShown : leftHidden) + (showsOptions ? rightShown : rightHidden))
        updateCanvasInsets()
    }

    /// The canvas extends under the panels, so fit view fits into the area excluding panels and the tool strip.
    func updateCanvasInsets() {
        guard let canvas = canvasHost.subviews.first(where: { $0 is CanvasView }) as? CanvasView else { return }
        let gap: CGFloat = 8
        canvas.fitInsets = NSEdgeInsets(top: ModeBar.slot - 12, left: showsLayers ? gap + layersWidth.constant : 0,
                                        bottom: tabs.isHidden ? 0 : 44, right: showsOptions ? gap + optionsWidth.constant : 0)
    }

    // MARK: - Moving the canvas over

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

    // MARK: - Tools

    func selectTool(_ id: String) {
        guard let tool = StudioTool.named(id), let host else { return }
        if id == "export" { host.exportPhotos(nil); return }
        currentTool = id
        UserDefaults.standard.set(id, forKey: "studioTool")
        strip.reload(selected: id)
        host.applyStudioTool(tool)
        options.show(tool: tool, content: host.studioOptionsView(for: tool))
    }

    /// Tools whose content depends on the layer selection: refill the options panel when the selection changes
    static let selectionTools: Set<String> = ["selSubject", "fill", "gradient", "lighten", "darken", "saturate", "desaturate",
                                               "sharpen", "soften", "maskPaint", "arrange"]
    func refreshOptionsForSelection() {
        guard Self.selectionTools.contains(currentTool), let tool = StudioTool.named(currentTool), let host else { return }
        options.show(tool: tool, content: host.studioOptionsView(for: tool))
    }

    /// When the tool changes inside a panel, only sync the indicator (options panel unchanged).
    func noteTool(_ id: String) {
        currentTool = id
        UserDefaults.standard.set(id, forKey: "studioTool")
        strip.reload(selected: id)
    }

    /// Re-applies the last tool when entering the mode (and re-fetches moved panels).
    func restoreTool() { selectTool(StudioTool.named(currentTool) != nil ? currentTool : "hand") }

    private func resetCurrentTool() {
        guard let host else { return }
        switch currentTool {
        case "adjust", "whiteBalance": host.resetAdjustments(nil)
        default: NSSound.beep()
        }
    }

    private var customizeSheet: ToolCustomizeSheet?

    func customize() {
        guard let window = view.window else { return }
        let sheet = ToolCustomizeSheet()
        sheet.onDone = { [weak self] list in
            StudioTool.strip = list
            self?.strip.reload(selected: self?.currentTool ?? "")
        }
        customizeSheet = sheet
        window.beginSheet(sheet.window!)
    }
}

extension NSButton.BezelStyle {
    /// App-wide push button style. macOS 26's default push button is already a glass pill.
    /// (.glass barely showed a border over glass panels and looked like plain text)
    static var appPush: NSButton.BezelStyle { .rounded }
}

/// Transparent background with a plain arrow cursor (clicks pass through)
final class ArrowCursorView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum StudioStyle {
    static let window = NSColor(white: 0.13, alpha: 1)
    static let canvasBack = NSColor(white: 0.13, alpha: 1)
    static let panel = NSColor(white: 0.19, alpha: 1)
    static let panelBorder = NSColor.white.withAlphaComponent(0.07)
    static let selection = NSColor.white.withAlphaComponent(0.1)
    static let accent = NSColor.controlAccentColor

    /// Floating panel look. From macOS 26, Liquid Glass (NSGlassEffectView) sits behind.
    /// interactive: bars holding clickable buttons (tool strip, per-mode bars, toolbar pills) have glass that reacts to presses (macOS 27).
    static func floating(_ v: NSView, radius: CGFloat = 16, interactive: Bool = false) {
        v.wantsLayer = true
        // Plain arrow over floating panels (so the photo view's edit cursor doesn't show through)
        let arrow = ArrowCursorView(frame: v.bounds)
        arrow.autoresizingMask = [.width, .height]
        v.addSubview(arrow, positioned: .below, relativeTo: nil)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            // Clear glass (untinted). The whole-bar wobble on press is turned off
            // — the bar swelling when picking a tool looked bad.
            _ = interactive
            glass.frame = v.bounds
            glass.autoresizingMask = [.width, .height]
            // Behind the content (sibling views): the glass is only a background
            v.addSubview(glass, positioned: .below, relativeTo: nil)
            v.layer?.backgroundColor = NSColor.clear.cgColor
            v.layer?.cornerRadius = radius
            return
        }
        v.layer?.backgroundColor = panel.cgColor
        v.layer?.cornerRadius = radius
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = panelBorder.cgColor
        v.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
    }

    static func label(_ s: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        return t
    }

    static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject?, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }
}

// MARK: - Tool strip

/// Tool strip floating on top. Grouped by category; the selected tool gets a round background.
final class StudioToolStrip: NSView {
    var onPick: ((String) -> Void)?
    var onCustomize: (() -> Void)?
    /// Not clickable, like the preview in the customization window.
    var interactive = true
    private let stack = NSStackView()
    private(set) var buttons: [String: NSButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        StudioStyle.floating(self, radius: 22, interactive: true)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(selected: String, list: [String] = StudioTool.strip) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        for id in list {
            if id == StudioTool.separator {
                let gap = NSView()
                gap.widthAnchor.constraint(equalToConstant: 12).isActive = true
                stack.addArrangedSubview(gap)
                continue
            }
            guard let tool = StudioTool.named(id) else { continue }
            let b = ToolStripButton(tool: tool, selected: id == selected)
            b.target = self
            b.action = #selector(tapped(_:))
            b.isEnabled = interactive
            buttons[id] = b
            stack.addArrangedSubview(b)
        }
        if interactive {
            let more = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "도구 사용자화")!,
                                target: self, action: #selector(moreTapped))
            more.isBordered = false
            more.contentTintColor = .secondaryLabelColor
            more.toolTip = "가려진 도구를 보거나 도구 목록을 사용자화합니다"
            more.widthAnchor.constraint(equalToConstant: 30).isActive = true
            let gap = NSView()
            gap.widthAnchor.constraint(equalToConstant: 8).isActive = true
            stack.addArrangedSubview(gap)
            stack.addArrangedSubview(more)
        }
    }

    @objc private func tapped(_ sender: ToolStripButton) { onPick?(sender.tool.id) }
    @objc private func moreTapped() { onCustomize?() }
}

final class ToolStripButton: BarToolButton {
    let tool: StudioTool

    init(tool: StudioTool, selected: Bool) {
        self.tool = tool
        super.init(image: tool.image, tip: tool.title + (tool.key.isEmpty ? "" : " (\(tool.key.uppercased()))") + (tool.ready ? "" : " — 준비 중"))
        dimmed = !tool.ready
        isOn = selected
        setAccessibilityLabel(tool.title)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tool options panel

/// Tool options floating on the right. Title is the tool name, content differs per tool. Compare/reset at the bottom.
final class StudioOptionsPanel: NSView {
    var onCompare: (() -> Void)?
    var onSplit: (() -> Void)?
    @objc private func splitTapped() { onSplit?() }
    var onReset: (() -> Void)?
    private let title = StudioStyle.label("", size: 13, weight: .semibold, color: .labelColor)
    private let content = NSView()
    private let resetButton = NSButton(title: "초기화", target: nil, action: nil)
    private(set) var toolID = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        StudioStyle.floating(self)
        let line = NSBox(); line.boxType = .separator
        let compare = NSButton(image: NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: "비교")!,
                               target: self, action: #selector(compareTapped))
        compare.toolTip = "보정 전과 비교 (Y)"
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        for b in [compare, resetButton] { b.bezelStyle = .appPush; b.controlSize = .regular }
        let bottomLine = NSBox(); bottomLine.boxType = .separator
        let split = NSButton(image: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "반반 비교")!,
                             target: self, action: #selector(splitTapped))
        split.toolTip = "반반 비교: 왼쪽은 보정 전, 오른쪽은 보정 후"
        split.bezelStyle = .appPush
        let bar = NSStackView(views: [compare, split, resetButton])
        bar.distribution = .fillEqually
        for v in [title, line, content, bottomLine, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            content.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -4),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottomLine.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows tool options. With `content` nil, shows a work-in-progress note and planned options dimmed.
    func show(tool: StudioTool, content view: NSView?) {
        toolID = tool.id
        title.stringValue = tool.title
        resetButton.isEnabled = ["adjust", "whiteBalance"].contains(tool.id)
        content.subviews.forEach { $0.removeFromSuperview() }
        var v = view ?? Self.placeholder(tool)
        // Content without its own scroll (effect picker etc.) goes inside a scroll view: longer content stretched the window
        if !(v is NSScrollView), !(v is SelfScrollingOptions), !v.subviews.contains(where: { $0 is NSScrollView }) { v = Self.scrolled(v) }
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    static func scrolled(_ inner: NSView) -> NSScrollView {
        let sc = NSScrollView()
        sc.drawsBackground = false
        sc.hasVerticalScroller = true
        sc.autohidesScrollers = true
        let doc = FlippedStackView()
        doc.orientation = .vertical
        doc.alignment = .leading
        doc.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        inner.translatesAutoresizingMaskIntoConstraints = false
        doc.addArrangedSubview(inner)
        doc.translatesAutoresizingMaskIntoConstraints = false
        sc.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: sc.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: sc.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: sc.contentView.topAnchor),
            inner.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -24),
        ])
        return sc
    }

    /// Tool not built yet: show where options go, but not clickable.
    static func placeholder(_ tool: StudioTool) -> NSView {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for name in tool.plannedOptions {
            let row = SliderRow(label: name, min: 0, max: 100, format: "%.0f%%")
            row.value = 50
            row.slider.isEnabled = false
            row.alphaValue = 0.45
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        let note = NSTextField(wrappingLabelWithString: "준비 중인 도구입니다.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 250
        stack.addArrangedSubview(note)
        return stack
    }

    @objc private func compareTapped() { onCompare?() }
    @objc private func resetTapped() { onReset?() }
}

// MARK: - Layers panel

/// Floating layers panel on the left: title and buttons, blend/opacity, list, search.
final class StudioLayersPanel: NSView, NSSearchFieldDelegate {
    var current: (() -> DevelopSettings?)?
    var onChange: ((DevelopSettings) -> Void)?
    var selectedID: (() -> String?)?
    var onSelect: ((String?) -> Void)?
    /// Thumbnail and size of the background (RAW develop) row.
    var background: (() -> (image: NSImage?, name: String, size: CGSize)?)?
    var addMenu: (() -> NSMenu)?
    var moreMenu: (() -> NSMenu)?
    var onToggleMask: (() -> Void)?
    /// Layer context menu (nil = background)
    var rowMenu: ((String?) -> NSMenu)?

    private let blend = NSPopUpButton()
    private let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValue = StudioStyle.label("100%", color: .secondaryLabelColor)
    /// Layer list (drag to reorder/regroup, drop Finder images — DragDrop.swift)
    let dropList = LayerDropList()
    private var list: FlippedStackView { dropList }
    private let search = ClickFocusSearchField()
    /// Filter by kind (all, adjustment, image, text, shape, fill, group)
    let kindFilter = NSPopUpButton()
    static let kinds: [(String, (AdjustLayer) -> Bool)] = [
        ("전체", { _ in true }), ("조정", { $0.kind == "adjust" || $0.kind == "copy" }), ("이미지", { $0.isImage || $0.kind == "paint" }),
        ("글자", { $0.isText }), ("모양", { $0.kind == "shape" }), ("칠", { $0.isFill }), ("그룹", { $0.isGroup }),
    ]
    private let addButton = StudioStyle.iconButton("plus", "레이어 추가", nil, #selector(addTapped))
    private let maskButton = StudioStyle.iconButton("rectangle.inset.filled.and.person.filled", "마스크 보기 (M)", nil, #selector(maskTapped))
    private let moreButton = StudioStyle.iconButton("ellipsis", "레이어 작업", nil, #selector(moreTapped))

    override init(frame: NSRect) {
        super.init(frame: frame)
        StudioStyle.floating(self)
        for b in [addButton, maskButton, moreButton] { b.target = self }
        let title = StudioStyle.label("레이어", size: 13, weight: .semibold, color: .labelColor)
        let header = NSStackView(views: [title, NSView(), addButton, maskButton, moreButton])
        header.spacing = 8

        for (key, name, _) in AdjustLayer.blendModes {
            blend.addItem(withTitle: name)
            blend.lastItem?.representedObject = key
        }
        blend.insertItem(withTitle: AdjustLayer.passThrough.1, at: 0)
        blend.item(at: 0)?.representedObject = AdjustLayer.passThrough.0
        blend.controlSize = .small
        blend.target = self
        blend.action = #selector(blendChanged)
        opacity.controlSize = .small
        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacity.isContinuous = true
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityValue.alignment = .right
        // Two rows: [blend mode ········] / [opacity  slider  100%] (so they don't overlap in narrow panels)
        let opRow = NSStackView(views: [StudioStyle.label("불투명도"), opacity, opacityValue])
        opRow.spacing = 8
        opacityValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
        opacity.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let blendRow = NSStackView(views: [blend, opRow])
        blendRow.orientation = .vertical
        blendRow.alignment = .leading
        blendRow.spacing = 8
        blend.widthAnchor.constraint(equalTo: blendRow.widthAnchor).isActive = true
        opRow.widthAnchor.constraint(equalTo: blendRow.widthAnchor).isActive = true
        let sep = NSBox(); sep.boxType = .separator

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "검색"
        search.delegate = self
        search.controlSize = .regular
        let sep2 = NSBox(); sep2.boxType = .separator
        kindFilter.controlSize = .small
        kindFilter.addItems(withTitles: Self.kinds.map(\.0))
        kindFilter.target = self
        kindFilter.action = #selector(kindChanged)
        kindFilter.toolTip = "종류별 거르기"

        for v in [header, blendRow, sep, scroll, sep2, search, kindFilter] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            blendRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            blendRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            blendRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: blendRow.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: sep2.topAnchor, constant: -6),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            sep2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sep2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sep2.bottomAnchor.constraint(equalTo: search.topAnchor, constant: -10),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: kindFilter.leadingAnchor, constant: -6),
            search.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            kindFilter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            kindFilter.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            kindFilter.widthAnchor.constraint(equalToConstant: 76),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var selected: AdjustLayer? {
        guard let id = selectedID?(), let s = current?() else { return nil }
        return s.layers.first { $0.id == id }
    }

    func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = current?()
        let layers = s?.layers ?? []
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let sel = selectedID?()
        let kind = Self.kinds[max(0, kindFilter.indexOfSelectedItem)].1
        let filtering = !q.isEmpty || kindFilter.indexOfSelectedItem > 0
        for (i, layer) in layers.enumerated().reversed() where (q.isEmpty || layer.name.localizedCaseInsensitiveContains(q)) && kind(layer) {
            let row = StudioLayerRow(layer: layer, depth: !filtering ? LayerTree.depth(layers, i) : 0, selected: layer.id == sel)
            row.onClick = { [weak self] in self?.onSelect?(layer.id); self?.reload() }
            row.contextMenu = { [weak self] in self?.rowMenu?(layer.id) }
            row.onToggle = { [weak self] on in
                guard let self, var s = self.current?(), let k = s.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                s.layers[k].enabled = on
                self.onChange?(s)
                self.reload()
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if let bg = background?(), kindFilter.indexOfSelectedItem <= 0, q.isEmpty || "배경".contains(q) || bg.name.localizedCaseInsensitiveContains(q) {
            let row = StudioLayerRow(background: bg.image, name: bg.name,
                                     size: bg.size, selected: sel == nil)
            row.onClick = { [weak self] in self?.onSelect?(nil); self?.reload() }
            row.contextMenu = { [weak self] in self?.rowMenu?(nil) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        // Blend and opacity belong to the selected layer. Disabled when the background is selected.
        let layer = selected
        blend.isEnabled = layer != nil
        opacity.isEnabled = layer != nil
        blend.item(at: 0)?.isHidden = !(layer?.isGroup ?? false)
        let key = layer?.blend ?? "normal"
        blend.selectItem(at: blend.itemArray.firstIndex { $0.representedObject as? String == key } ?? 1)
        opacity.doubleValue = Double(layer?.opacity ?? 1)
        opacityValue.stringValue = "\(Int((opacity.doubleValue * 100).rounded()))%"
    }

    private func editSelected(_ f: (inout AdjustLayer) -> Void) {
        guard let id = selectedID?(), var s = current?(), let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !s.layers[i].locked else { NSSound.beep(); reload(); return }
        f(&s.layers[i])
        onChange?(s)
    }

    @objc private func blendChanged() {
        guard let key = blend.selectedItem?.representedObject as? String else { return }
        editSelected { $0.blend = key }
        reload()
    }

    @objc private func opacityChanged() {
        opacityValue.stringValue = "\(Int((opacity.doubleValue * 100).rounded()))%"
        editSelected { $0.opacity = Float(opacity.doubleValue) }
        if NSApp.currentEvent?.type != .leftMouseDragged { reload() }
    }

    @objc private func addTapped() { popUp(addMenu?(), from: addButton) }
    @objc private func moreTapped() { popUp(moreMenu?(), from: moreButton) }
    @objc private func maskTapped() { onToggleMask?() }

    private func popUp(_ menu: NSMenu?, from b: NSView) {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func kindChanged() { reload() }
}

/// Search field that takes focus only on click (so it doesn't grab focus when the window first appears).
final class ClickFocusSearchField: NSSearchField {
    override var acceptsFirstResponder: Bool {
        let t = NSApp.currentEvent?.type
        return t == .leftMouseDown || t == .keyDown && window?.firstResponder === currentEditor()
    }
}

/// One layer list row: eye, content thumbnail, mask thumbnail, name/kind.
final class StudioLayerRow: DraggableLayerRow {
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { onClick?(); return contextMenu?() }
    var onToggle: ((Bool) -> Void)?
    private let isSelected: Bool

    init(layer: AdjustLayer, depth: Int, selected: Bool) {
        isSelected = selected
        super.init(frame: .zero)
        dragID = layer.id
        isGroupRow = layer.isGroup
        let content = LayerRowContent(layer: layer, name: layer.name, subtitle: LayerRowContent.subtitle(layer),
                                      visible: layer.enabled, toggleable: true, selected: selected)
        content.onToggle = { [weak self] on in self?.onToggle?(on) }
        build(content, depth: depth)
    }

    init(background image: NSImage?, name: String, size: CGSize, selected: Bool) {
        isSelected = selected
        super.init(frame: .zero)
        LayerThumbs.backgroundThumb = image
        let sub = size == .zero ? "RAW 현상" : "RAW 현상 · \(Int(size.width)) × \(Int(size.height)) px"
        let content = LayerRowContent(layer: nil, background: image ?? NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil),
                                      name: name, subtitle: sub, visible: true, toggleable: false, selected: selected)
        build(content, depth: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(_ content: LayerRowContent, depth: Int) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.38).cgColor : NSColor.clear.cgColor
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 + CGFloat(depth) * 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

// MARK: - Tool customization

/// "Customize Tools" window. Shows tools by category; clicking adds to or removes from the tool strip above.
final class ToolCustomizeSheet: NSWindowController {
    var onDone: (([String]) -> Void)?
    private var working = StudioTool.strip
    private let preview = StudioToolStrip()
    private let overlay = StripDragOverlay()
    private var tiles: [String: ToolTile] = [:]

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: w)
        let root = NSView()
        preview.interactive = false
        preview.reload(selected: "", list: working)
        let hint = StudioStyle.label("도구를 눌러 넣거나 빼고, 끌어서 원하는 자리에 넣습니다. 막대 안에서 끌면 순서가 바뀌고, 막대 밖으로 끌어내면 빠집니다. 흐린 도구는 아직 준비 중입니다.", size: 12, color: .labelColor)

        let groups = FlippedStackView()
        groups.orientation = .vertical
        groups.alignment = .leading
        groups.spacing = 18
        groups.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for g in StudioTool.Group.allCases {
            let tools = StudioTool.all.filter { $0.group == g }
            guard !tools.isEmpty else { continue }
            groups.addArrangedSubview(StudioStyle.label(g.rawValue, size: 13, weight: .semibold, color: .labelColor))
            var row: NSStackView?
            for (i, t) in tools.enumerated() {
                if i % 11 == 0 {
                    row = NSStackView()
                    row?.spacing = 4
                    row?.alignment = .top
                    groups.addArrangedSubview(row!)
                }
                let tile = ToolTile(tool: t)
                tile.toolID = t.id
                tile.onClick = { [weak self] in self?.toggle(t.id) }
                tiles[t.id] = tile
                row?.addArrangedSubview(tile)
            }
        }
        let groupsBox = NSView()
        groupsBox.wantsLayer = true
        groupsBox.layer?.cornerRadius = 10
        groupsBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = groups
        groups.translatesAutoresizingMaskIntoConstraints = false

        let help = NSButton(title: "", target: nil, action: nil)
        help.bezelStyle = .helpButton
        let space = NSButton(title: "빈칸 넣기", target: self, action: #selector(addSpace))
        let revert = NSButton(title: "기본값으로 되돌리기", target: self, action: #selector(revert))
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "완료", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let bar = NSStackView(views: [help, space, revert, NSView(), cancel, done])
        for v in [preview, hint, groupsBox, scroll, bar, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        overlay.strip = preview
        overlay.list = { [weak self] in self?.working ?? [] }
        overlay.onInsert = { [weak self] id, at in self?.insert(id, at: at) }
        overlay.onRemove = { [weak self] id in if self?.working.contains(id) == true { self?.toggle(id) } }
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: preview.topAnchor, constant: -8),
            overlay.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            overlay.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: -40),
            overlay.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 40),
        ])
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            preview.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            preview.heightAnchor.constraint(equalToConstant: 48),
            preview.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 18),
            hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            groupsBox.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            groupsBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            groupsBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            groupsBox.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: groupsBox.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: groupsBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: groupsBox.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: groupsBox.bottomAnchor),
            groups.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            groups.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            groups.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        w.contentView = root
        refresh()
    }

    private func refresh() {
        preview.reload(selected: "", list: working)
        for (id, tile) in tiles { tile.inStrip = working.contains(id) }
    }

    func toggle(_ id: String) {
        if let i = working.firstIndex(of: id) {
            working.remove(at: i)
            // Clean up places left with only separators.
            var cleaned: [String] = []
            for x in working where !(x == StudioTool.separator && (cleaned.last == StudioTool.separator || cleaned.isEmpty)) { cleaned.append(x) }
            if cleaned.last == StudioTool.separator { cleaned.removeLast() }
            working = cleaned
        } else {
            working.append(id)
        }
        refresh()
    }

    /// Inserts id at position `at` in the tool strip (moves it there if already present)
    func insert(_ id: String, at: Int) {
        var at = min(max(at, 0), working.count)
        if let old = working.firstIndex(of: id) {
            working.remove(at: old)
            if old < at { at -= 1 }
        }
        working.insert(id, at: min(at, working.count))
        refresh()
    }

    @objc private func addSpace() { if working.last != StudioTool.separator { working.append(StudioTool.separator) }; refresh() }
    @objc private func revert() { working = StudioTool.defaultStrip; refresh() }
    @objc private func cancel() { finish() }
    @objc private func done() { onDone?(working); finish() }

    private func finish() {
        if let w = window, let p = w.sheetParent { p.endSheet(w) } else { close() }
    }
}

/// One tool cell in the customization window (icon + name). Rounded border if it's in the tool strip.
final class ToolTile: NSView {
    var onClick: (() -> Void)?
    var inStrip = false { didSet { layer?.borderWidth = inStrip ? 1.5 : 0 } }

    init(tool: StudioTool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        let icon = NSImageView(image: tool.image)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = tool.ready ? .labelColor : .tertiaryLabelColor
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 16
        circle.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(icon)
        let name = StudioStyle.label(tool.title, size: 11, color: tool.ready ? .secondaryLabelColor : .tertiaryLabelColor)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.preferredMaxLayoutWidth = 92
        let v = NSStackView(views: [circle, name])
        v.orientation = .vertical
        v.spacing = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        toolTip = tool.ready ? tool.title : "\(tool.title) — 준비 중"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96),
            heightAnchor.constraint(equalToConstant: 84),
            circle.widthAnchor.constraint(equalToConstant: 32),
            circle.heightAnchor.constraint(equalToConstant: 32),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            v.centerXAnchor.constraint(equalTo: centerXAnchor),
            v.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Click to add/remove, drag to place at a chosen spot in the strip (.duochromeTool in DragDrop.swift)
    var toolID = ""
    private var downAt: NSPoint?
    private var dragged = false
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        guard let s = downAt, !dragged, hypot(event.locationInWindow.x - s.x, event.locationInWindow.y - s.y) > 4 else { return }
        dragged = true
        let item = NSPasteboardItem()
        item.setString(toolID, forType: .duochromeTool)
        let di = NSDraggingItem(pasteboardWriter: item)
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        let img = NSImage(size: bounds.size)
        if let rep { cacheDisplay(in: bounds, to: rep); img.addRepresentation(rep) }
        di.setDraggingFrame(bounds, contents: img)
        beginDraggingSession(with: [di], event: event, source: ToolDragSource.shared)
    }
    override func mouseUp(with event: NSEvent) { if !dragged { onClick?() }; downAt = nil; dragged = false }
}


/// Drag source for tools in the customization window (moves only within the app)
final class ToolDragSource: NSObject, NSDraggingSource {
    static let shared = ToolDragSource()
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// Drag board over the tool strip preview at the top of the customization window: shows the drop position as a vertical line and inserts.
/// Dragging a tool within the strip reorders it; dropping outside removes it (same as macOS toolbar customization).
final class StripDragOverlay: NSView, NSDraggingSource {
    weak var strip: StudioToolStrip?
    var list: (() -> [String])?
    var onInsert: ((String, Int) -> Void)?
    var onRemove: ((String) -> Void)?
    private let marker = NSView()
    private var pendingIndex: Int?
    private var downAt: NSPoint?
    private var downID: String?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.duochromeTool])
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        marker.layer?.cornerRadius = 1.5
        marker.isHidden = true
        addSubview(marker)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Tool buttons in the strip (working order, separators excluded) → horizontal centers in this board's coordinates
    private func slots() -> [(id: String, index: Int, midX: CGFloat)] {
        guard let strip, let ids = list?() else { return [] }
        return ids.enumerated().compactMap { i, id in
            guard let b = strip.buttons[id] else { return nil }
            let r = convert(b.bounds, from: b)
            return (id, i, r.midX)
        }
    }

    private func insertIndex(at x: CGFloat) -> (Int, CGFloat) {
        let s = slots()
        guard !s.isEmpty else { return (0, bounds.midX) }
        for (k, slot) in s.enumerated() where x < slot.midX {
            let lineX = k == 0 ? slot.midX - 19 : (s[k - 1].midX + slot.midX) / 2
            return (slot.index, lineX)
        }
        return ((list?().count ?? s.count), s[s.count - 1].midX + 19)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .duochromeTool) != nil else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        let (i, x) = insertIndex(at: p.x)
        pendingIndex = i
        marker.frame = NSRect(x: x - 1.5, y: bounds.midY - 18, width: 3, height: 36)
        marker.isHidden = false
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { marker.isHidden = true; pendingIndex = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        marker.isHidden = true
        guard let id = sender.draggingPasteboard.string(forType: .duochromeTool), let i = pendingIndex else { return false }
        onInsert?(id, i)
        pendingIndex = nil
        return true
    }

    // dragging tools within the strip (reorder, remove)
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downAt = event.locationInWindow
        dragging = false
        downID = slots().min(by: { abs($0.midX - p.x) < abs($1.midX - p.x) }).flatMap { abs($0.midX - p.x) < 18 ? $0.id : nil }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = downAt, !dragging, let id = downID, let b = strip?.buttons[id],
              hypot(event.locationInWindow.x - s.x, event.locationInWindow.y - s.y) > 4 else { return }
        dragging = true
        let item = NSPasteboardItem()
        item.setString(id, forType: .duochromeTool)
        let di = NSDraggingItem(pasteboardWriter: item)
        let frame = convert(b.bounds, from: b)
        di.setDraggingFrame(frame, contents: b.image)
        beginDraggingSession(with: [di], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { downAt = nil; downID = nil; dragging = false }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    /// If nothing accepts it (dropped outside the strip), remove it
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [], let id = downID { onRemove?(id) }
        downID = nil
    }
}
