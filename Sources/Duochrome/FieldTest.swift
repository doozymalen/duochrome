import AppKit
import CoreImage

/// Real-use field test (DUOCHROME_FIELDTEST=1): runs a session in the order a person would, measuring time and memory.
/// Runs only with a test catalog (DUOCHROME_CATALOG). Slow spots are marked "느림".
extension MainWindowController {
    /// Current memory use (MB, physical footprint)
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Time to actually render one tile (ms)
    private func renderMS(_ img: CIImage, rect: CGRect? = nil) -> Double {
        let r = (rect ?? img.extent).intersection(img.extent).integral
        let t0 = CACurrentMediaTime()
        _ = Render.context.createCGImage(img, from: r, format: .RGBA8, colorSpace: Render.displaySpace)
        return (CACurrentMediaTime() - t0) * 1000
    }

    /// Spins the main run loop so background work (thumbnails etc.) flows
    private func pump(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    static var fieldTestStarted = false
    /// What to do if the test ends early (restore the pre-test adjustments)
    static var fieldTestAbort: (() -> Void)?

    /// Enables develop features one by one, timing the first fit-view (1/4) draw (a fresh document each time — no cache)
    func profileFeatures(_ doc0: RawDocument) {
        let url = doc0.url
        func time(_ name: String, _ f: (inout DevelopSettings) -> Void) {
            guard let d = try? RawDocument(url: url) else { return }
            var s = d.asShot
            f(&s)
            d.settings = s
            d.settleForExport()
            let t0 = CACurrentMediaTime()
            let img = d.image(scale: 0.25)
            _ = Render.context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: Render.displaySpace)
            print(String(format: "  %@: %.0f ms", name, (CACurrentMediaTime() - t0) * 1000))
        }
        time("기본 (기록값)") { _ in }
        time("노출·대비") { $0.exposure = 0.5; $0.contrast = 20 }
        time("클래리티 20") { $0.clarity = 20 }
        time("구조 20") { $0.structure = 20 }
        time("HDR 하이라이트·섀도") { $0.highlight = 40; $0.shadow = 30 }
        time("디헤이즈 15") { $0.dehaze = 15 }
        time("컬러 에디터") { $0.color.editor[5].dSat = 30 }
        time("레벨") { $0.levelInWhite = 0.9 }
        time("노이즈 제거") { $0.lumaNoise = 0.4 }
        time("샤프닝") { $0.sharpenAmount = 120 }
        time("전부") { $0.exposure = 0.5; $0.contrast = 20; $0.clarity = 20; $0.highlight = 40; $0.shadow = 30; $0.dehaze = 15; $0.color.editor[5].dSat = 30; $0.levelInWhite = 0.9 }
    }

    /// Opens 12 photos in turn until fit view (mean ms, memory growth MB)
    @discardableResult
    func browseTest(fitScale: CGFloat) -> (Double, Double) {
        setMode(.edit)
        if ProcessInfo.processInfo.environment["DUOCHROME_CLEARCI"] != nil { Render.context.clearCaches() }
        let first = photoItem
        let memBefore = Self.memoryMB()
        var opens: [Double] = []
        final class Weak { weak var doc: RawDocument?; init(_ d: RawDocument?) { doc = d } }
        var olds: [Weak] = []
        for item in library.items.filter({ !$0.offline }).prefix(12) {
            let t0 = CACurrentMediaTime()
            olds.append(Weak(photo))
            show(item)
            let tShow = (CACurrentMediaTime() - t0) * 1000
            var tDraw = 0.0
            if let d = photo { tDraw = renderMS(d.image(scale: fitScale)) }
            opens.append((CACurrentMediaTime() - t0) * 1000)
            print(String(format: "  열기 %@: 문서 %.0f ms, 그리기 %.0f ms, 메모리 %.0f MB", item.name, tShow, tDraw, Self.memoryMB()))
            // While a person looks at the photo (1.5 s) — the next photo is prepared meanwhile
            pump(1.5)
        }
        pump(1.0)
        let memAfter = Self.memoryMB()
        let alive = olds.filter { $0.doc != nil }.count
        print("       넘긴 문서 \(olds.count)개 중 아직 살아 있는 것 \(alive)개 (지금 연 것·탭 제외하면 0이어야 함)")
        let openAvg = opens.reduce(0, +) / Double(max(opens.count, 1))
        print(String(format: "%@  사진 열기+맞춤 보기 평균 %.0f ms (최대 %.0f, %d장)", openAvg > 1500 ? "느림" : "보통", openAvg, opens.max() ?? 0, opens.count))
        print(String(format: "%@  사진 12장 넘긴 뒤 메모리 %.0f → %.0f MB (%+.0f)", memAfter - memBefore > 1500 ? "느림" : "보통", memBefore, memAfter, memAfter - memBefore))
        if let first { show(first) }
        return (openAvg, memAfter - memBefore)
    }

