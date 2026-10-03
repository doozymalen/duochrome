import Foundation
import ImageIO

/// External catalog (.cocatalog) import. **Read-only** — copies the catalog file to a temp folder and opens the copy.
///
/// Imports: photo list, album/group structure, ratings, color tags, thumbnail cache, some adjustments.
/// Photos whose files are missing are only marked "offline". No relinking from elsewhere.
///
/// Storage layout (verified with a 2026 catalog):
/// - ZCOLLECTION.Z_ENT: 2 album, 7 group/project, 8 special group (recent imports etc.), 36 folder
/// - Final adjustments are the ZVARIANTLAYER row pointed to by ZVARIANT.ZCOMBINEDSETTINGS
/// - Ratings/colors are in ZVARIANTMETADATA of ZVARIANT.ZDEFAULTLAYER
/// - Thumbnail cache Cache/Thumbnails/<8-digit variant id>.cot (not the photo id — the ranges overlap and attach the wrong photo)
/// - ZROTATION includes camera orientation: EXIF 6 is 90, 8 is 270 (or -90)
enum CatalogImport {
    struct Report {
        var images = 0, online = 0, offline = 0, trashedSkipped = 0
        var groups = 0, albums = 0, rated = 0, colored = 0, adjusted = 0, adjustSkippedExisting = 0
        var thumbs = 0
        var notes: [String] = []

        var summary: String {
            """
            사진 \(images)장 (원래 경로에 있음 \(online), 오프라인 \(offline)), 휴지통 제외 \(trashedSkipped)
            그룹 \(groups), 앨범 \(albums) · 별점 \(rated) · 색 태그 \(colored) · 썸네일 \(thumbs)
            조정값 \(adjusted)장 (이미 Duochrome에서 조정한 \(adjustSkippedExisting)장은 그대로 둠)
            """ + (notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n"))
        }
    }

