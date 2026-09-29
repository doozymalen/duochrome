import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Duochrome document → PSD/PSB, with layers.
///
/// - Bottom "Background": the developed photo (geometry and crop applied)
/// - Image/fill/text layers → pixel layers (effects and styles baked into pixels), blend mode, opacity, clipping, and masks preserved
/// - Groups → groups (including pass-through)
/// - Adjustment layers: unedited ones imported from PSD plus invert/posterize/threshold become PSD adjustment layers;
///   others (develop adjustments like exposure, clarity) are baked into pixel layers from the result applied to the layers below (mask and opacity kept)
/// - The merged image is our own final render
enum PSDExport {
    struct Options {
        /// 8 or 16
        var depth = 8
        /// nil picks by size (PSB above 2 GB or 30000 px)
        var psb: Bool?
    }

    private struct Out {
        var layer: PSD.Layer
        /// Per channel (id, compressed data including the 2-byte compression type)
        var data: [(Int16, Data)]
    }

    static func write(_ doc: RawDocument, to url: URL, options: Options = Options(), progress: ((String) -> Void)? = nil) throws {
        JobCenter.shared.begin("psd", title: "PSD 저장", detail: url.lastPathComponent)
        defer { JobCenter.shared.end("psd") }
        let report: (String) -> Void = { s in JobCenter.shared.detail("psd", s); progress?(s) }
        try BackgroundGate.during { try doc.withFullResolution { try writeNow(doc, to: url, options: options, progress: report) } }
    }

    /// Timing (DUOCHROME_PSDLOG): render and compression totals
    static var tRender = 0.0, tPack = 0.0

    private static func writeNow(_ doc: RawDocument, to url: URL, options: Options, progress: ((String) -> Void)?) throws {
        tRender = 0; tPack = 0
        let tAll = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["DUOCHROME_PSDLOG"] != nil {
                print(String(format: "PSD: 전체 %.1f초, 그리기 %.1f초, 압축·정리 %.1f초", CACurrentMediaTime() - tAll, tRender, tPack))
            }
        }
        let saved = doc.settings, savedFull = doc.showFullFrame
        defer { doc.settings = saved; doc.showFullFrame = savedFull; Render.exportContext.clearCaches(); Render.context.clearCaches() }
        doc.showFullFrame = false
        doc.settleForExport()
        doc.freezeDecodes = true
        defer { doc.freezeDecodes = false }
        let s = doc.settings
        let final = doc.image(scale: 1)
        let rect = final.extent.integral
        let W = Int(rect.width), H = Int(rect.height)
        let depth = options.depth == 16 ? 16 : 8
        let psb = options.psb ?? (W > 30000 || H > 30000 || W * H * 4 * (depth / 8) > 1_800_000_000)
        guard W > 0, H > 0, psb || (W <= 30000 && H <= 30000) else { throw PSD.Failure(message: "문서가 너무 커서 PSD로 쓸 수 없습니다 (PSB를 고르세요)") }
        let eff = SliderResponse.effective(s)
        let shape: (CIImage, CGFloat) -> CIImage = { m, sc in Geometry.crop(eff, Geometry.transform(eff, m, scale: sc)) }
        let clear = CIImage(color: .clear).cropped(to: rect)
        let gamma = s.gammaBlend ?? false

        /// Composite with only the first part of the layer list enabled (including the photo)
        func composite(_ layers: [AdjustLayer]) -> CIImage {
            var t = saved
            t.layers = layers
            doc.settings = t
            return doc.image(scale: 1)
        }

        var outs: [Out] = []
        // background
        progress?("배경")
        var bgSettings = saved; bgSettings.layers = []
        doc.settings = bgSettings
        let bg = doc.image(scale: 1)
        var bgLayer = PSD.Layer()
        bgLayer.name = "배경"
        let bgCh = autoreleasepool { channels(bg, rect: rect, depth: depth, psb: psb, alpha: false) }
        bgLayer.top = 0; bgLayer.left = 0; bgLayer.bottom = Int32(H); bgLayer.right = Int32(W)
        outs.append(Out(layer: bgLayer, data: bgCh.data))