    func runFieldTest() {
        // The develop hook runs again on every open → once only
        guard !Self.fieldTestStarted else { return }
        Self.fieldTestStarted = true
        var lines: [String] = []
        var slow: [String] = []
        func log(_ s: String) { print(s); lines.append(s) }
        func timed(_ name: String, limit: Double, _ f: () -> Void) -> Double {
            let t0 = CACurrentMediaTime(); f(); let ms = (CACurrentMediaTime() - t0) * 1000
            let bad = ms > limit
            if bad { slow.append("\(name) \(Int(ms))ms (기준 \(Int(limit)))") }
            log(String(format: "%@  %@ %.0f ms (메모리 %.0f MB)", bad ? "느림" : "보통", name, ms, Self.memoryMB()))
            return ms
        }
        guard let doc = photo else { print("실전 시험: 사진이 없음"); exit(1) }
        let mem0 = Self.memoryMB()
        // Restore this photo to its pre-test state at the end (leftover layers piled up with each test)
        let docSaved = doc.settings
        Self.fieldTestAbort = { [weak self] in self?.replaceSettings(docSaved, recordUndo: false) }
        log(String(format: "실전 시험 시작: %@ %.0f×%.0f, 메모리 %.0f MB, 목록 %d장", doc.url.lastPathComponent, doc.nativeSize.width, doc.nativeSize.height, mem0, library.items.count))
        let fitScale: CGFloat = 0.25
        let onlyOpen = ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "open"
        if onlyOpen { browseTest(fitScale: fitScale); exit(0) }
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "profile" { profileFeatures(doc); exit(0) }
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "ai" { aiFieldTest(doc); return }
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "tether" { tetherFieldTest(); return }
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "flow" { flowFieldTest(); return }
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "thumbs" { thumbBench(doc); return }
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == "psd" { psdBench(doc); return }

        // 1. First view: fit view and one 100% tile
        _ = timed("처음 맞춤 보기 그리기", limit: 1500) { _ = renderMS(doc.image(scale: fitScale)) }
        _ = timed("100% 한 조각 (1600×1000)", limit: 2500) { _ = renderMS(doc.image(scale: 1), rect: CGRect(x: 3000, y: 2000, width: 1600, height: 1000)) }

        // 2. Adjust: change values like dragging a slider and redraw (draft stage while dragging)
        var st = doc.settings
        var drags: [Double] = []
        for i in 0..<12 {
            st.exposure = Float(i) * 0.05
            st.contrast = Float(i * 3)
            st.clarity = Float(i * 2)
            apply(st, dragging: true)
            let t0 = CACurrentMediaTime()
            _ = renderMS(doc.image(scale: fitScale))
            drags.append((CACurrentMediaTime() - t0) * 1000)
        }
        apply(st, dragging: false)
        let dragAvg = drags.dropFirst().reduce(0, +) / Double(max(drags.count - 1, 1))
        // Drag exposure only (checks whether the RAW is decoded again)
        var expo: [Double] = []
        for i in 0..<10 {
            st.exposure = 0.5 + Float(i) * 0.03
            apply(st, dragging: true)
            let t0 = CACurrentMediaTime(); _ = renderMS(doc.image(scale: fitScale)); expo.append((CACurrentMediaTime() - t0) * 1000)
        }
        apply(st, dragging: false)
        let expoAvg = expo.dropFirst().reduce(0, +) / Double(max(expo.count - 1, 1))
        if expoAvg > 120 { slow.append("노출만 끌기 평균 \(Int(expoAvg))ms") }
        log(String(format: "%@  노출만 끌기 다시 그리기 평균 %.0f ms (첫 장면 %.0f)", expoAvg > 120 ? "느림" : "보통", expoAvg, expo.first ?? 0))
        if dragAvg > 120 { slow.append("슬라이더 끌기 다시 그리기 평균 \(Int(dragAvg))ms") }
        log(String(format: "%@  슬라이더 끌기 다시 그리기 평균 %.0f ms (최대 %.0f)", dragAvg > 120 ? "느림" : "보통", dragAvg, drags.max() ?? 0))
        _ = timed("자동 노출·레벨", limit: 800) { autoCard("exposure"); autoCard("levels") }
        _ = timed("컬러 에디터·HDR·디헤이즈 값", limit: 300) {
            var s = doc.settings
            s.highlight = 40; s.shadow = 30; s.dehaze = 15
            s.color.editor[5].dSat = 30; s.color.editor[3].dHue = -10
            replaceSettings(s, recordUndo: true, label: "실전 보정")
        }
        _ = timed("보정 뒤 맞춤 보기 그리기", limit: 900) { _ = renderMS(doc.image(scale: fitScale)) }
        _ = timed("보정 뒤 100% 한 조각", limit: 2500) { _ = renderMS(doc.image(scale: 1), rect: CGRect(x: 3000, y: 2000, width: 1600, height: 1000)) }

        // 3. Many photos: paste adjustments to 20 + ratings/picks/keywords, rebuild thumbnails
        if library.items.count < 21 { library.show(.all); browser.reload() }
        let batch = Array(library.items.filter { $0 !== photoItem && !$0.offline }.prefix(20))
        let raws = batch.map { library.rawSettings(for: $0.url) }
        batchClipboard = settingsDict(doc.settings).filter { !Self.batchExcluded.contains($0.key) }
        libraryMode.grid.library = library
        _ = timed("20장에 조정 붙이기", limit: 1500) {
            for item in batch {
                var dict = (library.rawSettings(for: item.url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
                for (k, v) in batchClipboard ?? [:] { dict[k] = v }
                library.saveRawSettings(dict, for: item.url)
                item.edited = true; item.thumbnail = nil
            }
        }
        let tThumb = CACurrentMediaTime()
        refreshThumbnails(batch)
        var waited = 0.0
        while batch.contains(where: { $0.thumbnail == nil }) && waited < 60 { pump(0.25); waited += 0.25 }
        let thumbMS = (CACurrentMediaTime() - tThumb) * 1000
        let thumbDone = batch.filter { $0.thumbnail != nil }.count
        if thumbMS > 20000 || thumbDone < batch.count { slow.append("썸네일 20장 \(Int(thumbMS))ms, 완료 \(thumbDone)") }
        log(String(format: "%@  보정한 20장 썸네일 다시 만들기 %.0f ms (완료 %d/%d)", thumbMS > 20000 || thumbDone < batch.count ? "느림" : "보통", thumbMS, thumbDone, batch.count))
        _ = timed("20장 별점·채택·키워드", limit: 1500) {
            for (i, item) in batch.enumerated() {
                try? library.catalog.setRating([item.id], i % 6)
                try? library.catalog.setFlag([item.id], i % 3 == 0 ? 1 : 0)
                try? library.catalog.addKeywords([item.id], ["실전시험", "건물>콘크리트"])
            }
        }
        _ = timed("검색 (이름 일부)", limit: 400) { library.query = "DZY68"; library.query = "" }

        // 4. Layer editing: stack layers (text, shape, paint, gradient mask, selection, effects, styles)
        setMode(.studio)
        let n = doc.nativeSize
        _ = timed("레이어 여섯 개 쌓기", limit: 800) {
            var s = doc.settings
            var t = AdjustLayer(name: "제목"); t.kind = "text"
            t.text = LayerText(string: "오후의 빛", font: "AppleSDGothicNeo-Bold", size: Double(n.height) / 12, color: [1, 1, 1], x: Double(n.width) * 0.08, y: Double(n.height) * 0.12)
            var styles = LayerStyles(); styles.dropShadow.enabled = true
            t.styles = styles
            var sh = AdjustLayer(name: "테두리"); sh.kind = "shape"
            sh.vector = VectorShape(path: .preset(.roundRect, in: CGRect(x: n.width * 0.05, y: n.height * 0.05, width: n.width * 0.9, height: n.height * 0.9), radius: 120), fill: nil, stroke: [1, 1, 1], strokeWidth: 30)
            var grad = AdjustLayer(name: "하늘 어둡게"); grad.mask.kind = .linear
            grad.mask.linear = [Double(n.width) / 2, Double(n.height), Double(n.width) / 2, Double(n.height) * 0.6]
            grad.adjust.exposure = -0.8
            var sel = AdjustLayer(name: "벽 선택 밝게"); sel.mask.kind = .polygon
            sel.mask.polygon = [0.3, 0.2, 0.7, 0.2, 0.7, 0.8, 0.3, 0.8].enumerated().map { $0.offset % 2 == 0 ? $0.element * Double(n.width) : $0.element * Double(n.height) }
            sel.mask.feather = 60; sel.adjust.exposure = 0.3
            var fx = AdjustLayer(name: "흐림 효과"); fx.kind = "adjust"
            var e = LayerEffect(kind: "gaussian"); e.params["radius"] = 6
            fx.adjust.effects = [e]; fx.opacity = 0.4
            s.layers += [grad, sel, fx, sh, t]
            replaceSettings(s, recordUndo: true, label: "실전 레이어")
        }
        _ = timed("붓질 칠하기 한 번", limit: 600) {
            let pts = (0..<60).map { CGPoint(x: n.width * (0.2 + 0.01 * CGFloat($0)), y: n.height * 0.5 + sin(CGFloat($0) / 6) * 200) }
            layersTab.select(nil)
            paintStroke(pts, pressures: pts.map { _ in 1 }, erase: false)
        }
        _ = timed("레이어 여섯 개 맞춤 보기", limit: 1500) { _ = renderMS(doc.image(scale: fitScale)) }
        _ = timed("레이어 여섯 개 100% 한 조각", limit: 4000) { _ = renderMS(doc.image(scale: 1), rect: CGRect(x: 3000, y: 2000, width: 1600, height: 1000)) }
        var thumbsReady = false
        _ = timed("레이어 썸네일", limit: 3000) {
            let layers = doc.settings.layers
            var pending = 0
            for l in layers where LayerThumbs.hasContent(l) { if LayerThumbs.content(l, done: { _ in pending -= 1 }) == nil { pending += 1 } }
            var w = 0.0
            while pending > 0 && w < 10 { pump(0.05); w += 0.05 }
            thumbsReady = pending <= 0
        }
        if !thumbsReady { slow.append("레이어 썸네일이 10초 안에 다 안 됨") }

        // 5. Undo/redo twenty times
        _ = timed("되돌리기·다시 하기 20번", limit: 1500) {
            for _ in 0..<10 { undoAdjust(nil) }
            for _ in 0..<10 { redoAdjust(nil) }
        }

        // 6. Export: JPEG, TIFF 16-bit at full size, PSD (layers), PSD read back
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-field-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = ExportRecipe(); r.folder = dir.path; r.keepMetadata = true
        var jpeg: URL?, tiff: URL?
        _ = timed("원본 크기 JPEG 내보내기", limit: 12000) { r.format = .jpeg; jpeg = try? Exporter.export(doc, recipe: r, name: "field") }
        _ = timed("원본 크기 TIFF 16비트 내보내기", limit: 15000) { r.format = .tiff16; tiff = try? Exporter.export(doc, recipe: r, name: "field") }
        let psdURL = dir.appendingPathComponent("field.psd")
        var psdOK = false
        _ = timed("PSD 쓰기 (레이어째)", limit: 25000) { psdOK = (try? PSDExport.write(doc, to: psdURL)) != nil }
        var psdLayers = 0
        _ = timed("PSD 다시 읽기", limit: 8000) { psdLayers = (try? PSD.read(psdURL))?.layers.count ?? 0 }
        func size(_ u: URL?) -> String { u.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "없음" }
        log("       파일: JPEG \(size(jpeg)), TIFF \(size(tiff)), PSD \(size(psdOK ? psdURL : nil)) (레이어 \(psdLayers))")
        if jpeg == nil || tiff == nil || !psdOK || psdLayers < 6 { slow.append("내보내기 실패: JPEG \(jpeg != nil) TIFF \(tiff != nil) PSD \(psdOK) 레이어 \(psdLayers)") }

        // 7. Stepping through photos
        let (openAvg, grow) = browseTest(fitScale: fitScale)
        if openAvg > 1500 { slow.append("사진 열기 평균 \(Int(openAvg))ms") }
        if grow > 1500 { slow.append(String(format: "사진 12장 넘긴 뒤 메모리 %.0f MB 늘어남", grow)) }

        // Revert: this photo and the 20 photos' adjustments/ratings (even in a test catalog, for the next test)
        replaceSettings(docSaved, recordUndo: false)
        for (item, raw) in zip(batch, raws) {
            if let raw, let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] { library.saveRawSettings(dict, for: item.url) } else { library.removeSettings(for: item.url) }
            try? library.catalog.setRating([item.id], 0); try? library.catalog.setFlag([item.id], 0)
        }
        try? FileManager.default.removeItem(at: dir)
        log(String(format: "끝: 메모리 %.0f MB (시작 %.0f)", Self.memoryMB(), mem0))
        print(slow.isEmpty ? "실전 시험: 느린 곳 없음" : "실전 시험: 느린 곳 \(slow.count)개 — " + slow.joined(separator: " / "))
        if let out = ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST_OUT"] {
            try? (lines + ["느린 곳: " + slow.joined(separator: " / ")]).joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        exit(0)
    }
}

// MARK: - AI field test (DUOCHROME_FIELDTEST=ai): starts the engine and actually runs erase, fill, denoise, upscale, expand
extension MainWindowController {
    func aiFieldTest(_ doc: RawDocument) {
        let out = ProcessInfo.processInfo.environment["DUOCHROME_AITEST_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-aitest")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let skip = Set((ProcessInfo.processInfo.environment["DUOCHROME_AITEST_SKIP"] ?? "").split(separator: ",").map(String.init))
        let n = doc.nativeSize
        let saved = doc.settings
        Self.fieldTestAbort = { [weak self] in self?.replaceSettings(saved, recordUndo: false) }
        print(String(format: "AI 시험: %@ %.0f×%.0f", doc.url.lastPathComponent, n.width, n.height))
        func snapshot(_ name: String) {
            let img = doc.image(scale: 0.25)
            if let d = AIRegion.png(img.transformed(by: .init(translationX: -img.extent.minX, y: -img.extent.minY))) {
                try? d.write(to: out.appendingPathComponent(name + ".png"))
            }
        }
        snapshot("0-원본")
        var steps: [(String, () -> Void, () -> Bool)] = []
        let layers0 = { [weak self] in self?.photo?.settings.layers.count ?? 0 }
        var count = 0
        func layerStep(_ name: String, _ start: @escaping () -> Void) {
            steps.append((name, { count = layers0(); start() }, { layers0() > count }))
        }
        let r = Double(max(n.width, n.height)) * 0.02
        let cx = Double(n.width) * 0.5, cy = Double(n.height) * 0.5
        // Warm the engine up like when picking a tool (start time measured separately)
        steps.append(("엔진 켜기", { AIEngine.shared.warmUp() }, { AIEngine.shared.isAlive() }))
        if !skip.contains("remove") {
            layerStep("지우기") { [weak self] in
                self?.aiRemove(strokes: [MaskStroke(points: [cx - r * 2, cy, cx + r * 2, cy], radius: r, hardness: 0.8)], smart: false)
            }
        }
        if !skip.contains("smart") {
            layerStep("스마트 지우기") { [weak self] in
                self?.aiRemove(strokes: [MaskStroke(points: [cx * 0.5, cy * 1.4, cx * 0.6, cy * 1.4], radius: r, hardness: 0.8)], smart: true)
            }
        }
        if !skip.contains("fill") {
            layerStep("생성형 채우기") { [weak self] in
                guard let self, var s = self.photo?.settings else { return }
                let full = CGRect(origin: .zero, size: n)
                let hole = CGRect(x: n.width * 0.62, y: n.height * 0.55, width: n.width * 0.14, height: n.height * 0.2)
                let m = CIImage(color: .white).cropped(to: hole).composited(over: CIImage(color: .black).cropped(to: full))
                var l = AdjustLayer(name: "채울 곳")
                l.mask.kind = .image
                l.mask.maskFile = AIBasic.store(m.transformed(by: .init(scaleX: 0.25, y: 0.25)), size: n) ?? ""
                s.layers.append(l)
                self.replaceSettings(s, recordUndo: true, label: "채울 곳")
                self.layersTab.select(l.id)
                count = layers0()
                self.aiGenerativeFill(prompt: "")
            }
        }
        if !skip.contains("reflection") { layerStep("반사 제거") { [weak self] in self?.aiRemoveReflection(nil) } }
        if !skip.contains("denoise") { layerStep("AI 노이즈 제거") { [weak self] in self?.aiDenoise(nil) } }
        let folder = URL(fileURLWithPath: ExportRecipe().folder)
        let base = doc.url.deletingPathExtension().lastPathComponent
        func fileStep(_ name: String, _ file: String, _ start: @escaping () -> Void) {
            let u = folder.appendingPathComponent(file)
            steps.append((name, { try? FileManager.default.removeItem(at: u); start() }, { FileManager.default.fileExists(atPath: u.path) && !JobCenter.shared.isBusy }))
        }
        if !skip.contains("upscale") { fileStep("2배 확대", "\(base)_2배.\(AIRemote.current == .local ? "png" : "jpg")") { [weak self] in self?.aiUpscale2x(nil) } }
        if !skip.contains("expand") { fileStep("생성형 확장", "\(base)_확장20.tif") { [weak self] in self?.aiGenerativeExpand(percent: 20, prompt: "") } }

        var i = 0
        var t0 = CACurrentMediaTime()
        var results: [String] = []
        func next() {
            guard i < steps.count else {
                self.replaceSettings(saved, recordUndo: false)
                print("AI 시험 끝\n" + results.joined(separator: "\n"))
                try? results.joined(separator: "\n").write(to: out.appendingPathComponent("결과.txt"), atomically: true, encoding: .utf8)
                AIEngine.shared.stop()
                exit(0)
            }
            let (name, start, done) = steps[i]
            t0 = CACurrentMediaTime()
            print("AI 시험 시작: \(name)")
            start()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                let el = CACurrentMediaTime() - t0
                if done() {
                    t.invalidate()
                    results.append(String(format: "%@ %.1f초", name, el))
                    print(results.last!)
                    snapshot("\(i + 1)-\(name)")
                    i += 1
                    next()
                } else if el > 2400 {
                    t.invalidate(); print("AI 시험 시간 초과: \(name)"); exit(1)
                }
            }
        }
        next()
    }
}


