import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// PSD·PSB → Duochrome 문서. 맨 아래 배경 레이어가 원본 사진 자리(현상 단계)가 되고, 나머지는 레이어가 된다.
///
/// - 픽셀 레이어 → 이미지 레이어 (PNG, 16비트면 16비트 PNG)
/// - 그룹 → 그룹 (통과 포함), 레이어 마스크·벡터 마스크 → 마스크 그림
/// - 조정 레이어 → 조정 수식을 구운 LUT 조정 레이어 (PSDAdjust), 반전은 그대로
/// - 칠 레이어(단색·그라디언트·패턴) → 칠 레이어
/// - 글자 레이어 → 글자 레이어 (글자·글꼴·크기·색·자리, 모양은 파일에 든 그림을 고치기 전까지 쓴다)
/// - 레이어 스타일 → Duochrome 레이어 스타일 (근사)
/// - 스마트 오브젝트 → 품은 파일 + 스마트 필터(흐림·언샤프·노이즈 등)를 효과로. 모르는 필터가 있으면 파일에 든 결과 픽셀
enum PSDImport {
    static let extensions: Set<String> = ["psd", "psb"]

    struct Result {
        var layers: [AdjustLayer] = []
        var notes: [String] = []
    }

    // MARK: - 그림 만들기

    static func colorSpace(_ f: PSD.File) -> CGColorSpace {
        if let icc = f.icc, let cs = CGColorSpace(iccData: icc as CFData), cs.model == .rgb || f.mode != 3 { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// 평면 채널들 → RGBA CGImage (w×h). 알파가 없으면 불투명.
    static func cgImage(_ f: PSD.File, color: [[UInt8]], alpha: [UInt8]?, width w: Int, height h: Int) -> CGImage? {
        let bps = f.depth == 32 ? 4 : (f.depth == 16 ? 2 : 1)
        guard w > 0, h > 0, !color.isEmpty else { return nil }
        let n = w * h
        var buf = [UInt8](repeating: 0, count: n * 4 * bps)
        var space = colorSpace(f)
        func put(_ src: [UInt8], _ comp: Int) {
            guard src.count >= n * bps else { return }
            src.withUnsafeBufferPointer { s in
                buf.withUnsafeMutableBufferPointer { d in
                    for i in 0 ..< n {
                        let si = i * bps, di = (i * 4 + comp) * bps
                        for k in 0 ..< bps { d[di + k] = s[si + k] }
                    }
                }
            }
        }
        func fillOpaque(_ comp: Int) {
            let one: [UInt8] = bps == 4 ? [0x3f, 0x80, 0, 0] : (bps == 2 ? [0xff, 0xff] : [0xff])
            for i in 0 ..< n { for k in 0 ..< bps { buf[(i * 4 + comp) * bps + k] = one[k] } }
        }
        switch f.mode {
        case 1, 8:   // 회색조·이중톤: 첫 채널을 세 번
            put(color[0], 0); put(color[0], 1); put(color[0], 2)
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        case 4:      // CMYK: 잉크값이 반전되어 있다. 맥 색 변환으로 RGB로
            guard color.count >= 4, bps == 1 else { return nil }
            return cmykImage(f, color: color, alpha: alpha, width: w, height: h)
        case 9:      // Lab
            guard color.count >= 3 else { return nil }
            for i in 0 ..< n {
                func v(_ c: Int) -> Float {
                    bps == 1 ? Float(color[c][i]) / 255 : Float(UInt16(color[c][i * 2]) << 8 | UInt16(color[c][i * 2 + 1])) / 65535
                }
                let rgb = PSDAdjust.fromLab(SIMD3(v(0) * 100, v(1) * 255 - 128, v(2) * 255 - 128))
                for c in 0 ..< 3 {
                    if bps == 1 { buf[i * 4 + c] = UInt8(min(max(rgb[c] * 255, 0), 255)) } else {
                        let u = UInt16(min(max(rgb[c] * 65535, 0), 65535)); buf[(i * 4 + c) * 2] = UInt8(u >> 8); buf[(i * 4 + c) * 2 + 1] = UInt8(u & 0xff)
                    }
                }
            }
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        default:
            guard color.count >= 3 else { return nil }
            put(color[0], 0); put(color[1], 1); put(color[2], 2)
        }
        if let a = alpha { put(a, 3) } else { fillOpaque(3) }
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        if bps == 2 { info.insert(.byteOrder16Big) }
        if bps == 4 { info.insert(.byteOrder32Big); info.insert(.floatComponents) }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: bps * 8, bitsPerPixel: bps * 32, bytesPerRow: w * 4 * bps,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func cmykImage(_ f: PSD.File, color: [[UInt8]], alpha: [UInt8]?, width w: Int, height h: Int) -> CGImage? {
        let n = w * h
        var buf = [UInt8](repeating: 0, count: n * 4)
        for i in 0 ..< n { for c in 0 ..< 4 { buf[i * 4 + c] = 255 - color[c][i] } }
        let space = f.icc.flatMap { CGColorSpace(iccData: $0 as CFData) }.flatMap { $0.model == .cmyk ? $0 : nil } ?? CGColorSpaceCreateDeviceCMYK()
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let cmyk = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                 shouldInterpolate: false, intent: .perceptual),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(cmyk, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: n * 4)
        var out = [UInt8](repeating: 255, count: n * 4)
        for i in 0 ..< n { out[i * 4] = p[i * 4]; out[i * 4 + 1] = p[i * 4 + 1]; out[i * 4 + 2] = p[i * 4 + 2]; if let a = alpha { out[i * 4 + 3] = a[i] } }
        guard let prov = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func colorChannelCount(_ f: PSD.File) -> Int {
        switch f.mode { case 1, 8: return 1; case 4: return 4; default: return 3 }
    }

    /// 레이어 픽셀 → CGImage (레이어 사각형 크기)
    static func layerImage(_ l: PSD.Layer, _ f: PSD.File) -> CGImage? {
        let w = l.width, h = l.height
        guard w > 0, h > 0 else { return nil }
        var color: [[UInt8]] = []
        for c in 0 ..< colorChannelCount(f) {
            guard let ch = l.channel(Int16(c)), let d = PSD.decode(ch, width: w, height: h, depth: f.depth, big: f.isPSB) else { return nil }
            color.append(d)
        }
        let alpha = l.channel(-1).flatMap { PSD.decode($0, width: w, height: h, depth: f.depth, big: f.isPSB) }
        return cgImage(f, color: color, alpha: alpha, width: w, height: h)
    }

    /// 합친 그림 (레이어가 없는 PSD)
    static func mergedImage(_ f: PSD.File) -> CGImage? {
        let ch = PSD.mergedChannels(f)
        let nc = colorChannelCount(f)
        guard ch.count >= nc else { return nil }
        let alpha = f.hasMergedAlpha && ch.count > nc ? ch[nc] : nil
        return cgImage(f, color: Array(ch[0 ..< nc]), alpha: alpha, width: f.width, height: f.height)
    }

    /// 픽셀 레이어만 표준 혼합으로 쌓은 그림 (스마트 오브젝트 속 문서는 합친 그림을 비워 두기도 한다)
    static func flatten(_ f: PSD.File) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: f.width, height: f.height)
        var out = CIImage(color: .clear).cropped(to: rect)
        for l in f.layers where l.visible && l.section == nil && l.width > 0 && !l.blocks.contains(where: { PSDAdjust.keys.contains($0.key) }) {
            guard let cg = layerImage(l, f) else { continue }
            var img = CIImage(cgImage: cg).transformed(by: .init(translationX: CGFloat(l.left), y: CGFloat(f.height) - CGFloat(l.bottom)))
            if l.opacity < 255 {
                img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(l.opacity) / 255)])
            }
            out = img.composited(over: out)
        }
        return Render.context.createCGImage(out.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// 맨 아래 레이어가 배경으로 쓸 만한가 (캔버스 전체, 불투명, 표준, 마스크·효과 없음)
    static func isBackground(_ l: PSD.Layer, _ f: PSD.File) -> Bool {
        guard l.left == 0, l.top == 0, l.width == f.width, l.height == f.height, l.visible, l.opacity == 255,
              l.blend == "norm", l.mask == nil, l.section == nil, l.channel(-1) == nil || l.name == "Background" else { return false }
        let special: Set<String> = ["TySh", "SoLd", "PlLd", "SoCo", "GdFl", "PtFl", "lfx2", "vmsk", "vsms"]
        return !l.blocks.contains { special.contains($0.key) || PSDAdjust.keys.contains($0.key) }
    }

    /// 원본 사진 자리에 쓸 그림
    static func base(_ f: PSD.File) -> CIImage? {
        let rect = CGRect(x: 0, y: 0, width: f.width, height: f.height)
        if let first = f.layers.first, isBackground(first, f), let cg = layerImage(first, f) { return CIImage(cgImage: cg) }
        if f.layers.isEmpty, let cg = mergedImage(f) { return CIImage(cgImage: cg) }
        return CIImage(color: .clear).cropped(to: rect)
    }

    // MARK: - 파일로

    static func writeImage(_ cg: CGImage, float: Bool = false) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-psd-\(UUID().uuidString).\(float ? "tiff" : "png")")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, (float ? UTType.tiff : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest), let name = try? LayerImageStore.importFile(tmp) else { return nil }
        try? FileManager.default.removeItem(at: tmp)
        return name
    }

    /// 마스크 채널(자기 사각형) + 바깥 기본색 → 캔버스 전체 흑백 PNG
    static func maskFile(_ l: PSD.Layer, _ f: PSD.File, vector: CGPath?) -> String? {
        let W = f.width, H = f.height
        var gray = [UInt8](repeating: 255, count: W * H)
        var any = false
        if let m = l.mask, !m.disabled, let ch = l.channel(-2) {
            any = true
            gray = [UInt8](repeating: m.defaultColor, count: W * H)
            if m.width > 0, m.height > 0, let d = PSD.decode(ch, width: m.width, height: m.height, depth: f.depth, big: f.isPSB) {
                let bps = max(f.depth / 8, 1)
                for y in 0 ..< m.height {
                    let cy = Int(m.top) + y
                    guard cy >= 0, cy < H else { continue }
                    for x in 0 ..< m.width {
                        let cx = Int(m.left) + x
                        guard cx >= 0, cx < W else { continue }
                        gray[cy * W + cx] = d[(y * m.width + x) * bps]
                    }
                }
            }
        }
        if let path = vector {
            any = true
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            // PSD 좌표(위가 0) → 그림 좌표
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            if let p = ctx.data?.bindMemory(to: UInt8.self, capacity: W * H) {
                // CGContext 메모리는 위 줄부터
                for i in 0 ..< W * H { gray[i] = UInt8((Int(gray[i]) * Int(p[i]) + 127) / 255) }
            }
        }
        guard any, let prov = CGDataProvider(data: Data(gray) as CFData),
              let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return writeImage(cg)
    }

    /// 벡터 마스크 경로 (vmsk·vsms). 캔버스 픽셀, 위가 0.
    static func vectorPath(_ l: PSD.Layer, _ f: PSD.File) -> CGPath? {
        guard let d = l.block("vmsk") ?? l.block("vsms"), d.count > 8 else { return nil }
        var r = PSD.Reader(d)
        _ = try? r.u32()
        let flags = (try? r.u32()) ?? 0
        if flags & 4 != 0 { return nil }   // 꺼 둠
        let path = CGMutablePath()
        var knots: [(CGPoint, CGPoint, CGPoint)] = []
        var closed = true
        func flush() {
            guard knots.count > 1 else { knots = []; return }
            path.move(to: knots[0].1)
            for i in 1 ..< knots.count { path.addCurve(to: knots[i].1, control1: knots[i - 1].2, control2: knots[i].0) }
            if closed { path.addCurve(to: knots[0].1, control1: knots.last!.2, control2: knots[0].0); path.closeSubpath() }
            knots = []
        }
        func pt() throws -> CGPoint {
            let y = Double(try r.i32()) / 16_777_216, x = Double(try r.i32()) / 16_777_216
            return CGPoint(x: x * Double(f.width), y: y * Double(f.height))
        }
        while r.remaining >= 26 {
            guard let sel = try? r.u16() else { break }
            switch sel {
            case 0, 3:
                flush(); closed = sel == 0
                try? r.skip(24)
            case 1, 2, 4, 5:
                guard let a = try? pt(), let b = try? pt(), let c = try? pt() else { return nil }
                knots.append((a, b, c))
            default:
                try? r.skip(24)
            }
        }
        flush()
        if flags & 1 != 0 {
            let inv = CGMutablePath()
            inv.addRect(CGRect(x: 0, y: 0, width: f.width, height: f.height))
            inv.addPath(path)
            return inv
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - 레이어로 바꾸기

    static func convert(_ f: PSD.File, progress: ((String) -> Void)? = nil) -> Result {
        var res = Result()
        let H = Double(f.height)
        var list = f.layers
        if let first = list.first, isBackground(first, f) { list.removeFirst() }
        var groupStack: [String] = []
        // 품은 파일 (스마트 오브젝트)
        let linked = linkedFiles(f)
        for (idx, l) in list.enumerated() {
            progress?("레이어 \(idx + 1)/\(list.count): \(l.unicodeName)")
            if l.section == 3 { groupStack.append(UUID().uuidString); continue }
            var layer = AdjustLayer(name: l.unicodeName)
            layer.enabled = l.visible
            layer.opacity = Float(l.opacity) / 255
            layer.blend = PSD.ourBlend(l.blend)
            if layer.blend == "passThrough" { layer.blend = "normal" }
            layer.clipped = l.clipping != 0
            if let io = l.block("iOpa"), let v = io.first { layer.fill = Float(v) / 255 }
            if let s = l.section, s == 1 || s == 2 {
                // 그룹 머리 (자식 다음에 온다)
                layer.id = groupStack.popLast() ?? UUID().uuidString
                layer.kind = "group"
                layer.blend = (l.sectionBlend ?? l.blend) == "pass" ? Layers.passThroughKey : PSD.ourBlend(l.sectionBlend ?? l.blend)
                layer.group = groupStack.last
                if let m = maskFile(l, f, vector: vectorPath(l, f)) { layer.mask = LayerMask(kind: .image, maskFile: m) }
                res.layers.append(layer)
                continue
            }
            layer.group = groupStack.last
            let adjKey = l.blocks.map(\.key).first { PSDAdjust.keys.contains($0) }
            if let key = adjKey, let data = l.block(key) {
                // 조정 레이어
                layer.kind = "adjust"
                layer.psdBlock = key + ":" + data.base64EncodedString()
                if let fn = PSDAdjust.function(key, data, blocks: l.blocks),
                          let file = try? LayerImageStore.importData(Data(PSDAdjust.cube(fn, title: l.unicodeName).utf8), ext: "cube") {
                    layer.adjust.lut = file
                } else {
                    layer.enabled = false
                    layer.name += " (가져오지 못함)"
                    res.notes.append("\(l.unicodeName): \(PSDAdjust.titles[key] ?? key) 조정을 읽지 못했습니다")
                }
            } else if let so = l.block("SoCo") ?? l.block("GdFl") ?? l.block("PtFl") {
                layer.kind = "fill"
                fill(&layer, so, key: l.block("SoCo") != nil ? "SoCo" : (l.block("GdFl") != nil ? "GdFl" : "PtFl"), f: f, notes: &res.notes)
            } else if let ty = l.block("TySh"), let t = text(ty, f: f) {
                layer.kind = "text"
                layer.text = t
                if let cg = layerImage(l, f), let file = writeImage(cg, float: f.depth == 32) {
                    layer.image = LayerImage(file: file, cx: Double(l.left) + Double(l.width) / 2,
                                             cy: H - (Double(l.top) + Double(l.height) / 2), width: Double(l.width), height: Double(l.height))
                }
            } else if let so = l.block("SoLd") ?? l.block("PlLd"), let rebuilt = smartObject(so, linked: linked, f: f) {
                layer.kind = "image"
                layer.image = rebuilt.0
                layer.adjust.effects = rebuilt.1.isEmpty ? nil : rebuilt.1
                layer.name += " (스마트)"
            } else {
                // 픽셀 레이어
                guard let cg = layerImage(l, f), let file = writeImage(cg, float: f.depth == 32) else {
                    if l.width > 0 { res.notes.append("\(l.unicodeName): 픽셀을 읽지 못했습니다") }
                    continue
                }
                layer.kind = "image"
                layer.image = LayerImage(file: file, cx: Double(l.left) + Double(l.width) / 2,
                                         cy: H - (Double(l.top) + Double(l.height) / 2), width: Double(l.width), height: Double(l.height))
            }
            if let m = maskFile(l, f, vector: vectorPath(l, f)) { layer.mask = LayerMask(kind: .image, maskFile: m) }
            if let fx = l.block("lfx2"), var styles = styles(fx) {
                if styles.isActive, layer.takesStyles { layer.styles = styles } else if styles.isActive {
                    styles = LayerStyles(); res.notes.append("\(l.unicodeName): 조정 레이어의 스타일은 가져오지 않았습니다")
                }
            }
            res.layers.append(layer)
        }
        return res
    }

    // MARK: - 칠

    private static func fill(_ layer: inout AdjustLayer, _ d: Data, key: String, f: PSD.File, notes: inout [String]) {
        guard let desc = PSD.versionedDescriptor(d) else { layer.fillColor = [0.5, 0.5, 0.5]; return }
        switch key {
        case "SoCo":
            layer.fillColor = PSD.Descriptor.rgb(desc.obj("Clr ")) ?? [0.5, 0.5, 0.5]
        case "GdFl":
            let stops = gradientStops(desc.obj("Grad"))
            let a = stops.first?.color ?? SIMD3(0, 0, 0), b = stops.last?.color ?? SIMD3(1, 1, 1)
            let rev = desc["Rvrs"]?.bool ?? false
            let c0 = rev ? b : a, c1 = rev ? a : b
            layer.fillColor = [c0.x, c0.y, c0.z, c1.x, c1.y, c1.z]
            // 각도 방향으로 캔버스를 가로지르는 선 (원본 좌표, 아래가 0 — PSD 각도도 반시계)
            let ang = (desc.double("Angl") ?? 90) * .pi / 180
            let cx = Double(f.width) / 2, cy = Double(f.height) / 2
            let half = (abs(cos(ang)) * Double(f.width) + abs(sin(ang)) * Double(f.height)) / 2
            layer.fillPoints = [cx - cos(ang) * half, cy - sin(ang) * half, cx + cos(ang) * half, cy + sin(ang) * half]
            if (desc["Type"]?.enumValue ?? "Lnr ") != "Lnr " { notes.append("\(layer.name): 선형이 아닌 그라디언트는 선형으로 바꿨습니다") }
        default:
            // 패턴: 문서에 든 패턴(Patt)을 무늬 파일로
            let id = desc.obj("Ptrn")?["Idnt"]?.string
            if let id, let file = PresetFiles.documentPattern(f, id: id) {
                layer.fillPatternFile = file
                layer.fillScale = Float(desc.double("Scl ") ?? 100)
            } else {
                layer.fillColor = [0.5, 0.5, 0.5]
                notes.append("\(layer.name): 패턴을 찾지 못해 회색으로 칠했습니다")
            }
        }
    }

    static func gradientStops(_ g: PSD.Descriptor?) -> [PSDAdjust.GradientStop] {
        guard let g, let clrs = g["Clrs"]?.list else { return [] }
        return clrs.compactMap { v in
            guard let o = v.object else { return nil }
            let c = PSD.Descriptor.rgb(o.obj("Clr ")) ?? [0, 0, 0]
            return PSDAdjust.GradientStop(loc: Float(o.double("Lctn") ?? 0) / 4096, mid: Float(o.double("Mdpn") ?? 50) / 100,
                                          color: SIMD3(c[0], c[1], c[2]))
        }
    }

    // MARK: - 글자

    static func text(_ d: Data, f: PSD.File) -> LayerText? {
        var r = PSD.Reader(d)
        guard (try? r.u16()) != nil else { return nil }
        var tr: [Double] = []
        for _ in 0 ..< 6 { guard let v = try? r.f64() else { return nil }; tr.append(v) }
        guard (try? r.u16()) != nil, (try? r.u32()) != nil, let desc = try? PSD.descriptor(&r) else { return nil }
        let str = desc["Txt "]?.string ?? ""
        var t = LayerText(string: str)
        let scaleY = hypot(tr[2], tr[3])
        t.x = tr[4]
        t.y = Double(f.height) - tr[5]
        t.rotation = -atan2(tr[1], tr[0]) * 180 / .pi
        if let engine = desc["EngineData"]?.rawData {
            let e = EngineData(engine)
            if let s = e.number("FontSize") { t.size = s * scaleY }
            if let c = e.fillColor() { t.color = c }
            if let j = e.number("Justification") { t.align = [0: 0, 1: 2, 2: 1][Int(j)] ?? 0 }
            if let lead = e.number("Leading"), e.bool("AutoLeading") == false { t.leading = lead * scaleY }
            if let tk = e.number("Tracking") { t.tracking = tk }
            let fontIndex = Int(e.number("Font") ?? 0)
            let names = e.fontNames()
            if fontIndex < names.count { t.font = TextRender.resolveFont(names[fontIndex]) }
        }
        return t
    }

    /// 글자 엔진 자료(포스트스크립트 비슷한 글)에서 필요한 값만 찾는다
    struct EngineData {
        let bytes: [UInt8]
        let text: String
        init(_ d: Data) {
            bytes = [UInt8](d)
            text = String(decoding: d.map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
        }
        func number(_ key: String) -> Double? {
            guard let r = text.range(of: "/\(key) ") else { return nil }
            let rest = text[r.upperBound...].prefix(40)
            let tok = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first.map(String.init) ?? ""
            return Double(tok)
        }
        func bool(_ key: String) -> Bool? {
            guard let r = text.range(of: "/\(key) ") else { return nil }
            return text[r.upperBound...].hasPrefix("true")
        }
        func fillColor() -> [Float]? {
            guard let r = text.range(of: "/FillColor"), let v = text[r.upperBound...].range(of: "/Values [") else { return nil }
            let rest = text[v.upperBound...].prefix(80)
            let nums = rest.split(separator: "]").first?.split(separator: " ").compactMap { Double($0) } ?? []
            guard nums.count >= 4 else { return nil }
            return [Float(nums[1]), Float(nums[2]), Float(nums[3])]
        }
        /// /FontSet [ << /Name (UTF-16) ... >> ... ]
        func fontNames() -> [String] {
            guard let fs = text.range(of: "/FontSet") else { return [] }
            var names: [String] = []
            var pos = text.distance(from: text.startIndex, to: fs.upperBound)
            let key = Array("/Name (".utf8)
            while names.count < 64 {
                guard let i = find(key, from: pos) else { break }
                var j = i + key.count
                var raw: [UInt8] = []
                while j < bytes.count, bytes[j] != 0x29 {
                    if bytes[j] == 0x5c, j + 1 < bytes.count { j += 1 }
                    raw.append(bytes[j]); j += 1
                }
                let s = raw.count >= 2 && raw[0] == 0xfe && raw[1] == 0xff
                    ? String(data: Data(raw.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
                    : String(decoding: raw, as: UTF8.self)
                names.append(s)
                pos = j
                // 다음 글꼴 사전이 아니면 멈춘다
                if let close = find(Array("]".utf8), from: j), let next = find(key, from: j), next > close { break }
            }
            return names
        }
        private func find(_ k: [UInt8], from: Int) -> Int? {
            guard k.count > 0, from < bytes.count else { return nil }
            var i = from
            while i + k.count <= bytes.count {
                if bytes[i] == k[0], Array(bytes[i ..< i + k.count]) == k { return i }
                i += 1
            }
            return nil
        }
    }

    // MARK: - 레이어 스타일 (lfx2)

    static func styles(_ d: Data) -> LayerStyles? {
        var r = PSD.Reader(d)
        guard (try? r.u32()) != nil, (try? r.u32()) != nil, let desc = try? PSD.descriptor(&r) else { return nil }
        var st = LayerStyles()
        func one(_ key: String, _ multi: String) -> PSD.Descriptor? {
            if let o = desc.obj(key) { return o }
            return desc[multi]?.list?.first?.object
        }
        func color(_ o: PSD.Descriptor, _ def: [Float]) -> [Float] { PSD.Descriptor.rgb(o.obj("Clr ")) ?? def }
        func on(_ o: PSD.Descriptor) -> Bool { (o["enab"]?.bool ?? true) && (o["present"]?.bool ?? true) }
        func num(_ o: PSD.Descriptor, _ k: String, _ def: Double) -> Float { Float(o.double(k) ?? def) }
        let global = Float(desc.double("gagl") ?? 120)
        func angle(_ o: PSD.Descriptor) -> Float { (o["uglg"]?.bool ?? false) ? global : num(o, "lagl", 120) }
        if let o = one("DrSh", "dropShadowMulti") {
            st.dropShadow = .init(enabled: on(o), color: color(o, [0, 0, 0]), opacity: num(o, "Opct", 75) / 100, angle: angle(o),
                                  distance: num(o, "Dstn", 5), size: num(o, "blur", 5), spread: num(o, "Ckmt", 0))
        }
        if let o = one("IrSh", "innerShadowMulti") {
            st.innerShadow = .init(enabled: on(o), color: color(o, [0, 0, 0]), opacity: num(o, "Opct", 75) / 100, angle: angle(o),
                                   distance: num(o, "Dstn", 5), size: num(o, "blur", 5), spread: num(o, "Ckmt", 0))
        }
        if let o = desc.obj("OrGl") {
            st.outerGlow = .init(enabled: on(o), color: color(o, [1, 1, 0.75]), opacity: num(o, "Opct", 75) / 100, size: num(o, "blur", 5),
                                 spread: num(o, "Ckmt", 0))
        }
        if let o = desc.obj("IrGl") {
            st.innerGlow = .init(enabled: on(o), color: color(o, [1, 1, 0.75]), opacity: num(o, "Opct", 75) / 100, size: num(o, "blur", 5),
                                 spread: num(o, "Ckmt", 0))
        }
        if let o = one("FrFX", "frameFXMulti") {
            let pos = o["Styl"]?.enumValue ?? "OutF"
            st.stroke = .init(enabled: on(o), color: color(o, [0, 0, 0]), opacity: num(o, "Opct", 100) / 100, size: num(o, "Sz  ", 3),
                              position: pos == "InsF" ? 1 : (pos == "CtrF" ? 2 : 0))
        }
        if let o = desc.obj("ebbl") {
            st.bevel = .init(enabled: on(o), depth: num(o, "srgR", 100), size: num(o, "blur", 5), angle: angle(o),
                             highlight: num(o, "hglO", 75) / 100, shadow: num(o, "sdwO", 75) / 100)
        }
        if let o = one("SoFi", "solidFillMulti") {
            st.colorOverlay = .init(enabled: on(o), color: color(o, [1, 0, 0]), opacity: num(o, "Opct", 100) / 100)
        }
        if let o = one("GrFl", "gradientFillMulti") {
            let stops = gradientStops(o.obj("Grad"))
            let a = stops.first?.color ?? SIMD3(1, 1, 1), b = stops.last?.color ?? SIMD3(0, 0, 0)
            st.gradientOverlay = .init(enabled: on(o), color: [a.x, a.y, a.z], color2: [b.x, b.y, b.z],
                                       opacity: num(o, "Opct", 100) / 100, angle: num(o, "Angl", 90))
        }
        if let o = desc.obj("patternFill") {
            st.patternOverlay.enabled = on(o)
            st.patternOverlay.opacity = num(o, "Opct", 100) / 100
            st.patternOverlay.scale = num(o, "Scl ", 100) * 0.4
        }
        if let o = desc.obj("ChFX") {
            st.satin = .init(enabled: on(o), color: color(o, [0, 0, 0]), opacity: num(o, "Opct", 50) / 100, angle: num(o, "lagl", 19),
                             distance: num(o, "Dstn", 11), size: num(o, "blur", 14))
        }
        if desc["masterFXSwitch"]?.bool == false { return LayerStyles() }
        return st
    }

    // MARK: - 스마트 오브젝트

    /// 문서에 품은 파일 (lnk2·lnkD·lnk3의 liFD): 고유 번호 → (파일 이름, 자료)
    static func linkedFiles(_ f: PSD.File) -> [String: (String, Data)] {
        var out: [String: (String, Data)] = [:]
        for key in ["lnk2", "lnkD", "lnk3"] {
            guard let d = f.globalBlock(key) else { continue }
            var r = PSD.Reader(d)
            while r.remaining > 8 {
                guard let len = try? r.u64(), len > 0 else { break }
                let start = r.pos
                let end = min(start + Int(len), d.endIndex)
                if let type = try? r.key(), type == "liFD", let _ = try? r.u32(), let id = try? r.pascal(pad: 1),
                   let name = try? r.unicode(), (try? r.key()) != nil, (try? r.key()) != nil, let dl = try? r.u64() {
                    if let open = try? r.u8(), open != 0 { _ = try? r.u32(); _ = try? PSD.descriptor(&r) }
                    if let data = try? r.bytes(Int(dl)) { out[id] = (name, Data(data)) }
                }
                r.pos = end
                // 8바이트 경계로
                while (r.pos - d.startIndex) % 4 != 0, r.pos < d.endIndex { r.pos += 1 }
            }
        }
        return out
    }

    /// 스마트 필터 → 우리 효과. 하나라도 모르는 필터면 nil (파일에 든 픽셀을 쓴다)
    static func smartFilters(_ desc: PSD.Descriptor) -> [LayerEffect]? {
        guard let fx = desc.obj("filterFX"), fx["enab"]?.bool != false, let list = fx["filterFXList"]?.list else { return [] }
        var out: [LayerEffect] = []
        for v in list {
            guard let o = v.object else { continue }
            if o["enab"]?.bool == false { continue }
            guard let flt = o.obj("Fltr") else { return nil }
            func p(_ k: String) -> Double? { flt.double(k) }
            var e: LayerEffect
            switch flt.cls {
            case "GsnB": e = LayerEffect(kind: "gaussian"); e.params["radius"] = p("Rds ") ?? 2
            case "MtnB": e = LayerEffect(kind: "motion"); e.params["distance"] = p("Dstn") ?? 10; e.params["angle"] = p("Angl") ?? 0
            case "UnsM": e = LayerEffect(kind: "unsharp"); e.params["amount"] = p("Amnt") ?? 100; e.params["radius"] = p("Rds ") ?? 1; e.params["threshold"] = p("Thsh") ?? 0
            case "AdNs": e = LayerEffect(kind: "addNoise"); e.params["amount"] = p("Nose") ?? 10; e.params["mono"] = (flt["Mnch"]?.bool ?? false) ? 1 : 0
            case "HghP": e = LayerEffect(kind: "highPass"); e.params["radius"] = p("Rds ") ?? 10
            case "Mdn ": e = LayerEffect(kind: "median"); e.params["passes"] = max(1, min(8, p("Rds ") ?? 2))
            case "boxblur": e = LayerEffect(kind: "box"); e.params["radius"] = p("Rds ") ?? 5
            default: return nil
            }
            out.append(e)
        }
        return out
    }

    static func smartObject(_ d: Data, linked: [String: (String, Data)], f: PSD.File) -> (LayerImage, [LayerEffect])? {
        var r = PSD.Reader(d)
        guard (try? r.key()) != nil, (try? r.u32()) != nil, (try? r.u32()) != nil, let desc = try? PSD.descriptor(&r),
              let id = desc["Idnt"]?.string, let file = linked[id], let effects = smartFilters(desc),
              let tr = desc["Trnf"]?.list?.compactMap({ $0.double }), tr.count == 8 else { return nil }
        // 품은 파일을 레이어 그림(PNG)으로. PSD·PSB는 우리 해독기로 합친 그림을, 나머지는 맥 그림 해독기로.
        let ext = (file.0 as NSString).pathExtension.lowercased()
        var cg: CGImage?
        if extensions.contains(ext) || file.1.prefix(4) == Data("8BPS".utf8) {
            if let inner = try? PSD.read(file.1) { cg = inner.layers.isEmpty ? mergedImage(inner) : flatten(inner) }
        } else if let src = CGImageSourceCreateWithData(file.1 as CFData, nil), CGImageSourceGetCount(src) > 0 {
            cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let cg, let name = writeImage(cg) else { return nil }
        let H = Double(f.height)
        let p = (0 ..< 4).map { CGPoint(x: tr[$0 * 2], y: H - tr[$0 * 2 + 1]) }   // 왼위, 오른위, 오른아래, 왼아래
        let cx = p.map(\.x).reduce(0, +) / 4, cy = p.map(\.y).reduce(0, +) / 4
        let w = hypot(p[1].x - p[0].x, p[1].y - p[0].y), h = hypot(p[2].x - p[1].x, p[2].y - p[1].y)
        let rot = atan2(p[1].y - p[0].y, p[1].x - p[0].x) * 180 / .pi
        return (LayerImage(file: name, cx: cx, cy: cy, width: w, rotation: rot, height: h), effects)
    }
}
