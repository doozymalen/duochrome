import AppKit

/// Paint brush options (brush engine): shared by the layers tab card and the layer-edit tool options panel.
/// Values are saved straight into PaintBrush.current (from the next stroke).
final class PaintOptionsView: NSStackView {
    private let color = NSColorWell()
    private let tip = NSPopUpButton()
    private let dualTip = NSPopUpButton()
    private let texture = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let pressureSize = NSButton(checkboxWithTitle: "압력 → 크기", target: nil, action: nil)
    private let pressureOpacity = NSButton(checkboxWithTitle: "압력 → 흐름", target: nil, action: nil)
    private var rows: [(WritableKeyPath<PaintBrush, Double>, SliderRow)] = []
    private var countRow: SliderRow!
    var onTool: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        mode.addItems(withTitles: ["칠하기 (B)", "지우개", "연필", "혼합 브러시", "픽셀 칠하기"])
        mode.controlSize = .small
        mode.target = self; mode.action = #selector(modeChanged)
        color.target = self; color.action = #selector(changed)
        color.colorWellStyle = .minimal
        color.widthAnchor.constraint(equalToConstant: 38).isActive = true
        color.heightAnchor.constraint(equalToConstant: 22).isActive = true
        add(NSStackView(views: [mode, NSView(), color]))
        let specs: [(String, WritableKeyPath<PaintBrush, Double>, Double, Double, String, Double)] = [
            ("크기 (원본 픽셀)", \.size, 1, 2000, "%.0f", 40), ("경도", \.hardness, 0, 1, "%.2f", 0.8),
            ("불투명도", \.opacity, 0, 1, "%.2f", 1), ("흐름", \.flow, 0.01, 1, "%.2f", 1),
            ("간격 (지름 비율)", \.spacing, 0.01, 2, "%.2f", 0.2), ("크기 흔들림", \.sizeJitter, 0, 1, "%.2f", 0),
            ("각도", \.angle, -180, 180, "%.0f°", 0), ("각도 흔들림", \.angleJitter, 0, 1, "%.2f", 0),
            ("둥글기", \.roundness, 0.05, 1, "%.2f", 1), ("산포", \.scatter, 0, 3, "%.2f", 0),
            ("색조 흔들림", \.hueJitter, 0, 1, "%.2f", 0), ("밝기 흔들림", \.brightnessJitter, 0, 1, "%.2f", 0),
            ("텍스처 깊이", \.textureDepth, 0, 1, "%.2f", 0.5), ("혼합 브러시: 묻히기", \.wet, 0, 1, "%.2f", 0.5),
        ]
        for (title, key, lo, hi, fmt, def) in specs {
            let r = SliderRow(label: title, min: lo, max: hi, format: fmt, defaultValue: def)
            r.onChange = { v, _ in var b = PaintBrush.current; b[keyPath: key] = v; PaintBrush.current = b }
            rows.append((key, r))
            add(r)
        }
        countRow = SliderRow(label: "한 자리에 찍는 수", min: 1, max: 10, format: "%.0f", defaultValue: 1)
        countRow.onChange = { v, _ in var b = PaintBrush.current; b.count = Int(v.rounded()); PaintBrush.current = b }
        add(countRow)
        for c in [pressureSize, pressureOpacity] { c.target = self; c.action = #selector(changed) }
        add(NSStackView(views: [pressureSize, pressureOpacity]))
        for p in [tip, dualTip, texture] { p.controlSize = .small; p.target = self; p.action = #selector(changed); add(p) }
        let hint = NSTextField(wrappingLabelWithString: "⌥를 누르고 칠하면 지웁니다. 붓 끝·텍스처는 파일 → 프리셋 가져오기로 더합니다.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        add(hint)
        NotificationCenter.default.addObserver(forName: PresetFiles.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func reload() {
        let b = PaintBrush.current
        let lib = PresetFiles.library
        mode.selectItem(at: b.mode)
        color.color = NSColor(srgbRed: CGFloat(b.color[0]), green: CGFloat(b.color[1]), blue: CGFloat(b.color[2]), alpha: 1)
        for (k, r) in rows { r.value = b[keyPath: k] }
        countRow.value = Double(b.count)
        pressureSize.state = b.pressureSize ? .on : .off
        pressureOpacity.state = b.pressureOpacity ? .on : .off
        func fill(_ p: NSPopUpButton, _ none: String, _ names: [String], _ files: [String], _ cur: String?) {
            p.removeAllItems(); p.addItem(withTitle: none)
            for (n, f) in zip(names, files) { p.addItem(withTitle: n); p.lastItem?.representedObject = f }
            if let cur, let i = files.firstIndex(of: cur) { p.selectItem(at: i + 1) }
        }
        fill(tip, "붓 끝: 둥근 붓", lib.brushes.map { "붓 끝: \($0.name)" }, lib.brushes.map(\.file), b.tip)
        fill(dualTip, "이중 브러시: 없음", lib.brushes.map { "이중 브러시: \($0.name)" }, lib.brushes.map(\.file), b.dualTip)
        fill(texture, "텍스처: 없음", lib.patterns.map { "텍스처: \($0.name)" }, lib.patterns.map(\.file), b.texture.map { $0.hasPrefix("tex-") ? String($0.dropFirst(4)) : $0 })
    }

    @objc private func modeChanged() {
        var b = PaintBrush.current; b.mode = mode.indexOfSelectedItem; PaintBrush.current = b
        onTool?(b.mode)
    }

    @objc private func changed() {
        var b = PaintBrush.current
        let c = color.color.usingColorSpace(.sRGB) ?? color.color
        b.color = [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
        b.pressureSize = pressureSize.state == .on
        b.pressureOpacity = pressureOpacity.state == .on
        b.tip = tip.selectedItem?.representedObject as? String
        b.dualTip = dualTip.selectedItem?.representedObject as? String
        // Textures copy the pattern image into the layer image folder (so it travels with the document)
        if let f = texture.selectedItem?.representedObject as? String {
            if b.texture == nil || !(b.texture!.hasPrefix("tex-") && b.texture!.contains(f)) {
                let name = "tex-" + f
                if !FileManager.default.fileExists(atPath: LayerImageStore.url(name).path) {
                    try? FileManager.default.copyItem(at: PresetFiles.url(f), to: LayerImageStore.url(name))
                }
                b.texture = name
            }
        } else { b.texture = nil }
        PaintBrush.current = b
    }
}