// MARK: - Tether field test (DUOCHROME_FIELDTEST=tether, DUOCHROME_TETHER_FAKE=source RAW path → fake camera)
// Goes to tether mode and checks connect, setting changes, live view, grid, capture, naming, catalog registration; saves the window as PNG
extension MainWindowController {
    func tetherFieldTest() {
        let out = ProcessInfo.processInfo.environment["DUOCHROME_AITEST_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-tethertest")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-tether-session-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let savedRule = AppSettings.tetherNaming
        AppSettings.tetherNaming = "{날짜}_{순번}"
        var results: [String] = []
        func snap(_ name: String) {
            guard let w = window, let frame = w.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        func check(_ name: String, _ ok: Bool) { results.append((ok ? "통과 " : "실패 ") + name); print(results.last!) }
        func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping (Bool) -> Void) {
            let t0 = Date()
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
                if cond() { t.invalidate(); then(true) } else if Date().timeIntervalSince(t0) > timeout { t.invalidate(); then(false) }
            }
        }
        func finish() {
            AppSettings.tetherNaming = savedRule
            gphoto?.stop()
            try? results.joined(separator: "\n").write(to: out.appendingPathComponent("결과.txt"), atomically: true, encoding: .utf8)
            print("테더링 시험 끝\n" + results.joined(separator: "\n"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
        sessionFolder = session
        setMode(.tether)
        wait({ self.gphoto?.connected == true }, 60) { ok in
            check("가짜 카메라 연결", ok)
            guard ok else { finish(); return }
            wait({ !(self.gphoto?.settings.isEmpty ?? true) }, 10) { ok in
                check("카메라 설정 받기 (\(self.gphoto?.settings.count ?? 0)개)", ok)
                self.gphoto?.set("iso", "1600")
                wait({ self.gphoto?.settings["iso"]?.value == "1600" }, 10) { ok in
                    check("ISO 원격 변경 → 1600", ok)
                    self.tetherMode.setLive(true)
                    self.gphoto?.live(true)
                    wait({ self.tetherMode.overlay.live.image != nil }, 10) { ok in
                        check("라이브 뷰 그림 표시", ok)
                        UserDefaults.standard.set(true, forKey: "tether.grid")
                        snap("1-라이브뷰")
                        self.gphoto?.live(false)
                        let before = (try? FileManager.default.contentsOfDirectory(atPath: session.path).count) ?? 0
                        let t0 = Date()
                        self.gphoto?.shoot()
                        wait({ self.photoItem?.url.deletingLastPathComponent().standardizedFileURL == session.standardizedFileURL }, 60) { ok in
                            let files = (try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []
                            check(String(format: "촬영 → 받기 → 목록 등록·열기 (%.1f초)", Date().timeIntervalSince(t0)), ok && files.count > before)
                            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
                            check("이름 규칙 {날짜}_{순번} → \(files.first ?? "")", files.contains { $0.hasPrefix(df.string(from: Date()) + "_0001") })
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                snap("2-촬영후")
                                try? FileManager.default.removeItem(at: session)
                                finish()
                            }
                        }
                    }
                }
            }
        }
    }
}


// MARK: - Real-use flow test (DUOCHROME_FIELDTEST=flow, DUOCHROME_FLOW_PHOTOS=photo folder)
// import → select/rate/pick → adjust/rotate → adjustment layer → back and forth with layer edit → export five formats → web export
extension MainWindowController {
    func flowFieldTest() {
        guard let photos = ProcessInfo.processInfo.environment["DUOCHROME_FLOW_PHOTOS"].map({ URL(fileURLWithPath: $0) }) else {
            print("흐름 시험: 사진 폴더가 없음"); exit(1)
        }
        var results: [String] = []
        func check(_ name: String, _ ok: Bool, _ note: String = "") { results.append((ok ? "통과 " : "실패 ") + name + (note.isEmpty ? "" : "  " + note)); print(results.last!) }
        func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping (Bool) -> Void) {
            let t0 = Date()
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
                if cond() { t.invalidate(); then(true) } else if Date().timeIntervalSince(t0) > timeout { t.invalidate(); then(false) }
            }
        }
        let expected = ((try? FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)) ?? [])
            .filter { Library.supported.contains($0.pathExtension.lowercased()) }.count
        let t0 = CACurrentMediaTime()
        setMode(.library)
        openFolder(photos)
        wait({ self.library.items.count == expected }, 60) { ok in
            check("사진 가져오기 (폴더 열기)", ok, String(format: "%d장, %.1f초", self.library.items.count, CACurrentMediaTime() - t0))
            guard ok, let first = self.library.items.first else { return self.flowFinish(results) }
            self.show(first)
            wait({ self.photo?.url.standardizedFileURL == first.url.standardizedFileURL }, 30) { ok in
                check("사진 열기", ok)
                self.rate(4)
                self.flag(1)
                let item = self.library.items.first { $0.url == first.url }
                check("별점·채택", item?.rating == 4 && item?.flag == 1, "별점 \(item?.rating ?? -1), 채택 \(item?.flag ?? -1)")
                self.setMode(.edit)
                guard let doc = self.photo else { return self.flowFinish(results) }
                var s = doc.settings
                s.exposure = 0.4; s.contrast = 12; s.rotation = 2
                self.replaceSettings(s, recordUndo: true, label: "흐름 보정")
                check("보정·회전", doc.settings.exposure == 0.4 && doc.settings.rotation == 2)
                // Thumbnail-first drawing: one frame from the thumbnail, then immediately the real image
                let pf0 = self.canvas.placeholderFrames
                let gray = NSImage(size: NSSize(width: 320, height: 213), flipped: false) { r in NSColor.gray.setFill(); r.fill(); return true }
                self.canvas.placeholder = gray.cgImage(forProposedRect: nil, context: nil, hints: nil)
                self.canvas.draw()
                check("썸네일 먼저 그리기", self.canvas.placeholderFrames == pf0 + 1 && self.canvas.placeholder == nil)
                let n0 = doc.settings.layers.count
                self.layersTab.addLayer(.full, native: doc.nativeSize)
                check("조정 레이어 더하기", (self.photo?.settings.layers.count ?? 0) == n0 + 1)
                self.setMode(.studio)
                self.setMode(.edit)
                check("심화 보정 오가기", self.mode == .edit && self.photo === doc)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-flow-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var r = ExportRecipe(); r.folder = dir.path; r.keepMetadata = true
                for f in [ExportRecipe.Format.jpeg, .png, .heic, .tiff8, .tiff16] {
                    r.format = f
                    let t = CACurrentMediaTime()
                    let url = try? Exporter.export(doc, recipe: r, name: "flow-\(f.rawValue)")
                    let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
                    check("내보내기 \(f.title)", size > 100_000, String(format: "%.1f MB, %.1f초", Double(size) / 1e6, CACurrentMediaTime() - t))
                }
                // Web export (same encoder, no window)
                let small = doc.image(scale: 0.25)
                if let cg = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                    let d = WebExportWindow.encode(cg, type: .jpeg, quality: 0.8)
                    check("웹용 내보내기 (JPEG 80%)", (d?.count ?? 0) > 10_000, "\((d?.count ?? 0) / 1000) KB")
                } else { check("웹용 내보내기", false) }
                try? FileManager.default.removeItem(at: dir)
                // Undo back to the pre-test state
                for _ in 0..<3 { self.undoAdjust(nil) }
                self.rate(0); self.flag(0)
                self.flowFinish(results)
            }
        }
    }

    private func flowFinish(_ results: [String]) {
        if let out = ProcessInfo.processInfo.environment["DUOCHROME_AITEST_DIR"] {
            try? results.joined(separator: "\n").write(toFile: out + "/결과.txt", atomically: true, encoding: .utf8)
        }
        print("흐름 시험 끝")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}


