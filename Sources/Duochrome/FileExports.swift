import AppKit
import CoreImage
import UniformTypeIdentifiers

/// 색 조정을 LUT(.cube)로 굽기. 픽셀 하나만 보는 조정(노출·화이트 밸런스 차이·기본 모습·하이라이트·톤 곡선·레벨·
/// 채도·컬러 밸런스·흑백·컬러 에디터)만 들어간다. 클래리티·디헤이즈·샤프닝·그레인·비네팅·레이어처럼 둘레를 보는 조정은 빠진다.
enum LUTExport {
    static func cube(_ doc: RawDocument, size n: Int = 33) -> String? {
        var s = SliderResponse.effective(doc.settings)
        // 둘레를 보는 조정은 끈다
        s.clarity = 0; s.structure = 0; s.dehaze = 0; s.shadow = 0; s.hotPixels = 0
        s.sharpenAmount = 0; s.grainAmount = 0; s.vignette = 0; s.layers = []
        let w = n * n, h = n
        var px = [Float](repeating: 1, count: w * h * 4)
        let k = Float(n - 1)
        for b in 0 ..< n { for g in 0 ..< n { for r in 0 ..< n {
            let i = (g * w + b * n + r) * 4
            px[i] = Float(r) / k; px[i + 1] = Float(g) / k; px[i + 2] = Float(b) / k
        } } }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var img = CIImage(bitmapData: data, bytesPerRow: w * 16, size: rect.size, format: .RGBAf,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // RAW 단계 중 따라 할 수 있는 것: 노출(기록값 대비), 화이트 밸런스 차이, 기본 모습
        let shot = doc.asShot
        if s.exposure != shot.exposure { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure - shot.exposure]) }
        if s.temperature != shot.temperature || s.tint != shot.tint {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(s.temperature), y: CGFloat(s.tint)),
                "inputTargetNeutral": CIVector(x: CGFloat(shot.temperature), y: CGFloat(shot.tint)),
            ])
        }
        if doc.isRaw { img = Look.apply(img, look: s.look, camera: doc.info.camera) }
        img = Develop.tone(s, img, scale: 1)
        var key = s.color
        key.luma = s.curves.luma
        img = ColorLUT.apply(key, to: img).cropped(to: rect)
        var out = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(img, toBitmap: &out, rowBytes: w * 16, bounds: rect, format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // 만들 때와 읽을 때 둘 다 위 줄부터라 그대로 읽는다
        var text = "TITLE \"\(doc.url.deletingPathExtension().lastPathComponent) (Duochrome)\"\n"
        text += "# 픽셀 단위 조정만 들어 있습니다 (클래리티·디헤이즈·샤프닝·그레인·비네팅·레이어 제외). 입력·출력 sRGB.\n"
        text += "LUT_3D_SIZE \(n)\n"
        for b in 0 ..< n { for g in 0 ..< n { for r in 0 ..< n {
            let i = (g * w + b * n + r) * 4
            text += String(format: "%.5f %.5f %.5f\n", min(max(out[i], 0), 1), min(max(out[i + 1], 0), 1), min(max(out[i + 2], 0), 1))
        } } }
        return text
    }
}

/// 지금 결과를 선형 DNG로 저장한다 (디모자이크한 16비트 선형 ProPhoto RGB, PhotometricInterpretation = LinearRaw).
/// 다른 RAW 프로그램에서 화이트 밸런스·노출을 다시 만질 수 있는 넓은 색 원본으로 넘길 때 쓴다.
enum DNGWriter {
    /// ProPhoto RGB(D50) → XYZ
    static let proPhotoToXYZ: [Double] = [0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0, 0, 0.8252100]

