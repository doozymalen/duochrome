import AppKit
import CoreImage

/// 컬러 에디터: 기본 / 고급 / 스킨 톤 탭.
/// - 기본: 사진의 색조 분포 그래프 + 여덟 색 칸, 색조·채도·밝기
/// - 고급: 큰 색조 휠에서 범위를 끌어 정하고, 스포이트로 범위를 더한다 (최대 35개). 조정 목록, 선택한 범위 보기
/// - 스킨 톤: 피부색 집기, 색조·채도·밝기 균일
/// 값은 `settings`를 바꾸고 `onChange`로 알린다 (속성 패널이 받아 저장).
final class ColorEditorView: NSStackView {
    var settings = DevelopSettings()
    var onChange: ((DevelopSettings, Bool) -> Void)?
    /// 캔버스에서 색 집기 (0 범위 더하기, 1 피부색)
    var onPick: ((Int) -> Void)?
    /// 선택한 색 범위 보기 (nil이면 끔)
    var onViewRange: ((ColorRange?) -> Void)?
    /// 색조 분포를 잴 사진 (sync 때 넣는다)
    weak var doc: RawDocument?

    private let tabs = NSSegmentedControl(labels: ["기본", "고급", "스킨 톤"], trackingMode: .selectOne, target: nil, action: nil)
    private let basicPage = NSStackView(), advancedPage = NSStackView(), skinPage = NSStackView()
    /// 고른 범위 (0~7 기본, 8~ 고급)
    private(set) var index = 0
    private var measureGeneration = 0

