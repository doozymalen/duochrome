import AppKit

/// Left panel of the layer editor: layer list (top = front), background (the develop result) at the bottom,
/// opacity and blend mode of the selected layer, and buttons to add, duplicate, reorder and delete.
final class RetouchLayersPanel: NSView {
    private weak var host: MainWindowController?
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let opacity = SliderRow(label: "불투명도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    private let blend = NSPopUpButton()
    private let selectedBox = NSStackView()

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self)
        let title = NSTextField(labelWithString: "레이어")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        for (key, name, _) in AdjustLayer.blendModes {
            blend.addItem(withTitle: name)
            blend.lastItem?.representedObject = key
        }
        blend.controlSize = .small
        blend.target = self; blend.action = #selector(blendChanged)
        opacity.onChange = { [weak self] v, dragging in
            self?.editSelected(dragging) { $0.opacity = Float(v) }
        }
        // Blend mode and opacity on one row, like the reference editor
        blend.toolTip = "혼합 모드"
        blend.widthAnchor.constraint(equalToConstant: 96).isActive = true
        selectedBox.orientation = .horizontal
        selectedBox.alignment = .bottom
        selectedBox.spacing = 10
        selectedBox.addArrangedSubview(blend)
        selectedBox.addArrangedSubview(opacity)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let doc = FlippedStackHolder(list)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        // Header: title, then + (new adjustment layer) and ⋯ (everything else), like the reference editor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer,
                                         button("plus", "새 조정 레이어 (선택 영역이 있으면 그 부분에만)", #selector(addAdjust)),
                                         button("sparkles", "빠른 보정 (배경 흐림·피부·노이즈)", #selector(quickMenu(_:))),
                                         button("ellipsis.circle", "레이어 작업", #selector(moreMenu(_:)))])
        header.spacing = 4

        let stack = NSStackView(views: [header, selectedBox, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectedBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        b.bezelStyle = .recessed
        b.toolTip = tip
        return b
    }

    func reload(host: MainWindowController) {
        self.host = host
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let layers = host.photo?.settings.layers ?? []
        let selected = host.layersTab.selectedID
        for (i, layer) in layers.enumerated().reversed() {
            let row = LayerListRow(layer: layer, selected: layer.id == selected, depth: LayerTree.depth(layers, i))
            row.onClick = { [weak host] in host?.layersTab.select(layer.id) }
            row.onToggle = { [weak host] on in
                guard let host, var s = host.photo?.settings, let k = s.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                s.layers[k].enabled = on
                host.replaceSettings(s, recordUndo: true, label: on ? "레이어 보이기" : "레이어 숨기기")
            }
            row.contextMenu = { [weak host] in host?.layerContextMenu(layer.id) }
            add(row)
        }
        let bg = LayerListRow(background: "배경")
        bg.onClick = { [weak host] in host?.layersTab.select(nil) }
        add(bg)
        // Opacity and blend only for a selected layer (the background is the develop result)
        let layer = layers.first { $0.id == selected }
        selectedBox.isHidden = layer == nil
        if let layer {
            opacity.value = Double(layer.opacity)
            if let i = AdjustLayer.blendModes.firstIndex(where: { $0.0 == layer.blend }) { blend.selectItem(at: i) }
        }
    }

    private func add(_ row: NSView) {
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func editSelected(_ dragging: Bool, _ f: (inout AdjustLayer) -> Void) {
        guard let host, var s = host.photo?.settings, let id = host.layersTab.selectedID,
              let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        f(&s.layers[i])
        host.apply(s, dragging: dragging)
    }

    @objc private func blendChanged() {
        guard let key = blend.selectedItem?.representedObject as? String else { return }
        editSelected(false) { $0.blend = key }
    }

    @objc private func addAdjust() { host?.retouchAddAdjustLayer() }
    @objc private func addPhoto() { host?.placeImageLayer(nil) }
    @objc private func duplicate() { host?.duplicateLayerOrBackground(nil) }
    @objc private func stamp() { host?.stampVisible(nil) }
    /// ⋯ in the header: the layer commands that used to be a row of buttons at the bottom
    @objc private func moreMenu(_ b: NSButton) {
        let m = NSMenu()
        for (t, sel) in [("사진을 레이어로 넣기…", #selector(addPhoto)), ("복제  ⌘J", #selector(duplicate)),
                         ("보이는 레이어 도장 찍기", #selector(stamp)), ("앞으로", #selector(raiseLayer)),
                         ("뒤로", #selector(lowerLayer)), ("레이어 지우기  ⌫", #selector(remove))] as [(String, Selector)] {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
            if t.hasPrefix("보이는") || t == "뒤로" { m.addItem(.separator()) }
        }
        m.popUp(positioning: nil, at: CGPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc private func quickMenu(_ b: NSButton) {
        let m = NSMenu()
        func item(_ title: String, _ f: @escaping (MainWindowController) -> Void) {
            let i = NSMenuItem(title: title, action: #selector(runQuick(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = QuickAction(f)
            m.addItem(i)
        }
        item("배경 흐림 (AI 피사체 밖)") { $0.retouchBackgroundBlur() }
        item("피부 매끈하게 (AI 피부)") { $0.skinSmoothAI(nil) }
        item("노이즈 제거 레이어 (전체)") { h in h.retouchFilterLayer("노이즈 제거") { $0.denoise = 50 } }
        item("선명하게 레이어 (전체)") { h in h.retouchFilterLayer("선명하게") { $0.sharpen = 80 } }
        m.popUp(positioning: nil, at: CGPoint(x: 0, y: b.bounds.height + 4), in: b)
    }
    private final class QuickAction {
        let run: (MainWindowController) -> Void
        init(_ f: @escaping (MainWindowController) -> Void) { run = f }
    }
    @objc private func runQuick(_ i: NSMenuItem) {
        guard let host, let a = i.representedObject as? QuickAction else { return }
        a.run(host)
    }
    @objc private func raiseLayer() { host?.layersTab.layerUp() }
    @objc private func lowerLayer() { host?.layersTab.layerDown() }
    @objc private func remove() { if host?.layersTab.deleteSelectedLayer() != true { NSSound.beep() } }
}

/// Holds a vertical stack at the top of a scroll view (flipped, so rows start at the top)
final class FlippedStackHolder: NSView {
    override var isFlipped: Bool { true }
    init(_ stack: NSStackView) {
        super.init(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Right panel of the layer editor: options of the picked tool, then the selected layer (adjustments and mask).
final class RetouchInspector: NSView {
    private weak var host: MainWindowController?
    private let toolTitle = NSTextField(labelWithString: "")
    private let toolBox = NSStackView()
    private let layerTitle = NSTextField(labelWithString: "")
    private let layerBox = NSStackView()
    private var adjustRows: [(WritableKeyPath<LocalAdjust, Float>, SliderRow)] = []
    private var filterRows: [(WritableKeyPath<LocalAdjust, Float>, SliderRow)] = []
    /// Filters of an adjustment layer (radii in source pixels)
    private static let filterSpecs: [(String, WritableKeyPath<LocalAdjust, Float>, Double, Double, String)] = [
        ("노이즈 제거", \.denoiseAmount, 0, 100, "%.0f"), ("선명하게", \.sharpen, 0, 300, "%.0f"),
        ("흐림", \.blur, 0, 100, "%.0f px"), ("피부 매끈하게", \.skinAmount, 0, 100, "%.0f"),
    ]
    private let brushSize = SliderRow(label: "붓 크기", min: 5, max: 1500, format: "%.0f px", defaultValue: 120)
    private let brushHardness = SliderRow(label: "경도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0.3)
    private let brushFlow = SliderRow(label: "흐름", min: 0.05, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    private let brushStrength = SliderRow(label: "세기", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0.5)
    private var rangeRadios: [NSButton] = []
    private lazy var rangeBox: NSView = {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        let title = NSTextField(labelWithString: "범위")
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        box.addArrangedSubview(title)
        for (k, t) in ["전체", "어두운 곳", "중간 밝기", "밝은 곳"].enumerated() {
            let r = NSButton(radioButtonWithTitle: t, target: self, action: #selector(rangePicked(_:)))
            r.tag = k
            rangeRadios.append(r)
            box.addArrangedSubview(r)
        }
        return box
    }()
    private let retouchSize = SliderRow(label: "크기", min: 2, max: 500, format: "%.0f px", defaultValue: 40)
    private let retouchFeather = SliderRow(label: "부드러움", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0.5)
    private let retouchOpacity = SliderRow(label: "불투명도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    /// Histogram of the whole result (fed from updateHistogram)
    let histogram = HistogramView()
    // Adjustment layer: curves and per-color adjustments
    let curveEditor = CurveEditorView()
    private let curveChannel = NSPopUpButton()
    private let hslColor = NSPopUpButton()
    private let hslRows = [SliderRow(label: "색조", min: -30, max: 30, format: "%+.0f°", defaultValue: 0),
                           SliderRow(label: "채도", min: -100, max: 100, format: "%+.0f", defaultValue: 0),
                           SliderRow(label: "밝기", min: -100, max: 100, format: "%+.0f", defaultValue: 0)]
    // Mask refinements
    private let maskFeather = SliderRow(label: "가장자리 흐림", min: 0, max: 300, format: "%.0f px", defaultValue: 0)
    private let radialFeather = SliderRow(label: "원 가장자리", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0.5)
    private let lumaMin = SliderRow(label: "밝기 범위 아래", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0)
    private let lumaMax = SliderRow(label: "밝기 범위 위", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    private let lumaSoft = SliderRow(label: "범위 부드러움", min: 0, max: 0.5, format: "%.0f%%", display: 100, defaultValue: 0.1)
    // Selection refinements (the document selection)
    private let selFeather = SliderRow(label: "선택 가장자리 흐림", min: 0, max: 300, format: "%.0f px", defaultValue: 0)
    private let selGrow = SliderRow(label: "넓히기/좁히기", min: -100, max: 100, format: "%+.0f px", defaultValue: 0)
    private let selRefine = SliderRow(label: "머리카락 다듬기", min: 0, max: 60, format: "%.0f px", defaultValue: 0)

    /// Adjustment values of an adjustment layer (LocalAdjust), in the order shown
    private static let adjustSpecs: [(String, WritableKeyPath<LocalAdjust, Float>, Double, Double, String)] = [
        ("노출", \.exposure, -4, 4, "%+.2f"), ("대비", \.contrast, -100, 100, "%+.0f"), ("밝기", \.brightness, -100, 100, "%+.0f"),
        ("하이라이트", \.highlightTone, -100, 100, "%+.0f"), ("섀도", \.shadow, -100, 100, "%+.0f"),
        ("채도", \.saturation, -100, 100, "%+.0f"), ("활기", \.vibrance, -100, 100, "%+.0f"),
        ("색온도", \.temperature, -100, 100, "%+.0f"), ("틴트", \.tint, -100, 100, "%+.0f"),
        ("클래리티", \.clarity, -100, 100, "%+.0f"), ("디헤이즈", \.dehaze, 0, 100, "%.0f"),
    ]

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self)
        for t in [toolTitle, layerTitle] { t.font = .systemFont(ofSize: 13, weight: .semibold) }
        for b in [toolBox, layerBox] {
            b.orientation = .vertical
            b.alignment = .leading
            b.spacing = 8
        }
        for (label, key, lo, hi, fmt) in Self.adjustSpecs {
            let r = SliderRow(label: label, min: lo, max: hi, format: fmt)
            r.onChange = { [weak self] v, dragging in self?.editAdjust(dragging) { $0[keyPath: key] = Float(v) } }
            adjustRows.append((key, r))
        }
        for (label, key, lo, hi, fmt) in Self.filterSpecs {
            let r = SliderRow(label: label, min: lo, max: hi, format: fmt, defaultValue: 0)
            r.onChange = { [weak self] v, dragging in self?.editAdjust(dragging) { $0[keyPath: key] = Float(v) } }
            filterRows.append((key, r))
        }
        brushSize.onChange = { [weak self] v, _ in self?.host?.layersTab.brushRadius = v; self?.host?.retouchBrushChanged() }
        brushHardness.onChange = { [weak self] v, _ in self?.host?.layersTab.brushHardness = v }
        brushFlow.onChange = { [weak self] v, _ in self?.host?.layersTab.brushFlow = v }
        brushStrength.onChange = { [weak self] v, dragging in
            guard let self, let tool = self.host?.retouchEditor.currentTool else { return }
            RetouchTool.setStrength(v, tool)
            self.updatePresetLayer(tool, dragging: dragging)
        }
        retouchSize.onChange = { [weak self] v, _ in self?.host?.retouch.brush.radius = v }
        retouchFeather.onChange = { [weak self] v, _ in self?.host?.retouch.brush.feather = v }
        retouchOpacity.onChange = { [weak self] v, _ in self?.host?.retouch.brush.opacity = v }

        curveChannel.addItems(withTitles: CurveSet.channels.map(\.0))
        curveChannel.selectItem(at: 0)
        curveChannel.target = self
        curveChannel.action = #selector(curveChannelChanged)
        curveEditor.onChange = { [weak self] c, dragging in
            self?.editAdjust(dragging) { $0.curves = c.isIdentity && c.luma.isIdentity ? nil : c }
        }
        curveEditor.heightAnchor.constraint(equalTo: curveEditor.widthAnchor).isActive = true
        hslColor.addItems(withTitles: ColorRange.basic.map(\.name))
        hslColor.selectItem(at: 0)
        hslColor.target = self
        hslColor.action = #selector(hslColorChanged)
        for (k, r) in hslRows.enumerated() {
            r.onChange = { [weak self] v, dragging in
                guard let self else { return }
                let i = max(self.hslColor.indexOfSelectedItem, 0)
                self.editAdjust(dragging) { a in
                    var h = a.hsl ?? [Float](repeating: 0, count: ColorRange.basic.count * 3)
                    if h.count != ColorRange.basic.count * 3 { h = [Float](repeating: 0, count: ColorRange.basic.count * 3) }
                    h[i * 3 + k] = Float(v)
                    a.hsl = h.allSatisfy { $0 == 0 } ? nil : h
                }
            }
        }
        maskFeather.onChange = { [weak self] v, d in self?.editMask(d) { $0.feather = v } }
        radialFeather.onChange = { [weak self] v, d in self?.editMask(d) { $0.radialFeather = v } }
        lumaMin.onChange = { [weak self] v, d in self?.editMask(d) { $0.lumaMin = Float(min(v, Double($0.lumaMax))) } }
        lumaMax.onChange = { [weak self] v, d in self?.editMask(d) { $0.lumaMax = Float(max(v, Double($0.lumaMin))) } }
        lumaSoft.onChange = { [weak self] v, d in self?.editMask(d) { $0.lumaSoft = Float(v) } }
        selFeather.onChange = { [weak self] v, _ in self?.editSelection { $0.feather = v } }
        selGrow.onChange = { [weak self] v, _ in self?.editSelection { $0.grow = v == 0 ? nil : v } }
        selRefine.onChange = { [weak self] v, _ in self?.editSelection { $0.refine = v == 0 ? nil : v } }
        histogram.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let stack = NSStackView(views: [toolTitle, toolBox, separator(), layerTitle, layerBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let holder = FlippedStackHolder(stack)
        let scroll = NSScrollView()
        scroll.documentView = holder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // Footer like the reference editor: compare (split before/after) and reset, always at the bottom
        let compare = NSButton(title: "", target: nil, action: #selector(MainWindowController.toggleSplitCompare(_:)))
        compare.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "비교")
        compare.toolTip = "비교 (왼쪽 보정 전 · 오른쪽 보정 후)"
        let reset = NSButton(title: "초기화", target: self, action: #selector(resetPressed))
        reset.toolTip = "고른 조정 레이어의 값, 없으면 도구 설정을 처음으로"
        for b in [compare, reset] { b.bezelStyle = .appPush; b.controlSize = .regular }
        let footer = NSStackView(views: [compare, reset])
        footer.distribution = .fillEqually
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        let line = separator()
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            holder.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            holder.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            holder.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            toolBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            layerBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    /// Hand/zoom tools: the whole photo with the visible part outlined
    private let navigator = NavigatorView()

    /// Move tool: order, transform, lock, hide, group and merge for the selected layer, like the reference editor's arrange panel
    private func arrangeButtons(_ host: MainWindowController) -> NSView {
        func b(_ title: String, _ f: @escaping (MainWindowController) -> Void) -> NSButton {
            let x = ClosureButton(title: title) { [weak host] in
                guard let host else { return }
                host.keyLayerEdit(f)
            }
            x.bezelStyle = .appPush
            x.controlSize = .small
            return x
        }
        func row(_ items: [NSButton]) -> NSStackView {
            let r = NSStackView(views: items)
            r.distribution = .fillEqually
            r.spacing = 6
            return r
        }
        func heading2(_ t: String) -> NSTextField {
            let h = NSTextField(labelWithString: t)
            h.font = .systemFont(ofSize: 11)
            h.textColor = .secondaryLabelColor
            return h
        }
        func editSel(_ f: @escaping (inout AdjustLayer) -> Void) -> (MainWindowController) -> Void {
            return { h in
                guard var s = h.photo?.settings, let id = h.layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
                f(&s.layers[i])
                h.apply(s, dragging: false)
            }
        }
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        let rows: [NSView] = [
            heading2("순서"),
            row([b("맨 뒤") { $0.layersTab.layerToEnd(top: false) }, b("뒤로") { $0.layersTab.layerDown() },
                 b("앞으로") { $0.layersTab.layerUp() }, b("맨 앞") { $0.layersTab.layerToEnd(top: true) }]),
            heading2("변형"),
            row([b("자유 변형") { $0.retouchEditor.selectTool("transform") }, b("원근 변형") { $0.retouchEditor.selectTool("perspective") }]),
            heading2("레이어"),
            row([b("잠금") { editSel { $0.locked = true }($0) }, b("잠금 풀기") { editSel { $0.locked = false }($0) }]),
            row([b("숨기기") { editSel { $0.enabled = false }($0) }, b("보이기") { editSel { $0.enabled = true }($0) }]),
            row([b("그룹") { $0.groupLayer(nil) }, b("그룹 풀기") { $0.ungroupLayer(nil) }]),
            row([b("아래와 합치기") { $0.mergeDown(nil) }]),
        ]
        for v in rows {
            box.addArrangedSubview(v)
            if v is NSStackView { v.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        }
        return box
    }

    /// Zoom level picker under the navigator (the reference editor shows the percentage there)
    private func zoomPopup(_ host: MainWindowController) -> NSView {
        let p = NSPopUpButton()
        p.controlSize = .small
        let levels: [CGFloat] = [0, 12.5, 25, 50, 100, 200, 400, 800]
        for l in levels { p.addItem(withTitle: l == 0 ? "화면 맞춤" : "\(l == 12.5 ? "12.5" : String(Int(l)))%"); p.lastItem?.representedObject = l }
        let now = host.canvas.zoomPercent
        p.setTitle("\(Int(now.rounded()))%")
        p.target = self
        p.action = #selector(zoomPicked(_:))
        return p
    }

    @objc private func zoomPicked(_ p: NSPopUpButton) {
        guard let host, let l = p.selectedItem?.representedObject as? CGFloat else { return }
        if l == 0 { host.zoomToFit(nil) } else { host.canvas.setZoomPercent(l); host.flashCommand("\(Int(l))%") }
    }

    /// [맞춤] [100%] [−] [+]
    private func zoomButtons(_ host: MainWindowController) -> NSView {
        let items: [(String, Selector)] = [("맞춤", #selector(MainWindowController.zoomToFit(_:))),
                                           ("100%", #selector(MainWindowController.zoomToActual(_:))),
                                           ("−", #selector(MainWindowController.zoomOut(_:))),
                                           ("+", #selector(MainWindowController.zoomIn(_:)))]
        let row = NSStackView(views: items.map { t, sel in
            let b = NSButton(title: t, target: host, action: sel)
            b.bezelStyle = .appPush
            b.controlSize = .small
            return b
        })
        row.distribution = .fillEqually
        row.spacing = 6
        return row
    }

    private func note(_ t: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: t)
        n.font = .systemFont(ofSize: 11)
        n.textColor = .secondaryLabelColor
        return n
    }

    private func put(_ views: [NSView], in box: NSStackView) {
        // A typed value (↩ in a slider's number field) rebuilds this list while that field is still being edited;
        // removing the edited row then left the reused rows out of order. End the editing first (the value is already in).
        if let editor = window?.firstResponder as? NSTextView, let field = editor.delegate as? NSView, field.isDescendant(of: box) {
            window?.makeFirstResponder(nil)
        }
        box.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views {
            box.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        }
    }

    // MARK: Tool options

    func show(tool: RetouchTool, host: MainWindowController) {
        self.host = host
        toolTitle.stringValue = tool.title
        var views: [NSView] = []
        switch tool.group {
        case .view:
            navigator.attach(host.canvas)
            views = [navigator, zoomPopup(host), zoomButtons(host), note("사진을 끌어 옮깁니다. 위 축소판을 누르거나 끌어도 옮겨집니다.")]
        case .select:
            host.selectionOptions.show(tool: tool.id)
            views = [host.selectionOptions]
            if tool.id == "selQuick" { brushSize.value = host.layersTab.brushRadius; views.insert(brushSize, at: 0) }
            if tool.id == "selSubject" { views.insert(note("사진을 누르면 AI가 피사체를 골라 선택 영역으로 잡습니다."), at: 0) }
            if tool.id == "selSky" { views.insert(note("사진을 누르면 하늘을 찾아 선택합니다."), at: 0) }
            views += selectionRefineViews(host)
        case .brush:
            brushSize.value = host.layersTab.brushRadius
            brushHardness.value = host.layersTab.brushHardness
            brushFlow.value = host.layersTab.brushFlow
            if tool.id == "maskBrush" {
                views = [brushSize, brushHardness, brushFlow,
                         note("고른 조정 레이어의 마스크를 칠합니다. 레이어가 없으면 처음 칠할 때 만들어집니다. ⌥를 누르고 칠하면 지웁니다.")]
            } else {
                brushStrength.value = RetouchTool.strength(tool.id)
                for (k, r) in rangeRadios.enumerated() { r.state = k == RetouchTool.range ? .on : .off }
                views = [brushSize, brushHardness, brushFlow, brushStrength, rangeBox,
                         note("칠한 곳에 '\(RetouchTool.presets[tool.id]?.name ?? tool.title)' 레이어가 걸립니다 (원본은 그대로). ⌥를 누르고 칠하면 지웁니다.")]
            }
        case .distort:
            brushSize.value = host.layersTab.brushRadius
            brushFlow.value = host.layersTab.brushFlow
            views = [brushSize, brushFlow, note("끌어서 칠합니다. 처음 칠할 때 지금 모습이 사진 레이어로 만들어지고 거기에 걸립니다. ↩ 또는 esc로 끝냅니다.")]
        case .gradient:
            views = [note(tool.id == "gradLinear"
                ? "사진 위를 끌어 그으면 시작점은 조정이 다 걸리고 끝점으로 갈수록 사라지는 그라디언트 레이어가 생깁니다 (하늘 어둡게 등). 고른 그라디언트의 점을 끌면 고칩니다."
                : "가운데에서 끌어 원을 그리면 안쪽에만 조정이 걸리는 레이어가 생깁니다 (⌥ 타원). 가운데를 끌면 옮기고, 오른쪽 점을 끌면 크기를 바꿉니다. 바깥에 걸려면 마스크 '반전'.")]
            if host.studioSelection != nil { views.append(note("선택 영역이 있어 그 안에만 걸립니다.")) }
        case .arrange where tool.id == "crop":
            // The batch-edit geometry panel is borrowed here; the batch-edit tool tabs take it back when that tab is shown again
            // It is a scroll view (no height of its own), so it sits in a box sized to its content; constraints tie it to the box
            // only, so they go away when the batch-edit tab takes it back (that tab sizes it by frame)
            let shape = host.shape.view
            let box = NSView()
            shape.removeFromSuperview()
            shape.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(shape)
            let h = (shape as? NSScrollView)?.documentView?.fittingSize.height ?? 520
            NSLayoutConstraint.activate([
                shape.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: -12),
                shape.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: 12),
                shape.topAnchor.constraint(equalTo: box.topAnchor),
                shape.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                box.heightAnchor.constraint(equalToConstant: h),
            ])
            views = [note("틀을 끌어 자릅니다. 회전·키스톤은 아래 값으로."), box]
        case .arrange where tool.id == "adjust":
            // Color adjustments act on an adjustment layer: its values show below. Without one, say so and offer to make it
            let sel = host.layersTab.selectedID.flatMap { id in host.photo?.settings.layers.first { $0.id == id } }
            if sel?.kind == "adjust" {
                views = [note("고른 조정 레이어의 값을 아래에서 바꿉니다.")]
            } else {
                let make = ClosureButton(title: host.studioSelection == nil ? "조정 레이어 만들기" : "이 선택으로 조정 레이어 만들기") { [weak host] in
                    host?.retouchAddAdjustLayer()
                }
                make.bezelStyle = .appPush
                views = [note("색 조정은 조정 레이어에 겁니다 (원본은 그대로). 선택 영역이 있으면 그 부분에만 걸립니다."), make]
            }
        case .arrange where tool.id == "move":
            views = [arrangeButtons(host), note("왼쪽에서 고른 사진 레이어를 끌어 옮깁니다. 변형은 ↩ 확정, esc 취소.")]
        case .arrange:
            views = [note("왼쪽에서 고른 사진 레이어를 끌어 옮깁니다.\n\n자유 변형(⌘T): 모서리를 끌면 크기(⇧ 비율 무시), 변 가운데는 한쪽만, 바깥을 끌면 회전(⇧ 15°씩).\n원근 변형: 네 모서리를 끌어 맞춥니다.\n둘 다 ↩ 확정, esc 취소.")]
        case .retouch:
            if tool.id == "aiRemove" || tool.id == "smartErase" {
                brushSize.value = host.layersTab.brushRadius
                views = [brushSize, note(tool.id == "aiRemove"
                    ? "지울 것을 칠하면 AI가 둘레에 맞게 새로 채웁니다 (처음에는 AI 엔진 설치가 필요합니다). 결과는 새 레이어로 들어옵니다."
                    : "지울 것을 칠하면 둘레 색으로 메웁니다. 작은 얼룩·먼지에 빠릅니다. 결과는 새 레이어로 들어옵니다.")]
            } else {
                let b = host.retouch.brush
                retouchSize.value = b.radius
                retouchFeather.value = b.feather
                retouchOpacity.value = b.opacity
                let what: String
                switch tool.id {
                case "clone": what = "누르거나 끌면 비슷한 결이 있는 곳을 골라 그대로 옮겨 붙입니다. 흰 원을 끌면 옮기고, ⌫로 고른 점을 지웁니다."
                case "patch": what = "고칠 곳을 올가미로 두르면 비슷한 곳을 찾아 메웁니다. 초록 올가미를 끌면 가져올 곳을 바꿉니다."
                default: what = "누르면 그 자리 얼룩을(스팟), 끌면 지나간 자리를(붓) 둘레에 맞춰 고칩니다. 흰 원을 끌면 옮기고, ⌫로 고른 점을 지웁니다."
                }
                let target = host.retouchLayerID == nil ? "배경(현상 결과)에 겁니다." : "고른 배경 복사 레이어에 겁니다."
                views = [retouchSize, retouchFeather, retouchOpacity, note(what + "\n" + target), retouchButtons()]
            }
        }
        put(views, in: toolBox)
        reloadLayer(host: host)
    }

    // MARK: Selected layer

    func reloadLayer(host: MainWindowController) {
        self.host = host
        let s = host.photo?.settings
        guard let id = host.layersTab.selectedID, let layer = s?.layers.first(where: { $0.id == id }) else {
            layerTitle.stringValue = "배경 (현상)"
            put([note("대량 보정의 현상 결과입니다. 위 +로 조정 레이어를 더합니다.")], in: layerBox)
            return
        }
        layerTitle.stringValue = layer.name
        var views: [NSView] = []
        if layer.kind == "adjust" {
            // Histogram belongs with the adjustment values (it used to sit above every tool)
            views.append(histogram)
            for (key, r) in adjustRows {
                r.value = Double(layer.adjust[keyPath: key])
                views.append(r)
            }
            // Filters
            views.append(heading("필터"))
            for (key, r) in filterRows {
                r.value = Double(layer.adjust[keyPath: key])
                views.append(r)
            }
            // Curves
            views.append(heading("커브"))
            curveEditor.curves = layer.adjust.curves ?? CurveSet()
            curveEditor.histogram = histogram.data?.luma
            views += [curveChannel, curveEditor]
            // Per-color
            views.append(heading("색상별"))
            views.append(hslColor)
            loadHSL(layer.adjust)
            views += hslRows
        } else if layer.isImage {
            views.append(note("사진 레이어입니다. 불투명도와 혼합 모드는 왼쪽 레이어 패널에서 바꿉니다."))
        }
        // Mask
        let maskTitle = NSTextField(labelWithString: "마스크")
        maskTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        views.append(maskTitle)
        views.append(maskButtons())
        maskFeather.value = layer.mask.feather
        views.append(maskFeather)
        if layer.mask.kind == .radial {
            radialFeather.value = layer.mask.radialFeather
            views.append(radialFeather)
        }
        // Luma range: the layer only acts on this brightness band (e.g. only the highlights)
        lumaMin.value = Double(layer.mask.lumaMin)
        lumaMax.value = Double(layer.mask.lumaMax)
        lumaSoft.value = Double(layer.mask.lumaSoft)
        views += [lumaMin, lumaMax, lumaSoft]
        put(views, in: layerBox)
    }

    private func retouchButtons() -> NSView {
        func b(_ t: String, _ a: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: a)
            x.bezelStyle = .appPush
            x.controlSize = .small
            return x
        }
        return NSStackView(views: [b("마지막 점 지우기", #selector(removeLastSpot)), b("모두 지우기", #selector(removeAllSpots))])
    }
    @objc private func removeLastSpot() { host?.retouch.onRemoveLast?() }
    @objc private func removeAllSpots() { host?.retouch.onRemoveAll?() }

    private func maskButtons() -> NSView {
        func b(_ t: String, _ a: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: a)
            x.bezelStyle = .appPush
            x.controlSize = .small
            return x
        }
        let row1 = NSStackView(views: [b("반전", #selector(invertMask)), b("전체로 (지우기)", #selector(clearMask))])
        let row2 = NSStackView(views: [b("선택 영역을 마스크로", #selector(maskFromSelection)), b("마스크 보기", #selector(showMask))])
        let box = NSStackView(views: [row1, row2])
        box.orientation = .vertical
        box.alignment = .leading
        return box
    }

    private func editLayer(_ label: String, dragging: Bool = false, _ f: (inout AdjustLayer) -> Void) {
        guard let host, var s = host.photo?.settings, let id = host.layersTab.selectedID,
              let i = s.layers.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        f(&s.layers[i])
        if dragging { host.apply(s, dragging: true) } else { host.replaceSettings(s, recordUndo: true, label: label) }
    }

    @objc private func rangePicked(_ b: NSButton) {
        for r in rangeRadios { r.state = r === b ? .on : .off }
        RetouchTool.range = b.tag
        if let tool = host?.retouchEditor.currentTool { updatePresetLayer(tool, dragging: false) }
    }

    /// Strength or range changed: the selected layer of this brush follows (strokes stay)
    private func updatePresetLayer(_ tool: String, dragging: Bool) {
        guard let host, var s = host.photo?.settings, let id = host.layersTab.selectedID,
              let i = s.layers.firstIndex(where: { $0.id == id && $0.preset == tool }), !s.layers[i].locked else { return }
        RetouchTool.applyPreset(tool, to: &s.layers[i])
        host.apply(s, dragging: dragging)
    }

    /// Footer "초기화": the selected adjustment layer's values back to zero (mask kept); with no such layer, the tool settings back to defaults
    @objc private func resetPressed() {
        guard let host else { return }
        if let id = host.layersTab.selectedID, var s = host.photo?.settings, let i = s.layers.firstIndex(where: { $0.id == id }),
           s.layers[i].kind == "adjust" {
            guard !s.layers[i].locked else { NSSound.beep(); return }
            s.layers[i].adjust = LocalAdjust()
            host.apply(s, dragging: false)
            reloadLayer(host: host)
            return
        }
        host.layersTab.brushRadius = 120
        host.layersTab.brushHardness = 0.3
        host.layersTab.brushFlow = 1
        var b = host.retouch.brush
        b.radius = 40; b.feather = 0.5; b.opacity = 1
        host.retouch.brush = b
        host.retouchBrushChanged()
        if let t = RetouchTool.named(host.retouchEditor.currentTool) { show(tool: t, host: host) }
    }

    private func editAdjust(_ dragging: Bool, _ f: (inout LocalAdjust) -> Void) {
        guard let host, var s = host.photo?.settings, let id = host.layersTab.selectedID,
              let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        f(&s.layers[i].adjust)
        host.apply(s, dragging: dragging)
    }

    private func heading(_ s: String) -> NSTextField {
        let h = NSTextField(labelWithString: s)
        h.font = .systemFont(ofSize: 12, weight: .semibold)
        return h
    }

    @objc private func curveChannelChanged() {
        let (_, key, color) = CurveSet.channels[max(curveChannel.indexOfSelectedItem, 0)]
        curveEditor.channelColor = color
        curveEditor.channel = key
    }

    private func loadHSL(_ a: LocalAdjust) {
        let i = max(hslColor.indexOfSelectedItem, 0)
        let h = a.hsl ?? []
        for (k, r) in hslRows.enumerated() { r.value = h.count > i * 3 + k ? Double(h[i * 3 + k]) : 0 }
    }

    @objc private func hslColorChanged() {
        guard let host, let id = host.layersTab.selectedID,
              let l = host.photo?.settings.layers.first(where: { $0.id == id }) else { return }
        loadHSL(l.adjust)
    }

    private func editMask(_ dragging: Bool, _ f: (inout LayerMask) -> Void) {
        guard let host, var s = host.photo?.settings, let id = host.layersTab.selectedID,
              let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        f(&s.layers[i].mask)
        host.apply(s, dragging: dragging)
    }

    /// Feather, grow and edge refine of the document selection (applied on top of its shape)
    private func selectionRefineViews(_ host: MainWindowController) -> [NSView] {
        let sel = host.studioSelection
        selFeather.value = sel?.feather ?? 0
        selGrow.value = sel?.grow ?? 0
        selRefine.value = sel?.refine ?? 0
        return [heading("선택 영역 다듬기"), selFeather, selGrow, selRefine]
    }

    private func editSelection(_ f: (inout LayerMask) -> Void) {
        guard let host, var sel = host.studioSelection else { NSSound.beep(); return }
        f(&sel)
        host.studioSelection = sel
    }

    /// Brush size changed by [ or ]: keep the size sliders in step
    func syncBrushSizes(_ host: MainWindowController) {
        brushSize.value = host.layersTab.brushRadius
        retouchSize.value = host.retouch.brush.radius
    }

    /// The selection changed: keep the refine sliders in step
    func selectionChanged(_ host: MainWindowController) {
        guard RetouchTool.named(host.retouchEditor.currentTool)?.group == .select else { return }
        let sel = host.studioSelection
        selFeather.value = sel?.feather ?? 0
        selGrow.value = sel?.grow ?? 0
        selRefine.value = sel?.refine ?? 0
    }

    @objc private func invertMask() { editLayer("마스크 반전") { $0.mask.invert.toggle() } }
    @objc private func clearMask() { editLayer("마스크 지우기") { $0.mask = LayerMask() } }
    @objc private func maskFromSelection() {
        guard let sel = host?.studioSelection else { NSSound.beep(); return }
        editLayer("선택 영역을 마스크로") { $0.mask = sel }
    }
    @objc private func showMask() { host?.toggleMaskView(nil) }
}

/// Push button running a closure
final class ClosureButton: NSButton {
    private var run: () -> Void = {}
    convenience init(title: String, _ run: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.run = run
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { run() }
}
