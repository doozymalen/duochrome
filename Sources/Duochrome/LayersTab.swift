import AppKit

/// Layers tab: adjustment layer list (top is the top layer), blend/opacity/mask/adjustments of the selected layer.
/// Masks are painted on the canvas with the cursor tool's mask (B).
final class LayersTabController: NSViewController {
    var current: (() -> DevelopSettings?)?
    var onChange: ((DevelopSettings, Bool) -> Void)?
    /// When the selected layer changes (mask view and canvas tool follow).
    var onSelect: ((String?) -> Void)?
    var onShowMask: ((Bool) -> Void)?

    private(set) var selectedID: String?
    var brushRadius: Double = 120 { didSet { UserDefaults.standard.set(brushRadius, forKey: "mask.radius") } }
    var brushHardness: Double = 0.3
    var brushFlow: Double = 1
    var erase = false

    /// Layer list (drag to reorder/regroup, drop Finder images — DragDrop.swift)
    let dropList = LayerDropList()
    private var list: FlippedStackView { dropList }
    private let detail = FlippedStackView()
    private let blendPopup = NSPopUpButton()
    private let opacity = SliderRow(label: "불투명도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    private let fillRow = SliderRow(label: "칠 불투명도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    private let posX = SliderRow(label: "가로 자리 (%)", min: -20, max: 120, format: "%.1f", defaultValue: 50)
    private let posY = SliderRow(label: "세로 자리 (%)", min: -20, max: 120, format: "%.1f", defaultValue: 50)
    private let sizeRow = SliderRow(label: "크기 (사진 너비의 %)", min: 1, max: 300, format: "%.0f", defaultValue: 50)
    private let rotRow = SliderRow(label: "회전", min: -180, max: 180, format: "%+.1f°")
    private var placeCard: Card!
    private var listCard: Card!
    /// In layer-edit mode the left layers panel shows the list, so this tab's list is hidden.
    var listHidden = false { didSet { if isViewLoaded { listCard.isHidden = listHidden } } }
    private var adjustCard: Card!
    /// Shows the file picker for image layers (from the window side).
    var onPlaceImage: (() -> Void)?
    /// Layer context menu (nil = background)
    var rowMenu: ((String?) -> NSMenu)?
    private let maskKind = NSTextField(labelWithString: "")
    private let invert = NSButton(checkboxWithTitle: "마스크 반전", target: nil, action: nil)
    private let lockBox = NSButton(checkboxWithTitle: "잠금", target: nil, action: nil)
    private let clipBox = NSButton(checkboxWithTitle: "아래 레이어에 클리핑", target: nil, action: nil)
    private let showMask = NSButton(checkboxWithTitle: "마스크 보기 (M)", target: nil, action: nil)
    private let feather = SliderRow(label: "마스크 흐림 (원본 픽셀)", min: 0, max: 300, format: "%.0f")
    private let radialFeather = SliderRow(label: "원형 가장자리 부드러움", min: 0, max: 1, format: "%.0f", display: 100, defaultValue: 0.5)
    private let lumaMin = SliderRow(label: "루마 레인지 아래", min: 0, max: 1, format: "%.0f", display: 255)
    private let lumaMax = SliderRow(label: "루마 레인지 위", min: 0, max: 1, format: "%.0f", display: 255, defaultValue: 1)
    private let lumaSoft = SliderRow(label: "루마 경계 부드러움", min: 0.005, max: 0.3, format: "%.0f", display: 255, defaultValue: 0.1)
    private let brushSize = SliderRow(label: "붓 크기 (반지름, 원본 픽셀)", min: 5, max: 1500, format: "%.0f", defaultValue: 120)
    private let brushHard = SliderRow(label: "붓 딱딱함", min: 0, max: 1, format: "%.0f", display: 100, defaultValue: 0.3)
    private let brushFlowRow = SliderRow(label: "붓 흐름", min: 0.05, max: 1, format: "%.0f", display: 100, defaultValue: 1)
    private let eraseBox = NSButton(checkboxWithTitle: "지우개 (옵션 키를 눌러도 됨)", target: nil, action: nil)
    private var brushViews: [NSView] = []
    private var radialViews: [NSView] = []
    private var adjustRows: [(WritableKeyPath<LocalAdjust, Float>, SliderRow)] = []
    private var detailCards: [Card] = []
    /// Layer effects editor (the layer-edit effects tool uses it too)
    let effectsEditor = EffectsEditor()
    private var effectsCard: Card?
    let stylesEditor = LayerStylesEditor()
    private var stylesCard: Card?
    private let fillPatternPopup = NSPopUpButton()
    /// Imported presets (.grd, .pat, .aco, .abr)
    private let fillPresetGradient = NSPopUpButton()
    private let fillPresetPattern = NSPopUpButton()
    private let fillSwatches = NSPopUpButton()
    private let gradientPreset = NSPopUpButton()
    private let brushTipPopup = NSPopUpButton()
    /// Mask brush tip (imported brush; nil for a round brush)
    var brushTip: PresetFiles.Brush?
    // text layer
    private var textCard: Card!
    private let textField = NSTextField()
    private let textFont = NSPopUpButton()
    private let textSize = SliderRow(label: "크기 (원본 픽셀)", min: 4, max: 2000, format: "%.0f", defaultValue: 120)
    private let textColor = NSColorWell()
    private let textAlign = NSSegmentedControl(labels: ["왼쪽", "가운데", "오른쪽"], trackingMode: .selectOne, target: nil, action: nil)
    private let textTracking = SliderRow(label: "자간", min: -200, max: 800, format: "%.0f", defaultValue: 0)
    private let fillScaleRow = SliderRow(label: "무늬 크기 (원본 픽셀)", min: 2, max: 800, format: "%.0f", defaultValue: 60)
    private var blendIfRows: [SliderRow] = []
    private var blendIfCard: Card?
    private var extraCards: [Card] = []
    private var mixerRows: [SliderRow] = []
    private let invertBox = NSButton(checkboxWithTitle: "반전", target: nil, action: nil)
    private let gradientBox = NSButton(checkboxWithTitle: "그라디언트 맵", target: nil, action: nil)
    private let mixerBox = NSButton(checkboxWithTitle: "채널 혼합 켜기", target: nil, action: nil)
    private let gradientDark = NSColorWell(style: .minimal)
    private var fillCard: Card!
    private let fillWell1 = NSColorWell(style: .minimal)
    private let fillWell2 = NSColorWell(style: .minimal)
    private let fillGradientBox = NSButton(checkboxWithTitle: "그라디언트", target: nil, action: nil)

    private func rgb(_ c: NSColor) -> [Float] {
        let s = c.usingColorSpace(.sRGB) ?? c
        return [Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)]
    }

    // MARK: Presets · text