    static func run(package: URL, into catalog: Catalog, library: Library,
                    progress: ((String) -> Void)? = nil) throws -> Report {
        var report = Report()
        let fm = FileManager.default
        guard let dbFile = (try fm.contentsOfDirectory(atPath: package.path)).first(where: { $0.hasSuffix(".cocatalogdb") }) else {
            throw SQLiteDB.Failure(message: "\(package.lastPathComponent) 안에 .cocatalogdb 파일이 없습니다")
        }
        let name = package.deletingPathExtension().lastPathComponent
        // Open the copy: doesn't touch the original's locks/journal even if another app has it open.
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-import-\(UUID().uuidString).db")
        try fm.copyItem(at: package.appendingPathComponent(dbFile), to: copy)
        defer { try? fm.removeItem(at: copy) }
        let srcDB = try SQLiteDB(path: copy.path, readOnly: true)
        progress?("카탈로그 읽는 중…")

        // paths
        var locations: [Int64: String] = [:]
        try srcDB.query("SELECT Z_PK, ZMACROOT, ZRELATIVEPATH FROM ZPATHLOCATION") { r in
            let root = r.text(1) ?? "", rel = r.text(2) ?? ""
            var path = root.isEmpty ? package.appendingPathComponent(rel).path : (root as NSString).appendingPathComponent(rel)
            if !path.hasPrefix("/") { path = "/" + path }
            locations[r.int(0)] = path
        }

        // photo + primary variant's rating, color, adjustment rows
        struct SourceImage {
            let pk: Int64; let path: String; let date: Double?; let camera: String?; let lens: String?
            var rating = 0, color = 0, combined: Int64 = 0, variant: Int64 = 0
        }
        var images: [Int64: SourceImage] = [:]
        try srcDB.query("""
            SELECT Z_PK, ZIMAGEFILENAME, ZIMAGELOCATION, ZISTRASHED, ZEXP_DATE, ZCAMERA_MODEL, ZCAMERA_LENS FROM ZIMAGE
            """) { r in
            if r.int(3) != 0 { report.trashedSkipped += 1; return }
            guard let dir = locations[r.int(2)], let file = r.text(1) else { return }
            images[r.int(0)] = SourceImage(pk: r.int(0), path: (dir as NSString).appendingPathComponent(file),
                                       date: r.optDouble(4), camera: r.text(5), lens: r.text(6))
        }
        try srcDB.query("""
            SELECT v.ZIMAGE, v.ZCOMBINEDSETTINGS, m.ZBASIC_RATING, m.ZCOLOR_TAG_INDEX, v.Z_PK FROM ZVARIANT v
            LEFT JOIN ZVARIANTMETADATA m ON m.ZLAYER = v.ZDEFAULTLAYER
            ORDER BY v.ZINDEX DESC
            """) { r in
            // With several variants, the first (lowest ZINDEX) overwrites last.
            guard var img = images[r.int(0)] else { return }
            img.combined = r.int(1)
            img.rating = Int(r.int(2))
            img.color = Int(r.int(3))
            img.variant = r.int(4)
            images[r.int(0)] = img
        }

        // Insert into the catalog
        progress?("사진 \(images.count)장 등록 중…")
        let thumbDir = package.appendingPathComponent("Cache/Thumbnails")
        let batch = try catalog.nextBatch()
        let now = Date().timeIntervalSince1970
        var idMap: [Int64: Int64] = [:]
        var online: [Int64: Bool] = [:]
        try catalog.db.transaction {
            for img in images.values {
                let exists = fm.fileExists(atPath: img.path)
                let thumb = thumbDir.appendingPathComponent(String(format: "%08lld.cot", img.variant)).path
                let hasThumb = fm.fileExists(atPath: thumb)
                let fid = try catalog.folderID((img.path as NSString).deletingLastPathComponent)
                try catalog.db.run("""
                    INSERT OR IGNORE INTO images(folder_id, filename, path, imported_at, import_batch, capture_date,
                        camera, lens, source, import_thumb, offline, rating, color)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, 'import', ?, ?, ?, ?)
                    """, [fid, (img.path as NSString).lastPathComponent, img.path, now, batch, img.date,
                          img.camera, img.lens, hasThumb ? thumb : nil, !exists, img.rating, img.color])
                let id = try catalog.db.scalar("SELECT id FROM images WHERE path = ?", [img.path])
                // For existing photos, keep Duochrome's rating/color and use imported values only when empty.
                try catalog.db.run("""
                    UPDATE images SET rating = CASE WHEN rating = 0 THEN ? ELSE rating END,
                        color = CASE WHEN color = 0 THEN ? ELSE color END,
                        import_thumb = COALESCE(import_thumb, ?), offline = ? WHERE id = ?
                    """, [img.rating, img.color, hasThumb ? thumb : nil, !exists, id])
                idMap[img.pk] = id
                online[img.pk] = exists
                report.images += 1
                if exists { report.online += 1 } else { report.offline += 1 }
                if img.rating > 0 { report.rated += 1 }
                if img.color > 0 { report.colored += 1 }
                if hasThumb { report.thumbs += 1 }
            }
        }

        // albums · groups
        progress?("앨범 구조 가져오는 중…")
        struct Coll { let pk: Int64; let ent: Int64; let name: String; let parent: Int64? }
        var colls: [Int64: Coll] = [:]
        try srcDB.query("SELECT Z_PK, Z_ENT, ZNAME, ZPARENT FROM ZCOLLECTION") { r in
            colls[r.int(0)] = Coll(pk: r.int(0), ent: r.int(1), name: r.text(2) ?? "",
                                   parent: r.isNull(3) ? nil : r.int(3))
        }
        let special: Set<String> = ["root", "All Images", "Recent Imports", "Recent Captures", "Trash", "Catalog"]
        let specialPKs = Set(colls.values.filter { special.contains($0.name) }.map(\.pk))
        let top = try catalog.addAlbum("가져옴 · \(name)", kind: 0, source: "import", key: "\(name):root")
        var albumMap: [Int64: Int64] = [:]
        func ensure(_ pk: Int64) throws -> Int64? {
            if let a = albumMap[pk] { return a }
            guard let c = colls[pk], !specialPKs.contains(pk), [2, 7, 8].contains(c.ent) else { return nil }
            // Skip automatic albums under recent imports / recent captures.
            if let p = c.parent, specialPKs.contains(p), colls[p]?.name != "root" { return nil }
            let parentID: Int64 = try c.parent.flatMap { specialPKs.contains($0) ? nil : try ensure($0) } ?? top
            let kind = c.ent == 2 ? 1 : 0
            let id = try catalog.addAlbum(c.name.isEmpty ? "이름 없음" : c.name, parent: parentID, kind: kind,
                                          source: "import", key: "\(name):\(pk)")
            if kind == 1 { report.albums += 1 } else { report.groups += 1 }
            albumMap[pk] = id
            return id
        }
        var members: [Int64: [Int64]] = [:]
        try srcDB.query("SELECT ZCOLLECTION, ZIMAGE FROM ZIMAGEINCOLLECTION") { r in
            if let id = idMap[r.int(1)] { members[r.int(0), default: []].append(id) }
        }
        for c in colls.values where [2, 7, 8].contains(c.ent) {
            guard let aid = try ensure(c.pk), let m = members[c.pk], colls[c.pk]?.ent == 2 else { continue }
            try catalog.addToAlbum(aid, m)
        }

        // adjustments
        progress?("조정값 옮기는 중…")
        var layers: [Int64: [String: Any]] = [:]
        let cols = ["ZEXPOSURE", "ZCONTRAST", "ZBRIGHTNESS", "ZSATURATION", "ZCLARITY", "ZCLARITYSTRUCTURE",
                    "ZHIGHLIGHTRECOVERY", "ZSHADOWRECOVERY", "ZWHITERECOVERY", "ZBLACKRECOVERY", "ZDEHAZEAMOUNT",
                    "ZROTATION", "ZFLIP", "ZGRADATIONCURVE", "ZGRADATIONCURVERED", "ZGRADATIONCURVEGREEN", "ZGRADATIONCURVEBLUE",
                    "ZLEVELSSHADOW", "ZLEVELSHIGHLIGHT", "ZFILMGRAINAMOUNT", "ZFILMGRAINGRANULARITY",
                    "ZBWENABLED", "ZBWRED", "ZBWYELLOW", "ZBWGREEN", "ZBWCYAN", "ZBWBLUE", "ZBWMAGENTA",
                    "ZBWDARKTONEHUE", "ZBWDARKTONESATURATION", "ZBWLIGHTTONEHUE", "ZBWLIGHTTONESATURATION",
                    "ZLENSVIGNETTING", "ZCOLORBALANCESHADOW", "ZCOLORBALANCEMIDTONE", "ZCOLORBALANCEHIGHLIGHT", "ZCOLORBALANCE",
                    "ZCROP", "ZWHITEBALANCE"]
        try srcDB.query("SELECT Z_PK, \(cols.joined(separator: ", ")) FROM ZVARIANTLAYER WHERE Z_PK IN (SELECT ZCOMBINEDSETTINGS FROM ZVARIANT WHERE ZISMODIFIED = 1)") { r in
            var d: [String: Any] = [:]
            for (i, c) in cols.enumerated() {
                let k = Int32(i + 1)
                if r.isNull(k) { continue }
                d[c] = r.text(k).flatMap { Double($0) } ?? r.text(k) ?? r.double(k)
            }
            layers[r.int(0)] = d
        }
        // As-shot white balance (base layer) and sensor size
        var shotWB: [Int64: String] = [:]
        try srcDB.query("SELECT v.Z_PK, d.ZWHITEBALANCE FROM ZVARIANT v JOIN ZVARIANTLAYER d ON d.Z_PK = v.ZDEFAULTLAYER") { r in
            if let t = r.text(1) { shotWB[r.int(0)] = t }
        }
        var sensor: [Int64: (Double, Double)] = [:]
        try srcDB.query("SELECT Z_PK, ZWIDTH, ZHEIGHT FROM ZIMAGE") { r in sensor[r.int(0)] = (r.double(1), r.double(2)) }
        for img in images.values {
            guard var d = layers[img.combined] else { continue }
            if let w = shotWB[img.variant] { d["SHOTWB"] = w }
            if let sz = sensor[img.pk] { d["SENSORW"] = sz.0; d["SENSORH"] = sz.1 }
            let url = URL(fileURLWithPath: img.path, isDirectory: false)
            if library.hasSettings(for: url) { report.adjustSkippedExisting += 1; continue }
            // Camera orientation: from EXIF if the source exists, else the nearest multiple of 90° from the rotation.
            var orientation: Int?
            if online[img.pk] == true,
               let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                orientation = p[kCGImagePropertyOrientation] as? Int
            }
            let dict = convert(d, orientation: orientation)
            guard !dict.isEmpty else { continue }
            library.saveRawSettings(dict, for: url)
            report.adjusted += 1
        }
        report.notes.append("화이트 밸런스·크롭·키스톤·로컬 레이어·스팟은 아직 옮기지 않았습니다 (저장 방식이 달라 변환식을 확인하는 중).")
        catalog.setMeta("import.\(name).importedAt", "\(now)")
        return report
    }

