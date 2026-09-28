import Foundation
import ImageIO

/// 외부 카탈로그(.cocatalog) 가져오기. **읽기만 한다** — 카탈로그 파일을 임시 폴더에 복사해서 그 복사본을 연다.
///
/// 가져오는 것: 사진 목록, 앨범·그룹 구조, 별점, 색 태그, 썸네일 캐시, 조정값 일부.
/// 경로에 파일이 없는 사진은 "오프라인"으로 표시만 한다. 다른 곳에서 찾아 다시 잇기(relink)는 하지 않는다.
///
/// 저장 방식 (2026 카탈로그로 확인):
/// - ZCOLLECTION.Z_ENT: 2 앨범, 7 그룹·프로젝트, 8 특수 그룹(최근 가져오기 등), 36 폴더
/// - 최종 조정값은 ZVARIANT.ZCOMBINEDSETTINGS가 가리키는 ZVARIANTLAYER 행
/// - 별점·색은 ZVARIANT.ZDEFAULTLAYER의 ZVARIANTMETADATA
/// - 썸네일 캐시 Cache/Thumbnails/<변형 번호 8자리>.cot (사진 번호가 아니다 — 번호대가 겹쳐 엉뚱한 사진이 붙는다)
/// - ZROTATION에 카메라 방향이 섞여 있다: EXIF 6이면 90, 8이면 270(또는 -90)
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
        // 복사본을 연다: 다른 앱이 열어 둔 상태여도 원본 잠금·저널을 건드리지 않는다.
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-import-\(UUID().uuidString).db")
        try fm.copyItem(at: package.appendingPathComponent(dbFile), to: copy)
        defer { try? fm.removeItem(at: copy) }
        let srcDB = try SQLiteDB(path: copy.path, readOnly: true)
        progress?("카탈로그 읽는 중…")

        // 경로
        var locations: [Int64: String] = [:]
        try srcDB.query("SELECT Z_PK, ZMACROOT, ZRELATIVEPATH FROM ZPATHLOCATION") { r in
            let root = r.text(1) ?? "", rel = r.text(2) ?? ""
            var path = root.isEmpty ? package.appendingPathComponent(rel).path : (root as NSString).appendingPathComponent(rel)
            if !path.hasPrefix("/") { path = "/" + path }
            locations[r.int(0)] = path
        }

        // 사진 + 대표 변형의 별점·색·조정값 행
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
            // 변형이 여럿이면 첫 변형(ZINDEX가 가장 작은 것)이 마지막에 덮어쓴다.
            guard var img = images[r.int(0)] else { return }
            img.combined = r.int(1)
            img.rating = Int(r.int(2))
            img.color = Int(r.int(3))
            img.variant = r.int(4)
            images[r.int(0)] = img
        }

        // 카탈로그에 넣기
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
                // 이미 있던 사진이면 Duochrome 쪽 별점·색을 지키고, 비어 있을 때만 가져온 값을 쓴다.
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

        // 앨범·그룹
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
            // 최근 가져오기·최근 촬영 아래의 자동 앨범은 건너뛴다.
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

        // 조정값
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
        // 카메라 기록 화이트 밸런스(기본 레이어)와 센서 크기
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
            let url = URL(fileURLWithPath: img.path)
            if library.hasSettings(for: url) { report.adjustSkippedExisting += 1; continue }
            // 카메라 방향: 원본이 있으면 EXIF에서, 없으면 회전값에서 가장 가까운 90° 배수로 추정.
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

    /// 가져온 값 → Duochrome 설정 조각 (JSON 사전). 카메라 기록값 위에 덮어 읽힌다.
    static func convert(_ d: [String: Any], orientation: Int?) -> [String: Any] {
        func num(_ k: String) -> Double? { d[k] as? Double }
        var out: [String: Any] = [:]
        if let v = num("ZEXPOSURE"), v != 0 { out["exposure"] = v }
        for (c, s) in [("ZCONTRAST", "contrast"), ("ZBRIGHTNESS", "brightness"), ("ZSATURATION", "saturation"),
                       ("ZCLARITY", "clarity"), ("ZCLARITYSTRUCTURE", "structure"), ("ZDEHAZEAMOUNT", "dehaze")] {
            if let v = num(c), v != 0 { out[s] = max(-100, min(100, v)) }
        }
        // 가져온 HDR: 하이라이트는 음수가 복구(어둡게), 섀도는 양수가 밝게. Duochrome은 둘 다 0~100.
        if let v = num("ZHIGHLIGHTRECOVERY"), v < 0 { out["highlight"] = min(-v, 100) }
        if let v = num("ZSHADOWRECOVERY"), v > 0 { out["shadow"] = min(v, 100) }
        if let v = num("ZWHITERECOVERY"), v != 0 { out["white"] = v }
        if let v = num("ZBLACKRECOVERY"), v != 0 { out["black"] = v }

        // 회전: 카메라 방향만큼 빼고 남는 것만 (90° 배수는 quarterTurns, 나머지는 미세 회전).
        if var rot = num("ZROTATION") {
            let cam: Double
            switch orientation {
            case 6: cam = 90
            case 8: cam = 270
            case 3: cam = 180
            case 1: cam = 0
            default: cam = (rot / 90).rounded() * 90   // 원본이 없으면 가장 가까운 90° 배수를 카메라 방향으로 본다
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

        // 화이트 밸런스: 가져온 RGB 배율 ÷ 카메라 기록 배율 → 미레드·틴트 차이 (R5M2 실측 계수).
        // 절대 색온도는 RAW를 열어야 알아서 차이로 적고, 처음 열 때 카메라 기록값에 더한다 (RawDocument.applyImportedWB)
        if let (dm, dt) = wbShift(d["ZWHITEBALANCE"] as? String, shot: d["SHOTWB"] as? String) {
            out["importWBShift"] = [dm, dt]
        }
        // 크롭 "센서 가운데 X;Y;세로(Y) 폭;가로(X) 폭" (센서 좌표, 위가 0) → 형태 보정 틀의 0~1
        if let c = crop(d["ZCROP"] as? String, sensor: (d["SENSORW"] as? Double, d["SENSORH"] as? Double), orientation: orientation,
                        quarterTurns: out["quarterTurns"] as? Double ?? 0, rotation: out["rotation"] as? Double ?? 0) {
            out["crop"] = ["x": c.x, "y": c.y, "w": c.w, "h": c.h]
        }

        // 커브 "x,y;x,y"
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

        // 레벨 "r;g;b;전체" — 전체 채널만
        func last(_ k: String) -> Double? {
            (d[k] as? String)?.split(separator: ";").last.flatMap { Double($0) }
        }
        if let v = last("ZLEVELSSHADOW"), v != 0 { out["levelInBlack"] = v }
        if let v = last("ZLEVELSHIGHLIGHT"), v != 1 { out["levelInWhite"] = v }

        // 필름 그레인 (0~100)
        if let v = num("ZFILMGRAINAMOUNT"), v > 0 {
            out["grainAmount"] = v
            if let g = num("ZFILMGRAINGRANULARITY") { out["grainSize"] = g }
        }

        // 비네팅 "양|방식|…" — 양은 EV. Duochrome -100~100 (대략 1EV = 40)
        if let s = d["ZLENSVIGNETTING"] as? String, let v = s.split(separator: "|").first.flatMap({ Double($0) }), v != 0 {
            out["vignette"] = max(-100, min(100, v * 40))
        }

        // 흑백
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

        // 컬러 밸런스 "r;g;b" 배율 → 색 휠 (색조·양)
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

    /// 가져온 배율 변화 → (미레드 차이, 틴트 차이). ln(R/B)·ln(G²/RB) 변화를 R5M2 실측 기울기로 푼다.
    static func wbShift(_ user: String?, shot: String?) -> (Double, Double)? {
        func parse(_ s: String?) -> [Double]? { s?.split(separator: ";").compactMap { Double($0) }.count == 3 ? s!.split(separator: ";").compactMap { Double($0) } : nil }
        guard let u = parse(user), let sh = parse(shot), u[0] > 0, u[2] > 0, sh[0] > 0, sh[2] > 0 else { return nil }
        let r = log(u[0] / sh[0]) - log(u[1] / sh[1]), b = log(u[2] / sh[2]) - log(u[1] / sh[1])
        let y1 = r - b, y2 = -r - b             // 바라는 ln(R/B), ln(G²/RB) 변화
        guard abs(y1) > 0.002 || abs(y2) > 0.002 else { return nil }
        // [a b; c d] [Δmired; Δtint] = [y1; y2]
        let a = -0.01055, bb = -0.00290, c = -0.00270, dd = -0.01265
        let det = a * dd - bb * c
        return ((dd * y1 - bb * y2) / det, (a * y2 - c * y1) / det)
    }

    /// 센서 좌표 크롭 → Duochrome 크롭 (틀 기준 0~1, 아래가 0)
    static func crop(_ s: String?, sensor: (Double?, Double?), orientation: Int?, quarterTurns: Double, rotation: Double) -> CropRect? {
        guard let v = s?.split(separator: ";").compactMap({ Double($0) }), v.count == 4, v[2] > 1, v[3] > 1,
              let W = sensor.0, let H = sensor.1, W > 0, H > 0 else { return nil }
        let o = orientation ?? 1
        // 센서 (X 오른쪽, Y 아래) → Duochrome 원본 좌표 (카메라 방향을 반영, 아래가 0)
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
        // 센서 X가 화면 가로인가
        let xHorizontal = abs(px.x - c.x) >= abs(px.y - c.y)
        let wd = (xHorizontal ? ex : ey) * k, hd = (xHorizontal ? ey : ex) * k
        let F = Geometry.frameSize(st, native: native)
        var r = CGRect(x: (c.x - wd / 2) / F.width, y: (c.y - hd / 2) / F.height, width: wd / F.width, height: hd / F.height)
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.02, r.height > 0.02, !(r.width > 0.999 && r.height > 0.999) else { return nil }
        return CropRect(r)
    }

    /// RGB 배율(중간 회색에 곱해지는 값)을 색 휠 한 칸으로 바꾼다. 거의 1이면 nil.
    static func wheel(_ s: String?) -> [String: Any]? {
        guard let v = s?.split(separator: ";").compactMap({ Double($0) }), v.count == 3 else { return nil }
        // 중간 회색(0.5)이 옮겨 가는 양. 밝기 성분은 빼고 색만 본다.
        var d = SIMD3<Double>(v[0] - 1, v[1] - 1, v[2] - 1) * 0.5
        let y = 0.2126 * d.x + 0.7152 * d.y + 0.0722 * d.z
        d -= SIMD3(repeating: y)
        let mag = (d * d).sum().squareRoot()
        guard mag > 0.002 else { return nil }
        // 색조: Duochrome 색 휠과 같은 HSV 각도
        let r = d.x, g = d.y, b = d.z
        let mx = max(r, g, b), mn = min(r, g, b), c = mx - mn
        var h: Double
        if mx == r { h = (g - b) / c } else if mx == g { h = 2 + (b - r) / c } else { h = 4 + (r - g) / c }
        h *= 60
        if h < 0 { h += 360 }
        // 휠 끝(양 1)에서 옮겨 가는 색 크기는 대략 0.25 × 0.8
        return ["hue": h, "amount": min(mag / 0.2, 1), "lightness": 0]
    }
}