    // 기본
    private let histogram = HueHistogramView()
    private var basicRows: [SliderRow] = []
    // 고급
    private let wheel = HueRangeWheel()
    private var advancedRows: [SliderRow] = []
    private let list = NSStackView()
    private let viewRange = NSButton(checkboxWithTitle: "선택한 색 범위 보기", target: nil, action: nil)
    private let removeButton = NSButton()
    // 전·후
    private let compareBasic = BeforeAfterView(), compareAdvanced = BeforeAfterView()
    // 스킨 톤
    private let skinSwatch = NSView()
    private let skinOn = NSButton(checkboxWithTitle: "사용", target: nil, action: nil)
    private var skinRows: [SliderRow] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        tabs.segmentDistribution = .fillEqually
        tabs.controlSize = .small
        tabs.selectedSegment = UserDefaults.standard.integer(forKey: "colorEditorTab")
        tabs.target = self
        tabs.action = #selector(tabChanged)
        add(tabs, to: self)
        for p in [basicPage, advancedPage, skinPage] {
            p.orientation = .vertical
            p.alignment = .leading
            p.spacing = 10
            add(p, to: self)
        }
        buildBasic()
        buildAdvanced()
        buildSkin()
        tabChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ v: NSView, to s: NSStackView) {
        s.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
    }

    private var ranges: [ColorRange] { settings.color.editor }
    private var basicCount: Int { ColorRange.basic.count }

    private func edit(_ dragging: Bool, _ f: (inout ColorRange) -> Void) {
        guard settings.color.editor.indices.contains(index) else { return }
        f(&settings.color.editor[index])
        onChange?(settings, dragging)
        refreshDecor()
    }

    // MARK: 기본

    private func buildBasic() {
        histogram.onPick = { [weak self] i in self?.select(i) }
        add(histogram, to: basicPage)
        histogram.heightAnchor.constraint(equalToConstant: 92).isActive = true
        let specs: [(String, Double, Double, String, WritableKeyPath<ColorRange, Float>)] = [
            ("색조", -30, 30, "%+.0f°", \.dHue), ("채도", -100, 100, "%+.0f", \.dSat), ("밝기", -100, 100, "%+.0f", \.dLight),
        ]
        basicRows = specs.map { (label, lo, hi, fmt, key) in
            let r = SliderRow(label: label, min: lo, max: hi, format: fmt)
            r.onChange = { [weak self] v, d in self?.edit(d) { $0[keyPath: key] = Float(v) } }
            add(r, to: basicPage)
            return r
        }
        add(compareBasic, to: basicPage)
    }

    // MARK: 고급

    private func buildAdvanced() {
        wheel.onChange = { [weak self] hue, width, soft, dragging in
            self?.edit(dragging) { $0.hue = hue; $0.width = width; $0.soft = soft }
        }
        let wheelBox = NSView()
        wheel.translatesAutoresizingMaskIntoConstraints = false
        wheelBox.addSubview(wheel)
        NSLayoutConstraint.activate([
            wheel.topAnchor.constraint(equalTo: wheelBox.topAnchor),
            wheel.bottomAnchor.constraint(equalTo: wheelBox.bottomAnchor),
            wheel.centerXAnchor.constraint(equalTo: wheelBox.centerXAnchor),
            wheel.widthAnchor.constraint(equalToConstant: 188),
            wheel.heightAnchor.constraint(equalToConstant: 188),
        ])
        add(wheelBox, to: advancedPage)

        let pick = iconButton("eyedropper.halffull", "사진에서 색을 집어 범위를 더합니다 (최대 35개)", #selector(pickTapped))
        let plus = iconButton("plus", "지금 휠 자리에 범위 더하기", #selector(addTapped))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "고른 범위 지우기")
        removeButton.bezelStyle = .smallSquare
        removeButton.toolTip = "고른 범위 지우기"
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        viewRange.controlSize = .small
        viewRange.target = self
        viewRange.action = #selector(viewRangeChanged)
        let tools = NSStackView(views: [pick, plus, removeButton, NSView()])
        tools.spacing = 4
        add(tools, to: advancedPage)

        let specs: [(String, Double, Double, String, Double, WritableKeyPath<ColorRange, Float>)] = [
            ("부드러움", 0, 1, "%.0f", 100, \.soft), ("색조", -30, 30, "%+.0f°", 1, \.dHue),
            ("채도", -100, 100, "%+.0f", 1, \.dSat), ("밝기", -100, 100, "%+.0f", 1, \.dLight),
        ]
        advancedRows = specs.map { (label, lo, hi, fmt, disp, key) in
            let r = SliderRow(label: label, min: lo, max: hi, format: fmt, display: disp, defaultValue: key == \ColorRange.soft ? 0.6 : 0)
            r.onChange = { [weak self] v, d in self?.edit(d) { $0[keyPath: key] = Float(v) } }
            add(r, to: advancedPage)
            return r
        }
        add(viewRange, to: advancedPage)
        add(compareAdvanced, to: advancedPage)
        let title = NSTextField(labelWithString: "조정 목록")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        add(title, to: advancedPage)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        add(list, to: advancedPage)
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .smallSquare
        b.toolTip = tip
        return b
    }

    // MARK: 스킨 톤

    private func buildSkin() {
        skinSwatch.wantsLayer = true
        skinSwatch.layer?.cornerRadius = 5
        skinSwatch.widthAnchor.constraint(equalToConstant: 36).isActive = true
        skinSwatch.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let pick = NSButton(title: "피부색 집기", image: NSImage(systemSymbolName: "eyedropper.halffull", accessibilityDescription: nil)!,
                            target: self, action: #selector(skinPickTapped))
        pick.bezelStyle = .appPush
        pick.controlSize = .small
        skinOn.controlSize = .small
        skinOn.target = self
        skinOn.action = #selector(skinOnChanged)
        let top = NSStackView(views: [skinSwatch, pick, NSView(), skinOn])
        top.spacing = 8
        add(top, to: skinPage)
        let specs: [(String, Double, Double, WritableKeyPath<SkinTone, Float>)] = [
            ("색조 균일", 0, 100, \.hueAmount), ("채도 균일", 0, 100, \.satAmount), ("밝기 균일", 0, 100, \.lightAmount),
            ("범위 넓이", 10, 90, \.width),
        ]
        skinRows = specs.map { (label, lo, hi, key) in
            let r = SliderRow(label: label, min: lo, max: hi, format: "%.0f", defaultValue: key == \SkinTone.width ? 40 : 0)
            r.onChange = { [weak self] v, d in
                guard let self else { return }
                self.settings.color.skin[keyPath: key] = Float(v)
                self.onChange?(self.settings, d)
            }
            add(r, to: skinPage)
            return r
        }
        let hint = NSTextField(wrappingLabelWithString: "피부색을 집으면 그 색 쪽으로 색조·채도·밝기의 흩어짐을 모읍니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        add(hint, to: skinPage)
    }

    // MARK: 동작

    @objc private func tabChanged() {
        let t = max(tabs.selectedSegment, 0)
        UserDefaults.standard.set(t, forKey: "colorEditorTab")
        basicPage.isHidden = t != 0
        advancedPage.isHidden = t != 1
        skinPage.isHidden = t != 2
        // 탭에 맞는 범위를 고른다
        if t == 0, index >= basicCount { index = 0 }
        if t == 1, index < basicCount, ranges.count > basicCount { index = basicCount }
        if t != 1, viewRange.state == .on { viewRange.state = .off; onViewRange?(nil) }
        refresh()
    }

    func showTab(_ t: Int) { tabs.selectedSegment = t; tabChanged() }

    func select(_ i: Int) {
        guard ranges.indices.contains(i) else { return }
        index = i
        if i >= basicCount, tabs.selectedSegment != 1 { tabs.selectedSegment = 1; tabChanged(); return }
        refresh()
    }

    @objc private func pickTapped() { onPick?(0) }
    @objc private func skinPickTapped() { onPick?(1) }

    @objc private func addTapped() {
        guard ranges.count < basicCount + 35 else { NSSound.beep(); return }
        let hue = ranges.indices.contains(index) ? ranges[index].hue : 0
        settings.color.editor.append(ColorRange(name: "범위 \(ranges.count - basicCount + 1)", hue: hue, width: 30))
        index = ranges.count - 1
        onChange?(settings, false)
        refresh()
    }

    @objc private func removeTapped() {
        guard index >= basicCount, ranges.indices.contains(index) else { NSSound.beep(); return }
        settings.color.editor.remove(at: index)
        index = ranges.count > basicCount ? min(index, ranges.count - 1) : 0
        onChange?(settings, false)
        refresh()
    }

    @objc private func viewRangeChanged() { refreshDecor() }

    @objc private func skinOnChanged() {
        settings.color.skin.enabled = skinOn.state == .on
        onChange?(settings, false)
    }

    // MARK: 화면 맞추기

    func sync(_ s: DevelopSettings, doc: RawDocument?) {
        settings = s
        if doc !== self.doc {
            self.doc = doc
            histogram.bins = []
            // 색조 분포는 뒤에서 잰다 (주 스레드에서 재면 사진을 열 때마다 1초 넘게 멈췄다)
            measureGeneration += 1
            let gen = measureGeneration
            if doc != nil {
                // 사진을 빨리 넘기면 재지 않는다 (0.8초 머문 뒤에만)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, gen == self.measureGeneration, let doc = self.doc else { return }
                    let img = doc.analysisImage()
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        BackgroundGate.waitQuiet()
                        guard let s = self, gen == s.measureGeneration else { return }
                        let bins = HueHistogramView.measure(img)
                        DispatchQueue.main.async {
                            guard let self, gen == self.measureGeneration else { return }
                            self.histogram.bins = bins
                        }
                    }
                }
            }
        }
        index = min(index, max(ranges.count - 1, 0))
        refresh()
    }

    private func refresh() {
        guard ranges.indices.contains(index) else { return }
        let r = ranges[index]
        for (row, v) in zip(basicRows, [r.dHue, r.dSat, r.dLight]) { row.value = Double(v) }
        for (row, v) in zip(advancedRows, [r.soft, r.dHue, r.dSat, r.dLight]) { row.value = Double(v) }
        let sk = settings.color.skin
        for (row, v) in zip(skinRows, [sk.hueAmount, sk.satAmount, sk.lightAmount, sk.width]) { row.value = Double(v) }
        skinOn.state = sk.enabled ? .on : .off
        skinSwatch.layer?.backgroundColor = NSColor(hue: CGFloat(sk.hue / 360), saturation: CGFloat(sk.sat),
                                                   brightness: CGFloat(sk.light), alpha: 1).cgColor
        removeButton.isEnabled = index >= basicCount
        rebuildList()
        refreshDecor()
    }

    /// 트랙 색, 휠, 전·후 칸, 범위 보기처럼 값에 따라 모양만 바뀌는 것
    private func refreshDecor() {
        guard ranges.indices.contains(index) else { return }
        let r = ranges[index]
        histogram.selected = index < basicCount ? index : -1
        histogram.ranges = ranges
        let base = NSColor(hue: CGFloat(r.hue / 360), saturation: 0.8, brightness: 0.9, alpha: 1)
        let hueTrack = stride(from: -30.0, through: 30.0, by: 10).map {
            NSColor(hue: CGFloat(((Double(r.hue) + $0) / 360 + 1).truncatingRemainder(dividingBy: 1)), saturation: 0.8, brightness: 0.9, alpha: 1)
        }
        let satTrack = [NSColor(white: 0.5, alpha: 1), base]
        let lightTrack = [NSColor(white: 0.12, alpha: 1), base, NSColor(white: 0.95, alpha: 1)]
        for (row, c) in zip(basicRows, [hueTrack, satTrack, lightTrack]) { row.slider.trackColors = c }
        for (row, c) in zip(advancedRows, [nil, hueTrack, satTrack, lightTrack]) { row.slider.trackColors = c }
        wheel.set(hue: r.hue, width: r.width, soft: r.soft, others: ranges.enumerated().filter { $0.offset >= basicCount && $0.offset != index }.map(\.element.hue))
        compareBasic.show(r)
        compareAdvanced.show(r)
        for (i, row) in list.arrangedSubviews.enumerated() {
            (row as? RangeListRow)?.update(ranges.indices.contains(i + basicCount) ? ranges[i + basicCount] : nil, selected: i + basicCount == index)
        }
        onViewRange?(viewRange.state == .on && tabs.selectedSegment == 1 ? r : nil)
    }

    private func rebuildList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let adv = Array(ranges.enumerated()).filter { $0.offset >= basicCount }
        if adv.isEmpty {
            let hint = NSTextField(wrappingLabelWithString: "스포이트나 +로 범위를 더하면 여기에 쌓입니다.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .tertiaryLabelColor
            list.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return
        }
        for (i, r) in adv {
            let row = RangeListRow()
            row.update(r, selected: i == index)
            row.onClick = { [weak self] in self?.select(i) }
            row.onToggle = { [weak self] on in
                guard let self, self.settings.color.editor.indices.contains(i) else { return }
                self.settings.color.editor[i].off = on ? nil : true
                self.onChange?(self.settings, false)
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

// MARK: - 조정 목록 한 줄

/// [체크] [색 점] ΔH ΔS ΔL
final class RangeListRow: NSView {
    var onClick: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dot = NSView()
    private let text = NSTextField(labelWithString: "")
    private var selected = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        check.controlSize = .small
        check.target = self
        check.action = #selector(toggled)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = NSStackView(views: [check, dot, text])
        h.spacing = 6
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            h.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            h.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ r: ColorRange?, selected: Bool) {
        guard let r else { return }
        self.selected = selected
        check.state = r.off == true ? .off : .on
        dot.layer?.backgroundColor = NSColor(hue: CGFloat(r.hue / 360), saturation: 0.8, brightness: 0.9, alpha: 1).cgColor
        text.stringValue = String(format: "ΔH %+.0f  ΔS %+.0f  ΔL %+.0f", r.dHue, r.dSat, r.dLight)
        text.textColor = r.off == true ? .tertiaryLabelColor : .labelColor
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : NSColor.clear.cgColor
    }

    @objc private func toggled() { onToggle?(check.state == .on) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - 전·후 색 칸

/// 고른 범위의 가운데 색이 조정 전·후에 어떻게 되는지 (RGB·HSL 숫자와 함께)
final class BeforeAfterView: NSView {
    private let before = NSView(), after = NSView()
    private let beforeText = NSTextField(labelWithString: ""), afterText = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        var cols: [NSView] = []
        for (title, box, label) in [("전", before, beforeText), ("후", after, afterText)] {
            box.wantsLayer = true
            box.layer?.cornerRadius = 4
            box.heightAnchor.constraint(equalToConstant: 26).isActive = true
            label.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 2
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 10, weight: .semibold)
            t.textColor = .tertiaryLabelColor
            let v = NSStackView(views: [t, box, label])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 3
            box.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
            cols.append(v)
        }
        let h = NSStackView(views: cols)
        h.distribution = .fillEqually
        h.spacing = 10
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 엔진(ColorLUT)과 같은 식으로 가운데 색을 옮겨 본다
    func show(_ r: ColorRange) {
        let s0: Float = 0.7, v0: Float = 0.8
        let h1 = r.hue + (r.off == true ? 0 : r.dHue)
        let s1 = r.off == true ? s0 : min(max(s0 * (1 + r.dSat / 100), 0), 1)
        let v1 = r.off == true ? v0 : max(v0 * (1 + r.dLight / 100 * 0.6), 0)
        for (box, label, h, s, v) in [(before, beforeText, r.hue, s0, v0), (after, afterText, h1, s1, min(v1, 1))] {
            let c = NSColor(hue: CGFloat((h / 360).truncatingRemainder(dividingBy: 1) + (h < 0 ? 1 : 0)), saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
            box.layer?.backgroundColor = c.cgColor
            let rgb = c.usingColorSpace(.sRGB) ?? c
            // HSL (L = V(1 - S/2))
            let l = v * (1 - s / 2)
            let sl: Float = (l == 0 || l == 1) ? 0 : (v - l) / min(l, 1 - l)
            let hh = Int(((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360))
            label.stringValue = String(format: "RGB %d %d %d\nHSL %d° %d%% %d%%",
                                       Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255),
                                       hh, Int(sl * 100), Int(l * 100))
        }
    }
}

// MARK: - 색조 분포 그래프 + 여덟 색 칸

final class HueHistogramView: NSView {
    /// 색조 90칸 (4°씩), 채도로 무게를 준 분포
    var bins: [Float] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var ranges: [ColorRange] = ColorRange.basic { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?

    private var graph: NSRect { NSRect(x: 0, y: 26, width: bounds.width, height: bounds.height - 26) }
    private var strip: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: 20) }

    /// 사진 작게 → 색조 분포
    static func measure(_ doc: RawDocument) -> [Float] { measure(doc.image(scale: Develop.guideScale)) }

    /// 그림 → 색조 분포 (뒤 스레드에서 불러도 된다)
    static func measure(_ img: CIImage) -> [Float] {
        let k = 128 / max(img.extent.width, img.extent.height, 1)
        let small = img.transformed(by: .init(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 2, h > 2 else { return [] }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var bins = [Float](repeating: 0, count: 90)
        for i in 0..<(w * h) {
            let c = SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]).clamped(lowerBound: .zero, upperBound: .one)
            let (hue, sat, _) = ColorLUT.hsv(c)
            guard sat > 0.06 else { continue }
            bins[min(Int(hue / 4), 89)] += sat
        }
        return bins
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = graph
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: g, xRadius: 6, yRadius: 6).fill()
        // 격자
        NSColor.white.withAlphaComponent(0.06).setStroke()
        for i in 1..<4 {
            let x = g.minX + g.width * CGFloat(i) / 4
            let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: g.minY)); p.line(to: NSPoint(x: x, y: g.maxY)); p.lineWidth = 0.5; p.stroke()
        }
        if let top = bins.max(), top > 0 {
            let bw = g.width / CGFloat(bins.count)
            for (i, v) in bins.enumerated() where v > 0 {
                let hgt = (g.height - 8) * CGFloat(sqrt(v / top))
                NSColor(hue: CGFloat(i) / CGFloat(bins.count), saturation: 0.75, brightness: 0.85, alpha: 0.9).setFill()
                NSRect(x: g.minX + CGFloat(i) * bw, y: g.minY + 2, width: max(bw - 0.5, 1), height: hgt).fill()
            }
        }
        // 고른 범위 표시 (그래프 위 얇은 띠)
        if ranges.indices.contains(selected) {
            let r = ranges[selected]
            let x0 = CGFloat((r.hue - r.width / 2) / 360), x1 = CGFloat((r.hue + r.width / 2) / 360)
            NSColor.white.withAlphaComponent(0.12).setFill()
            for (a, b) in wrap(x0, x1) { NSRect(x: g.minX + a * g.width, y: g.minY, width: (b - a) * g.width, height: g.height).fill() }
        }
        // 여덟 색 칸
        let n = ColorRange.basic.count
        let cw = strip.width / CGFloat(n)
        let bg = NSBezierPath(roundedRect: strip, xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.07).setFill(); bg.fill()
        for i in 0..<n {
            let cell = NSRect(x: strip.minX + CGFloat(i) * cw, y: strip.minY, width: cw, height: strip.height)
            if i == selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            let r = ranges.indices.contains(i) ? ranges[i] : ColorRange.basic[i]
            let d: CGFloat = 10
            let sq = NSRect(x: cell.midX - d / 2, y: cell.midY - d / 2, width: d, height: d)
            NSColor(hue: CGFloat(r.hue / 360), saturation: 0.85, brightness: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: sq, xRadius: 2, yRadius: 2).fill()
            if !r.isNeutral {
                // 바꾼 색은 아래 작은 점
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: cell.midX - 1.5, y: cell.minY + 1, width: 3, height: 3)).fill()
            }
        }
    }

    private func wrap(_ a: CGFloat, _ b: CGFloat) -> [(CGFloat, CGFloat)] {
        if a < 0 { return [(0, b), (1 + a, 1)] }
        if b > 1 { return [(a, 1), (0, b - 1)] }
        return [(a, b)]
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let n = ColorRange.basic.count
        if strip.insetBy(dx: 0, dy: -4).contains(p) {
            onPick?(min(max(Int((p.x - strip.minX) / (strip.width / CGFloat(n))), 0), n - 1))
        } else if graph.contains(p) {
            // 그래프를 누르면 가장 가까운 기본 색
            let hue = Float((p.x - graph.minX) / graph.width * 360)
            let best = ColorRange.basic.enumerated().min { a, b in
                func d(_ h: Float) -> Float { let x = abs(h - hue).truncatingRemainder(dividingBy: 360); return min(x, 360 - x) }
                return d(a.element.hue) < d(b.element.hue)
            }
            if let best { onPick?(best.offset) }
        }
    }
}

