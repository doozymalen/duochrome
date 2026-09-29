import AppKit

/// Per-mode bar. A rounded bar floating below the toolbar, over the canvas.
/// The toolbar (top) is the same in all three modes; tools and actions used only in one mode go here.
/// Same look, height, and position as the layer-edit tool strip (StudioToolStrip).
final class ModeBar: NSView {
    /// Plain arrow over panels and bars (so the photo view's edit cursor doesn't show through)
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    static let height: CGFloat = 44
    /// Height of the bar plus top/bottom margins. The canvas starts this far down.
    static let slot: CGFloat = 8 + height + 8

    private let stack = NSStackView()

    init(_ items: [NSView]) {
        super.init(frame: .zero)
        StudioStyle.floating(self, radius: Self.height / 2, interactive: true)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        items.forEach { stack.addArrangedSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Gap between groups (12 pt, same as between groups in the layer-edit tool strip)
    static func gap(_ width: CGFloat = 12) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    /// Centers the bar in its slot (shrinks within 8 pt side margins when narrow).
    static func place(_ bar: NSView, in slot: NSView) {
        bar.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(bar)
        let center = bar.centerXAnchor.constraint(equalTo: slot.centerXAnchor)
        center.priority = .defaultHigh
        NSLayoutConstraint.activate([
            center,
            bar.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: slot.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: slot.trailingAnchor, constant: -8),
        ])
    }
}

/// Tool button on a glass bar (shared by per-mode bars and the layer-edit tool strip).
/// Selected tool: a 30 pt circle (clear white, faint shadow) inset within the bar grows in slightly and the icon turns black.
/// Hover shows a faint circle. (The old white pill filling the bar height looked bad)
class BarToolButton: NSButton {
    static let size: CGFloat = 34
    static let dot: CGFloat = 30

    var isOn = false { didSet { if isOn != oldValue { restyle(animated: true) } } }
    /// Dimmed like a work-in-progress tool (still clickable)
    var dimmed = false { didSet { restyle(animated: false) } }
    private let dotLayer = CALayer()
    private var hovering = false

    init(image: NSImage?, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        self.image = image
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        setAccessibilityLabel(tip)
        wantsLayer = true
        dotLayer.cornerRadius = Self.dot / 2
        dotLayer.shadowColor = NSColor.black.cgColor
        dotLayer.shadowOffset = CGSize(width: 0, height: -1)
        dotLayer.shadowRadius = 3
        layer?.insertSublayer(dotLayer, at: 0)
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
        restyle(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { restyle(animated: false) } }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dotLayer.bounds = CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot)
        dotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; restyle(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle(animated: true) }

    private func restyle(animated: Bool) {
        let fill: NSColor = isOn ? NSColor(white: 0.97, alpha: 1)
            : (hovering && isEnabled ? NSColor.white.withAlphaComponent(0.10) : .clear)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setDisableActions(!animated)
        dotLayer.backgroundColor = fill.cgColor
        dotLayer.shadowOpacity = isOn ? 0.35 : 0
        CATransaction.commit()
        if animated && isOn {
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.82
            pop.toValue = 1
            pop.duration = 0.18
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dotLayer.add(pop, forKey: "pop")
        }
        contentTintColor = isOn ? NSColor(white: 0.1, alpha: 1)
            : (!isEnabled || dimmed ? .tertiaryLabelColor : .labelColor)
    }
}

/// Round button in a per-mode bar.
final class ModeBarButton: BarToolButton {
    init(_ symbol: String, _ tip: String, target: AnyObject?, action: Selector) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let img = (NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tip))?.withSymbolConfiguration(config)
        super.init(image: img, tip: tip)
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Search field inside a per-mode bar (pill shape, small size matched to the bar height).
final class ModeBarSearchField: NSSearchField {
    /// Takes focus only on click, so it doesn't grab focus when the window first appears (same as ClickFocusSearchField).
    override var acceptsFirstResponder: Bool {
        let t = NSApp.currentEvent?.type
        return t == .leftMouseDown || t == .keyDown && window?.firstResponder === currentEditor()
    }

    convenience init(placeholder: String, width: CGFloat, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        placeholderString = placeholder
        controlSize = .regular
        sendsSearchStringImmediately = false
        self.target = target
        self.action = action
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }
}

// MARK: - Batch-edit mode bar and shared toolbar actions

extension MainWindowController {
    /// Batch-edit bar: [8 cursor tools] [auto adjust · exposure warning · copy adjustments · apply adjustments] (photo search moved above the right photo panel)
    func makeBulkBar() -> ModeBar {
        let straighten = NSImage(systemSymbolName: "level", accessibilityDescription: nil) != nil ? "level" : "ruler"
        let keystone = NSImage(systemSymbolName: "perspective", accessibilityDescription: nil) != nil ? "perspective" : "trapezoid.and.line.vertical"
        let tools: [(String, String)] = [
            ("hand.raised", "이동 (H)"),
            ("plus.magnifyingglass", "확대 (Z) — 옵션을 누르고 누르면 축소"),
            ("crop", "크롭 (C)"),
            (straighten, "수평 맞추기 (L) — 기울어진 선을 따라 끌기"),
            (keystone, "키스톤 (K) — 세로여야 할 선 두 개를 따라 끌기"),
            ("eyedropper", "화이트 밸런스 (W) — 무채색이어야 할 곳 누르기"),
            ("bandage", "리터칭 (Q) — 복구 브러시·복제 도장·패치"),
            ("paintbrush", "마스크 (B) — 고른 레이어의 마스크를 칠하거나 그라디언트를 끌기"),
        ]
        cursorButtons = tools.map { ModeBarButton($0.0, $0.1, target: self, action: #selector(setCursorTool(_:))) }
        cursorButtons.first?.isOn = true
        let clip = ModeBarButton("exclamationmark.triangle", "노출 경고 (⌥⌘O)", target: self, action: #selector(toggleClipping(_:)))
        clippingButton = clip
        return ModeBar(cursorButtons + [
            ModeBar.gap(),
            ModeBarButton("wand.and.stars", "자동 조정 (⇧⌘A)", target: self, action: #selector(autoAdjust(_:))),
            clip,
            ModeBarButton("doc.on.doc", "조정 복사 (⇧⌘C)", target: self, action: #selector(copyAdjustments(_:))),
            ModeBarButton("doc.on.clipboard", "조정 적용 (⇧⌘V)", target: self, action: #selector(pasteAdjustments(_:))),
        ])
    }

    /// Canvas visible in the current mode (moved by the toolbar zoom control)
    var activeCanvas: CanvasView { mode == .tether ? tetherMode.viewer.canvas : viewer.canvas }

    /// Left/right panel buttons of the shared toolbar. Collapse/expand that mode's panels.
    @objc func toggleLeftPanel(_ sender: Any?) { togglePanel(left: true) }
    @objc func toggleRightPanel(_ sender: Any?) { togglePanel(left: false) }

    func togglePanel(left: Bool) {
        let layout: GlassLayoutController? = switch mode {
        case .edit: self.split
        case .tether: tetherMode.split
        case .library: libraryMode.split
        case .studio: nil
        }
        if let layout {
            if left { layout.showsLeft.toggle() } else { layout.showsRight.toggle() }
        } else if left {
            studioMode.showsLayers.toggle()
        } else {
            studioMode.showsOptions.toggle()
        }
    }
}
