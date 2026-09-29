import AppKit
import CoreImage

/// Layer styles (fx): drawn along the alpha of layers with shape (image, fill, text, shape).
/// Distances and sizes in source pixels. Colors are display RGB 0–1.
struct LayerStyles: Equatable, Codable {
    struct Shadow: Equatable, Codable {
        var enabled = false
        var color: [Float] = [0, 0, 0]
        var opacity: Float = 0.6
        var angle: Float = 120          // light direction (°)
        var distance: Float = 15
        var size: Float = 20
        var spread: Float = 0           // 0~100 %
    }
    struct Glow: Equatable, Codable {
        var enabled = false
        var color: [Float] = [1, 0.95, 0.7]
        var opacity: Float = 0.7
        var size: Float = 25
        var spread: Float = 0
    }
    struct Stroke: Equatable, Codable {
        var enabled = false
        var color: [Float] = [1, 1, 1]
        var opacity: Float = 1
        var size: Float = 6
        /// 0 outside, 1 inside, 2 center
        var position = 0
    }
    struct Bevel: Equatable, Codable {
        var enabled = false
        var depth: Float = 100          // %
        var size: Float = 12
        var angle: Float = 120
        var highlight: Float = 0.75
        var shadow: Float = 0.75
    }
    struct Overlay: Equatable, Codable {
        var enabled = false
        var color: [Float] = [1, 0.3, 0.3]
        var color2: [Float] = [0.2, 0.3, 1]
        var opacity: Float = 1
        var angle: Float = 90
        /// Pattern: 0 checker, 1 stripes, 2 clouds, 3 dots
        var pattern = 0
        var scale: Float = 40
    }
    struct Satin: Equatable, Codable {
        var enabled = false
        var color: [Float] = [0, 0, 0]
        var opacity: Float = 0.5
        var angle: Float = 19
        var distance: Float = 11
        var size: Float = 14
    }

    var dropShadow = Shadow()
    var innerShadow = Shadow(opacity: 0.75, distance: 5, size: 5)
    var outerGlow = Glow()
    var innerGlow = Glow(color: [1, 1, 0.75], size: 10)
    var stroke = Stroke()
    var bevel = Bevel()
    var colorOverlay = Overlay()
    var gradientOverlay = Overlay(color: [1, 1, 1], color2: [0, 0, 0])
    var patternOverlay = Overlay(color: [0.9, 0.9, 0.9], color2: [0.6, 0.6, 0.6])
    var satin = Satin()

    var isActive: Bool {
        dropShadow.enabled || innerShadow.enabled || outerGlow.enabled || innerGlow.enabled || stroke.enabled || bevel.enabled
            || colorOverlay.enabled || gradientOverlay.enabled || patternOverlay.enabled || satin.enabled
    }

    // MARK: - Drawing

