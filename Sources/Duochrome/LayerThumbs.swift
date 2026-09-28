import AppKit
import CoreImage

/// 레이어 목록 썸네일: 그 레이어 하나의 내용을 캔버스 비율로 체크무늬 위에,
/// 마스크가 있으면 마스크 썸네일도. 뒤에서 약 100px로 그리고, 레이어가 바뀔 때까지 기억해 둔다.
enum LayerThumbs {
    /// 지금 열린 사진 (창이 사진을 열 때 넣는다)
    static weak var doc: RawDocument?
    /// 썸네일 긴 변 (점). 레티나를 위해 두 배로 그린다.
    static let side: CGFloat = 100

    private static var cache: [String: NSImage] = [:]
    private static var waiting: [String: [(NSImage) -> Void]] = [:]
    private static let queue = DispatchQueue(label: "duochrome.layerthumbs", qos: .utility)

    /// 내용을 그릴 수 있는 레이어 (조정 레이어·그룹은 아이콘)
    static func hasContent(_ l: AdjustLayer) -> Bool {
        l.isImage || l.isText || l.isFill || l.kind == "paint" || l.kind == "shape"
    }

    static func hasMask(_ l: AdjustLayer) -> Bool { l.mask.kind != .full || l.mask.vector != nil }

    /// 캔버스 비율 (가로 / 세로): 형태 보정·크롭 뒤
    static func aspect() -> CGFloat {
        guard let d = doc else { return 1.5 }
        let n = d.nativeSize
        guard n.width > 0, n.height > 0 else { return 1.5 }
        let r = frame(d.settings, native: n, scale: 1)
        return r.height > 0 ? r.width / r.height : n.width / n.height
    }

    private static func shape(_ s: DevelopSettings) -> (CIImage, CGFloat) -> CIImage {
        { m, sc in Geometry.crop(s, Geometry.transform(s, m, scale: sc)) }
    }