// MARK: - 큰 색조 휠 (고급)

/// 바깥 고리가 색조. 고른 범위는 부채꼴로 보이고, 가운데 손잡이를 끌면 색조, 양쪽 손잡이를 끌면 넓이,
/// 바깥 눈금(부드러움 끝)을 끌면 부드러움이 바뀐다.
final class HueRangeWheel: NSView {
    /// (색조, 넓이, 부드러움, 끄는 중인지)
    var onChange: ((Float, Float, Float, Bool) -> Void)?
    private var hue: Float = 0, width: Float = 45, soft: Float = 0.6
    private var others: [Float] = []
    private static var ring: CGImage? = makeRing(size: 360)

    func set(hue: Float, width: Float, soft: Float, others: [Float]) {
        self.hue = hue; self.width = width; self.soft = soft; self.others = others
        needsDisplay = true
    }

    private var outerR: CGFloat { min(bounds.width, bounds.height) / 2 - 12 }
    private var innerR: CGFloat { outerR * 0.62 }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    /// 색조 → 화면 각도 (빨강이 위, 색 균형 휠과 같다)
    private func angle(_ h: Float) -> CGFloat { (CGFloat(h) + ColorWheelView.hueOffset) * .pi / 180 }
    private func point(_ h: Float, _ r: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(angle(h)) * r, y: center.y + sin(angle(h)) * r)
    }
    private var softEdge: Float { width / 2 + max(width * soft, 1) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let ring = Self.ring else { return }
        let rect = NSRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2)
        // 고리
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.addEllipse(in: rect.insetBy(dx: outerR - innerR, dy: outerR - innerR))
        ctx.clip(using: .evenOdd)
        ctx.draw(ring, in: rect)
        ctx.restoreGState()
        // 가운데 어두운 원
        NSColor(white: 0.14, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: outerR - innerR + 1, dy: outerR - innerR + 1)).fill()

        // 범위 부채꼴: 부드러움 끝까지는 옅게, 넓이 안은 진하게
        func wedge(_ from: Float, _ to: Float, alpha: CGFloat) {
            let p = NSBezierPath()
            p.move(to: center)
            p.appendArc(withCenter: center, radius: outerR + 4, startAngle: angle(from) * 180 / .pi, endAngle: angle(to) * 180 / .pi)
            p.close()
            NSColor.white.withAlphaComponent(alpha).setFill()
            p.fill()
        }
        wedge(hue - softEdge, hue + softEdge, alpha: 0.10)
        wedge(hue - width / 2, hue + width / 2, alpha: 0.20)
        // 테두리 선
        NSColor.white.withAlphaComponent(0.8).setStroke()
        for h in [hue - width / 2, hue + width / 2] {
            let l = NSBezierPath(); l.move(to: point(h, innerR * 0.35)); l.line(to: point(h, outerR + 4)); l.lineWidth = 1.2; l.stroke()
        }
        // 바깥 눈금 셋: 가운데, 부드러움 양 끝
        for h in [hue - softEdge, hue, hue + softEdge] {
            let t = NSBezierPath(); t.move(to: point(h, outerR + 3)); t.line(to: point(h, outerR + 10))
            NSColor.white.withAlphaComponent(0.85).setStroke(); t.lineWidth = 2; t.stroke()
        }
        // 다른 범위는 고리 위 작은 점
        for h in others {
            let p = point(h, (innerR + outerR) / 2)
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let o = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)); o.lineWidth = 1; o.stroke()
        }
        // 손잡이: 가운데(색조), 양쪽(넓이)
        knob(point(hue, (innerR + outerR) / 2), 7)
        knob(point(hue - width / 2, innerR * 0.8), 5)
        knob(point(hue + width / 2, innerR * 0.8), 5)
    }

    private func knob(_ p: NSPoint, _ r: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 2; sh.shadowColor = NSColor.black.withAlphaComponent(0.6); sh.set()
        NSColor(white: 0.9, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private enum Part { case hue, left, right, soft }
    private var part: Part = .hue
    private var grabOffset: Float = 0

    private func hueAt(_ p: NSPoint) -> Float {
        var h = Float(atan2(p.y - center.y, p.x - center.x) * 180 / .pi - ColorWheelView.hueOffset)
        while h < 0 { h += 360 }
        return h.truncatingRemainder(dividingBy: 360)
    }

    private func diff(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dist = hypot(p.x - center.x, p.y - center.y)
        let h = hueAt(p)
        let d = diff(h, hue)
        if dist > outerR + 1 && abs(abs(d) - softEdge) < 10 {
            part = .soft
        } else if abs(abs(d) - width / 2) < 6 && dist < outerR {
            part = d < 0 ? .left : .right
        } else {
            part = .hue
            grabOffset = abs(d) < width / 2 ? d : 0   // 부채꼴 안을 잡으면 잡은 자리 그대로 돌린다
        }
        if event.clickCount == 2 { soft = 0.6; width = 45; onChange?(hue, width, soft, false); needsDisplay = true; return }
        drag(p, dragging: true)
    }

    override func mouseDragged(with event: NSEvent) { drag(convert(event.locationInWindow, from: nil), dragging: true) }
    override func mouseUp(with event: NSEvent) { onChange?(hue, width, soft, false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func drag(_ p: NSPoint, dragging: Bool) {
        let h = hueAt(p)
        switch part {
        case .hue:
            var n = h - grabOffset
            while n < 0 { n += 360 }
            hue = n.truncatingRemainder(dividingBy: 360)
        case .left, .right:
            width = min(max(abs(diff(h, hue)) * 2, 6), 180)
        case .soft:
            let edge = abs(diff(h, hue))
            soft = min(max((edge - width / 2) / max(width, 1), 0), 1)
        }
        needsDisplay = true
        onChange?(hue, width, soft, dragging)
    }

    private static func makeRing(size n: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Double(x) + 0.5) / Double(n) * 2 - 1
                let dy = 1 - (Double(y) + 0.5) / Double(n) * 2
                var h = atan2(dy, dx) * 180 / .pi - Double(ColorWheelView.hueOffset)
                while h < 0 { h += 360 }
                let r = hypot(dx, dy)
                // 안쪽은 흐리게, 바깥은 선명하게
                let c = NSColor(hue: h.truncatingRemainder(dividingBy: 360) / 360, saturation: 0.35 + 0.5 * min(r, 1), brightness: 0.8, alpha: 1)
                let i = (y * n + x) * 4
                px[i] = UInt8(c.redComponent * 255); px[i + 1] = UInt8(c.greenComponent * 255)
                px[i + 2] = UInt8(c.blueComponent * 255); px[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - 선택한 색 범위 보기 (캔버스)

enum RangeView {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 rangeView(__sample s, float hue, float inner, float outer) {
        vec3 c = clamp(s.rgb, 0.0, 1.0);
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float d = mx - mn;
        float h = 0.0;
        if (d > 0.00001) {
            if (mx == c.r) { h = mod((c.g - c.b) / d, 6.0); }
            else if (mx == c.g) { h = (c.b - c.r) / d + 2.0; }
            else { h = (c.r - c.g) / d + 4.0; }
            h = h * 60.0;
            if (h < 0.0) { h = h + 360.0; }
        }
        float sat = mx > 0.0 ? d / mx : 0.0;
        float dd = mod(abs(h - hue), 360.0);
        if (dd > 180.0) { dd = 360.0 - dd; }
        float hw = dd <= inner ? 1.0 : (dd >= outer ? 0.0 : 1.0 - (dd - inner) / (outer - inner));
        float t = clamp((sat - 0.03) / 0.12, 0.0, 1.0);
        float w = hw * hw * (3.0 - 2.0 * hw) * t * t * (3.0 - 2.0 * t);
        float g = dot(c, vec3(0.299, 0.587, 0.114)) * 0.45 + 0.08;
        return vec4(mix(vec3(g), c, w), s.a);
    }
    """)

    /// 범위 밖을 어두운 회색으로 (화면 sRGB 값에서 재고 다시 작업 공간으로)
    static func apply(_ img: CIImage, _ r: ColorRange) -> CIImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let k = kernel, let inS = img.matchedFromWorkingSpace(to: srgb) else { return img }
        let inner = r.width / 2, outer = inner + max(r.width * r.soft, 1)
        guard let out = k.apply(extent: img.extent, arguments: [inS, r.hue, inner, outer]) else { return img }
        return out.matchedToWorkingSpace(from: srgb) ?? img
    }
}
