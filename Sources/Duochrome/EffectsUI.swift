import AppKit

/// Layer effects editor: add effects (menu by category), per-effect enable/order/delete, and value sliders.
/// Shared by the "Effects" card in the batch-edit layers tab and the layer-edit effects tool options panel.
final class EffectsEditor: NSStackView {
    /// (new effect list, dragging)
    var onChange: (([LayerEffect], Bool) -> Void)?
    private(set) var effects: [LayerEffect] = []
    private var structure: [String] = []           // Row structure (id, kind) — if unchanged, only update values
    private var rows: [String: [String: SliderRow]] = [:]
    private var switches: [String: NSSwitch] = [:]
    private var expanded: Set<String> = []
    private let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let empty = NSTextField(wrappingLabelWithString: "효과가 없습니다. 위 메뉴에서 더하세요.")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        addButton.addItem(withTitle: "효과 더하기")
        addButton.controlSize = .small
        let menu = addButton.menu!
        for cat in EffectCategory.allCases {
            let specs = Effects.all.filter { $0.category == cat }
            guard !specs.isEmpty else { continue }
            let item = menu.addItem(withTitle: cat.rawValue, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in specs {
                let i = sub.addItem(withTitle: s.title, action: #selector(addTapped(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = s.kind
            }
            item.submenu = sub
        }
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .secondaryLabelColor
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sets the list from outside (when a layer is selected or values changed)
    func show(_ list: [LayerEffect]) {
        effects = list
        let s = list.map { "\($0.id):\($0.kind)" }
        if s != structure { rebuild(); return }
        for fx in list {
            switches[fx.id]?.state = fx.enabled ? .on : .off
            for (k, row) in rows[fx.id] ?? [:] { row.value = fx.value(k) }
        }
    }

    @objc private func addTapped(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let fx = LayerEffect(kind: kind)
        expanded.insert(fx.id)
        effects.append(fx)
        rebuild()
        onChange?(effects, false)
    }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = [:]; switches = [:]
        structure = effects.map { "\($0.id):\($0.kind)" }
        add(addButton)
        if effects.isEmpty { add(empty) }
        for (idx, fx) in effects.enumerated() {
            guard let spec = Effects.spec(fx.kind) else { continue }
            let title = NSButton(title: (expanded.contains(fx.id) ? "▾ " : "▸ ") + spec.title, target: self, action: #selector(toggleExpand(_:)))
            title.isBordered = false
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.alignment = .left
            title.identifier = NSUserInterfaceItemIdentifier(fx.id)
            let sw = NSSwitch()
            sw.controlSize = .mini
            sw.state = fx.enabled ? .on : .off
            sw.target = self; sw.action = #selector(toggleEnabled(_:))
            sw.identifier = NSUserInterfaceItemIdentifier(fx.id)
            switches[fx.id] = sw
            func small(_ symbol: String, _ tip: String, _ sel: Selector, enabled: Bool = true) -> NSButton {
                let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
                b.isBordered = false
                b.contentTintColor = .secondaryLabelColor
                b.toolTip = tip
                b.identifier = NSUserInterfaceItemIdentifier(fx.id)
                b.isEnabled = enabled
                return b
            }
            let head = NSStackView(views: [title, NSView(),
                                           small("chevron.up", "위로 (먼저 건다)", #selector(fxUp(_:)), enabled: idx > 0),
                                           small("chevron.down", "아래로", #selector(fxDown(_:)), enabled: idx < effects.count - 1),
                                           small("arrow.counterclockwise", "기본값으로", #selector(resetFx(_:))),
                                           small("trash", "지우기", #selector(removeFx(_:))), sw])
            head.spacing = 4
            add(head)
            guard expanded.contains(fx.id) else { continue }
            var map: [String: SliderRow] = [:]
            for p in spec.params {
                let span = p.range.upperBound - p.range.lowerBound
                let fmt = span <= 2 ? "%.2f" : (span <= 20 ? "%.1f" : "%.0f")
                let row = SliderRow(label: p.title + (p.unit.isEmpty ? "" : " (\(p.unit))"), min: p.range.lowerBound,
                                    max: p.range.upperBound, format: fmt, defaultValue: p.def)
                row.value = fx.value(p.key)
                let id = fx.id, key = p.key
                row.onChange = { [weak self] v, dragging in
                    guard let self, let i = self.effects.firstIndex(where: { $0.id == id }) else { return }
                    self.effects[i].params[key] = v
                    self.onChange?(self.effects, dragging)
                }
                map[p.key] = row
                add(row)
            }
            rows[fx.id] = map
        }
    }

    private func add(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func index(_ sender: NSView) -> Int? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return effects.firstIndex { $0.id == id }
    }

    @objc private func toggleExpand(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuild()
    }
    @objc private func toggleEnabled(_ sender: NSSwitch) {
        guard let i = index(sender) else { return }
        effects[i].enabled = sender.state == .on
        onChange?(effects, false)
    }
    @objc private func fxUp(_ sender: NSButton) {
        guard let i = index(sender), i > 0 else { return }
        effects.swapAt(i, i - 1); rebuild(); onChange?(effects, false)
    }
    @objc private func fxDown(_ sender: NSButton) {
        guard let i = index(sender), i < effects.count - 1 else { return }
        effects.swapAt(i, i + 1); rebuild(); onChange?(effects, false)
    }
    @objc private func resetFx(_ sender: NSButton) {
        guard let i = index(sender) else { return }
        effects[i].params = Effects.spec(effects[i].kind)?.defaults ?? [:]
        show(effects); onChange?(effects, false)
    }
    @objc private func removeFx(_ sender: NSButton) {
        guard let i = index(sender) else { return }
        effects.remove(at: i); rebuild(); onChange?(effects, false)
    }
}

/// Effect picker (layer-edit effects tool): small previews applied to the current photo, by category.
/// Clicking adds the effect to the selected layer.
final class EffectsBrowser: NSStackView {
    var onPick: ((String) -> Void)?
    private let categoryPopup = NSPopUpButton()
    private let grid = NSStackView()
    private var source: CIImage?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        for c in EffectCategory.allCases where Effects.all.contains(where: { $0.category == c }) {
            categoryPopup.addItem(withTitle: c.rawValue)
            categoryPopup.lastItem?.representedObject = c.rawValue
        }
        categoryPopup.controlSize = .small
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged)
        categoryPopup.selectItem(at: UserDefaults.standard.integer(forKey: "effects.category"))
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        addArrangedSubview(categoryPopup)
        addArrangedSubview(grid)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Image used for previews (current photo, downscaled)
    func setSource(_ img: CIImage?) {
        source = img.map { i in
            let k = 96 / max(i.extent.width, i.extent.height)
            let s = i.transformed(by: .init(scaleX: k, y: k))
            return s.transformed(by: .init(translationX: -s.extent.minX, y: -s.extent.minY))
        }
        reload()
    }

    @objc private func categoryChanged() {
        UserDefaults.standard.set(categoryPopup.indexOfSelectedItem, forKey: "effects.category")
        reload()
    }

    private func reload() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let name = categoryPopup.selectedItem?.representedObject as? String,
              let cat = EffectCategory(rawValue: name) else { return }
        let specs = Effects.all.filter { $0.category == cat }
        var row: NSStackView?
        for (i, s) in specs.enumerated() {
            if i % 2 == 0 {
                row = NSStackView()
                row?.spacing = 6
                grid.addArrangedSubview(row!)
            }
            let tile = EffectTile(title: s.title, image: preview(s))
            tile.onClick = { [weak self] in self?.onPick?(s.kind) }
            row?.addArrangedSubview(tile)
        }
    }

    private func preview(_ s: EffectSpec) -> NSImage? {
        guard let src = source else { return nil }
        // Use a large radius so differences show on a small image (exaggerated compared to the real photo scale)
        let out = Effects.apply([LayerEffect(kind: s.kind)], src, scale: 0.12)
        guard let cg = Render.context.createCGImage(out, from: src.extent.integral, format: .RGBA8, colorSpace: Render.displaySpace) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

final class EffectTile: NSView {
    var onClick: (() -> Void)?
    init(title: String, image: NSImage?) {
        super.init(frame: .zero)
        let iv = NSImageView()
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let v = NSStackView(views: [iv, label])
        v.orientation = .vertical
        v.spacing = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        toolTip = title
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 118), heightAnchor.constraint(equalToConstant: 96),
            iv.widthAnchor.constraint(equalToConstant: 114), iv.heightAnchor.constraint(equalToConstant: 72),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 114),
            v.topAnchor.constraint(equalTo: topAnchor), v.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