    private static func frame(_ s: DevelopSettings, native n: CGSize, scale: CGFloat) -> CGRect {
        let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: n.width * scale, height: n.height * scale))
        return shape(s)(clear, scale).extent
    }

    private static func key(_ kind: String, _ l: AdjustLayer, _ s: DevelopSettings, _ n: CGSize) -> String {
        var solo = l
        solo.name = ""; solo.enabled = true; solo.opacity = 1; solo.blend = "normal"; solo.locked = false
        let data = (try? JSONEncoder().encode(solo)) ?? Data()
        return "\(kind)|\(n.width)x\(n.height)|\(s.geometryKey)|\(data.hashValue)"
    }

    /// 내용 썸네일. 기억해 둔 게 있으면 바로 돌려주고, 없으면 nil을 돌려주고 다 그리면 `done`을 부른다.
    static func content(_ l: AdjustLayer, done: @escaping (NSImage) -> Void) -> NSImage? {
        guard let d = doc, hasContent(l) else { return nil }
        let s = d.settings, n = d.nativeSize, gamma = s.gammaBlend ?? false
        let k = key("c", l, s, n)
        return fetch(k, done: done) {
            var solo = l
            solo.mask = LayerMask(); solo.opacity = 1; solo.blend = "normal"; solo.clipped = false; solo.group = nil
            solo.enabled = true; solo.blendIf = nil
            let sc = side * 2 / max(n.width, n.height)
            let r = frame(s, native: n, scale: sc)
            let clear = CIImage(color: .clear).cropped(to: r)
            let img = Layers.apply([solo], to: clear, guide: clear, scale: sc, guideScale: sc, native: n, shape: shape(s), gamma: gamma)
            return picture(img, rect: r, checker: true)
        }
    }

    /// 마스크 썸네일 (흰 곳이 보인다)
    static func mask(_ l: AdjustLayer, done: @escaping (NSImage) -> Void) -> NSImage? {
        guard let d = doc, hasMask(l) else { return nil }
        let s = d.settings, n = d.nativeSize
        let k = key("m", l, s, n)
        return fetch(k, done: done) {
            let sc = side * 2 / max(n.width, n.height)
            let r = frame(s, native: n, scale: sc)
            // 밝기 범위 마스크는 가운데 회색 기준으로 어림한다 (썸네일용)
            let base = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: r)
            let m = Layers.maskImage(l.mask, scale: sc, native: n, shape: shape(s), base: base)
            let gray = m.applyingFilter("CIColorMatrix", parameters: [
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            return picture(gray.cropped(to: r).composited(over: CIImage(color: .black).cropped(to: r)), rect: r, checker: false)
        }
    }

    private static func fetch(_ k: String, done: @escaping (NSImage) -> Void, make: @escaping () -> NSImage?) -> NSImage? {
        if let hit = cache[k] { return hit }
        if waiting[k] != nil { waiting[k]?.append(done); return nil }
        waiting[k] = [done]
        queue.async {
            let img = make()
            DispatchQueue.main.async {
                let calls = waiting.removeValue(forKey: k) ?? []
                guard let img else { return }
                if cache.count > 400 { cache.removeAll() }
                cache[k] = img
                calls.forEach { $0(img) }
            }
        }
        return nil
    }

    /// 체크무늬 위에 그림을 얹어 NSImage로
    private static func picture(_ img: CIImage, rect r: CGRect, checker: Bool) -> NSImage? {
        guard r.width >= 1, r.height >= 1,
              let cg = Render.context.createCGImage(img, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let size = NSSize(width: r.width, height: r.height)
        return NSImage(size: size, flipped: false) { rect in
            if checker {
                let cell: CGFloat = max(4, rect.height / 6)
                NSColor(white: 0.85, alpha: 1).setFill(); rect.fill()
                NSColor(white: 0.65, alpha: 1).setFill()
                var y: CGFloat = 0, row = 0
                while y < rect.height {
                    var x: CGFloat = row % 2 == 0 ? 0 : cell
                    while x < rect.width { NSRect(x: x, y: y, width: cell, height: cell).fill(); x += cell * 2 }
                    y += cell; row += 1
                }
            }
            NSGraphicsContext.current?.cgContext.draw(cg, in: rect)
            return true
        }
    }
}

/// 레이어 목록 한 줄의 공통 내용: [눈] [내용 썸네일] [사슬 + 마스크 썸네일] [이름 / 종류·불투명도]
final class LayerRowContent: NSStackView {
    var onToggle: ((Bool) -> Void)?
    private let eye = NSButton()
    private var visible: Bool

    /// `thumb`가 nil이면 레이어에서 썸네일을 만든다. 배경 줄은 `thumb`를 준다.
    init(layer: AdjustLayer?, background: NSImage? = nil, name: String, subtitle: String, visible: Bool, toggleable: Bool, selected: Bool) {
        self.visible = visible
        super.init(frame: .zero)
        spacing = 6
        alignment = .centerY
        let h: CGFloat = 32
        let w = (h * LayerThumbs.aspect()).clamped(to: 24...58)

        eye.isBordered = false
        eye.bezelStyle = .regularSquare
        eye.imageScaling = .scaleProportionallyDown
        eye.target = self
        eye.action = #selector(eyeTapped)
        eye.toolTip = "보이기 / 숨기기"
        eye.widthAnchor.constraint(equalToConstant: 18).isActive = true
        eye.heightAnchor.constraint(equalToConstant: 18).isActive = true
        eye.isEnabled = toggleable
        eye.alphaValue = toggleable ? 1 : 0.35
        setEye()
        addArrangedSubview(eye)

        // 내용 썸네일 (또는 아이콘)
        let box = ThumbBox(size: NSSize(width: w, height: h), selected: selected)
        if let background {
            box.image = background
        } else if let layer {
            if LayerThumbs.hasContent(layer) {
                box.image = LayerThumbs.content(layer) { [weak box] img in box?.image = img }
                if box.image == nil { box.symbol = symbol(layer) }
            } else if layer.kind == "copy", let bg = LayerThumbs.backgroundThumb ?? LayerThumbs.backgroundProvider?() {
                box.image = bg
            } else {
                box.symbol = symbol(layer)
            }
        }
        addArrangedSubview(box)

        if let layer, LayerThumbs.hasMask(layer) {
            let chain = NSImageView(image: NSImage(systemSymbolName: "link", accessibilityDescription: "마스크 연결")!)
            chain.contentTintColor = .tertiaryLabelColor
            chain.symbolConfiguration = .init(pointSize: 9, weight: .regular)
            chain.widthAnchor.constraint(equalToConstant: 10).isActive = true
            let mbox = ThumbBox(size: NSSize(width: w, height: h), selected: false)
            mbox.image = LayerThumbs.mask(layer) { [weak mbox] img in mbox?.image = img }
            if mbox.image == nil { mbox.symbol = "circle.lefthalf.filled" }
            mbox.toolTip = "레이어 마스크"
            setCustomSpacing(2, after: box)
            addArrangedSubview(chain)
            setCustomSpacing(2, after: chain)
            addArrangedSubview(mbox)
        }

        let n = NSTextField(labelWithString: name)
        n.font = .systemFont(ofSize: 12, weight: .medium)
        n.textColor = visible ? .labelColor : .tertiaryLabelColor
        n.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sub.textColor = .tertiaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        for t in [n, sub] { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let texts = NSStackView(views: [n, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setCustomSpacing(8, after: arrangedSubviews.last!)
        addArrangedSubview(texts)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setEye() {
        eye.image = NSImage(systemSymbolName: visible ? "eye" : "eye.slash", accessibilityDescription: visible ? "보임" : "숨김")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        eye.contentTintColor = visible ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func eyeTapped() {
        visible.toggle()
        setEye()
        onToggle?(visible)
    }

    private func symbol(_ l: AdjustLayer) -> String {
        if l.isGroup { return "folder.fill" }
        if l.isText { return "textformat" }
        if l.isFill { return l.fillColor.count == 6 ? "square.bottomhalf.filled" : "drop.fill" }
        if l.kind == "copy" { return "square.on.square" }
        if l.isImage { return "photo" }
        return "slider.horizontal.3"
    }

    /// 레이어 종류 한 줄 (종류 · 불투명도 · 칠)
    static func subtitle(_ l: AdjustLayer) -> String {
        var s: String
        if l.isGroup { s = "그룹" }
        else if l.isText { s = "글자" + (l.text.map { " · \(Int($0.size)) px" } ?? "") }
        else if l.isFill { s = l.fillColor.count == 6 ? "그라디언트 칠" : "칠" }
        else if l.kind == "copy" { s = "배경 복사" }
        else if l.kind == "paint" { s = "칠한 레이어" }
        else if l.isImage { s = "이미지" }
        else { s = "조정 레이어" }
        s += " · \(Int((l.opacity * 100).rounded()))%"
        if l.fill < 1 { s += " · 칠 \(Int((l.fill * 100).rounded()))%" }
        if l.clipped { s = "↳ " + s }
        if l.locked { s = "🔒 " + s }
        return s
    }
}

extension LayerThumbs {
    /// 배경(RAW 현상) 썸네일: 배경 복사 레이어에도 쓴다
    static var backgroundThumb: NSImage?
    /// 배경 썸네일을 만드는 곳 (창이 넣는다)
    static var backgroundProvider: (() -> NSImage?)?
}

/// 썸네일 칸: 둥근 모서리, 고른 줄이면 흰 테두리
final class ThumbBox: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var symbol: String? { didSet { needsDisplay = true } }
    private let selected: Bool
    private let size: NSSize

    init(size: NSSize, selected: Bool) {
        self.size = size
        self.selected = selected
        super.init(frame: NSRect(origin: .zero, size: size))
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        if let image {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // 캔버스 비율을 지키며 칸에 맞춘다
            let s = image.size
            let k = min(bounds.width / max(s.width, 1), bounds.height / max(s.height, 1))
            let d = NSRect(x: (bounds.width - s.width * k) / 2, y: (bounds.height - s.height * k) / 2, width: s.width * k, height: s.height * k)
            image.draw(in: d)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.white.withAlphaComponent(0.07).setFill()
            path.fill()
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                let tinted = img.tinted(.secondaryLabelColor)
                let s = tinted.size
                tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            }
        }
        (selected ? NSColor.white.withAlphaComponent(0.9) : NSColor.white.withAlphaComponent(0.15)).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
    }
}

private extension NSImage {
    func tinted(_ c: NSColor) -> NSImage {
        let out = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            c.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return out
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
