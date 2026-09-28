import AppKit

/// 모드별 막대. 창 막대 밑, 캔버스 위에 떠 있는 둥근 막대.
/// 창 막대(맨 위)는 세 모드가 똑같고, 그 모드에서만 쓰는 도구·동작은 여기에 둔다.
/// 심화 보정의 도구 막대(StudioToolStrip)와 같은 모양·같은 높이·같은 자리.
final class ModeBar: NSView {
    /// 패널·막대 위는 보통 화살표 (아래 사진 화면의 편집 포인터가 비치지 않게)
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    static let height: CGFloat = 44
    /// 막대와 위아래 여백을 합친 높이. 캔버스는 이만큼 아래에서 시작한다.
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

    /// 무리 사이 빈칸 (심화 보정 도구 막대의 무리 사이와 같은 12pt)
    static func gap(_ width: CGFloat = 12) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    /// 막대를 slot 가운데에 띄운다 (좁으면 양옆 8pt 안으로 줄어든다).
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

/// 유리 막대 위 도구 단추 (모드별 막대·심화 보정 도구 막대 공통).
/// 고른 도구: 막대 안에 여백을 두고 앉은 30pt 원(맑은 흰색, 옅은 그림자)이 살짝 커지며 나타나고 아이콘은 검게.
/// 올려 두면 옅은 원. (예전의 막대 높이를 꽉 채우던 흰 알약은 보기 싫었다)
class BarToolButton: NSButton {
    static let size: CGFloat = 34
    static let dot: CGFloat = 30

    var isOn = false { didSet { if isOn != oldValue { restyle(animated: true) } } }
    /// 준비 중 도구처럼 흐리게 (누를 수는 있다)
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

/// 모드별 막대의 둥근 단추.
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

/// 모드별 막대 안의 검색칸 (알약 모양, 막대 높이에 맞춘 작은 크기).
final class ModeBarSearchField: NSSearchField {
    /// 창이 처음 뜰 때 검색칸이 초점을 가져가지 않게, 눌렀을 때만 초점을 받는다 (ClickFocusSearchField와 같다).
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

// MARK: - 대량 보정 모드별 막대와 공통 창 막대 동작

extension MainWindowController {
    /// 대량 보정 막대: [커서 도구 8개] [자동 조정 · 노출 경고 · 조정 복사 · 조정 적용] (사진 검색은 오른쪽 사진 패널 위로 옮겼다)
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

    /// 지금 모드에서 보이는 캔버스 (창 막대의 확대 조절이 이걸 움직인다)
    var activeCanvas: CanvasView { mode == .tether ? tetherMode.viewer.canvas : viewer.canvas }

    /// 공통 창 막대의 왼쪽·오른쪽 패널 단추. 모드마다 그 모드의 패널을 접고 편다.
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