// MARK: - Thumbnail speed (DUOCHROME_FIELDTEST=thumbs): rebuilds 12 adjusted photos through the real path
extension MainWindowController {
    func thumbBench(_ doc: RawDocument) {
        if library.items.count < 13 { library.show(.all) }
        let batch = Array(library.items.filter { $0 !== photoItem && !$0.offline }.prefix(12))
        let raws = batch.map { library.rawSettings(for: $0.url) }
        var d = settingsDict(doc.settings).filter { !Self.batchExcluded.contains($0.key) }
        d["exposure"] = 0.3; d["clarity"] = 15
        for item in batch {
            var dict = (library.rawSettings(for: item.url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            for (k, v) in d { dict[k] = v }
            library.saveRawSettings(dict, for: item.url)
            item.thumbnail = nil
        }
        let t0 = CACurrentMediaTime()
        refreshThumbnails(batch)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            guard !batch.contains(where: { $0.thumbnail == nil }) || CACurrentMediaTime() - t0 > 120 else { return }
            t.invalidate()
            let ms = (CACurrentMediaTime() - t0) * 1000
            let done = batch.filter { $0.thumbnail != nil }.count
            let size = batch.first?.thumbnail?.size ?? .zero
            print(String(format: "썸네일 %d장 %.0f ms (장당 %.0f ms), 크기 %.0f×%.0f", done, ms, ms / Double(max(done, 1)), size.width, size.height))
            for (item, raw) in zip(batch, raws) {
                if let raw, let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] { self.library.saveRawSettings(dict, for: item.url) } else { self.library.removeSettings(for: item.url) }
            }
            exit(0)
        }
    }
}