        let byID = Dictionary(saved.layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func chain(_ l: AdjustLayer) -> [String] {
            var c: [String] = []
            var p = l.group
            while let g = p, c.count < 32 { c.insert(g, at: 0); p = byID[g]?.group }
            return c
        }
        var open: [String] = []
        for (i, layer) in saved.layers.enumerated() { autoreleasepool {
            progress?("레이어 \(i + 1)/\(saved.layers.count): \(layer.name)")
            // Open the group this layer belongs to (group end divider)
            let c = chain(layer)
            for g in c where !open.contains(g) {
                var d = PSD.Layer()
                d.name = "</Layer group>"
                d.flags = 0x18
                d.blocks = [("lsct", u32Data(3))]
                outs.append(Out(layer: d, data: emptyChannels()))
                open.append(g)
            }
            var rec = PSD.Layer()
            rec.name = layer.name
            rec.opacity = UInt8(max(0, min(255, (layer.opacity * 255).rounded())))
            rec.flags = layer.enabled ? 0x08 : 0x0A
            rec.clipping = layer.clipped ? 1 : 0
            rec.blocks = [("luni", unicodeData(layer.name))]
            // mask (only when it has a shape)
            var maskData: (PSD.Mask, Data)?
            if layer.mask.kind != .full || layer.mask.combos != nil || layer.mask.invert || layer.mask.hasLumaRange {
                // Only luma range, color range, and refine edge need pixels of the composite below (the rest use size only)
                let needsPixels = layer.mask.hasLumaRange || (layer.mask.colorRange?.count ?? 0) >= 4 || (layer.mask.refine ?? 0) >= 0.5
                let base = needsPixels ? composite(Array(saved.layers.prefix(i))) : clear
                let m = Layers.maskImage(layer.mask, scale: 1, native: doc.nativeSize, shape: shape, base: base)
                maskData = maskChannel(m, rect: rect, depth: depth, psb: psb)
            }
            if layer.isGroup {
                if let idx = open.lastIndex(of: layer.id) { open.remove(at: idx) }
                rec.blend = layer.blend == Layers.passThroughKey ? "pass" : PSD.psdBlend(layer.blend)
                var lsct = PSD.Writer()
                lsct.u32(1); lsct.key("8BIM"); lsct.key(rec.blend)
                rec.blocks.append(("lsct", lsct.data))
                var ch = emptyChannels()
                if let (m, d) = maskData { rec.mask = m; ch.append((-2, d)) }
                outs.append(Out(layer: rec, data: ch))
                return
            }
            rec.blend = PSD.psdBlend(layer.blend)
            if rec.blend == "pass" { rec.blend = "norm" }
            if let native = nativeAdjustment(layer) {
                // PSD adjustment layer
                rec.blocks.append(native)
                var ch = emptyChannels()
                if let (m, d) = maskData { rec.mask = m; ch.append((-2, d)) }
                outs.append(Out(layer: rec, data: ch))
                return
            }
            let content: CIImage
            if layer.isImage || layer.isFill || layer.isText || layer.kind == "shape" {
                var solo = layer
                solo.mask = LayerMask(); solo.opacity = 1; solo.blend = "normal"; solo.clipped = false; solo.group = nil; solo.enabled = true
                solo.blendIf = nil
                content = Layers.apply([solo], to: clear, guide: clear, scale: 1, guideScale: 1, native: doc.nativeSize, shape: shape, gamma: gamma)
            } else {
                // Adjustment/duplicate layers: bake the result of fully applying this layer to the composite below
                var solo = layer
                solo.mask = LayerMask(); solo.opacity = 1; solo.enabled = true; solo.blendIf = nil
                content = composite(Array(saved.layers.prefix(i)) + [solo])
                rec.blend = "norm"
                rec.name += " (구움)"
                rec.blocks = [("luni", unicodeData(rec.name))]
            }
            let ch = channels(content, rect: rect, depth: depth, psb: psb, alpha: true, crop: true)
            rec.top = Int32(ch.bounds.minY); rec.left = Int32(ch.bounds.minX)
            rec.bottom = Int32(ch.bounds.maxY); rec.right = Int32(ch.bounds.maxX)
            var data = ch.data
            if let (m, d) = maskData { rec.mask = m; data.append((-2, d)) }
            outs.append(Out(layer: rec, data: data))
        } }
        // Unclosed group (group layer missing): close it as an unnamed group
        for _ in open.reversed() {
            var g = PSD.Layer(); g.name = "그룹"; g.blend = "pass"
            var lsct = PSD.Writer(); lsct.u32(1); lsct.key("8BIM"); lsct.key("pass")
            g.blocks = [("lsct", lsct.data)]
            outs.append(Out(layer: g, data: emptyChannels()))
        }
        doc.settings = saved
        progress?("합친 그림")
        let merged = autoreleasepool { channels(final, rect: rect, depth: depth, psb: psb, alpha: false, merged: true) }
        try assemble(outs, merged: merged.data, width: W, height: H, depth: depth, psb: psb, to: url)
    }