    /// Imported values → Duochrome settings fragment (JSON dictionary). Read on top of the as-shot values.
    static func convert(_ d: [String: Any], orientation: Int?) -> [String: Any] {
        func num(_ k: String) -> Double? { d[k] as? Double }
        var out: [String: Any] = [:]
        if let v = num("ZEXPOSURE"), v != 0 { out["exposure"] = v }
        for (c, s) in [("ZCONTRAST", "contrast"), ("ZBRIGHTNESS", "brightness"), ("ZSATURATION", "saturation"),
                       ("ZCLARITY", "clarity"), ("ZCLARITYSTRUCTURE", "structure"), ("ZDEHAZEAMOUNT", "dehaze")] {
            if let v = num(c), v != 0 { out[s] = max(-100, min(100, v)) }
        }
        // Imported HDR: negative highlights recover (darker), positive shadows brighten. Duochrome's highlights/shadows are both -100–100 (negative highlights recover, positive shadows brighten).
        if let v = num("ZHIGHLIGHTRECOVERY"), v != 0 { out["highlights"] = min(max(v, -100), 100) }
        if let v = num("ZSHADOWRECOVERY"), v != 0 { out["shadow"] = min(max(v, -100), 100) }
        if let v = num("ZWHITERECOVERY"), v != 0 { out["white"] = v }
        if let v = num("ZBLACKRECOVERY"), v != 0 { out["black"] = v }

        // Rotation: subtract camera orientation and keep the rest (multiples of 90° as quarterTurns, remainder as fine rotation).
        if var rot = num("ZROTATION") {
            let cam: Double
            switch orientation {
            case 6: cam = 90
            case 8: cam = 270
            case 3: cam = 180
            case 1: cam = 0
            default: cam = (rot / 90).rounded() * 90   // Without the source, treat the nearest multiple of 90° as the camera orientation
            }
            rot -= cam
            while rot > 180 { rot -= 360 }
            while rot <= -180 { rot += 360 }
            let q = (rot / 90).rounded()
            let fine = rot - q * 90
            if q != 0 { out["quarterTurns"] = Double((Int(q) % 4 + 4) % 4) }
            if abs(fine) > 0.001 { out["rotation"] = max(-45, min(45, fine)) }
        }
        if let f = num("ZFLIP"), f != 0 {
            if Int(f) & 1 != 0 { out["flipH"] = 1.0 }
            if Int(f) & 2 != 0 { out["flipV"] = 1.0 }
        }

        // White balance: imported RGB multipliers ÷ as-shot multipliers → mired/tint deltas (R5M2 measured coefficients).
        // Absolute temperature needs the RAW, so store a delta and add it to the as-shot value on first open (RawDocument.applyImportedWB)
        if let (dm, dt) = wbShift(d["ZWHITEBALANCE"] as? String, shot: d["SHOTWB"] as? String) {
            out["importWBShift"] = [dm, dt]
        }
        // Crop "sensor center X;Y;height (Y);width (X)" (sensor coordinates, top is 0) → geometry frame 0–1
        if let c = crop(d["ZCROP"] as? String, sensor: (d["SENSORW"] as? Double, d["SENSORH"] as? Double), orientation: orientation,
                        quarterTurns: out["quarterTurns"] as? Double ?? 0, rotation: out["rotation"] as? Double ?? 0) {
            out["crop"] = ["x": c.x, "y": c.y, "w": c.w, "h": c.h]
        }

        // curve "x,y;x,y"
        func curve(_ k: String) -> [String: Any]? {
            guard let s = d[k] as? String else { return nil }
            let pts = s.split(separator: ";").compactMap { p -> [Double]? in
                let v = p.split(separator: ",").compactMap { Double($0) }
                return v.count == 2 ? v : nil
            }
            guard pts.count >= 2, pts != [[0, 0], [1, 1]] else { return nil }
            return ["points": pts]
        }
        var curves: [String: Any] = [:]
        for (c, s) in [("ZGRADATIONCURVE", "rgb"), ("ZGRADATIONCURVERED", "red"), ("ZGRADATIONCURVEGREEN", "green"),
                       ("ZGRADATIONCURVEBLUE", "blue")] {
            if let v = curve(c) { curves[s] = v }
        }
        if !curves.isEmpty { out["curves"] = curves }

        // levels "r;g;b;master" — master channel only
        func last(_ k: String) -> Double? {
            (d[k] as? String)?.split(separator: ";").last.flatMap { Double($0) }
        }
        if let v = last("ZLEVELSSHADOW"), v != 0 { out["levelInBlack"] = v }
        if let v = last("ZLEVELSHIGHLIGHT"), v != 1 { out["levelInWhite"] = v }

        // film grain (0–100)
        if let v = num("ZFILMGRAINAMOUNT"), v > 0 {
            out["grainAmount"] = v
            if let g = num("ZFILMGRAINGRANULARITY") { out["grainSize"] = g }
        }

        // vignette "amount|mode|…" — amount in EV. Duochrome -100–100 (roughly 1 EV = 40)
        if let s = d["ZLENSVIGNETTING"] as? String, let v = s.split(separator: "|").first.flatMap({ Double($0) }), v != 0 {
            out["vignette"] = max(-100, min(100, v * 40))
        }

        // black & white
        if let e = num("ZBWENABLED"), e != 0 {
            var bw: [String: Any] = ["enabled": true]
            for (c, s) in [("ZBWRED", "red"), ("ZBWYELLOW", "yellow"), ("ZBWGREEN", "green"), ("ZBWCYAN", "cyan"),
                           ("ZBWBLUE", "blue"), ("ZBWMAGENTA", "magenta")] {
                if let v = num(c) { bw[s] = v }
            }
            if let h = num("ZBWDARKTONEHUE"), let a = num("ZBWDARKTONESATURATION"), a > 0 {
                bw["shadowTone"] = ["hue": h, "amount": min(a / 100, 1), "lightness": 0]
            }
            if let h = num("ZBWLIGHTTONEHUE"), let a = num("ZBWLIGHTTONESATURATION"), a > 0 {
                bw["highlightTone"] = ["hue": h, "amount": min(a / 100, 1), "lightness": 0]
            }
            out["color"] = ["bw": bw]
        }

        // Color balance "r;g;b" multipliers → color wheel (hue, amount)
        var wheels: [String: Any] = [:]
        for (c, s) in [("ZCOLORBALANCE", "master"), ("ZCOLORBALANCESHADOW", "shadow"),
                       ("ZCOLORBALANCEMIDTONE", "mid"), ("ZCOLORBALANCEHIGHLIGHT", "high")] {
            if let w = wheel(d[c] as? String) { wheels[s] = w }
        }
        if !wheels.isEmpty {
            var color = out["color"] as? [String: Any] ?? [:]
            for (k, v) in wheels { color[k] = v }
            out["color"] = color
        }
        return out
    }