    /// Applies styles to content (an image with alpha). Result in the original extent.
    static func apply(_ st: LayerStyles, _ content: CIImage, scale: CGFloat) -> CIImage {
        guard st.isActive else { return content }
        let e = content.extent
        let a = alphaGray(content)
        func px(_ v: Float) -> CGFloat { CGFloat(v) * scale }
        func shift(_ m: CIImage, angle: Float, distance: Float, sign: CGFloat = 1) -> CIImage {
            let r = Double(angle) * .pi / 180
            // Shadows fall away from the light
            return m.transformed(by: .init(translationX: -CGFloat(cos(r)) * px(distance) * sign, y: -CGFloat(sin(r)) * px(distance) * sign))
        }
        var under: [CIImage] = [], over: [CIImage] = []

        if st.dropShadow.enabled {
            let d = st.dropShadow
            var m = shift(a, angle: d.angle, distance: d.distance)
            if d.spread > 0 { m = dilate(m, px(d.size * d.spread / 100)) }
            m = soften(m, px(d.size * (1 - d.spread / 100)) / 2)
            under.append(colored(d.color, m, opacity: d.opacity, e))
        }
        if st.outerGlow.enabled {
            let g = st.outerGlow
            var m = a
            if g.spread > 0 { m = dilate(m, px(g.size * g.spread / 100)) }
            m = soften(m, px(g.size * (1 - g.spread / 100)) / 2)
            under.append(colored(g.color, m, opacity: g.opacity, e))
        }
        if st.innerShadow.enabled {
            let d = st.innerShadow
            let outside = invert(soften(shift(a, angle: d.angle, distance: d.distance), px(d.size) / 2))
            over.append(colored(d.color, mul(a, outside), opacity: d.opacity, e))
        }
        if st.innerGlow.enabled {
            let g = st.innerGlow
            let edge = invert(soften(erode(a, px(g.size) / 3), px(g.size) / 2))
            over.append(colored(g.color, mul(a, edge), opacity: g.opacity, e))
        }
        if st.satin.enabled {
            let t = st.satin
            let p = soften(shift(a, angle: t.angle, distance: t.distance), px(t.size) / 2)
            let n = soften(shift(a, angle: t.angle, distance: t.distance, sign: -1), px(t.size) / 2)
            let diff = p.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: n])
            over.append(colored(t.color, mul(a, diff), opacity: t.opacity, e))
        }
        if st.colorOverlay.enabled {
            over.append(colored(st.colorOverlay.color, a, opacity: st.colorOverlay.opacity, e))
        }
        if st.gradientOverlay.enabled {
            let g = st.gradientOverlay
            let r = Double(g.angle) * .pi / 180
            let c = CGPoint(x: e.midX, y: e.midY), h = max(e.width, e.height) / 2
            let grad = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: c.x - CGFloat(cos(r)) * h, y: c.y - CGFloat(sin(r)) * h), "inputColor0": ciColor(g.color2),
                "inputPoint1": CIVector(x: c.x + CGFloat(cos(r)) * h, y: c.y + CGFloat(sin(r)) * h), "inputColor1": ciColor(g.color),
            ])!.outputImage!.cropped(to: e)
            over.append(masked(grad, a, opacity: g.opacity, e))
        }
        if st.patternOverlay.enabled {
            let g = st.patternOverlay
            over.append(masked(pattern(g, e, scale: scale), a, opacity: g.opacity, e))
        }
        if st.bevel.enabled {
            let b = st.bevel
            let height = soften(a, px(b.size) / 2)
            let r = Double(b.angle) * .pi / 180
            // Slope = height toward the light − height away (two points 1/4 of the size apart).
            // Measuring with neighboring pixel differences caused steps due to the blur's internal down/upscaling.
            let d = max(px(b.size) / 4, 1)
            let lx = CGFloat(cos(r)) * d, ly = CGFloat(sin(r)) * d
            // Lit faces = where height rises away from the light: h(p − l) − h(p + l) > 0
            let toward = height.clampedToExtent().transformed(by: .init(translationX: lx, y: ly)).cropped(to: e)
            let away = height.clampedToExtent().transformed(by: .init(translationX: -lx, y: -ly)).cropped(to: e)
            let k = CGFloat(b.depth / 100) * 2
            let negAway = away.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let posToward = toward.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let slope = posToward.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: negAway])
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                              "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: e)
            let light = mul(a, slope.applyingFilter("CIColorClamp"))
            let dark = mul(a, slope.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0)]).applyingFilter("CIColorClamp"))
            over.append(colored([1, 1, 1], light, opacity: b.highlight, e))
            over.append(colored([0, 0, 0], dark, opacity: b.shadow, e))
        }
        if st.stroke.enabled {
            let s = st.stroke
            let w = px(s.size)
            let m: CIImage
            switch s.position {
            case 1: m = sub(a, erode(a, w))
            case 2: m = sub(dilate(a, w / 2), erode(a, w / 2))
            default: m = sub(dilate(a, w), a)
            }
            over.append(colored(s.color, m, opacity: s.opacity, e))
        }
        var out = content
        for u in under.reversed() { out = out.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: u]) }
        // Overlay styles only inside the content (the outer stroke is already the outer shape)
        for o in over { out = o.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: out]) }
        return out.cropped(to: e)
    }

    // MARK: Helpers

    static func alphaGray(_ i: CIImage) -> CIImage {
        i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: i.extent)
    }
    static func soften(_ m: CIImage, _ r: CGFloat) -> CIImage {
        r < 0.3 ? m : m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: m.extent)
    }
    static func dilate(_ m: CIImage, _ r: CGFloat) -> CIImage {
        r < 0.5 ? m : m.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: m.extent)
    }
    static func erode(_ m: CIImage, _ r: CGFloat) -> CIImage {
        r < 0.5 ? m : m.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: m.extent)
    }
    static func invert(_ m: CIImage) -> CIImage { m.applyingFilter("CIColorInvert") }
    static func mul(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: a.extent)
    }
    /// a − b (both grayscale masks): a × (1 − b)
    static func sub(_ a: CIImage, _ b: CIImage) -> CIImage { mul(a, invert(b)) }
    static func ciColor(_ c: [Float]) -> CIColor {
        let v = (c + [0, 0, 0]).prefix(3).map { CGFloat(pow(max($0, 0), 2.2)) }
        return CIColor(red: v[0], green: v[1], blue: v[2], alpha: 1, colorSpace: Render.workingSpace) ?? CIColor(red: v[0], green: v[1], blue: v[2])
    }
    /// Solid color in the mask shape and opacity
    static func colored(_ c: [Float], _ m: CIImage, opacity: Float, _ e: CGRect) -> CIImage {
        masked(CIImage(color: ciColor(c)).cropped(to: e), m, opacity: opacity, e)
    }
    static func masked(_ img: CIImage, _ m: CIImage, opacity: Float, _ e: CGRect) -> CIImage {
        let mm = m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0)])
        return img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), "inputMaskImage": mm]).cropped(to: e)
    }
    static func pattern(_ o: Overlay, _ e: CGRect, scale: CGFloat) -> CIImage {
        let s = max(CGFloat(o.scale) * scale, 1)
        switch o.pattern {
        case 1:
            return CIFilter(name: "CIStripesGenerator", parameters: [
                "inputColor0": ciColor(o.color), "inputColor1": ciColor(o.color2), kCIInputWidthKey: s, kCIInputSharpnessKey: 1])!
                .outputImage!.cropped(to: e)
        case 2:
            let c = Effects.clouds(e, scale: scale * CGFloat(o.scale) / 40, seed: 5)
            return c.applyingFilter("CIFalseColor", parameters: ["inputColor0": ciColor(o.color2), "inputColor1": ciColor(o.color)])
        case 3:
            return CIFilter(name: "CIDotScreen", parameters: [:]).flatMap { _ in
                CIImage(color: ciColor(o.color)).cropped(to: e)
                    .applyingFilter("CIDotScreen", parameters: [kCIInputWidthKey: s, kCIInputSharpnessKey: 0.9, kCIInputCenterKey: CIVector(x: e.minX, y: e.minY)])
            } ?? CIImage(color: ciColor(o.color)).cropped(to: e)
        default:
            return CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputColor0": ciColor(o.color), "inputColor1": ciColor(o.color2), kCIInputWidthKey: s, kCIInputSharpnessKey: 1,
                kCIInputCenterKey: CIVector(x: e.minX, y: e.minY)])!.outputImage!.cropped(to: e)
        }
    }
}