    /// 선형 ProPhoto (D50)
    static let linearProPhoto: CGColorSpace = {
        let m = proPhotoToXYZ
        let white: [CGFloat] = [0.9642, 1, 0.8249], black: [CGFloat] = [0, 0, 0], gamma: [CGFloat] = [1, 1, 1]
        let cols: [CGFloat] = [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]].map { CGFloat($0) }
        return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: black, gamma: gamma, matrix: cols)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    }()

    static func invert(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        return [A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
                B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
                C / det, -(a * h - b * g) / det, (a * e - b * d) / det]
    }

    static func write(_ doc: RawDocument, to url: URL, scale: CGFloat = 1) throws {
        try write(image: doc.image(scale: scale), to: url, camera: doc.info.camera)
    }

    /// 작업 공간 그림 → DNG. baselineExposure(EV)는 읽는 프로그램이 밝힐 양 (HDR 합치기)
    static func write(image img: CIImage, to url: URL, camera: String, baselineExposure: Double = 0) throws {
        let rect = img.extent.integral
        let W = Int(rect.width), H = Int(rect.height)
        guard W > 0, H > 0 else { throw PSD.Failure(message: "그림이 비었습니다") }
        let space = linearProPhoto
        var pix = [UInt16](repeating: 0, count: W * H * 4)
        pix.withUnsafeMutableBytes { p in
            Render.context.render(img, toBitmap: p.baseAddress!, rowBytes: W * 8, bounds: rect, format: .RGBA16, colorSpace: space)
        }
        // RGB만 (알파 빼기)
        var rgb = [UInt16](repeating: 0, count: W * H * 3)
        for i in 0 ..< W * H { rgb[i * 3] = pix[i * 4]; rgb[i * 3 + 1] = pix[i * 4 + 1]; rgb[i * 3 + 2] = pix[i * 4 + 2] }
        pix = []

        // TIFF (작은 엔디언)
        var out = Data()
        func u16(_ v: UInt16) { out.append(UInt8(v & 0xff)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for s in [0, 8, 16, 24] { out.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        struct Entry { var tag: UInt16; var type: UInt16; var count: UInt32; var data: Data }
        func shorts(_ v: [UInt16]) -> Data { var d = Data(); for x in v { d.append(UInt8(x & 0xff)); d.append(UInt8(x >> 8)) }; return d }
        func longs(_ v: [UInt32]) -> Data { var d = Data(); for x in v { for s in [0, 8, 16, 24] { d.append(UInt8((x >> UInt32(s)) & 0xff)) } }; return d }
        func srats(_ v: [Double]) -> Data {
            longs(v.flatMap { [UInt32(bitPattern: Int32(($0 * 10000).rounded())), 10000] })
        }
        func ascii(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        func floats(_ v: [Float]) -> Data { longs(v.map { $0.bitPattern }) }

        let rowsPerStrip = max(1, min(H, (1 << 20) / (W * 6)))
        let strips = (H + rowsPerStrip - 1) / rowsPerStrip
        let camToXYZinv = invert(proPhotoToXYZ)   // XYZ → 카메라(ProPhoto)
        let make = camera.isEmpty ? "Duochrome" : camera
        var entries: [Entry] = [
            Entry(tag: 254, type: 4, count: 1, data: longs([0])),
            Entry(tag: 256, type: 4, count: 1, data: longs([UInt32(W)])),
            Entry(tag: 257, type: 4, count: 1, data: longs([UInt32(H)])),
            Entry(tag: 258, type: 3, count: 3, data: shorts([16, 16, 16])),
            Entry(tag: 259, type: 3, count: 1, data: shorts([1])),
            Entry(tag: 262, type: 3, count: 1, data: shorts([34892])),
            Entry(tag: 271, type: 2, count: 0, data: ascii("Duochrome")),
            Entry(tag: 272, type: 2, count: 0, data: ascii(make)),
            Entry(tag: 273, type: 4, count: UInt32(strips), data: Data()),   // 나중에 채운다
            Entry(tag: 274, type: 3, count: 1, data: shorts([1])),
            Entry(tag: 277, type: 3, count: 1, data: shorts([3])),
            Entry(tag: 278, type: 4, count: 1, data: longs([UInt32(rowsPerStrip)])),
            Entry(tag: 279, type: 4, count: UInt32(strips), data: Data()),
            Entry(tag: 284, type: 3, count: 1, data: shorts([1])),
            Entry(tag: 305, type: 2, count: 0, data: ascii("Duochrome")),
            Entry(tag: 50706, type: 1, count: 4, data: Data([1, 4, 0, 0])),
            Entry(tag: 50707, type: 1, count: 4, data: Data([1, 1, 0, 0])),
            Entry(tag: 50708, type: 2, count: 0, data: ascii("Duochrome Linear ProPhoto")),
            Entry(tag: 50717, type: 4, count: 1, data: longs([65535])),
            Entry(tag: 50721, type: 10, count: 9, data: srats(camToXYZinv)),
            Entry(tag: 50728, type: 5, count: 3, data: longs([1, 1, 1, 1, 1, 1])),
            Entry(tag: 50730, type: 10, count: 1, data: srats([baselineExposure])),
            Entry(tag: 50778, type: 3, count: 1, data: shorts([23])),
            Entry(tag: 50936, type: 2, count: 0, data: ascii("Duochrome Linear")),
            Entry(tag: 50940, type: 11, count: 4, data: floats([0, 0, 1, 1])),
        ]
        for i in entries.indices where entries[i].type == 2 { entries[i].count = UInt32(entries[i].data.count) }
        // 배치: 머리(8) → IFD → 넘치는 값 → 그림 줄
        let ifdSize = 2 + entries.count * 12 + 4
        var extraOffset = 8 + ifdSize
        var extras = Data()
        // 줄 자리·크기 표 길이를 먼저 잡는다
        let stripTable = strips * 4
        let offsetsPos = extraOffset, countsPos = extraOffset + stripTable
        extraOffset += stripTable * 2
        var fields: [(Entry, UInt32)] = []   // (항목, 넘치면 자리)
        for e in entries {
            if e.tag == 273 { fields.append((e, UInt32(strips > 1 ? offsetsPos : 0))); continue }
            if e.tag == 279 { fields.append((e, UInt32(strips > 1 ? countsPos : 0))); continue }
            if e.data.count > 4 {
                fields.append((e, UInt32(extraOffset + extras.count)))
                extras.append(e.data)
                if extras.count % 2 == 1 { extras.append(0) }
            } else {
                fields.append((e, 0))
            }
        }
        let dataStart = extraOffset + extras.count
        var offsets: [UInt32] = [], counts: [UInt32] = []
        var pos = dataStart
        for sIdx in 0 ..< strips {
            let rows = min(rowsPerStrip, H - sIdx * rowsPerStrip)
            offsets.append(UInt32(pos)); counts.append(UInt32(rows * W * 6)); pos += rows * W * 6
        }
        out.append(contentsOf: [0x49, 0x49, 42, 0]); u32(8)
        u16(UInt16(fields.count))
        for (e, off) in fields {
            u16(e.tag); u16(e.type); u32(e.count)
            if e.tag == 273 || e.tag == 279 {
                if strips == 1 { u32(e.tag == 273 ? offsets[0] : counts[0]) } else { u32(off) }
                continue
            }
            if e.data.count > 4 { u32(off) } else {
                var d = e.data; while d.count < 4 { d.append(0) }; out.append(d)
            }
        }
        u32(0)
        if strips > 1 { out.append(longs(offsets)); out.append(longs(counts)) } else { out.append(Data(count: stripTable * 2)) }
        out.append(extras)
        rgb.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
        try out.write(to: url, options: .atomic)
    }
}

extension MainWindowController {
    @objc func exportLUT(_ sender: Any?) {
        guard let doc = photo, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.url.deletingPathExtension().lastPathComponent + ".cube"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "지금 사진의 색 조정을 33³ LUT로 굽습니다 (클래리티·디헤이즈·샤프닝·그레인·비네팅·레이어처럼 둘레를 보는 조정은 빠집니다)."
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url, let text = LUTExport.cube(doc) else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func exportDNG(_ sender: Any?) {
        guard let doc = photo, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.url.deletingPathExtension().lastPathComponent + "-duochrome.dng"
        panel.allowedContentTypes = [UTType(filenameExtension: "dng") ?? .data]
        panel.message = "지금 결과(모든 조정·레이어)를 16비트 선형 DNG로 저장합니다. 원본 RAW는 그대로 둡니다."
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            do { try DNGWriter.write(doc, to: url) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}