    /// Imported multiplier change → (mired delta, tint delta). Solves ln(R/B) and ln(G²/RB) changes with R5M2 measured slopes.
    static func wbShift(_ user: String?, shot: String?) -> (Double, Double)? {
        func parse(_ s: String?) -> [Double]? { s?.split(separator: ";").compactMap { Double($0) }.count == 3 ? s!.split(separator: ";").compactMap { Double($0) } : nil }
        guard let u = parse(user), let sh = parse(shot), u[0] > 0, u[2] > 0, sh[0] > 0, sh[2] > 0 else { return nil }
        let r = log(u[0] / sh[0]) - log(u[1] / sh[1]), b = log(u[2] / sh[2]) - log(u[1] / sh[1])
        let y1 = r - b, y2 = -r - b             // desired ln(R/B), ln(G²/RB) changes
        guard abs(y1) > 0.002 || abs(y2) > 0.002 else { return nil }
        // [a b; c d] [Δmired; Δtint] = [y1; y2]
        let a = -0.01055, bb = -0.00290, c = -0.00270, dd = -0.01265
        let det = a * dd - bb * c
        return ((dd * y1 - bb * y2) / det, (a * y2 - c * y1) / det)
    }

    /// Sensor-coordinate crop → Duochrome crop (frame-relative 0–1, bottom is 0)
    static func crop(_ s: String?, sensor: (Double?, Double?), orientation: Int?, quarterTurns: Double, rotation: Double) -> CropRect? {
        guard let v = s?.split(separator: ";").compactMap({ Double($0) }), v.count == 4, v[2] > 1, v[3] > 1,
              let W = sensor.0, let H = sensor.1, W > 0, H > 0 else { return nil }
        let o = orientation ?? 1
        // sensor (X right, Y down) → Duochrome source coordinates (with camera orientation, bottom is 0)
        func nat(_ X: Double, _ Y: Double) -> CGPoint {
            switch o {
            case 6: return CGPoint(x: H - Y, y: W - X)
            case 8: return CGPoint(x: Y, y: X)
            case 3: return CGPoint(x: W - X, y: Y)
            default: return CGPoint(x: X, y: H - Y)
            }
        }
        let native = (o == 6 || o == 8) ? CGSize(width: H, height: W) : CGSize(width: W, height: H)
        var st = DevelopSettings()
        st.quarterTurns = Float(quarterTurns); st.rotation = Float(rotation)
        let cx = v[0], cy = v[1], ey = v[2], ex = v[3]
        let c = Geometry.toDisplay(nat(cx, cy), st, native: native, fullFrame: true)
        let px = Geometry.toDisplay(nat(cx + 100, cy), st, native: native, fullFrame: true)
        let k = hypot(px.x - c.x, px.y - c.y) / 100
        // is sensor X the screen horizontal?
        let xHorizontal = abs(px.x - c.x) >= abs(px.y - c.y)
        let wd = (xHorizontal ? ex : ey) * k, hd = (xHorizontal ? ey : ex) * k
        let F = Geometry.frameSize(st, native: native)
        var r = CGRect(x: (c.x - wd / 2) / F.width, y: (c.y - hd / 2) / F.height, width: wd / F.width, height: hd / F.height)
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.02, r.height > 0.02, !(r.width > 0.999 && r.height > 0.999) else { return nil }
        return CropRect(r)
    }

    /// Turns RGB multipliers (applied to middle gray) into one color wheel. nil if nearly 1.
    static func wheel(_ s: String?) -> [String: Any]? {
        guard let v = s?.split(separator: ";").compactMap({ Double($0) }), v.count == 3 else { return nil }
        // How far middle gray (0.5) moves. Drop the luminance component and look at color only.
        var d = SIMD3<Double>(v[0] - 1, v[1] - 1, v[2] - 1) * 0.5
        let y = 0.2126 * d.x + 0.7152 * d.y + 0.0722 * d.z
        d -= SIMD3(repeating: y)
        let mag = (d * d).sum().squareRoot()
        guard mag > 0.002 else { return nil }
        // Hue: same HSV angle as Duochrome's color wheel
        let r = d.x, g = d.y, b = d.z
        let mx = max(r, g, b), mn = min(r, g, b), c = mx - mn
        var h: Double
        if mx == r { h = (g - b) / c } else if mx == g { h = 2 + (b - r) / c } else { h = 4 + (r - g) / c }
        h *= 60
        if h < 0 { h += 360 }
        // At the wheel edge (amount 1) the color shift is roughly 0.25 × 0.8
        return ["hue": h, "amount": min(mag / 0.2, 1), "lightness": 0]
    }
}