// MARK: - Editor (layer-edit styles tool, layers tab "Styles" card)

final class LayerStylesEditor: NSStackView {
    var onChange: ((LayerStyles, Bool) -> Void)?
    private(set) var styles = LayerStyles()
    private var syncs: [() -> Void] = []
    private let hint = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: LayerStyles?, applicable: Bool) {
        styles = s ?? LayerStyles()
        hint.stringValue = applicable ? "" : "스타일은 모양이 있는 레이어(이미지·칠·글자·모양)에 입힙니다."
        hint.isHidden = applicable
        syncs.forEach { $0() }
    }

    private func emit(_ dragging: Bool) { onChange?(styles, dragging) }

    private func add(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func section(_ title: String, _ on: WritableKeyPath<LayerStyles, Bool>) {
        let sw = NSSwitch()
        sw.controlSize = .mini
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [label, NSView(), sw])
        add(row)
        let action = ClosureTarget { [weak self, weak sw] in
            guard let self, let sw else { return }
            self.styles[keyPath: on] = sw.state == .on
            self.emit(false)
        }
        sw.target = action; sw.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(sw, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        syncs.append { [weak self, weak sw] in sw?.state = self?.styles[keyPath: on] == true ? .on : .off }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<LayerStyles, Float>, _ lo: Double, _ hi: Double, _ fmt: String, display: Double = 1) {
        let row = SliderRow(label: title, min: lo, max: hi, format: fmt, display: display)
        row.onChange = { [weak self] v, d in self?.styles[keyPath: key] = Float(v); self?.emit(d) }
        syncs.append { [weak self, weak row] in if let self { row?.value = Double(self.styles[keyPath: key]) } }
        add(row)
    }

    private func color(_ title: String, _ key: WritableKeyPath<LayerStyles, [Float]>) {
        let well = NSColorWell(style: .minimal)
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        add(NSStackView(views: [label, NSView(), well]))
        let action = ClosureTarget { [weak self, weak well] in
            guard let self, let c = well?.color.usingColorSpace(.sRGB) else { return }
            self.styles[keyPath: key] = [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
            self.emit(false)
        }
        well.target = action; well.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(well, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        syncs.append { [weak self, weak well] in
            guard let c = self?.styles[keyPath: key], c.count >= 3 else { return }
            well?.color = NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
        }
    }

    private func choice(_ title: String, _ key: WritableKeyPath<LayerStyles, Int>, _ items: [String]) {
        let p = NSPopUpButton()
        p.controlSize = .small
        p.addItems(withTitles: items)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        add(NSStackView(views: [label, NSView(), p]))
        let action = ClosureTarget { [weak self, weak p] in
            guard let self, let p else { return }
            self.styles[keyPath: key] = p.indexOfSelectedItem
            self.emit(false)
        }
        p.target = action; p.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(p, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        syncs.append { [weak self, weak p] in if let self { p?.selectItem(at: self.styles[keyPath: key]) } }
    }

    private func line() { let b = NSBox(); b.boxType = .separator; add(b) }

    private func build() {
        add(hint)
        section("그림자", \.dropShadow.enabled)
        color("색", \.dropShadow.color)
        slider("불투명도", \.dropShadow.opacity, 0, 1, "%.0f%%", display: 100)
        slider("각도", \.dropShadow.angle, -180, 180, "%.0f°")
        slider("거리", \.dropShadow.distance, 0, 500, "%.0f")
        slider("크기", \.dropShadow.size, 0, 250, "%.0f")
        slider("퍼짐", \.dropShadow.spread, 0, 100, "%.0f%%")
        line()
        section("외부 광선", \.outerGlow.enabled)
        color("색", \.outerGlow.color)
        slider("불투명도", \.outerGlow.opacity, 0, 1, "%.0f%%", display: 100)
        slider("크기", \.outerGlow.size, 0, 250, "%.0f")
        slider("퍼짐", \.outerGlow.spread, 0, 100, "%.0f%%")
        line()
        section("획", \.stroke.enabled)
        color("색", \.stroke.color)
        slider("크기", \.stroke.size, 1, 250, "%.0f")
        slider("불투명도", \.stroke.opacity, 0, 1, "%.0f%%", display: 100)
        choice("위치", \.stroke.position, ["바깥쪽", "안쪽", "가운데"])
        line()
        section("내부 그림자", \.innerShadow.enabled)
        color("색", \.innerShadow.color)
        slider("불투명도", \.innerShadow.opacity, 0, 1, "%.0f%%", display: 100)
        slider("각도", \.innerShadow.angle, -180, 180, "%.0f°")
        slider("거리", \.innerShadow.distance, 0, 500, "%.0f")
        slider("크기", \.innerShadow.size, 0, 250, "%.0f")
        line()
        section("내부 광선", \.innerGlow.enabled)
        color("색", \.innerGlow.color)
        slider("불투명도", \.innerGlow.opacity, 0, 1, "%.0f%%", display: 100)
        slider("크기", \.innerGlow.size, 0, 250, "%.0f")
        line()
        section("경사와 엠보스", \.bevel.enabled)
        slider("깊이", \.bevel.depth, 1, 1000, "%.0f%%")
        slider("크기", \.bevel.size, 0, 250, "%.0f")
        slider("빛 각도", \.bevel.angle, -180, 180, "%.0f°")
        slider("밝은 쪽", \.bevel.highlight, 0, 1, "%.0f%%", display: 100)
        slider("어두운 쪽", \.bevel.shadow, 0, 1, "%.0f%%", display: 100)
        line()
        section("새틴", \.satin.enabled)
        color("색", \.satin.color)
        slider("불투명도", \.satin.opacity, 0, 1, "%.0f%%", display: 100)
        slider("각도", \.satin.angle, -180, 180, "%.0f°")
        slider("거리", \.satin.distance, 1, 250, "%.0f")
        slider("크기", \.satin.size, 0, 250, "%.0f")
        line()
        section("색상 오버레이", \.colorOverlay.enabled)
        color("색", \.colorOverlay.color)
        slider("불투명도", \.colorOverlay.opacity, 0, 1, "%.0f%%", display: 100)
        line()
        section("그라디언트 오버레이", \.gradientOverlay.enabled)
        color("시작 색", \.gradientOverlay.color)
        color("끝 색", \.gradientOverlay.color2)
        slider("각도", \.gradientOverlay.angle, -180, 180, "%.0f°")
        slider("불투명도", \.gradientOverlay.opacity, 0, 1, "%.0f%%", display: 100)
        line()
        section("패턴 오버레이", \.patternOverlay.enabled)
        choice("무늬", \.patternOverlay.pattern, ["체크", "줄무늬", "구름", "점"])
        color("색 1", \.patternOverlay.color)
        color("색 2", \.patternOverlay.color2)
        slider("크기", \.patternOverlay.scale, 2, 400, "%.0f")
        slider("불투명도", \.patternOverlay.opacity, 0, 1, "%.0f%%", display: 100)
    }
}

/// Button/switch actions as closures (target is held weakly, so retained via associated objects)
final class ClosureTarget: NSObject {
    static var key = 0
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}
