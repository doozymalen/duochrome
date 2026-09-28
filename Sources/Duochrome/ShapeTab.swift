import AppKit

extension DevelopSettings {
    /// 조정 탭이 다루지 않는 값(형태·리터칭·레이어)을 `other`에서 가져온다.
    /// 조정 탭은 자기 값을 따로 들고 있어서, 이걸 안 하면 슬라이더 하나 움직일 때 리터칭 점과 레이어가 옛 값으로 돌아간다.
    mutating func adoptNonAdjust(from other: DevelopSettings) {
        adoptGeometry(from: other)
        spots = other.spots
        layers = other.layers
    }

    /// 형태 탭이 다루는 값만 `other`에서 가져온다. 두 패널이 서로 값을 덮어쓰지 않게 할 때 쓴다.
    mutating func adoptGeometry(from other: DevelopSettings) {
        quarterTurns = other.quarterTurns; flipH = other.flipH; flipV = other.flipV
        rotation = other.rotation; keystoneV = other.keystoneV; keystoneH = other.keystoneH
        keystoneAspect = other.keystoneAspect; crop = other.crop; cropAspect = other.cropAspect
    }
}

/// "형태" 탭: 회전·뒤집기, 크롭 비율, 키스톤. 크롭과 수평 맞추기는 커서 도구로 캔버스에서 한다.
final class ShapeTabController: NSViewController {
    /// 지금 사진의 값 (한 곳에서만 들고 있게 문서에서 읽는다).
    var current: (() -> DevelopSettings?)?
    var onChange: ((DevelopSettings, Bool) -> Void)?
    var nativeSize: CGSize = .zero

    private let angle = SliderRow(label: "각도", min: -45, max: 45, format: "%+.1f°")
    private let kV = SliderRow(label: "세로", min: -100, max: 100, format: "%+.0f")
    private let kH = SliderRow(label: "가로", min: -100, max: 100, format: "%+.0f")
    private let kA = SliderRow(label: "비율", min: -100, max: 100, format: "%+.0f")
    private let aspect = NSPopUpButton()
    private let keyMode = NSPopUpButton()
    /// 선 긋기 방식이 바뀜 / 자동 키스톤 누름
    var onKeystoneMode: ((Geometry.KeystoneMode) -> Void)?
    var onAutoKeystone: ((Geometry.KeystoneMode) -> Void)?
    var keystoneMode: Geometry.KeystoneMode { Geometry.KeystoneMode(rawValue: keyMode.indexOfSelectedItem) ?? .vertical }
    private let sizeLabel = NSTextField(labelWithString: "")

