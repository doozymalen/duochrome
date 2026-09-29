import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Preset file import: brushes (.abr), gradients (.grd), patterns (.pat), swatches (.aco).
/// Imported items are gathered in the preset folder (`~/Library/Application Support/Duochrome/Presets`)
/// and used by the mask brush, fill layers, gradient maps, and color pickers.
enum PresetFiles {
    struct Swatch: Codable, Equatable { var name: String; var rgb: [Float] }
    struct Gradient: Codable, Equatable {
        var name: String
        /// (position 0–1, midpoint 0–1, r, g, b) repeated
        var stops: [Float]
    }
    struct Pattern: Codable, Equatable { var name: String; var file: String; var width: Int; var height: Int }
    struct Brush: Codable, Equatable { var name: String; var file: String; var width: Int; var height: Int; var spacing: Float }

    struct Library: Codable {
        var swatches: [Swatch] = []
        var gradients: [Gradient] = []
        var patterns: [Pattern] = []
        var brushes: [Brush] = []
    }

    // MARK: - Storage

    static var folder: URL = {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if env["DUOCHROME_SELFTEST"] != nil || env["DUOCHROME_SNAPSHOT"] != nil || env["DUOCHROME_CATALOG_TEST"] != nil {
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test-presets")
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Duochrome/Presets", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var cached: Library?
    static var library: Library {
        get {
            if let c = cached { return c }
            let l = (try? Data(contentsOf: folder.appendingPathComponent("library.json")))
                .flatMap { try? JSONDecoder().decode(Library.self, from: $0) } ?? Library()
            cached = l
            return l
        }
        set {
            cached = newValue
            if let d = try? JSONEncoder().encode(newValue) { try? d.write(to: folder.appendingPathComponent("library.json")) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static let changed = Notification.Name("DuochromePresetsChanged")

    static func url(_ file: String) -> URL { folder.appendingPathComponent(file) }

    /// Imports one file into the library. Returns a description of how many were added.
    @discardableResult
    static func importFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let base = url.deletingPathExtension().lastPathComponent
        var lib = library
        switch url.pathExtension.lowercased() {
        case "aco":
            let s = try readACO(data)
            lib.swatches += s
            library = lib
            return "견본 \(s.count)개"
        case "grd":
            let g = try readGRD(data)
            lib.gradients += g
            library = lib
            return "그라디언트 \(g.count)개"
        case "pat":
            let p = try readPAT(data, prefix: base)
            lib.patterns += p
            library = lib
            return "패턴 \(p.count)개"
        case "abr":
            let b = try readABR(data, prefix: base)
            lib.brushes += b
            library = lib
            return "브러시 \(b.count)개"
        default:
            throw PSD.Failure(message: "\(url.lastPathComponent): 알 수 없는 프리셋 형식")
        }
    }

    static func writeGray(_ pixels: [UInt8], width w: Int, height h: Int, to dir: URL, name: String) -> String? {
        guard let prov = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return writePNG(cg, to: dir, name: name)
    }

    static func writePNG(_ cg: CGImage, to dir: URL, name: String) -> String? {
        let file = name + ".png"
        guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(file) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? file : nil
    }

    // MARK: - Swatches .aco

    static func readACO(_ d: Data) throws -> [Swatch] {
        var r = PSD.Reader(d)
        var v1: [SIMD3<Float>] = []
        let ver = try r.u16()
        guard ver == 1 || ver == 2 else { throw PSD.Failure(message: "견본 파일이 아닙니다") }
        let n = Int(try r.u16())
        func color(_ space: UInt16, _ a: UInt16, _ b: UInt16, _ c: UInt16, _ dd: UInt16) -> SIMD3<Float> {
            let fa = Float(a) / 65535, fb = Float(b) / 65535, fc = Float(c) / 65535, fd = Float(dd) / 65535
            switch space {
            case 0: return SIMD3(fa, fb, fc)
            case 1: // HSB
                let rgb = NSColor(hue: CGFloat(fa), saturation: CGFloat(fb), brightness: CGFloat(fc), alpha: 1)
                return SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
            case 2: // CMYK (0 is full ink)
                let k = 1 - fd
                return SIMD3(fa * k, fb * k, fc * k)
            case 7: // Lab: L 0~10000, a·b −12800~12700
                return PSDAdjust.fromLab(SIMD3(Float(a) / 100, Float(Int16(bitPattern: b)) / 100, Float(Int16(bitPattern: c)) / 100))
            case 8: let g = 1 - Float(a) / 10000; return SIMD3(g, g, g)
            default: return SIMD3(fa, fb, fc)
            }
        }
        for _ in 0 ..< n {
            let s = try r.u16(); let a = try r.u16(), b = try r.u16(), c = try r.u16(), e = try r.u16()
            v1.append(color(s, a, b, c, e))
        }
        var names = Array(repeating: "", count: n)
        var colors = v1
        // names are present when version 2 follows
        if ver == 1, r.remaining >= 4, (try? r.u16()) == 2 {
            let n2 = Int(try r.u16())
            colors = []; names = []
            for _ in 0 ..< n2 {
                let s = try r.u16(); let a = try r.u16(), b = try r.u16(), c = try r.u16(), e = try r.u16()
                colors.append(color(s, a, b, c, e))
                names.append(try r.unicode())
            }
        } else if ver == 2 {
            // Files with only version 2: names weren't skipped above, so read again
            var r2 = PSD.Reader(d); _ = try r2.u16(); _ = try r2.u16()
            colors = []; names = []
            for _ in 0 ..< n {
                let s = try r2.u16(); let a = try r2.u16(), b = try r2.u16(), c = try r2.u16(), e = try r2.u16()
                colors.append(color(s, a, b, c, e))
                names.append(try r2.unicode())
            }
        }
        return zip(names, colors).map { Swatch(name: $0.0, rgb: [$0.1.x, $0.1.y, $0.1.z]) }
    }

    // MARK: - Gradients .grd (version 5, descriptor)

    static func readGRD(_ d: Data) throws -> [Gradient] {
        var r = PSD.Reader(d)
        guard try r.key() == "8BGR" else { throw PSD.Failure(message: "그라디언트 파일이 아닙니다") }
        let ver = try r.u16()
        guard ver == 5 else { throw PSD.Failure(message: "옛 그라디언트 형식(판 \(ver))은 읽지 못합니다") }
        _ = try r.u32()
        let desc = try PSD.descriptor(&r)
        var out: [Gradient] = []
        for v in desc["GrdL"]?.list ?? [] {
            guard let g = v.object?.obj("Grad") else { continue }
            let stops = PSDImport.gradientStops(g)
            guard stops.count >= 2 else { continue }   // noise gradients have no color list
            out.append(Gradient(name: g["Nm  "]?.string.map(cleanName) ?? "그라디언트",
                                stops: stops.flatMap { [$0.loc, $0.mid, $0.color.x, $0.color.y, $0.color.z] }))
        }
        return out
    }

    /// "$$$/Gradients/Name=Blue" → "Blue"
    static func cleanName(_ s: String) -> String {
        if s.hasPrefix("$$$"), let eq = s.firstIndex(of: "=") { return String(s[s.index(after: eq)...]) }
        return s
    }

    static func stops(_ g: Gradient) -> [PSDAdjust.GradientStop] {
        stride(from: 0, to: g.stops.count - 4, by: 5).map {
            PSDAdjust.GradientStop(loc: g.stops[$0], mid: g.stops[$0 + 1], color: SIMD3(g.stops[$0 + 2], g.stops[$0 + 3], g.stops[$0 + 4]))
        }
    }

    // MARK: - Patterns .pat

    static func readPAT(_ d: Data, prefix: String) throws -> [Pattern] {
        var r = PSD.Reader(d)
        guard try r.key() == "8BPT" else { throw PSD.Failure(message: "패턴 파일이 아닙니다") }
        _ = try r.u16()
        let n = Int(try r.u32())
        var out: [Pattern] = []
        for i in 0 ..< n {
            guard let p = try readPattern(&r, into: folder, fallbackName: "\(prefix) \(i + 1)", hasLength: false) else { continue }
            out.append(p.0)
        }
        return out
    }

    /// One pattern (length + version + mode + size + name + unique id + virtual memory array). The second return value is the unique id.
    static func readPattern(_ r: inout PSD.Reader, into dir: URL, fallbackName: String, hasLength: Bool = true) throws -> (Pattern, String)? {
        // Inside PSD (Patt) a length is prefixed; .pat files have none (the end is known from the virtual memory array length)
        var end: Int?
        if hasLength {
            let len = Int(try r.u32())
            end = r.pos + (len + 3) / 4 * 4
        }
        var vmaEnd = r.pos
        defer { r.pos = end ?? vmaEnd }
        _ = try r.u32()
        let mode = try r.u32()
        let h = Int(try r.u16()), w = Int(try r.u16())
        let name = cleanName(try r.unicode())
        let id = try r.pascal(pad: 1)
        var palette: [UInt8] = []
        if mode == 2 { palette = [UInt8](try r.bytes(768)); try r.skip(4) }
        // virtual memory array
        _ = try r.u32()
        let vmaLen = Int(try r.u32())
        vmaEnd = r.pos + vmaLen
        let top = Int(try r.i32()), left = Int(try r.i32()), bottom = Int(try r.i32()), right = Int(try r.i32())
        let nch = Int(try r.u32())
        let pw = right - left, ph = bottom - top
        guard pw > 0, ph > 0 else { return nil }
        var planes: [[UInt8]] = []
        for _ in 0 ..< nch + 2 {
            guard r.remaining >= 4 else { break }
            let written = try r.u32()
            guard written != 0 else { continue }
            let clen = Int(try r.u32())
            guard clen > 0 else { continue }
            let cstart = r.pos
            let depth = Int(try r.u32())
            let ct = Int(try r.i32()), cl = Int(try r.i32()), cb = Int(try r.i32()), cr = Int(try r.i32())
            _ = try r.u16()
            let comp = try r.u8()
            let cw = cr - cl, chh = cb - ct
            let bpp = max(depth / 8, 1)
            let payload = try r.bytes(clen - (r.pos - cstart))
            var plane: [UInt8]
            if comp == 1 {
                plane = PSD.decode(PSD.Channel(id: 0, compression: 1, payload: payload), width: cw, height: chh, depth: depth, big: false) ?? []
            } else {
                plane = [UInt8](payload.prefix(cw * chh * bpp))
            }
            if bpp == 2 { plane = stride(from: 0, to: plane.count, by: 2).map { plane[$0] } }
            if plane.count == pw * ph { planes.append(plane) }
            r.pos = cstart + clen
        }
        var rgba = [UInt8](repeating: 255, count: pw * ph * 4)
        switch mode {
        case 1, 8:
            guard let g = planes.first else { return nil }
            for i in 0 ..< pw * ph { rgba[i * 4] = g[i]; rgba[i * 4 + 1] = g[i]; rgba[i * 4 + 2] = g[i] }
        case 2:
            guard let g = planes.first else { return nil }
            for i in 0 ..< pw * ph { let k = Int(g[i]); rgba[i * 4] = palette[k]; rgba[i * 4 + 1] = palette[256 + k]; rgba[i * 4 + 2] = palette[512 + k] }
        default:
            guard planes.count >= 3 else { return nil }
            for i in 0 ..< pw * ph { for c in 0 ..< 3 { rgba[i * 4 + c] = planes[c][i] } }
            if planes.count >= 4 { for i in 0 ..< pw * ph { rgba[i * 4 + 3] = planes[3][i] } }
        }
        guard let prov = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let file = writePNG(cg, to: dir, name: "pattern-" + UUID().uuidString) else { return nil }
        _ = (w, h)
        return (Pattern(name: name.isEmpty ? fallbackName : name, file: file, width: pw, height: ph), id)
    }

    /// Extracts the pattern with a matching unique id from a PSD's patterns (Patt/Pat2/Pat3) as PNG into the layer image folder
    static func documentPattern(_ f: PSD.File, id: String) -> String? {
        for key in ["Patt", "Pat2", "Pat3"] {
            guard let d = f.globalBlock(key) else { continue }
            var r = PSD.Reader(d)
            while r.remaining > 16 {
                guard let (p, pid) = (try? readPattern(&r, into: LayerImageStore.folder, fallbackName: "패턴")) ?? nil else { break }
                if pid == id { return p.file }
                try? FileManager.default.removeItem(at: LayerImageStore.url(p.file))
            }
        }
        return nil
    }

    // MARK: - Brushes .abr

    static func readABR(_ d: Data, prefix: String) throws -> [Brush] {
        var r = PSD.Reader(d)
        let ver = try r.u16()
        var out: [Brush] = []
        if ver == 1 || ver == 2 {
            // old format: count, (type, size, data)
            let n = Int(try r.u16())
            for i in 0 ..< n {
                let type = try r.u16(); let size = Int(try r.u32())
                let start = r.pos
                defer { r.pos = start + size }
                guard type == 2 else { continue }   // skip type 1 computed brushes
                _ = try r.u32()
                let spacing = Float(try r.u16())
                if ver == 2 { _ = try r.unicode() }
                _ = try r.u8()
                try r.skip(8)
                let top = Int(try r.i32()), left = Int(try r.i32()), bottom = Int(try r.i32()), right = Int(try r.i32())
                let depth = Int(try r.u16()); let comp = try r.u8()
                if let b = brushTip(&r, top: top, left: left, bottom: bottom, right: right, depth: depth, comp: comp,
                                    name: "\(prefix) \(i + 1)", spacing: spacing) { out.append(b) }
            }
            return out
        }
        guard ver >= 6 else { throw PSD.Failure(message: "알 수 없는 브러시 판 \(ver)") }
        let sub = try r.u16()
        while r.remaining > 12 {
            guard try r.key() == "8BIM" else { break }
            let key = try r.key()
            let len = Int(try r.u32())
            let end = r.pos + len
            if key == "samp" {
                var i = 0
                while r.pos < end - 4 {
                    let size = Int(try r.u32())
                    let next = r.pos + (size + 3) / 4 * 4
                    // skip the unique id and an unknown header (47 bytes for subversion 1, 301 for 2)
                    try r.skip(sub == 1 ? 47 : 301)
                    let top = Int(try r.i32()), left = Int(try r.i32()), bottom = Int(try r.i32()), right = Int(try r.i32())
                    let depth = Int(try r.u16()); let comp = try r.u8()
                    i += 1
                    if let b = brushTip(&r, top: top, left: left, bottom: bottom, right: right, depth: depth, comp: comp,
                                        name: "\(prefix) \(i)", spacing: 25) { out.append(b) }
                    r.pos = next
                }
            }
            r.pos = (end + 3) / 4 * 4 > d.endIndex ? end : end
            if r.pos < d.endIndex, (r.pos - d.startIndex) % 2 == 1 { r.pos += 1 }
        }
        return out
    }

    private static func brushTip(_ r: inout PSD.Reader, top: Int, left: Int, bottom: Int, right: Int, depth: Int, comp: UInt8,
                                 name: String, spacing: Float) -> Brush? {
        let w = right - left, h = bottom - top
        guard w > 0, h > 0, w < 10000, h < 10000 else { return nil }
        let bpp = max(depth / 8, 1)
        var pix: [UInt8]
        if comp == 1 {
            var counts: [Int] = []
            for _ in 0 ..< h { guard let c = try? r.u16() else { return nil }; counts.append(Int(c)) }
            pix = []
            for c in counts {
                guard let row = try? r.bytes(c) else { return nil }
                pix.append(contentsOf: PSD.packBitsDecode(row, size: w * bpp))
            }
        } else {
            guard let raw = try? r.bytes(w * h * bpp) else { return nil }
            pix = [UInt8](raw)
        }
        if bpp == 2 { pix = stride(from: 0, to: pix.count, by: 2).map { pix[$0] } }
        guard pix.count == w * h, let file = writeGray(pix, width: w, height: h, to: folder, name: "brush-" + UUID().uuidString) else { return nil }
        return Brush(name: name, file: file, width: w, height: h, spacing: spacing)
    }

    // MARK: - Brush tip images

    private static var tipCache: [String: CGImage] = [:]
    private static let tipLock = NSLock()

    /// Brush tip (white, alpha = brush shape). Bright areas of the brush file are what gets painted.
    static func tip(_ file: String) -> CGImage? {
        tipLock.lock(); defer { tipLock.unlock() }
        if let hit = tipCache[file] { return hit }
        guard let src = CGImageSourceCreateWithURL(url(file) as CFURL, nil),
              let gray = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = gray.width, h = gray.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let mask = ctx.makeImage(),
              let alpha = CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                  provider: mask.dataProvider!, decode: [1, 0], shouldInterpolate: true),
              let white = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        white.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: alpha)
        white.setFillColor(CGColor(gray: 1, alpha: 1))
        white.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = white.makeImage() else { return nil }
        if tipCache.count > 32 { tipCache.removeAll() }
        tipCache[file] = img
        return img
    }

    /// Stamps the brush tip along a line (spacing as a fraction of diameter)
    static func stamp(_ ctx: CGContext, tip: CGImage, points: [CGPoint], diameter: CGFloat, spacing: CGFloat, alpha: CGFloat) {
        guard let first = points.first, diameter > 0.5 else { return }
        let aspect = CGFloat(tip.height) / CGFloat(max(tip.width, 1))
        let rect = { (p: CGPoint) in CGRect(x: p.x - diameter / 2, y: p.y - diameter * aspect / 2, width: diameter, height: diameter * aspect) }
        ctx.setAlpha(alpha)
        ctx.draw(tip, in: rect(first))
        let step = max(diameter * spacing, 0.5)
        var carry: CGFloat = 0
        var prev = first
        for p in points.dropFirst() {
            let dx = p.x - prev.x, dy = p.y - prev.y
            let dist = hypot(dx, dy)
            var t = step - carry
            while t <= dist {
                ctx.draw(tip, in: rect(CGPoint(x: prev.x + dx * t / dist, y: prev.y + dy * t / dist)))
                t += step
            }
            carry = dist - (t - step)
            prev = p
        }
        ctx.setAlpha(1)
    }
}