    // MARK: - Can it be written as a PSD adjustment layer

    private static func nativeAdjustment(_ l: AdjustLayer) -> (key: String, data: Data)? {
        guard l.kind == "adjust" else { return nil }
        // Adjustments imported from PSD and untouched except for the LUT
        if let raw = l.psdBlock, let colon = raw.firstIndex(of: ":") {
            var a = l.adjust; a.lut = ""; a.invert = 0
            if a == LocalAdjust(), let d = Data(base64Encoded: String(raw[raw.index(after: colon)...])) {
                return (String(raw[..<colon]), d)
            }
        }
        var bare = l.adjust
        let inv = bare.invert >= 0.5, post = bare.posterize, thr = bare.threshold
        bare.invert = 0; bare.posterize = 0; bare.threshold = 0
        guard bare == LocalAdjust() else { return nil }
        let used = [inv, post >= 2, thr > 0].filter { $0 }.count
        guard used == 1 else { return nil }
        if inv { return ("nvrt", Data()) }
        var w = PSD.Writer()
        if post >= 2 { w.u16(UInt16(post)); w.u16(0); return ("post", w.data) }
        w.u16(UInt16(thr)); w.u16(0); return ("thrs", w.data)
    }

    // MARK: - Channels

    private static func emptyChannels() -> [(Int16, Data)] {
        [(-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0]))]
    }

    private static func u32Data(_ v: UInt32) -> Data { var w = PSD.Writer(); w.u32(v); return w.data }
    private static func unicodeData(_ s: String) -> Data { var w = PSD.Writer(); w.unicode(s); return w.data }

    /// Image → sRGB planar channels (alpha unpremultiplied). With crop, only the rectangle that has alpha.
    private static func channels(_ img: CIImage, rect: CGRect, depth: Int, psb: Bool, alpha: Bool, crop: Bool = false,
                                 merged: Bool = false) -> (data: [(Int16, Data)], bounds: CGRect) {
        let W = Int(rect.width), H = Int(rect.height)
        let bps = depth / 8
        var buf = [UInt8](repeating: 0, count: W * H * 4 * bps)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let src = img.cropped(to: rect).composited(over: CIImage(color: .clear).cropped(to: rect))
        let tr = CACurrentMediaTime()
        buf.withUnsafeMutableBytes { p in
            Render.exportContext.render(src, toBitmap: p.baseAddress!, rowBytes: W * 4 * bps, bounds: rect,
                                  format: bps == 2 ? .RGBA16 : .RGBA8, colorSpace: space)
        }
        tRender += CACurrentMediaTime() - tr
        Render.exportContext.clearCaches()
        let tp = CACurrentMediaTime()
        defer { tPack += CACurrentMediaTime() - tp }
        // Core Image results are premultiplied. PSD uses unpremultiplied color.
        // Unpremultiply, byte-swap, and bounds search are split into row bands across cores (it used to scan 45 MP three times in one pass)
        let lanes = max(1, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))
        let rowsPer = (H + lanes - 1) / lanes
        var bounds = [(Int, Int, Int, Int)](repeating: (W, H, 0, 0), count: lanes)
        buf.withUnsafeMutableBufferPointer { b in
            let base = b.baseAddress!
            bounds.withUnsafeMutableBufferPointer { bb in
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    let ya = lane * rowsPer, yb = min(H, ya + rowsPer)
                    guard ya < yb else { return }
                    var bx0 = W, by0 = H, bx1 = 0, by1 = 0
                    for y in ya ..< yb {
                        let row = y * W * 4
                        if bps == 1 {
                            for x in 0 ..< W {
                                let i = row + x * 4
                                let a = Int(base[i + 3])
                                if a != 0 { bx0 = min(bx0, x); bx1 = max(bx1, x + 1); by0 = min(by0, y); by1 = max(by1, y + 1) }
                                guard alpha, a > 0, a < 255 else { continue }
                                for c in 0 ..< 3 { base[i + c] = UInt8(min(255, (Int(base[i + c]) * 255 + a / 2) / a)) }
                            }
                        } else {
                            base.withMemoryRebound(to: UInt16.self, capacity: b.count / 2) { h in
                                for x in 0 ..< W {
                                    let i = row + x * 4
                                    let a = Int(h[i + 3])
                                    if a != 0 { bx0 = min(bx0, x); bx1 = max(bx1, x + 1); by0 = min(by0, y); by1 = max(by1, y + 1) }
                                    if alpha, a > 0, a < 65535 {
                                        for c in 0 ..< 3 { h[i + c] = UInt16(min(65535, (Int(h[i + c]) * 65535 + a / 2) / a)) }
                                    }
                                    // 16-bit: the Mac is little-endian, PSD is big-endian
                                    for c in 0 ..< 4 { h[i + c] = h[i + c].byteSwapped }
                                }
                            }
                        }
                    }
                    bb[lane] = (bx0, by0, bx1, by1)
                }
            }
        }
        var x0 = 0, y0 = 0, x1 = W, y1 = H
        if crop {
            x0 = bounds.map(\.0).min() ?? W; y0 = bounds.map(\.1).min() ?? H
            x1 = bounds.map(\.2).max() ?? 0; y1 = bounds.map(\.3).max() ?? 0
            if x1 <= x0 || y1 <= y0 { return (emptyChannels(), .zero) }
        }
        let w = x1 - x0, h = y1 - y0
        let ids: [Int16] = alpha ? [-1, 0, 1, 2] : [0, 1, 2]
        var out: [(Int16, Data)] = []
        var rows: [[UInt8]] = []
        // compress the channels (3–4) concurrently
        var packed = [(rows: [UInt8], counts: [Int])](repeating: ([], []), count: ids.count)
        buf.withUnsafeBufferPointer { src in
            packed.withUnsafeMutableBufferPointer { pk in
                DispatchQueue.concurrentPerform(iterations: ids.count) { ci in
                    let comp = ids[ci] == -1 ? 3 : Int(ids[ci])
                    var planeRows: [UInt8] = []
                    planeRows.reserveCapacity(w * (y1 - y0) * bps / 2)
                    var counts: [Int] = []
                    counts.reserveCapacity(y1 - y0)
                    var row = [UInt8](repeating: 0, count: w * bps)
                    for y in y0 ..< y1 {
                        let base = y * W * 4 * bps
                        for x in 0 ..< w {
                            let si = base + ((x + x0) * 4 + comp) * bps
                            for k in 0 ..< bps { row[x * bps + k] = src[si + k] }
                        }
                        let before = planeRows.count
                        row.withUnsafeBufferPointer { PSD.packBitsEncode($0, into: &planeRows) }
                        counts.append(planeRows.count - before)
                    }
                    pk[ci] = (planeRows, counts)
                }
            }
        }
        for (ci, id) in ids.enumerated() {
            let planeRows = packed[ci].rows, counts = packed[ci].counts
            packed[ci] = ([], [])   // Free immediately after moving (it held two copies of all four channels)
            if merged {
                rows.append(planeRows)
                out.append((id, Data(counts.flatMap { psb ? be32($0) : be16($0) })))
                continue
            }
            var d = Data([0, 1])
            for c in counts { d.append(contentsOf: psb ? be32(c) : be16(c)) }
            d.append(contentsOf: planeRows)
            out.append((id, d))
        }
        if merged {
            // Merged image: all channels' row lengths first, then the data
            var d = Data([0, 1])
            for (_, c) in out { d.append(c) }
            for r in rows { d.append(contentsOf: r) }
            return ([(0, d)], CGRect(x: x0, y: y0, width: w, height: h))
        }
        // Bitmaps have 0 at the top, so the rect is top-based too
        return (out, CGRect(x: x0, y: y0, width: w, height: h))
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    private static func maskChannel(_ m: CIImage, rect: CGRect, depth: Int, psb: Bool) -> (PSD.Mask, Data) {
        let W = Int(rect.width), H = Int(rect.height)
        let bps = depth / 8
        var buf = [UInt8](repeating: 0, count: W * H * 4 * bps)
        buf.withUnsafeMutableBytes { p in
            Render.exportContext.render(m.cropped(to: rect), toBitmap: p.baseAddress!, rowBytes: W * 4 * bps, bounds: rect,
                                  format: bps == 2 ? .RGBA16 : .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var d = Data([0, 1]), rowsData: [UInt8] = []
        var counts: [Int] = []
        // Compress each row band separately and concatenate in order (multiple cores)
        let lanes = max(1, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))
        let rowsPer = (H + lanes - 1) / lanes
        var parts = [(rows: [UInt8], counts: [Int])](repeating: ([], []), count: lanes)
        buf.withUnsafeBufferPointer { src in
            parts.withUnsafeMutableBufferPointer { pt in
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    let ya = lane * rowsPer, yb = min(H, ya + rowsPer)
                    guard ya < yb else { return }
                    var out: [UInt8] = [], cs: [Int] = []
                    var row = [UInt8](repeating: 0, count: W * bps)
                    for y in ya ..< yb {
                        for x in 0 ..< W {
                            let si = (y * W + x) * 4 * bps
                            if bps == 2 { row[x * 2] = src[si + 1]; row[x * 2 + 1] = src[si] } else { row[x] = src[si] }
                        }
                        let before = out.count
                        row.withUnsafeBufferPointer { PSD.packBitsEncode($0, into: &out) }
                        cs.append(out.count - before)
                    }
                    pt[lane] = (out, cs)
                }
            }
        }
        for p in parts { rowsData.append(contentsOf: p.rows); counts.append(contentsOf: p.counts) }
        for c in counts { d.append(contentsOf: psb ? be32(c) : be16(c)) }
        d.append(contentsOf: rowsData)
        var mask = PSD.Mask()
        mask.top = 0; mask.left = 0; mask.bottom = Int32(H); mask.right = Int32(W)
        mask.defaultColor = 0
        return (mask, d)
    }

    // MARK: - Assembling the file

    /// Writes to the file sequentially (it used to concatenate ~700 MB of layer data in memory three times before saving)
    private static func assemble(_ outs: [Out], merged: [(Int16, Data)], width W: Int, height H: Int, depth: Int, psb: Bool, to url: URL) throws {
        // layer records (small)
        var rec = PSD.Writer()
        rec.i16(Int16(outs.count))
        for o in outs {
            let l = o.layer
            rec.i32(l.top); rec.i32(l.left); rec.i32(l.bottom); rec.i32(l.right)
            rec.u16(UInt16(o.data.count))
            for (id, d) in o.data { rec.i16(id); rec.len(d.count, psb) }
            rec.key("8BIM"); rec.key(l.blend)
            rec.u8(l.opacity); rec.u8(l.clipping); rec.u8(l.flags); rec.u8(0)
            var extra = PSD.Writer()
            if let m = l.mask {
                extra.u32(20)
                extra.i32(m.top); extra.i32(m.left); extra.i32(m.bottom); extra.i32(m.right)
                extra.u8(m.defaultColor); extra.u8(m.flags); extra.u16(0)
            } else {
                extra.u32(0)
            }
            extra.u32(0)   // blending ranges
            extra.pascal(l.name, pad: 4)
            for (k, d) in l.blocks {
                extra.key("8BIM"); extra.key(k)
                let padded = (d.count + 3) / 4 * 4
                extra.len(padded, psb && PSD.longKeys.contains(k))
                extra.bytes(d)
                for _ in d.count ..< padded { extra.u8(0) }
            }
            rec.u32(UInt32(extra.data.count)); rec.bytes(extra.data)
        }
        let channelBytes = outs.reduce(0) { $0 + $1.data.reduce(0) { $0 + $1.1.count } }
        let raw = rec.data.count + channelBytes
        let pad = (4 - raw % 4) % 4
        let liLen = raw + pad
        var lmHead = PSD.Writer(), lmTail = PSD.Writer()
        if depth == 16 {
            // 16-bit documents: layers inside the Lr16 block
            lmHead.len(0, psb); lmHead.u32(0)
            lmHead.key("8BIM"); lmHead.key("Lr16"); lmHead.len(liLen, psb)
        } else {
            lmHead.len(liLen, psb)
            lmTail.u32(0)   // global layer mask
        }
        var head = PSD.Writer()
        head.key("8BPS"); head.u16(psb ? 2 : 1); head.bytes(Data(count: 6))
        head.u16(3); head.u32(UInt32(H)); head.u32(UInt32(W)); head.u16(UInt16(depth)); head.u16(3)
        head.u32(0)   // color mode data
        // image resources: ICC (sRGB)
        var res = PSD.Writer()
        if let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? {
            res.key("8BIM"); res.u16(1039); res.u16(0)
            res.u32(UInt32(icc.count)); res.bytes(icc)
            if icc.count % 2 == 1 { res.u8(0) }
        }
        head.u32(UInt32(res.data.count)); head.bytes(res.data)
        head.len(lmHead.data.count + liLen + lmTail.data.count, psb)
        // Write to a temp file in the same folder and swap (the old file survives a failure midway)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let h = try FileHandle(forWritingTo: tmp)
        do {
            try h.write(contentsOf: head.data)
            try h.write(contentsOf: lmHead.data)
            try h.write(contentsOf: rec.data)
            for o in outs { for (_, d) in o.data { try h.write(contentsOf: d) } }
            if pad > 0 { try h.write(contentsOf: Data(count: pad)) }
            try h.write(contentsOf: lmTail.data)
            for (_, d) in merged { try h.write(contentsOf: d) }
            try h.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? h.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

extension MainWindowController {
    /// File → Export as PSD (PSD/PSB)
    @objc func exportPSD(_ sender: Any?) {
        guard let doc = photo, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (doc.url.lastPathComponent as NSString).deletingPathExtension + ".psd"
        panel.allowedContentTypes = [UTType(filenameExtension: "psd") ?? .data, UTType(filenameExtension: "psb") ?? .data]
        panel.message = "레이어째 PSD로 씁니다. 현상 조정처럼 PSD에 담을 수 없는 조정은 픽셀 레이어로 굽습니다."
        let depth = NSPopUpButton()
        depth.addItems(withTitles: ["8비트", "16비트"])
        depth.selectItem(at: UserDefaults.standard.integer(forKey: "psd.depth"))
        let box = NSStackView(views: [NSTextField(labelWithString: "비트 수:"), depth])
        box.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = box
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(depth.indexOfSelectedItem, forKey: "psd.depth")
            var o = PSDExport.Options()
            o.depth = depth.indexOfSelectedItem == 1 ? 16 : 8
            if url.pathExtension.lowercased() == "psb" { o.psb = true }
            self.window?.subtitle = "PSD 쓰는 중…"
            do {
                try PSDExport.write(doc, to: url, options: o) { NSLog("PSD: %@", $0) }
                self.window?.subtitle = doc.url.lastPathComponent
            } catch {
                self.window?.subtitle = doc.url.lastPathComponent
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}