    func reloadPresets() {
        let lib = PresetFiles.library
        func fill(_ pop: NSPopUpButton, _ title: String, _ names: [String], images: [NSImage?] = []) {
            pop.removeAllItems()
            pop.addItem(withTitle: title)
            for (i, n) in names.enumerated() {
                pop.addItem(withTitle: n)
                if i < images.count { pop.lastItem?.image = images[i] }
            }
            pop.isEnabled = !names.isEmpty
        }
        func swatchImage(_ rgb: [Float]) -> NSImage {
            NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
                NSColor(srgbRed: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
                return true
            }
        }
        func gradientImage(_ g: PresetFiles.Gradient) -> NSImage {
            NSImage(size: NSSize(width: 40, height: 12), flipped: false) { r in
                let st = PresetFiles.stops(g)
                for x in 0 ..< 40 {
                    let c = PSDAdjust.sample(st, Float(x) / 39)
                    NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1).setFill()
                    NSRect(x: CGFloat(x), y: 0, width: 1, height: r.height).fill()
                }
                return true
            }
        }
        let empty = "(파일 → 프리셋 가져오기)"
        fill(fillSwatches, lib.swatches.isEmpty ? "견본 \(empty)" : "견본에서 색 고르기", lib.swatches.map { $0.name.isEmpty ? "견본" : $0.name },
             images: lib.swatches.map { swatchImage($0.rgb) })
        fill(fillPresetGradient, lib.gradients.isEmpty ? "그라디언트 \(empty)" : "가져온 그라디언트로 칠", lib.gradients.map(\.name),
             images: lib.gradients.map(gradientImage))
        fill(gradientPreset, lib.gradients.isEmpty ? "그라디언트 맵 프리셋 \(empty)" : "그라디언트 맵에 프리셋 쓰기", lib.gradients.map(\.name),
             images: lib.gradients.map(gradientImage))
        fill(fillPresetPattern, lib.patterns.isEmpty ? "패턴 \(empty)" : "가져온 패턴으로 칠", lib.patterns.map(\.name))
        brushTipPopup.removeAllItems()
        brushTipPopup.addItem(withTitle: "붓 끝: 둥근 붓")
        for b in lib.brushes { brushTipPopup.addItem(withTitle: "붓 끝: \(b.name) (\(b.width)×\(b.height))") }
        if let t = brushTip, let i = lib.brushes.firstIndex(of: t) { brushTipPopup.selectItem(at: i + 1) }
    }

    @objc private func fillSwatchChosen() {
        let i = fillSwatches.indexOfSelectedItem - 1
        let lib = PresetFiles.library
        guard i >= 0, i < lib.swatches.count else { return }
        let c = lib.swatches[i].rgb
        edit(false) { l in
            if l.fillColor.count >= 6 { l.fillColor[0] = c[0]; l.fillColor[1] = c[1]; l.fillColor[2] = c[2] } else { l.fillColor = c }
        }
        NSColorPanel.shared.color = NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
        fillSwatches.selectItem(at: 0)
    }

    @objc private func fillPresetGradientChosen() {
        let i = fillPresetGradient.indexOfSelectedItem - 1
        let lib = PresetFiles.library
        guard i >= 0, i < lib.gradients.count else { return }
        let g = lib.gradients[i]
        let n = nativeSizeHint
        edit(false) { l in
            let st = PresetFiles.stops(g)
            l.fillStops = g.stops
            l.fillPattern = nil; l.fillPatternFile = nil
            if let a = st.first?.color, let b = st.last?.color { l.fillColor = [a.x, a.y, a.z, b.x, b.y, b.z] }
            if l.fillPoints.count != 4 { l.fillPoints = [n.width / 2, n.height, n.width / 2, 0] }
        }
        fillPresetGradient.selectItem(at: 0)
    }

    @objc private func fillPresetPatternChosen() {
        let i = fillPresetPattern.indexOfSelectedItem - 1
        let lib = PresetFiles.library
        guard i >= 0, i < lib.patterns.count,
              let file = try? LayerImageStore.importFile(PresetFiles.url(lib.patterns[i].file)) else { return }
        edit(false) { l in
            l.fillPatternFile = file
            l.fillPattern = nil
            l.fillStops = nil
            l.fillScale = 100
        }
        fillPresetPattern.selectItem(at: 0)
    }

    @objc private func gradientPresetChosen() {
        let i = gradientPreset.indexOfSelectedItem - 1
        let lib = PresetFiles.library
        guard i >= 0, i < lib.gradients.count else { return }
        let g = lib.gradients[i]
        edit(false) { l in l.adjust.gradientStops = g.stops; l.adjust.gradientMap = [] }
        gradientPreset.selectItem(at: 0)
    }

    @objc private func brushTipChosen() {
        let i = brushTipPopup.indexOfSelectedItem - 1
        let lib = PresetFiles.library
        brushTip = i >= 0 && i < lib.brushes.count ? lib.brushes[i] : nil
    }

    private func editText(_ dragging: Bool, _ f: (inout LayerText) -> Void) {
        edit(dragging) { l in
            guard var t = l.text else { return }
            f(&t)
            l.text = t
            l.image = nil   // Once edited, we render it instead of the embedded image
        }
    }

    @objc private func textChanged() {
        let fam = textFont.titleOfSelectedItem
        let c = rgb(textColor.color)
        editText(false) { t in
            t.string = textField.stringValue
            if let fam, NSFont(name: t.font, size: 12)?.familyName != fam,
               let face = NSFontManager.shared.availableMembers(ofFontFamily: fam)?.first?.first as? String { t.font = face }
            t.color = c
            t.align = max(0, textAlign.selectedSegment)
        }
    }

    @objc private func fillPatternChanged() {
        let i = fillPatternPopup.indexOfSelectedItem
        edit(false) { l in
            l.fillPattern = i == 0 ? nil : i - 1
            l.fillPatternFile = nil
            // Patterns need two colors
            if i > 0, l.fillColor.count < 6 { l.fillColor = (l.fillColor + [0.5, 0.5, 0.5]).prefix(3) + [0.15, 0.15, 0.15] }
        }
    }

    @objc private func fillChanged() {
        let n = nativeSizeHint
        edit(false) { l in
            if self.fillGradientBox.state == .on {
                l.fillColor = self.rgb(self.fillWell1.color) + self.rgb(self.fillWell2.color)
                if l.fillPoints.count != 4 { l.fillPoints = [n.width / 2, n.height, n.width / 2, 0] }
            } else {
                l.fillColor = self.rgb(self.fillWell1.color)
            }
        }
    }

    /// Adds a fill layer. Gradients run top to bottom.
    func addFillLayer(colors: [Float], gradient: Bool) {
        addLayer(.full)
        guard var s = current?(), let i = s.layers.indices.last else { return }
        let n = nativeSizeHint
        s.layers[i].kind = "fill"
        s.layers[i].fillColor = colors
        if gradient { s.layers[i].fillPoints = [n.width / 2, n.height, n.width / 2, 0] }
        s.layers[i].name = (gradient ? "그라디언트 칠 " : "단색 칠 ") + "\(s.layers.count)"
        onChange?(s, false)
        sync(s)
    }

    @objc private func addSolidFill() { addFillLayer(colors: [0.5, 0.5, 0.5], gradient: false) }
    /// Adds a text layer at the center of the photo
    @objc func addTextLayer() {
        addLayer(.full)
        guard var s = current?(), let i = s.layers.indices.last else { return }
        let n = nativeSizeHint
        s.layers[i].kind = "text"
        s.layers[i].name = "글자 \(s.layers.count)"
        s.layers[i].text = LayerText(string: "글자", font: "AppleSDGothicNeo-Bold", size: Double(n.height) / 10,
                                     color: [1, 1, 1], x: Double(n.width) / 2, y: Double(n.height) / 2, align: 1)
        onChange?(s, false)
        sync(s)
        textField.window?.makeFirstResponder(textField)
    }
    @objc private func addGradientFill() { addFillLayer(colors: [0, 0, 0, 1, 1, 1], gradient: true) }
    private let gradientLight = NSColorWell(style: .minimal)

    @objc private func invertColorsChanged() { edit(false) { $0.adjust.invert = self.invertBox.state == .on ? 1 : 0 } }
    @objc private func mixerChanged() {
        edit(false) { $0.adjust.mixer = self.mixerBox.state == .on ? [1, 0, 0, 0, 1, 0, 0, 0, 1] : [] }
    }
    @objc private func gradientMapChanged() {
        func rgb(_ c: NSColor) -> [Float] {
            let s = c.usingColorSpace(.sRGB) ?? c
            return [Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)]
        }
        edit(false) { $0.adjust.gradientMap = self.gradientBox.state == .on ? rgb(self.gradientDark.color) + rgb(self.gradientLight.color) : [] }
    }

    override func loadView() {
        brushRadius = UserDefaults.standard.object(forKey: "mask.radius") as? Double ?? 120
        let root = FlippedStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false

        // list card
        listCard = Card(title: "레이어")
        listCard.hideToggle()
        let addMenu = NSPopUpButton(frame: .zero, pullsDown: true)
        addMenu.addItem(withTitle: "레이어 추가")
        for (title, kind) in [("브러시 레이어", LayerMask.Kind.brush), ("선형 그라디언트", .linear),
                              ("원형 그라디언트", .radial), ("전체 (마스크 없음)", .full),
                              ("사각형 선택", .rect), ("타원 선택", .ellipse), ("올가미 선택", .polygon)] {
            let item = NSMenuItem(title: title, action: #selector(addLayer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            addMenu.menu?.addItem(item)
        }
        addMenu.menu?.addItem(.separator())
        for (title, sel) in [("글자 레이어", #selector(addTextLayer)), ("단색 칠 레이어", #selector(addSolidFill)), ("그라디언트 칠 레이어", #selector(addGradientFill)),
                             ("LUT 불러오기 (.cube)…", #selector(importLUTMenu)), ("이미지 레이어 (파일에서)…", #selector(placeImageMenu)), ("클립보드 그림으로 이미지 레이어", #selector(pasteImageMenu)),
                             ("그룹으로 묶기", #selector(groupSelected)), ("그룹 풀기", #selector(ungroupSelected))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            addMenu.menu?.addItem(item)
        }
        addMenu.controlSize = .small
        let remove = NSButton(title: "삭제", target: self, action: #selector(removeLayer))
        remove.controlSize = .small
        remove.bezelStyle = .appPush
        let dup = NSButton(title: "복제", target: self, action: #selector(duplicateLayer))
        dup.controlSize = .small
        dup.bezelStyle = .appPush
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "위로")!, target: self, action: #selector(layerUp))
        let down = NSButton(image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "아래로")!, target: self, action: #selector(layerDown))
        for b in [up, down] { b.controlSize = .small; b.bezelStyle = .appPush }
        let bar = NSStackView(views: [addMenu, dup, remove, NSView(), up, down])
        bar.spacing = 4
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        for v in [bar, list] as [NSView] {
            listCard.body.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: listCard.body.widthAnchor).isActive = true
        }
        listCard.applyCollapse()

        // layer settings
        let layerCard = Card(title: "혼합과 불투명도")
        for (key, name, _) in AdjustLayer.blendModes {
            blendPopup.addItem(withTitle: name)
            blendPopup.lastItem?.representedObject = key
        }
        blendPopup.controlSize = .small
        blendPopup.target = self
        blendPopup.action = #selector(blendChanged)
        blendPopup.insertItem(withTitle: AdjustLayer.passThrough.1, at: 0)
        blendPopup.item(at: 0)?.representedObject = AdjustLayer.passThrough.0
        let blendRow = NSStackView(views: [small("혼합 모드"), blendPopup])
        add(blendRow, to: layerCard)
        lockBox.target = self; lockBox.action = #selector(lockChanged)
        clipBox.target = self; clipBox.action = #selector(clipChanged)
        clipBox.toolTip = "바로 아래 레이어의 마스크 안에서만 효과가 납니다"
        add(NSStackView(views: [lockBox, clipBox]), to: layerCard)
        add(opacity, to: layerCard)
        opacity.onChange = { [weak self] v, d in self?.edit(d) { $0.opacity = Float(v) } }
        add(fillRow, to: layerCard)
        fillRow.onChange = { [weak self] v, d in self?.edit(d) { $0.fill = Float(v) } }

        // image layer position
        placeCard = Card(title: "이미지 자리")
        for r in [posX, posY, sizeRow, rotRow] { add(r, to: placeCard) }
        let placeHint = NSTextField(wrappingLabelWithString: "마스크 도구(B)로 사진 위에서 끌어 옮길 수도 있습니다 (마스크가 전체일 때).")
        placeHint.font = .systemFont(ofSize: 11)
        placeHint.textColor = .tertiaryLabelColor
        add(placeHint, to: placeCard)
        posX.onChange = { [weak self] v, d in guard let n = self?.nativeSizeHint else { return }; self?.edit(d) { $0.image?.cx = v / 100 * n.width } }
        posY.onChange = { [weak self] v, d in guard let n = self?.nativeSizeHint else { return }; self?.edit(d) { $0.image?.cy = v / 100 * n.height } }
        sizeRow.onChange = { [weak self] v, d in guard let n = self?.nativeSizeHint else { return }; self?.edit(d) { $0.image?.width = v / 100 * n.width } }
        rotRow.onChange = { [weak self] v, d in self?.edit(d) { $0.image?.rotation = v } }

        // mask
        let maskCard = Card(title: "마스크")
        maskKind.font = .systemFont(ofSize: 11)
        maskKind.textColor = .secondaryLabelColor
        invert.target = self; invert.action = #selector(invertChanged)
        showMask.target = self; showMask.action = #selector(showMaskChanged)
        eraseBox.target = self; eraseBox.action = #selector(eraseChanged)
        for v in [maskKind, NSStackView(views: [invert, showMask]), feather, radialFeather, lumaMin, lumaMax, lumaSoft,
                  brushSize, brushHard, brushFlowRow, eraseBox] as [NSView] {
            add(v, to: maskCard)
        }
        add(brushTipPopup, to: maskCard)
        brushViews = [brushSize, brushHard, brushFlowRow, eraseBox, brushTipPopup]
        radialViews = [radialFeather]
        feather.onChange = { [weak self] v, d in self?.edit(d) { $0.mask.feather = v } }
        radialFeather.onChange = { [weak self] v, d in self?.edit(d) { $0.mask.radialFeather = v } }
        lumaMin.onChange = { [weak self] v, d in self?.edit(d) { $0.mask.lumaMin = Float(v) } }
        lumaMax.onChange = { [weak self] v, d in self?.edit(d) { $0.mask.lumaMax = Float(v) } }
        lumaSoft.onChange = { [weak self] v, d in self?.edit(d) { $0.mask.lumaSoft = Float(v) } }
        brushSize.onChange = { [weak self] v, _ in self?.brushRadius = v }
        brushHard.onChange = { [weak self] v, _ in self?.brushHardness = v }
        brushFlowRow.onChange = { [weak self] v, _ in self?.brushFlow = v }

        // adjustments
        adjustCard = Card(title: "레이어 조정")
        let specs: [(String, WritableKeyPath<LocalAdjust, Float>, Double, Double, String)] = [
            ("노출", \.exposure, -4, 4, "%+.2f"), ("대비", \.contrast, -100, 100, "%+.0f"),
            ("밝기", \.brightness, -100, 100, "%+.0f"), ("채도", \.saturation, -100, 100, "%+.0f"),
            ("하이라이트", \.highlightTone, -100, 100, "%+.0f"), ("섀도", \.shadow, -100, 100, "%+.0f"),
            ("클래리티", \.clarity, -100, 100, "%+.0f"), ("디헤이즈", \.dehaze, 0, 100, "%.0f"),
            ("색온도 (차갑게 ↔ 따뜻하게)", \.temperature, -100, 100, "%+.0f"), ("틴트 (초록 ↔ 자홍)", \.tint, -100, 100, "%+.0f"),
        ]
        for (label, key, lo, hi, fmt) in specs {
            let row = SliderRow(label: label, min: lo, max: hi, format: fmt)
            row.onChange = { [weak self] v, d in self?.edit(d) { $0.adjust[keyPath: key] = Float(v) } }
            adjustRows.append((key, row))
            add(row, to: adjustCard)
        }
        adjustCard.onReset = { [weak self] in self?.edit(false) { $0.adjust = LocalAdjust() } }

        // color adjustments
        let colorCard = Card(title: "색 조정")
        let colorSpecs: [(String, WritableKeyPath<LocalAdjust, Float>, Double, Double, String, Double?)] = [
            ("활기", \.vibrance, -100, 100, "%+.0f", nil), ("색조 돌리기", \.hue, -180, 180, "%+.0f°", nil),
            ("포토 필터 색조", \.filterHue, 0, 360, "%.0f°", 35), ("포토 필터 농도", \.filterDensity, 0, 100, "%.0f%%", nil),
            ("포스터화 단계 (0 끔)", \.posterize, 0, 32, "%.0f", nil), ("한계값 (0 끔)", \.threshold, 0, 255, "%.0f", nil),
        ]
        for (label, key, lo, hi, fmt, def) in colorSpecs {
            let row = SliderRow(label: label, min: lo, max: hi, format: fmt, defaultValue: def)
            row.onChange = { [weak self] v, d in self?.edit(d) { $0.adjust[keyPath: key] = Float(key == \LocalAdjust.posterize ? v.rounded() : v) } }
            adjustRows.append((key, row))
            add(row, to: colorCard)
        }
        invertBox.target = self; invertBox.action = #selector(invertColorsChanged)
        gradientBox.target = self; gradientBox.action = #selector(gradientMapChanged)
        mixerBox.target = self; mixerBox.action = #selector(mixerChanged)
        for w in [gradientDark, gradientLight] {
            w.target = self; w.action = #selector(gradientMapChanged)
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        gradientDark.color = NSColor(red: 0.1, green: 0.05, blue: 0.2, alpha: 1)
        gradientLight.color = NSColor(red: 1, green: 0.85, blue: 0.6, alpha: 1)
        add(NSStackView(views: [invertBox]), to: colorCard)
        add(NSStackView(views: [gradientBox, NSView(), small("어두운 색"), gradientDark, small("밝은 색"), gradientLight]), to: colorCard)
        add(gradientPreset, to: colorCard)
        colorCard.onReset = { [weak self] in
            self?.edit(false) { l in
                l.adjust.vibrance = 0; l.adjust.hue = 0; l.adjust.filterHue = 35; l.adjust.filterDensity = 0
                l.adjust.posterize = 0; l.adjust.threshold = 0; l.adjust.invert = 0; l.adjust.gradientMap = []; l.adjust.gradientStops = nil
            }
        }
        // channel mixer
        let mixCard = Card(title: "채널 혼합")
        add(NSStackView(views: [mixerBox]), to: mixCard)
        for (i, name) in ["빨강 ← 빨강", "빨강 ← 초록", "빨강 ← 파랑", "초록 ← 빨강", "초록 ← 초록", "초록 ← 파랑",
                          "파랑 ← 빨강", "파랑 ← 초록", "파랑 ← 파랑"].enumerated() {
            let row = SliderRow(label: name, min: -2, max: 2, format: "%+.0f%%", display: 100, defaultValue: i % 4 == 0 ? 1 : 0)
            row.onChange = { [weak self] v, d in
                self?.edit(d) { l in
                    if l.adjust.mixer.count != 9 { l.adjust.mixer = [1, 0, 0, 0, 1, 0, 0, 0, 1] }
                    l.adjust.mixer[i] = Float(v)
                }
            }
            mixerRows.append(row)
            add(row, to: mixCard)
        }
        mixCard.onReset = { [weak self] in self?.edit(false) { $0.adjust.mixer = [] } }
        // filters
        let filterCard = Card(title: "필터")
        let fSpecs: [(String, WritableKeyPath<LocalAdjust, Float>, Double, Double, String)] = [
            ("가우시안 흐림 (원본 픽셀)", \.blur, 0, 300, "%.1f"), ("동작 흐림 거리", \.motionBlur, 0, 500, "%.0f"),
            ("동작 흐림 각도", \.motionAngle, -180, 180, "%+.0f°"), ("하이 패스 반경 (0 끔)", \.highPass, 0, 200, "%.1f"),
            ("노이즈 추가", \.noise, 0, 100, "%.0f"), ("중간값 (먼지와 스크래치)", \.median, 0, 5, "%.0f"),
            ("선명 효과", \.sharpen, 0, 300, "%.0f"),
        ]
        for (label, key, lo, hi, fmt) in fSpecs {
            let row = SliderRow(label: label, min: lo, max: hi, format: fmt)
            row.onChange = { [weak self] v, d in self?.edit(d) { $0.adjust[keyPath: key] = Float(v) } }
            adjustRows.append((key, row))
            add(row, to: filterCard)
        }
        let hpHint = NSTextField(wrappingLabelWithString: "하이 패스 레이어를 오버레이·소프트 라이트로 섞으면 주파수 분리 리터칭이 됩니다.")
        hpHint.font = .systemFont(ofSize: 11)
        hpHint.textColor = .tertiaryLabelColor
        add(hpHint, to: filterCard)
        filterCard.onReset = { [weak self] in
            self?.edit(false) { l in
                l.adjust.blur = 0; l.adjust.motionBlur = 0; l.adjust.motionAngle = 0; l.adjust.highPass = 0
                l.adjust.noise = 0; l.adjust.median = 0; l.adjust.sharpen = 0
            }
        }
        extraCards = [colorCard, mixCard, filterCard]

        // fill layer
        fillCard = Card(title: "칠")
        for w in [fillWell1, fillWell2] {
            w.target = self; w.action = #selector(fillChanged)
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        fillGradientBox.target = self; fillGradientBox.action = #selector(fillChanged)
        add(NSStackView(views: [small("색"), fillWell1, fillGradientBox, fillWell2]), to: fillCard)
        let fillHint = NSTextField(wrappingLabelWithString: "그라디언트 방향은 마스크 도구(B)로 사진 위에서 끌어 정합니다.")
        fillHint.font = .systemFont(ofSize: 11)
        fillHint.textColor = .tertiaryLabelColor
        add(fillHint, to: fillCard)
        // Pattern fill (fill layer pattern): checker, stripes, clouds, dots in two colors
        fillPatternPopup.addItems(withTitles: ["무늬 없음 (단색·그라디언트)", "체크", "줄무늬", "구름", "점"])
        fillPatternPopup.controlSize = .small
        fillPatternPopup.target = self; fillPatternPopup.action = #selector(fillPatternChanged)
        add(fillPatternPopup, to: fillCard)
        fillScaleRow.onChange = { [weak self] v, d in self?.edit(d) { $0.fillScale = Float(v) } }
        add(fillScaleRow, to: fillCard)
        for (pop, sel) in [(fillPresetGradient, #selector(fillPresetGradientChosen)), (fillPresetPattern, #selector(fillPresetPatternChosen)),
                           (fillSwatches, #selector(fillSwatchChosen)), (gradientPreset, #selector(gradientPresetChosen)),
                           (brushTipPopup, #selector(brushTipChosen))] {
            pop.controlSize = .small
            pop.target = self; pop.action = sel
        }
        add(fillSwatches, to: fillCard)
        add(fillPresetGradient, to: fillCard)
        add(fillPresetPattern, to: fillCard)
        reloadPresets()
        NotificationCenter.default.addObserver(forName: PresetFiles.changed, object: nil, queue: .main) { [weak self] _ in self?.reloadPresets() }

        // text layer
        textCard = Card(title: "글자")
        textField.placeholderString = "글자"
        textField.usesSingleLineMode = false
        textField.lineBreakMode = .byWordWrapping
        textField.cell?.wraps = true
        textField.target = self; textField.action = #selector(textChanged)
        textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        add(textField, to: textCard)
        textFont.controlSize = .small
        textFont.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        textFont.target = self; textFont.action = #selector(textChanged)
        add(textFont, to: textCard)
        textSize.onChange = { [weak self] v, d in self?.editText(d) { $0.size = v } }
        textTracking.onChange = { [weak self] v, d in self?.editText(d) { $0.tracking = v } }
        add(textSize, to: textCard)
        add(textTracking, to: textCard)
        textColor.target = self; textColor.action = #selector(textChanged)
        textColor.widthAnchor.constraint(equalToConstant: 44).isActive = true
        textAlign.controlSize = .small
        textAlign.target = self; textAlign.action = #selector(textChanged)
        add(NSStackView(views: [small("색"), textColor, NSView(), textAlign]), to: textCard)
        let textHint = NSTextField(wrappingLabelWithString: "PSD에서 가져온 글자는 고치기 전까지 파일에 든 모양을 씁니다. 자리는 이미지 자리처럼 마스크 도구(B)로 끌어 옮깁니다.")
        textHint.font = .systemFont(ofSize: 11)
        textHint.textColor = .tertiaryLabelColor
        add(textHint, to: textCard)

        // Blend If
        let biCard = Card(title: "혼합 조건")
        let biNames = ["이 레이어 · 검정 시작", "이 레이어 · 검정 끝", "이 레이어 · 흰색 시작", "이 레이어 · 흰색 끝",
                       "아래 레이어 · 검정 시작", "아래 레이어 · 검정 끝", "아래 레이어 · 흰색 시작", "아래 레이어 · 흰색 끝"]
        for (k, name) in biNames.enumerated() {
            let def: Double = k % 4 < 2 ? 0 : 1
            let row = SliderRow(label: name, min: 0, max: 1, format: "%.0f", display: 255, defaultValue: def)
            row.onChange = { [weak self] v, d in
                self?.edit(d) { l in
                    var b = l.blendIf ?? [0, 0, 1, 1, 0, 0, 1, 1]
                    b[k] = Float(v)
                    // keep start ≤ end
                    if k % 2 == 0 { b[k + 1] = max(b[k + 1], b[k]) } else { b[k - 1] = min(b[k - 1], b[k]) }
                    l.blendIf = b == [0, 0, 1, 1, 0, 0, 1, 1] ? nil : b
                }
            }
            blendIfRows.append(row)
            add(row, to: biCard)
        }
        let biHint = NSTextField(wrappingLabelWithString: "이 레이어·아래 레이어 밝기가 범위 밖이면 효과가 빠집니다. 시작과 끝을 벌리면 부드럽게 섞입니다 (⌥ 끌기).")
        biHint.font = .systemFont(ofSize: 11)
        biHint.textColor = .tertiaryLabelColor
        add(biHint, to: biCard)
        blendIfCard = biCard

        // Layer effects (stacked like smart filters, Effects.swift)
        let fxCard = Card(title: "효과")
        add(effectsEditor, to: fxCard)
        effectsEditor.onChange = { [weak self] list, d in self?.edit(d) { $0.adjust.effects = list.isEmpty ? nil : list } }
        effectsCard = fxCard
        // Layer styles (LayerStyles.swift)
        let stCard = Card(title: "스타일")
        add(stylesEditor, to: stCard)
        stylesEditor.onChange = { [weak self] st, d in self?.edit(d) { $0.styles = st.isActive ? st : nil } }
        stylesCard = stCard
        detailCards = [layerCard, textCard, placeCard, fillCard, maskCard, blendIfCard!, adjustCard, colorCard, mixCard, filterCard, fxCard, stCard]
        listCard.isHidden = listHidden
        for card in [listCard!] + detailCards {
            card.hideToggle()
            card.applyCollapse()
            root.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view = scroll
        // If the photo opened before the tab, fill with its layers (a late-created tab stayed on "no photo")
        sync(current?())
    }

    private func small(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func add(_ v: NSView, to card: Card) {
        card.body.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
    }

    // MARK: - Changing values

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return current?()?.layers.firstIndex { $0.id == id }
    }

    /// Edits the one selected layer. Locked layers aren't changed (only unlocking works).
    private func edit(_ dragging: Bool, allowLocked: Bool = false, _ f: (inout AdjustLayer) -> Void) {
        guard var s = current?(), let i = selectedIndex else { return }
        if s.layers[i].locked && !allowLocked { NSSound.beep(); sync(s); return }
        f(&s.layers[i])
        onChange?(s, dragging)
        if !dragging { sync(s) }
    }

    private func editAll(_ f: (inout DevelopSettings) -> Void) {
        guard var s = current?() else { return }
        f(&s)
        onChange?(s, false)
        sync(s)
    }

    func select(_ id: String?) {
        selectedID = id
        onSelect?(id)
        sync(current?())
    }

    @objc private func addLayer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = LayerMask.Kind(rawValue: raw) else { return }
        addLayer(kind)
    }

    /// Adds a new layer on top and selects it. Gradients get a default shape at the photo center.
    func addLayer(_ kind: LayerMask.Kind, native: CGSize? = nil) {
        guard let s0 = current?() else { return }
        let names: [LayerMask.Kind: String] = [.brush: "브러시", .linear: "선형 그라디언트", .radial: "원형 그라디언트", .full: "전체",
                                               .rect: "사각형 선택", .ellipse: "타원 선택", .polygon: "올가미 선택"]
        var layer = AdjustLayer(name: "\(names[kind] ?? "레이어") \(s0.layers.count + 1)")
        layer.mask.kind = kind
        let size = native ?? nativeSizeHint
        layer.mask.linear = [size.width / 2, size.height * 0.95, size.width / 2, size.height * 0.5]
        layer.mask.radial = [size.width / 2, size.height / 2, size.width * 0.25, size.width * 0.25]
        selectedID = layer.id
        editAll { $0.layers.append(layer) }
        onSelect?(layer.id)
    }

    var nativeSizeHint = CGSize(width: 8192, height: 5464)

    @objc func removeLayer() {
        guard let i = selectedIndex else { return }
        selectedID = nil
        editAll { LayerTree.remove(&$0.layers, i) }
        onSelect?(nil)
    }

    @objc func duplicateLayer() {
        guard let i = selectedIndex, let s = current?() else { return }
        // For a group, duplicate descendants with new ids too.
        let r = LayerTree.block(s.layers, i)
        var ids: [String: String] = [:]
        var copies = Array(s.layers[r])
        for k in copies.indices { let n = UUID().uuidString; ids[copies[k].id] = n; copies[k].id = n }
        for k in copies.indices { if let g = copies[k].group, let n = ids[g] { copies[k].group = n } }
        copies[copies.count - 1].name += " 복사"
        let newID = copies[copies.count - 1].id
        selectedID = newID
        editAll { $0.layers.insert(contentsOf: copies, at: r.upperBound + 1) }
        onSelect?(newID)
    }

    @objc func layerUp() {
        guard let i = selectedIndex else { return }
        editAll { LayerTree.moveUp(&$0.layers, i) }
    }

    @objc func layerDown() {
        guard let i = selectedIndex else { return }
        editAll { LayerTree.moveDown(&$0.layers, i) }
    }

    /// Bring to front / send to back (⇧⌘] / ⇧⌘[): step until it can't move further
    func layerToEnd(top: Bool) {
        guard let id = selectedID, selectedIndex != nil else { return }
        editAll { s in
            for _ in 0..<s.layers.count {
                guard let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
                let before = s.layers.map(\.id)
                if top { LayerTree.moveUp(&s.layers, i) } else { LayerTree.moveDown(&s.layers, i) }
                if s.layers.map(\.id) == before { return }
            }
        }
    }

    /// Select the layer above / below (⌥] / ⌥[). Below the bottom is the background.
    func selectNeighbor(up: Bool) {
        guard let layers = current?()?.layers, !layers.isEmpty else { return }
        let next: String?
        if let i = selectedIndex {
            let j = i + (up ? 1 : -1)
            if j >= layers.count { NSSound.beep(); return }
            next = j < 0 ? nil : layers[j].id
        } else {
            guard up else { NSSound.beep(); return }
            next = layers[0].id
        }
        select(next)
    }

    /// Delete the selected layer (⌫). Locked layers just beep. True if something was deleted.
    func deleteSelectedLayer() -> Bool {
        guard let i = selectedIndex, let s = current?() else { return false }
        if s.layers[i].locked { NSSound.beep(); return true }
        // After deleting, select the layer right below (below the group block for groups)
        let below = LayerTree.block(s.layers, i).lowerBound - 1
        let next = below >= 0 ? s.layers[below].id : nil
        removeLayer()
        if next != nil { select(next) }
        return true
    }

    @objc private func placeImageMenu() { onPlaceImage?() }

    /// Adds a .cube LUT as a full adjustment layer (strength via opacity).
    @objc func importLUTMenu() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        panel.message = "LUT(.cube)를 고르세요. 파일은 복사해 둡니다."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        importLUT(u)
    }

    func importLUT(_ u: URL) {
        guard let file = try? LayerImageStore.importFile(u) else { NSSound.beep(); return }
        guard CubeLUT.load(file) != nil else {
            let a = NSAlert()
            a.messageText = "\(u.lastPathComponent)을 읽을 수 없습니다"
            a.informativeText = "3D .cube LUT만 읽습니다."
            a.runModal()
            return
        }
        addLayer(.full)
        guard var s = current?(), let i = s.layers.indices.last else { return }
        s.layers[i].adjust.lut = file
        s.layers[i].name = "LUT · " + u.deletingPathExtension().lastPathComponent
        onChange?(s, false)
        sync(s)
    }
    @objc private func pasteImageMenu() { pasteImage() }

    /// Adds an image file as an image layer, centered at half the photo width.
    func addImageLayer(file: String, name: String) {
        guard let s0 = current?(), let src = Layers.sourceImage(file) else { NSSound.beep(); return }
        let n = nativeSizeHint
        var width = n.width * 0.5
        // Tall images don't exceed half the photo height
        let h = width * src.extent.height / max(src.extent.width, 1)
        if h > n.height * 0.5 { width *= n.height * 0.5 / h }
        var layer = AdjustLayer(name: "\(name) \(s0.layers.count + 1)")
        layer.kind = "image"
        layer.image = LayerImage(file: file, cx: n.width / 2, cy: n.height / 2, width: width)
        // If the selected layer is in a group, insert into the same group right above it.
        let at = selectedIndex.map { $0 + 1 } ?? s0.layers.count
        if let i = selectedIndex { layer.group = s0.layers[i].isGroup ? s0.layers[i].id : s0.layers[i].group }
        let insertAt = selectedIndex.flatMap { s0.layers[$0].isGroup ? $0 : nil } ?? at
        selectedID = layer.id
        editAll { $0.layers.insert(layer, at: insertAt) }
        onSelect?(layer.id)
    }

    /// Clipboard image as an image layer (⌘V).
    func pasteImage() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, let file = try? LayerImageStore.importFile(u) {
            addImageLayer(file: file, name: u.deletingPathExtension().lastPathComponent)
            return
        }
        if let data = pb.data(forType: .png), let file = try? LayerImageStore.importData(data, ext: "png") {
            addImageLayer(file: file, name: "붙여넣은 그림"); return
        }
        if let data = pb.data(forType: .tiff), let file = try? LayerImageStore.importData(data, ext: "tiff") {
            addImageLayer(file: file, name: "붙여넣은 그림"); return
        }
        NSSound.beep()
    }

    @objc func groupSelected() {
        guard let i = selectedIndex else { NSSound.beep(); return }
        var gid = ""
        let n = (current?()?.layers.filter(\.isGroup).count ?? 0) + 1
        editAll { gid = LayerTree.groupLayer(&$0.layers, i, name: "그룹 \(n)") }
        select(gid)
    }

    @objc func ungroupSelected() {
        guard let i = selectedIndex, current?()?.layers[i].isGroup == true else { NSSound.beep(); return }
        selectedID = nil
        editAll { LayerTree.ungroup(&$0.layers, i) }
        onSelect?(nil)
    }

    @objc private func blendChanged() {
        guard let key = blendPopup.selectedItem?.representedObject as? String else { return }
        edit(false) { $0.blend = key }
    }

    @objc private func lockChanged() { edit(false, allowLocked: true) { $0.locked = self.lockBox.state == .on } }
    @objc private func clipChanged() { edit(false) { $0.clipped = self.clipBox.state == .on } }

    @objc private func invertChanged() { edit(false) { $0.mask.invert = self.invert.state == .on } }
    @objc private func showMaskChanged() { onShowMask?(showMask.state == .on) }
    @objc private func eraseChanged() { erase = eraseBox.state == .on }

    func setShowMask(_ on: Bool) { showMask.state = on ? .on : .off }

    // MARK: - Display

    func sync(_ s: DevelopSettings?) {
        guard isViewLoaded else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let layers = s?.layers ?? []
        if let id = selectedID, !layers.contains(where: { $0.id == id }) { selectedID = nil }
        for (idx, layer) in layers.enumerated().reversed() {
            let row = LayerListRow(layer: layer, selected: layer.id == selectedID, depth: LayerTree.depth(layers, idx))
            row.onClick = { [weak self] in self?.select(layer.id) }
            row.contextMenu = { [weak self] in self?.rowMenu?(layer.id) }
            row.onToggle = { [weak self] on in
                guard let self, var s = self.current?(), let i = s.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                s.layers[i].enabled = on
                self.onChange?(s, false)
                self.sync(s)
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let bg = LayerListRow(background: s == nil ? "사진 없음" : "배경 (RAW 현상)")
        bg.onClick = { [weak self] in self?.select(nil) }
        bg.contextMenu = { [weak self] in self?.rowMenu?(nil) }
        list.addArrangedSubview(bg)
        bg.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

        let layer = selectedIndex.flatMap { s?.layers[$0] }
        detailCards.forEach { $0.isHidden = layer == nil }
        guard let layer else { return }
        blendPopup.item(at: 0)?.isHidden = !layer.isGroup
        let i = blendPopup.itemArray.firstIndex { $0.representedObject as? String == layer.blend } ?? 1
        blendPopup.selectItem(at: i)
        opacity.value = Double(layer.opacity)
        fillRow.value = Double(layer.fill)
        fillRow.isHidden = layer.isGroup
        placeCard.isHidden = !layer.isImage && !(layer.isText && layer.image != nil)
        fillCard.isHidden = !layer.isFill
        textCard.isHidden = !layer.isText
        if let t = layer.text {
            if textField.currentEditor() == nil { textField.stringValue = t.string }
            let fam = NSFont(name: t.font, size: 12)?.familyName ?? t.font
            textFont.selectItem(withTitle: fam)
            textSize.value = t.size
            textTracking.value = t.tracking
            let c = t.color.map { CGFloat($0) } + [1, 1, 1]
            textColor.color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
            textAlign.selectedSegment = t.align
        }
        if layer.isFill {
            let c = layer.fillColor.map { CGFloat($0) }
            if c.count >= 3 { fillWell1.color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1) }
            if c.count == 6 { fillWell2.color = NSColor(srgbRed: c[3], green: c[4], blue: c[5], alpha: 1) }
            fillGradientBox.state = c.count == 6 ? .on : .off
            fillWell2.isEnabled = c.count == 6
        }
        adjustCard.isHidden = layer.kind != "adjust"
        effectsCard?.isHidden = layer.isGroup
        fillPatternPopup.selectItem(at: (layer.fillPattern ?? -1) + 1)
        fillScaleRow.value = Double(layer.fillScale ?? 60)
        fillScaleRow.isHidden = layer.fillPattern == nil
        let bi = layer.blendIf ?? [0, 0, 1, 1, 0, 0, 1, 1]
        for (k, row) in blendIfRows.enumerated() { row.value = Double(bi[k]) }
        effectsEditor.show(layer.adjust.fx)
        stylesCard?.isHidden = !layer.takesStyles
        stylesEditor.show(layer.styles, applicable: layer.takesStyles)
        if let im = layer.image {
            let n = nativeSizeHint
            posX.value = im.cx / n.width * 100
            posY.value = im.cy / n.height * 100
            sizeRow.value = im.width / n.width * 100
            rotRow.value = im.rotation
        }
        let kindName: [LayerMask.Kind: String] = [
            .brush: "브러시 마스크 — 마스크 도구(B)로 칠합니다. 옵션 키를 누르고 칠하면 지웁니다.",
            .linear: "선형 그라디언트 — 마스크 도구(B)로 효과가 시작할 곳에서 끝날 곳까지 끕니다.",
            .radial: "원형 그라디언트 — 마스크 도구(B)로 가운데에서 바깥으로 끕니다.",
            .full: "전체 — 사진 전체에 겁니다. 루마 레인지로 밝기 범위만 고를 수 있습니다.",
            .rect: "사각형 선택 — 마스크 도구(B)로 대각선으로 끕니다. 가장자리는 마스크 흐림으로 부드럽게 합니다.",
            .ellipse: "타원 선택 — 마스크 도구(B)로 대각선으로 끕니다.",
            .polygon: "올가미 선택 — 마스크 도구(B)로 둘레를 따라 그립니다. 손을 떼면 닫힙니다.",
        ]
        maskKind.stringValue = kindName[layer.mask.kind] ?? ""
        invert.state = layer.mask.invert ? .on : .off
        lockBox.state = layer.locked ? .on : .off
        clipBox.state = layer.clipped ? .on : .off
        clipBox.isEnabled = (s?.layers.firstIndex { $0.id == layer.id } ?? 0) > 0
        feather.value = layer.mask.feather
        radialFeather.value = layer.mask.radialFeather
        lumaMin.value = Double(layer.mask.lumaMin)
        lumaMax.value = Double(layer.mask.lumaMax)
        lumaSoft.value = Double(layer.mask.lumaSoft)
        brushViews.forEach { $0.isHidden = layer.mask.kind != .brush }
        radialViews.forEach { $0.isHidden = layer.mask.kind != .radial }
        brushSize.value = brushRadius
        brushHard.value = brushHardness
        brushFlowRow.value = brushFlow
        eraseBox.state = erase ? .on : .off
        for (key, row) in adjustRows { row.value = Double(layer.adjust[keyPath: key]) }
        let a = layer.adjust
        invertBox.state = a.invert >= 0.5 ? .on : .off
        gradientBox.state = a.gradientMap.count == 6 || a.gradientStops != nil ? .on : .off
        if a.gradientMap.count == 6 {
            let g = a.gradientMap.map { CGFloat($0) }
            gradientDark.color = NSColor(srgbRed: g[0], green: g[1], blue: g[2], alpha: 1)
            gradientLight.color = NSColor(srgbRed: g[3], green: g[4], blue: g[5], alpha: 1)
        }
        mixerBox.state = a.mixer.count == 9 ? .on : .off
        let mix = a.mixer.count == 9 ? a.mixer : [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for (row, v) in zip(mixerRows, mix) { row.value = Double(v) }
        // Hide adjustment cards for image and group layers
        extraCards.forEach { $0.isHidden = layer.kind != "adjust" }
    }
}

final class LayerListRow: DraggableLayerRow {
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { onClick?(); return contextMenu?() }
    var onToggle: ((Bool) -> Void)?
    private let selected: Bool

    init(layer: AdjustLayer, selected: Bool, depth: Int = 0) {
        self.selected = selected
        super.init(frame: .zero)
        dragID = layer.id
        isGroupRow = layer.isGroup
        let content = LayerRowContent(layer: layer, name: layer.name, subtitle: LayerRowContent.subtitle(layer),
                                      visible: layer.enabled, toggleable: true, selected: selected)
        content.onToggle = { [weak self] on in self?.onToggle?(on) }
        place(content, depth: depth)
    }

    init(background title: String) {
        selected = false
        super.init(frame: .zero)
        let content = LayerRowContent(layer: nil, background: LayerThumbs.backgroundProvider?() ?? NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil),
                                      name: title, subtitle: "RAW 현상", visible: true, toggleable: false, selected: false)
        place(content, depth: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func place(_ content: LayerRowContent, depth: Int) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4 + CGFloat(depth) * 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),   // the visibility check sits at the right end
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }


    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// Mask tool on the canvas. Behaves as paint/linear/radial by the selected layer's mask type.
final class MaskOverlayView: NSView {
    weak var canvas: CanvasView?
    /// Selected adjustment layer (named adjustLayer since `layer` clashes with NSView's).
    var adjustLayer: AdjustLayer? { didSet { needsDisplay = true } }
    var brushRadius: Double = 120
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// Finished brush stroke (source coordinates, whether eraser).
    var onStroke: (([CGPoint], Bool) -> Void)?
    /// When a new gradient is dragged (source coordinates start, end, dragging).
    var onGradient: ((CGPoint, CGPoint, Bool) -> Void)?
    /// When a lasso selection is finished (source coordinate points).
    var onPolygon: (([CGPoint]) -> Void)?
    /// Moving an image layer (source coordinates start, current, dragging).
    var onMoveImage: ((CGPoint, CGPoint, Bool) -> Void)?
    /// Click-based selection tools: single click (row, column, magic wand, color), polygon (a vertex per click),
    /// magnetic (lasso snapping to edges), quick selection (painting spreads to similar areas)
    enum ClickMode { case none, point, polygonClicks, magnetic, quick }
    var clickMode: ClickMode = .none { didSet { clicks = []; drawing = []; needsDisplay = true } }
    var onPoint: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    /// Snaps a view-coordinate point to an edge (magnetic lasso)
    var snapView: ((CGPoint) -> CGPoint)?
    var onQuickStroke: (([CGPoint], NSEvent.ModifierFlags) -> Void)?
    /// Tool receiving strokes instead of quick selection (AI erase, object selection)
    var quickOverride: (([CGPoint], NSEvent.ModifierFlags) -> Void)?
    var onPolygonFlags: (([CGPoint], NSEvent.ModifierFlags) -> Void)?
    private var clicks: [CGPoint] = []
    private var polyFlags: NSEvent.ModifierFlags = []
    /// Modifier keys and drag id at drag start (selection add/subtract)
    private(set) var startFlags: NSEvent.ModifierFlags = []
    private(set) var gesture = 0

    /// One-time work on the first canvas click (layer edit: create the layer on first use, not on tool pick).
    /// Returning true ends that click here (one-shot things like fill layers and AI selection).
    var prepare: (() -> Bool)?
    private var movesImage: Bool { adjustLayer.map { ($0.isImage || $0.isText || $0.kind == "shape") && $0.mask.kind == .full } ?? false }

    private var drawing: [CGPoint] = []
    private var dragStart: CGPoint?
    private var hover: CGPoint?
    private var erasing = false

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private var viewBrush: CGFloat { CGFloat(brushRadius) * (canvas?.zoom ?? 1) }

    override func draw(_ dirtyRect: NSRect) {
        if clickMode == .polygonClicks, !clicks.isEmpty {
            let p = NSBezierPath()
            p.move(to: clicks[0]); clicks.dropFirst().forEach { p.line(to: $0) }
            if let h = hover { p.line(to: h) }
            selectionStroke(p)
            for c in clicks { NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill() }
        }
        if (clickMode == .magnetic || clickMode == .quick), drawing.count > 1 {
            let p = NSBezierPath()
            p.move(to: drawing[0]); drawing.dropFirst().forEach { p.line(to: $0) }
            if clickMode == .quick {
                p.lineWidth = max(viewBrush * 2, 2); p.lineCapStyle = .round; p.lineJoinStyle = .round
                NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke(); p.stroke()
            } else { selectionStroke(p) }
        }
        guard let layer = adjustLayer, let toView else { return }
        switch layer.mask.kind {
        case .brush:
            if drawing.count > 0 {
                let p = NSBezierPath()
                p.move(to: drawing[0])
                for q in drawing.dropFirst() { p.line(to: q) }
                if drawing.count == 1 { p.line(to: CGPoint(x: drawing[0].x + 0.1, y: drawing[0].y)) }
                p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.lineWidth = viewBrush * 2
                (erasing ? NSColor.systemBlue : NSColor.systemRed).withAlphaComponent(0.3).setStroke()
                p.stroke()
            }
            if let h = hover {
                let c = NSBezierPath(ovalIn: CGRect(x: h.x - viewBrush, y: h.y - viewBrush, width: viewBrush * 2, height: viewBrush * 2))
                NSColor.white.withAlphaComponent(0.7).setStroke()
                c.lineWidth = 1
                c.stroke()
            }
        case .linear:
            let m = layer.mask.linear
            let a = toView(CGPoint(x: m[0], y: m[1])), b = toView(CGPoint(x: m[2], y: m[3]))
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            let n = CGPoint(x: -dy / len * 2000, y: dx / len * 2000)
            for (p, dash) in [(a, false), (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), true), (b, false)] {
                let l = NSBezierPath()
                l.move(to: CGPoint(x: p.x - n.x, y: p.y - n.y)); l.line(to: CGPoint(x: p.x + n.x, y: p.y + n.y))
                if dash { l.setLineDash([6, 4], count: 2, phase: 0) }
                l.lineWidth = 1.5
                NSColor.white.withAlphaComponent(0.8).setStroke()
                l.stroke()
            }
        case .radial:
            let m = layer.mask.radial
            let c = toView(CGPoint(x: m[0], y: m[1]))
            let e = toView(CGPoint(x: m[0] + m[2], y: m[1])), f = toView(CGPoint(x: m[0], y: m[1] + m[3]))
            let rx = hypot(e.x - c.x, e.y - c.y), ry = hypot(f.x - c.x, f.y - c.y)
            let o = NSBezierPath(ovalIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
            o.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.8).setStroke()
            o.stroke()
            let k = CGFloat(1 - layer.mask.radialFeather * 0.9)
            let inner = NSBezierPath(ovalIn: CGRect(x: c.x - rx * k, y: c.y - ry * k, width: rx * k * 2, height: ry * k * 2))
            inner.setLineDash([5, 4], count: 2, phase: 0)
            inner.lineWidth = 1
            inner.stroke()
        case .rect, .ellipse:
            let b = layer.mask.box
            guard b[0] != b[2] || b[1] != b[3] else { break }
            let x0 = min(b[0], b[2]), x1 = max(b[0], b[2]), y0 = min(b[1], b[3]), y1 = max(b[1], b[3])
            let p = NSBezierPath()
            if layer.mask.kind == .rect {
                let c = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)].map(toView)
                p.move(to: c[0]); c.dropFirst().forEach { p.line(to: $0) }
            } else {
                let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = (x1 - x0) / 2, ry = (y1 - y0) / 2
                let c = (0..<48).map { i -> CGPoint in
                    let t = Double(i) / 48 * 2 * .pi
                    return toView(CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t)))
                }
                p.move(to: c[0]); c.dropFirst().forEach { p.line(to: $0) }
            }
            p.close()
            selectionStroke(p)
        case .image:
            break
        case .polygon:
            let pts = drawing.count > 1 ? drawing : stride(from: 0, to: layer.mask.polygon.count - 1, by: 2)
                .map { toView(CGPoint(x: layer.mask.polygon[$0], y: layer.mask.polygon[$0 + 1])) }
            guard pts.count > 1 else { break }
            let p = NSBezierPath()
            p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }
            p.close()
            selectionStroke(p)
        case .full:
            // image layer: picture border
            if let im = layer.image {
                let hw = im.width / 2
                let src = Layers.sourceImage(im.file)
                let hh = hw * Double((src?.extent.height ?? 1) / max(src?.extent.width ?? 1, 1))
                let a = im.rotation * .pi / 180
                let corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { (x, y) in
                    toView(CGPoint(x: im.cx + x * cos(a) - y * sin(a), y: im.cy + x * sin(a) + y * cos(a)))
                }
                let p = NSBezierPath()
                p.move(to: corners[0]); corners.dropFirst().forEach { p.line(to: $0) }; p.close()
                p.lineWidth = 1
                p.setLineDash([5, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.8).setStroke()
                p.stroke()
            }
        }
    }

    /// Selection outline: black dashes over a white line (visible on any background).
    private func selectionStroke(_ p: NSBezierPath) {
        p.lineWidth = 1.5
        NSColor.white.setStroke()
        p.stroke()
        p.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.black.setStroke()
        p.stroke()
    }

    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startFlags = event.modifierFlags.intersection([.shift, .option, .command])
        gesture += 1
        if let fromView {
            switch clickMode {
            case .point:
                onPoint?(fromView(p), startFlags); return
            case .polygonClicks:
                if clicks.count >= 3, event.clickCount >= 2 || hypot(p.x - clicks[0].x, p.y - clicks[0].y) < 8 {
                    let pts = clicks
                    clicks = []
                    onPolygonFlags?(pts.map(fromView), polyFlags)
                    needsDisplay = true
                    return
                }
                if clicks.isEmpty { polyFlags = startFlags }
                clicks.append(p)
                needsDisplay = true
                return
            case .magnetic:
                polyFlags = startFlags
                drawing = [snapView?(p) ?? p]
                return
            case .quick:
                drawing = [p]
                return
            case .none: break
            }
        }
        if let prep = prepare {
            prepare = nil
            if prep() { return }
        }
        guard let layer = adjustLayer else { return }
        if layer.mask.kind == .brush || layer.mask.kind == .polygon {
            erasing = event.modifierFlags.contains(.option)
            drawing = [p]
        } else {
            dragStart = p
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        switch clickMode {
        case .magnetic:
            if let last = drawing.last, hypot(p.x - last.x, p.y - last.y) >= 4 { drawing.append(snapView?(p) ?? p) }
            needsDisplay = true
            return
        case .quick:
            if let last = drawing.last, hypot(p.x - last.x, p.y - last.y) >= max(viewBrush / 3, 3) { drawing.append(p) }
            needsDisplay = true
            return
        case .point, .polygonClicks: return
        case .none: break
        }
        guard let layer = adjustLayer, let fromView else { return }
        if layer.mask.kind == .brush {
            if let last = drawing.last, hypot(p.x - last.x, p.y - last.y) >= max(viewBrush / 4, 2) { drawing.append(p) }
        } else if layer.mask.kind == .polygon {
            if let last = drawing.last, hypot(p.x - last.x, p.y - last.y) >= 3 { drawing.append(p) }
        } else if let s = dragStart, movesImage {
            onMoveImage?(fromView(s), fromView(p), true)
        } else if let s = dragStart, hypot(p.x - s.x, p.y - s.y) > 4 {
            onGradient?(fromView(s), fromView(p), true)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let fromView {
            switch clickMode {
            case .magnetic:
                if drawing.count >= 3 { onPolygonFlags?(drawing.map(fromView), polyFlags) }
                drawing = []; needsDisplay = true; return
            case .quick:
                if !drawing.isEmpty { (quickOverride ?? onQuickStroke)?(drawing.map(fromView), startFlags) }
                drawing = []; needsDisplay = true; return
            case .point, .polygonClicks: return
            case .none: break
            }
        }
        guard let layer = adjustLayer, let fromView else { return }
        if layer.mask.kind == .brush, !drawing.isEmpty {
            onStroke?(drawing.map(fromView), erasing)
            drawing = []
        } else if layer.mask.kind == .polygon, !drawing.isEmpty {
            if drawing.count >= 3 { onPolygon?(drawing.map(fromView)) }
            drawing = []
        } else if let s = dragStart, movesImage {
            onMoveImage?(fromView(s), fromView(p), false)
        } else if let s = dragStart, hypot(p.x - s.x, p.y - s.y) > 4 {
            onGradient?(fromView(s), fromView(p), false)
        }
        dragStart = nil
        needsDisplay = true
    }
}