    static let aspects: [(String, Float)] = [
        ("자유", 0), ("원본", -1), ("1:1", 1), ("4:5", 4.0 / 5), ("5:4", 5.0 / 4),
        ("2:3", 2.0 / 3), ("3:2", 3.0 / 2), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9),
    ]

    override func loadView() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rotate = Card(title: "회전과 뒤집기")
        let turns = NSStackView(views: [
            iconButton("rotate.left", "왼쪽으로 90°", #selector(rotateLeft)),
            iconButton("rotate.right", "오른쪽으로 90°", #selector(rotateRight)),
            iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "좌우 뒤집기", #selector(flipH)),
            iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "상하 뒤집기", #selector(flipV)),
        ])
        turns.spacing = 6
        add(angle, to: rotate)
        rotate.body.addArrangedSubview(turns)
        angle.onChange = { [weak self] v, d in self?.change(d) { $0.rotation = Float(v) } }

        let crop = Card(title: "크롭")
        for (name, _) in Self.aspects { aspect.addItem(withTitle: name) }
        aspect.target = self
        aspect.action = #selector(aspectChanged)
        aspect.controlSize = .small
        let reset = NSButton(title: "크롭 초기화", target: self, action: #selector(resetCrop))
        reset.controlSize = .small
        reset.bezelStyle = .appPush
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        let aspectRow = NSStackView(views: [label("비율"), aspect, NSView(), reset])
        crop.body.addArrangedSubview(aspectRow)
        aspectRow.widthAnchor.constraint(equalTo: crop.body.widthAnchor).isActive = true
        crop.body.addArrangedSubview(sizeLabel)
        let hint = NSTextField(wrappingLabelWithString: "크롭 영역은 위 커서 도구의 크롭(C)으로 사진 위에서 조절합니다. 수평 도구(L)로 기울어진 선을 따라 그으면 각도가 맞춰집니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        crop.body.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: crop.body.widthAnchor).isActive = true

        let key = Card(title: "키스톤")
        for r in [kV, kH, kA] { add(r, to: key) }
        for m in Geometry.KeystoneMode.allCases { keyMode.addItem(withTitle: m.title) }
        keyMode.controlSize = .small
        keyMode.target = self
        keyMode.action = #selector(keyModeChanged)
        let auto = NSButton(title: "자동", target: self, action: #selector(autoKeystone))
        auto.controlSize = .small
        auto.bezelStyle = .appPush
        auto.toolTip = "사진 속 곧은 선을 찾아 맞춥니다"
        let modeRow = NSStackView(views: [label("방식"), keyMode, NSView(), auto])
        key.body.addArrangedSubview(modeRow)
        modeRow.widthAnchor.constraint(equalTo: key.body.widthAnchor).isActive = true
        let keyHint = NSTextField(wrappingLabelWithString: "키스톤 도구(K)로 곧아야 할 선을 따라 그으면 맞춰집니다. 전체는 세로 둘, 가로 둘을 차례로 긋습니다.")
        keyHint.font = .systemFont(ofSize: 11)
        keyHint.textColor = .tertiaryLabelColor
        key.body.addArrangedSubview(keyHint)
        keyHint.widthAnchor.constraint(equalTo: key.body.widthAnchor).isActive = true
        kV.onChange = { [weak self] v, d in self?.change(d) { $0.keystoneV = Float(v) } }
        kH.onChange = { [weak self] v, d in self?.change(d) { $0.keystoneH = Float(v) } }
        kA.onChange = { [weak self] v, d in self?.change(d) { $0.keystoneAspect = Float(v) } }

        for (card, reset) in [(rotate, { (s: inout DevelopSettings) in s.rotation = 0; s.quarterTurns = 0; s.flipH = 0; s.flipV = 0 }),
                              (crop, { (s: inout DevelopSettings) in s.crop = CropRect(); s.cropAspect = 0 }),
                              (key, { (s: inout DevelopSettings) in s.keystoneV = 0; s.keystoneH = 0; s.keystoneAspect = 0 })] {
            card.onReset = { [weak self] in self?.change(false, reset) }
            card.hideToggle()
            card.applyCollapse()
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view = scroll
    }

    private func add(_ row: SliderRow, to card: Card) {
        card.body.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
    }

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tip)!
        let b = NSButton(image: image, target: self, action: action)
        b.bezelStyle = .appPush
        b.controlSize = .regular
        b.toolTip = tip
        return b
    }

    /// 값 하나를 바꿔 알린다.
    private func change(_ dragging: Bool, _ edit: (inout DevelopSettings) -> Void) {
        guard var s = current?() else { return }
        edit(&s)
        onChange?(s, dragging)
        if !dragging { sync(s) }
    }

    func sync(_ s: DevelopSettings) {
        angle.value = Double(s.rotation)
        kV.value = Double(s.keystoneV)
        kH.value = Double(s.keystoneH)
        kA.value = Double(s.keystoneAspect)
        let i = Self.aspects.firstIndex { $0.1 == s.cropAspect } ?? 0
        aspect.selectItem(at: i)
        let size = Geometry.croppedSize(s, native: nativeSize)
        sizeLabel.stringValue = nativeSize == .zero ? "" : "\(Int(size.width)) × \(Int(size.height)) 픽셀"
    }

    @objc private func rotateLeft() { change(false) { $0.quarterTurns = Float((Int($0.quarterTurns) + 3) % 4); $0.crop = CropRect() } }
    @objc private func rotateRight() { change(false) { $0.quarterTurns = Float((Int($0.quarterTurns) + 1) % 4); $0.crop = CropRect() } }
    @objc private func flipH() { change(false) { $0.flipH = $0.flipH == 0 ? 1 : 0 } }
    @objc private func flipV() { change(false) { $0.flipV = $0.flipV == 0 ? 1 : 0 } }
    @objc private func keyModeChanged() { onKeystoneMode?(keystoneMode) }
    @objc private func autoKeystone() { onAutoKeystone?(keystoneMode) }
    func selectKeystoneMode(_ m: Geometry.KeystoneMode) { keyMode.selectItem(at: m.rawValue); onKeystoneMode?(m) }

    @objc private func resetCrop() { change(false) { $0.crop = CropRect(); $0.cropAspect = 0 } }

    @objc private func aspectChanged() {
        var ratio = Self.aspects[aspect.indexOfSelectedItem].1
        let native = nativeSize
        change(false) { s in
            let frame = Geometry.frameSize(s, native: native)
            if ratio < 0 { ratio = Float(frame.width / frame.height) }
            s.cropAspect = ratio
            if ratio > 0 { s.crop = Self.fit(s.crop, aspect: CGFloat(ratio), frame: frame) }
        }
    }

    /// 지금 크롭 안에 들어가는 가장 큰 비율 고정 사각형 (가운데 기준).
    static func fit(_ c: CropRect, aspect: CGFloat, frame: CGSize) -> CropRect {
        let r = c.cg
        let wPx = r.width * frame.width, hPx = r.height * frame.height
        var w = wPx, h = wPx / aspect
        if h > hPx { h = hPx; w = hPx * aspect }
        let nw = w / frame.width, nh = h / frame.height
        return CropRect(CGRect(x: r.midX - nw / 2, y: r.midY - nh / 2, width: nw, height: nh))
    }
}

// MARK: - 캔버스 위 크롭·수평 도구

/// 캔버스 위에 겹치는 투명한 뷰. 크롭 영역과 손잡이, 수평선을 그리고 끌기를 받는다.
final class CropOverlayView: NSView {
    enum Mode { case crop, straighten, keystone }
    var mode: Mode = .crop { didSet { needsDisplay = true } }
    weak var canvas: CanvasView?
    var crop = CropRect() { didSet { needsDisplay = true } }
    var aspect: CGFloat = 0
    var onCrop: ((CropRect, Bool) -> Void)?
    /// 그은 선이 수평(또는 수직)이 되려면 더 돌려야 할 각도(°, 시계 방향이 양수).
    var onStraighten: ((Float) -> Void)?
    /// 선 긋기 키스톤: 세로여야 할 선, 가로여야 할 선 (뷰 좌표).
    var onKeystoneLines: (([(CGPoint, CGPoint)], [(CGPoint, CGPoint)]) -> Void)?
    /// 세로 둘, 가로 둘, 또는 세로 둘 + 가로 둘.
    var keystoneMode: Geometry.KeystoneMode = .vertical { didSet { keystoneLines = []; needsDisplay = true } }
    private var keystoneLines: [(CGPoint, CGPoint)] = []

    private enum Grab { case move, handle(Int) }
    private var grab: Grab?
    private var startCrop = CropRect()
    private var startPoint = CGPoint.zero
    private var lineEnd: CGPoint?

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override var isFlipped: Bool { false }

    private var frameSize: CGSize { canvas?.document?.frameSize ?? .zero }

    /// 크롭 영역을 뷰 좌표로.
    private var cropViewRect: CGRect {
        guard let c = canvas else { return .zero }
        let f = frameSize
        let a = c.viewPoint(forImage: CGPoint(x: crop.x * f.width, y: crop.y * f.height))
        let b = c.viewPoint(forImage: CGPoint(x: (crop.x + crop.w) * f.width, y: (crop.y + crop.h) * f.height))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 손잡이 여덟 개: 0 왼아래, 1 아래, 2 오른아래, 3 오른쪽, 4 오른위, 5 위, 6 왼위, 7 왼쪽.
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard canvas?.document != nil else { return }
        if mode == .keystone {
            NSColor.systemOrange.setStroke()
            var all = keystoneLines
            if let end = lineEnd { all.append((startPoint, end)) }
            for (a, b) in all {
                let p = NSBezierPath()
                p.move(to: a); p.line(to: b)
                p.lineWidth = 2
                p.setLineDash([6, 3], count: 2, phase: 0)
                p.stroke()
            }
            let n = keystoneLines.count, total = keystoneMode.lineCount
            let horizontalNext = keystoneMode == .horizontal || (keystoneMode == .full && n >= 2)
            let hint = "\(horizontalNext ? "가로" : "세로")여야 할 선을 따라 끄세요 (\(n + 1)/\(total))"
            (hint as NSString).draw(at: NSPoint(x: 12, y: bounds.maxY - 24), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.systemOrange])
            return
        }
        if mode == .straighten {
            if let end = lineEnd {
                let p = NSBezierPath()
                p.move(to: startPoint); p.line(to: end)
                p.lineWidth = 2
                NSColor.systemOrange.setStroke()
                p.stroke()
            }
            return
        }
        let r = cropViewRect
        // 크롭 밖을 어둡게.
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: r))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        outside.fill()
        // 삼분할 선.
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for i in 1...2 {
            let t = CGFloat(i) / 3
            let g = NSBezierPath()
            g.move(to: CGPoint(x: r.minX + r.width * t, y: r.minY)); g.line(to: CGPoint(x: r.minX + r.width * t, y: r.maxY))
            g.move(to: CGPoint(x: r.minX, y: r.minY + r.height * t)); g.line(to: CGPoint(x: r.maxX, y: r.minY + r.height * t))
            g.lineWidth = 0.5
            g.stroke()
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1
        border.stroke()
        NSColor.white.setFill()
        for h in handles(r) { NSBezierPath(rect: CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)).fill() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        if mode == .straighten || mode == .keystone { lineEnd = p; return }
        startCrop = crop
        let r = cropViewRect
        if let i = handles(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) {
            grab = .handle(i)
        } else if r.contains(p) {
            grab = .move
        } else {
            grab = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mode == .straighten || mode == .keystone { lineEnd = p; needsDisplay = true; return }
        guard let grab, let c = canvas else { return }
        let f = frameSize
        // 끈 거리를 틀 기준 0~1로.
        let dx = (p.x - startPoint.x) / c.zoom / f.width, dy = (p.y - startPoint.y) / c.zoom / f.height
        var r = startCrop.cg
        switch grab {
        case .move:
            r.origin.x = min(max(r.minX + dx, 0), 1 - r.width)
            r.origin.y = min(max(r.minY + dy, 0), 1 - r.height)
        case .handle(let i):
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            if [0, 6, 7].contains(i) { minX = min(max(minX + dx, 0), maxX - 0.02) }
            if [2, 3, 4].contains(i) { maxX = max(min(maxX + dx, 1), minX + 0.02) }
            if [0, 1, 2].contains(i) { minY = min(max(minY + dy, 0), maxY - 0.02) }
            if [4, 5, 6].contains(i) { maxY = max(min(maxY + dy, 1), minY + 0.02) }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if aspect > 0 { r = constrain(r, handle: i, frame: f) }
        }
        crop = CropRect(r)
        onCrop?(crop, true)
    }

    /// 비율을 지키며 손잡이 반대편을 고정한다. 틀을 넘으면 줄인다.
    private func constrain(_ r: CGRect, handle i: Int, frame f: CGSize) -> CGRect {
        let a = aspect * f.height / f.width   // 0~1 좌표에서의 가로/세로
        var w = r.width, h = r.height
        if [1, 5].contains(i) { w = h * a } else { h = w / a }
        let s0 = startCrop.cg
        var x = [0, 6, 7].contains(i) ? s0.maxX - w : ([1, 5].contains(i) ? s0.midX - w / 2 : s0.minX)
        var y = [0, 1, 2].contains(i) ? s0.maxY - h : ([3, 7].contains(i) ? s0.midY - h / 2 : s0.minY)
        // 틀 밖으로 나가면 비율을 지킨 채 줄인다.
        let over = max(0, -x) + max(0, x + w - 1)
        if over > 0 { let k = (w - over) / w; w *= k; h *= k; x = max(x, 0); x = min(x, 1 - w) }
        let overY = max(0, -y) + max(0, y + h - 1)
        if overY > 0 { let k = (h - overY) / h; w *= k; h *= k; y = max(y, 0); y = min(y, 1 - h) }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .keystone {
            defer { lineEnd = nil; needsDisplay = true }
            guard let end = lineEnd, hypot(end.x - startPoint.x, end.y - startPoint.y) > 30 else { return }
            keystoneLines.append((startPoint, end))
            if keystoneLines.count == keystoneMode.lineCount {
                switch keystoneMode {
                case .vertical: onKeystoneLines?(keystoneLines, [])
                case .horizontal: onKeystoneLines?([], keystoneLines)
                case .full: onKeystoneLines?(Array(keystoneLines[0..<2]), Array(keystoneLines[2..<4]))
                }
                keystoneLines = []
            }
            return
        }
        if mode == .straighten {
            defer { lineEnd = nil; needsDisplay = true }
            guard let end = lineEnd, hypot(end.x - startPoint.x, end.y - startPoint.y) > 20 else { return }
            var deg = atan2(end.y - startPoint.y, end.x - startPoint.x) * 180 / .pi
            // 가장 가까운 수평·수직까지의 차이만 쓴다.
            while deg > 45 { deg -= 90 }
            while deg < -45 { deg += 90 }
            onStraighten?(Float(deg))
            return
        }
        if grab != nil { onCrop?(crop, false) }
        grab = nil
    }
}
