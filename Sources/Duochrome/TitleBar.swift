import AppKit

/// 창 막대 (세 모드 공통). 단추를 알약 모양 묶음에 담는다.
/// 왼쪽: [패널 단추 | 패널 메뉴] [− 확대 +] 다음에 제목. 가운데: 모드 전환. 오른쪽: [실행 취소 · 다시] [비교 · 내보내기 · 더 보기] [오른쪽 패널].
final class ToolbarCapsule: NSView {
    static let height: CGFloat = 30
    private let stack = NSStackView()

    init(_ items: [NSView]) {
        super.init(frame: .zero)
        // 창 막대 알약도 리퀴드 글래스 (macOS 26 이전에는 옅은 반투명 알약)
        StudioStyle.floating(self, radius: Self.height / 2, interactive: true)
        if #unavailable(macOS 26) {
            shadow = nil
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        }
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
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


    /// 알약 안 단추 (테두리 없음, 아이콘만)
    static func button(_ symbol: String, _ tip: String, target: AnyObject?, action: Selector?, width: CGFloat = 32) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let b = NSButton(image: (NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage())
            .withSymbolConfiguration(config) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }

    /// 누르면 메뉴가 뜨는 단추 (패널 단추 옆 ⌄, 더 보기 ⋯)
    static func menuButton(_ symbol: String, _ tip: String, width: CGFloat = 24, menu: @escaping () -> NSMenu) -> NSButton {
        let b = MenuCapsuleButton(image: NSImage(), target: nil, action: nil)
        let config = NSImage.SymbolConfiguration(pointSize: symbol == "chevron.down" ? 10 : 14, weight: symbol == "chevron.down" ? .semibold : .regular)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        b.makeMenu = menu
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.target = b
        b.action = #selector(MenuCapsuleButton.pop)
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }

    /// 알약 안 칸막이 (패널 단추와 ⌄ 사이 선)
    static func divider() -> NSView {
        let v = NSBox()
        v.boxType = .custom
        v.borderWidth = 0
        v.fillColor = NSColor.white.withAlphaComponent(0.14)
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }
}

