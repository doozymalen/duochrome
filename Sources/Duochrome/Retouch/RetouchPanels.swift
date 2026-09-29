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
        let blendRow = NSStackView(views: [NSTextField(labelWithString: "혼합"), blend])
        blendRow.spacing = 6
        selectedBox.orientation = .vertical
        selectedBox.alignment = .leading
        selectedBox.spacing = 6
        for v in [opacity, blendRow] as [NSView] {
            selectedBox.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: selectedBox.widthAnchor).isActive = true
        }

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

        let buttons = NSStackView(views: [
            button("plus", "새 조정 레이어 (선택 영역이 있으면 그 부분에만)", #selector(addAdjust)),
            button("photo.badge.plus", "사진을 레이어로 넣기", #selector(addPhoto)),
            button("plus.square.on.square", "복제 (⌘J, 선택 영역이 있으면 그 부분만)", #selector(duplicate)),
            button("chevron.up", "앞으로", #selector(moveUp)),
            button("chevron.down", "뒤로", #selector(moveDown)),
            button("trash", "레이어 지우기", #selector(remove)),
        ])
        buttons.spacing = 4

        let stack = NSStackView(views: [title, selectedBox, scroll, buttons])
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
    @objc private func moveUp() { host?.layersTab.layerUp() }
    @objc private func moveDown() { host?.layersTab.layerDown() }
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
    private let brushSize = SliderRow(label: "붓 크기", min: 5, max: 1500, format: "%.0f px", defaultValue: 120)
    private let brushHardness = SliderRow(label: "경도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 0.3)
    private let brushFlow = SliderRow(label: "흐름", min: 0.05, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
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
        brushSize.onChange = { [weak self] v, _ in self?.host?.layersTab.brushRadius = v; self?.host?.retouchBrushChanged() }
        brushHardness.onChange = { [weak self] v, _ in self?.host?.layersTab.brushHardness = v }
        brushFlow.onChange = { [weak self] v, _ in self?.host?.layersTab.brushFlow = v }
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

        let stack = NSStackView(views: [histogram, toolTitle, toolBox, separator(), layerTitle, layerBox])
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
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            holder.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            holder.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            toolBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            layerBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            histogram.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    private func note(_ t: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: t)
        n.font = .systemFont(ofSize: 11)
        n.textColor = .secondaryLabelColor
        return n
    }

    private func put(_ views: [NSView], in box: NSStackView) {
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
            views = [note("사진을 끌어 옮겨 봅니다. 두 손가락으로 확대·축소, ⌘0 화면에 맞추기, ⌘1 실제 크기.")]
        case .select:
            host.selectionOptions.show(tool: tool.id)
            views = [host.selectionOptions]
            if tool.id == "selQuick" { brushSize.value = host.layersTab.brushRadius; views.insert(brushSize, at: 0) }
            if tool.id == "selSubject" { views.insert(note("사진을 누르면 AI가 피사체를 골라 선택 영역으로 잡습니다."), at: 0) }
            if tool.id == "selSky" { views.insert(note("사진을 누르면 하늘을 찾아 선택 영역으로 잡습니다. 가장자리는 아래 '머리카락 다듬기'로 나뭇가지·건물 윤곽에 맞춥니다."), at: 0) }
            views += selectionRefineViews(host)
        case .brush:
            brushSize.value = host.layersTab.brushRadius
            brushHardness.value = host.layersTab.brushHardness
            brushFlow.value = host.layersTab.brushFlow
            let what = tool.id == "maskBrush"
                ? "고른 조정 레이어의 마스크를 칠합니다. 칠한 곳에만 조정이 걸리고, ⌥를 누르고 칠하면 지웁니다."
                : "칠한 곳에 '\(RetouchTool.presets[tool.id]?.name ?? tool.title)' 레이어가 걸립니다. 세기는 아래 레이어 값으로 바꾸고, ⌥를 누르고 칠하면 지웁니다."
            views = [brushSize, brushHardness, brushFlow, note(what)]
        case .gradient:
            views = [note(tool.id == "gradLinear"
                ? "사진 위를 끌어 그으면 시작점은 조정이 다 걸리고 끝점으로 갈수록 사라지는 그라디언트 레이어가 생깁니다 (하늘 어둡게 등). 고른 그라디언트의 점을 끌면 고칩니다."
                : "가운데에서 끌어 원을 그리면 안쪽에만 조정이 걸리는 레이어가 생깁니다 (⌥ 타원). 가운데를 끌면 옮기고, 오른쪽 점을 끌면 크기를 바꿉니다. 바깥에 걸려면 마스크 '반전'.")]
            if host.studioSelection != nil { views.append(note("선택 영역이 있어 그 안에만 걸립니다.")) }
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
            put([note("배경은 대량 보정의 현상 결과입니다. 노출·색 같은 전체 보정은 대량 보정에서 바꾸면 여기에도 바로 반영됩니다.\n\n위 + 단추로 조정 레이어를 더하면 그 레이어 값으로 보정합니다. 선택 영역이 있으면 그 부분에만 걸립니다.")], in: layerBox)
            return
        }
        layerTitle.stringValue = layer.name
        var views: [NSView] = []
        if layer.kind == "adjust" {
            for (key, r) in adjustRows {
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