// MARK: - PSD write speed (DUOCHROME_FIELDTEST=psd): the same six layers as the field test
extension MainWindowController {
    func psdBench(_ doc: RawDocument) {
        let saved = doc.settings
        let n = doc.nativeSize
        var s = doc.settings
        s.layers = []   // so it's measured under the same conditions
        var t = AdjustLayer(name: "제목"); t.kind = "text"
        t.text = LayerText(string: "오후의 빛", font: "AppleSDGothicNeo-Bold", size: Double(n.height) / 12, color: [1, 1, 1], x: Double(n.width) * 0.08, y: Double(n.height) * 0.12)
        var styles = LayerStyles(); styles.dropShadow.enabled = true
        t.styles = styles
        var sh = AdjustLayer(name: "테두리"); sh.kind = "shape"
        sh.vector = VectorShape(path: .preset(.roundRect, in: CGRect(x: n.width * 0.05, y: n.height * 0.05, width: n.width * 0.9, height: n.height * 0.9), radius: 120), fill: nil, stroke: [1, 1, 1], strokeWidth: 30)
        var grad = AdjustLayer(name: "하늘 어둡게"); grad.mask.kind = .linear
        grad.mask.linear = [Double(n.width) / 2, Double(n.height), Double(n.width) / 2, Double(n.height) * 0.6]
        grad.adjust.exposure = -0.8
        var sel = AdjustLayer(name: "벽 선택 밝게"); sel.mask.kind = .polygon
        sel.mask.polygon = [0.3, 0.2, 0.7, 0.2, 0.7, 0.8, 0.3, 0.8].enumerated().map { $0.offset % 2 == 0 ? $0.element * Double(n.width) : $0.element * Double(n.height) }
        sel.mask.feather = 60; sel.adjust.exposure = 0.3
        var fx = AdjustLayer(name: "흐림 효과"); fx.kind = "adjust"
        var e = LayerEffect(kind: "gaussian"); e.params["radius"] = 6
        fx.adjust.effects = [e]; fx.opacity = 0.4
        s.layers += [grad, sel, fx, sh, t]
        replaceSettings(s, recordUndo: false)
        let pts = (0..<60).map { CGPoint(x: n.width * (0.2 + 0.01 * CGFloat($0)), y: n.height * 0.5 + sin(CGFloat($0) / 6) * 200) }
        layersTab.select(nil)
        paintStroke(pts, pressures: pts.map { _ in 1 }, erase: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-psdbench-\(UUID().uuidString).psd")
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CACurrentMediaTime()
            let ok = (try? PSDExport.write(doc, to: url)) != nil
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            // When measuring write-only memory, skip reading back (reading a 740 MB file whole raises the peak)
            let back = ProcessInfo.processInfo.environment["DUOCHROME_PSD_NOREAD"] != nil ? -1 : ((try? PSD.read(url))?.layers.count ?? -1)
            print(String(format: "PSD 쓰기 %@ %.1f초, %.0f MB, 다시 읽은 레이어 %d", ok ? "성공" : "실패", CACurrentMediaTime() - t0, Double(size) / 1e6, back))
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.replaceSettings(saved, recordUndo: false)
                exit(0)
            }
        }
    }
}