final class MenuCapsuleButton: NSButton {
    var makeMenu: (() -> NSMenu)?
    @objc func pop() {
        guard let menu = makeMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// 확대 슬라이더: 가는 줄, 왼쪽부터 손잡이까지 강조 색, 작은 흰 손잡이
final class CapsuleSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let h: CGFloat = 3
        let track = NSRect(x: rect.minX + 2, y: rect.midY - h / 2, width: rect.width - 4, height: h)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let knob = knobRect(flipped: flipped)
        var fill = track
        fill.size.width = max(0, knob.midX - track.minX)
        (isEnabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = 12
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        (isEnabled ? NSColor.white : NSColor(white: 0.6, alpha: 1)).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSToolbarItem.Identifier {
    static let barPanels = Self("barPanels")
    static let barHistory = Self("barHistory")
    static let barActions = Self("barActions")
    static let barAI = Self("barAI")
    static let barInspector = Self("barInspector")
}

extension MainWindowController {
    /// 공통 창 막대의 항목 순서
    var titleBarItems: [NSToolbarItem.Identifier] {
        [.barPanels, .studioZoom, .flexibleSpace, .modeSwitch, .flexibleSpace, .barAI, .barHistory, .barActions, .barInspector]
    }

    func titleBarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        func item(_ label: String, _ capsule: ToolbarCapsule, navigational: Bool = false) -> NSToolbarItem {
            let it = NSToolbarItem(itemIdentifier: id)
            it.label = label
            it.view = capsule
            it.isBordered = false
            // 제목보다 앞(왼쪽)에 둔다 — [패널] [확대] 다음에 제목
            it.isNavigational = navigational
            return it
        }
        let T = ToolbarCapsule.self
        switch id {
        case .barPanels:
            return item("패널", ToolbarCapsule([
                T.button("sidebar.left", "왼쪽 패널 보기·숨기기", target: self, action: #selector(toggleLeftPanel(_:))),
                T.divider(),
                T.menuButton("chevron.down", "패널", menu: { [weak self] in self?.panelsMenu() ?? NSMenu() }),
            ]), navigational: true)
        case .studioZoom:
            let minus = T.button("minus", "축소", target: self, action: #selector(studioZoomOut(_:)), width: 22)
            let plus = T.button("plus", "확대", target: self, action: #selector(studioZoomIn(_:)), width: 22)
            for b in [minus, plus] { b.contentTintColor = .secondaryLabelColor }
            // 슬라이더는 배율의 로그 (1% ~ 1600%)
            let slider = NSSlider(value: 2, minValue: 0, maxValue: log10(1600), target: self, action: #selector(studioZoomSlid(_:)))
            slider.cell = CapsuleSliderCell()
            slider.minValue = 0; slider.maxValue = log10(1600); slider.doubleValue = 2
            slider.target = self; slider.action = #selector(studioZoomSlid(_:))
            slider.isContinuous = true
            slider.controlSize = .small
            slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 58).isActive = true
            studioZoomSlider = slider
            studioZoomLabel = label
            return item("확대/축소", ToolbarCapsule([minus, slider, plus, label, ModeBar.gap(6)]), navigational: true)
        case .barAI:
            let b = T.button("sparkles", "AI 엔진 켜기·끄기", target: self, action: #selector(toggleAIEngine(_:)))
            AIEngineButton.attach(b)
            return item("AI 엔진", ToolbarCapsule([b]))
        case .barHistory:
            return item("실행 취소", ToolbarCapsule([
                T.button("arrow.uturn.backward", "실행 취소 (⌘Z)", target: self, action: #selector(undoAdjust(_:))),
                T.button("arrow.uturn.forward", "다시 실행 (⇧⌘Z)", target: self, action: #selector(redoAdjust(_:))),
            ]))
        case .barActions:
            let jobs = T.button("hourglass", "작업 진행 창 열기·닫기 (⌥⌘J)", target: self, action: #selector(toggleJobsPanel(_:)))
            JobsPanel.barButton = jobs
            JobsPanel.refreshBarButton()
            return item("동작", ToolbarCapsule([
                T.button("square.split.2x1", "보정 전과 비교", target: self, action: #selector(toggleOriginal(_:))),
                T.button("square.and.arrow.up", "내보내기 (⇧⌘E)", target: self, action: #selector(exportPhotos(_:))),
                jobs,
                T.menuButton("ellipsis", "더 보기", width: 32, menu: { [weak self] in self?.moreMenu() ?? NSMenu() }),
            ]))
        case .barInspector:
            return item("오른쪽 패널", ToolbarCapsule([
                T.button("sidebar.right", "오른쪽 패널 보기·숨기기", target: self, action: #selector(toggleRightPanel(_:))),
            ]))
        default: return nil
        }
    }

    private func panelsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "왼쪽 패널 보기·숨기기", action: #selector(toggleLeftPanel(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "오른쪽 패널 보기·숨기기", action: #selector(toggleRightPanel(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "모든 패널 보기·숨기기 (Tab)", action: #selector(toggleAllPanels(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        for mm in AppMode.segments {
            let i = m.addItem(withTitle: "\(mm.title) 모드", action: #selector(pickModeFromMenu(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = mm.rawValue
            i.state = mm == mode ? .on : .off
        }
        return m
    }

    private func moreMenu() -> NSMenu {
        let m = NSMenu()
        if mode == .studio {
            m.addItem(withTitle: "도구 사용자화…", action: #selector(studioCustomize(_:)), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "맞춤 크기로 보기", action: #selector(zoomActiveFit(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "실제 크기 (100%)", action: #selector(zoomActiveActual(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "설정…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        return m
    }

    @objc func toggleAllPanels(_ sender: Any?) {
        if mode == .studio { keyTogglePanels(left: true) } else { togglePanel(left: true); togglePanel(left: false) }
    }
    @objc func pickModeFromMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? Int, let m = AppMode(rawValue: raw) { setMode(m) }
    }
    @objc func zoomActiveFit(_ sender: Any?) { activeCanvas.zoomToFit() }
    @objc func zoomActiveActual(_ sender: Any?) { activeCanvas.zoomToActual() }
}

/// 모드 전환 (창 가운데). 알약 안에 세 칸, 고른 칸은 안쪽 알약으로 칠한다.
final class ModeSwitch: NSView {
    var onPick: ((Int) -> Void)?
    var selectedSegment = 0 { didSet { restyle() } }
    private var buttons: [NSButton] = []
    private let capsule: ToolbarCapsule

    init(items: [(symbol: String, title: String, tip: String)]) {
        var bs: [NSButton] = []
        for (i, it) in items.enumerated() {
            // 아이콘과 글자 사이를 조금 띄운다
            let b = NSButton(title: " " + it.title, image: NSImage(systemSymbolName: it.symbol, accessibilityDescription: it.title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage(), target: nil, action: nil)
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.toolTip = it.tip
            b.tag = i
            b.wantsLayer = true
            b.layer?.cornerRadius = 12
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true
            bs.append(b)
        }
        capsule = ToolbarCapsule(bs)
        buttons = bs
        super.init(frame: .zero)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for b in bs { b.target = self; b.action = #selector(tapped(_:)) }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: NSButton) {
        selectedSegment = sender.tag
        onPick?(sender.tag)
    }

    private func restyle() {
        for b in buttons {
            let on = b.tag == selectedSegment
            b.layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            b.contentTintColor = on ? .labelColor : .secondaryLabelColor
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: on ? .semibold : .regular),
                .foregroundColor: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
        }
    }
}
