import AppKit

/// 세 가지 작업 모드. 같은 카탈로그·같은 사진 선택을 함께 쓴다.
/// 세 모드: ① 대량 보정(격자 보기 포함) ② 심화 보정(레이어) ③ 테더링.
/// 번호는 저장된 설정과 맞추려고 그대로 둔다 (library = 대량 보정의 격자 보기).
enum AppMode: Int, CaseIterable {
    case library, edit, tether, studio
    var title: String { ["격자 보기", "대량 보정", "테더링", "심화 보정"][rawValue] }
    var symbol: String { ["square.grid.3x3", "slider.horizontal.below.rectangle", "camera", "paintbrush.pointed"][rawValue] }
    /// 모드 전환 키 (한 글자)
    var key: String { ["g", "e", "t", "p"][rawValue] }
    /// 모드 단추의 칸: 대량 보정(격자 포함) · 심화 보정 · 테더링
    var segment: Int { [0, 0, 2, 1][rawValue] }
    static let segments: [AppMode] = [.edit, .studio, .tether]
}

extension MainWindowController {
    // MARK: - 모드

    func setupModes() {
        libraryMode.grid.library = library
        libraryMode.onSearch = { [weak self] field in self?.searchPhotos(field) }
        libraryMode.onBack = { [weak self] in self?.toggleGridView(nil) }
        libraryMode.sources.catalog = library.catalog
        tetherMode.strip.library = library
        libraryTab.sources.catalog = library.catalog

        // 사진 묶음 고르기 (라이브러리 모드 왼쪽, 편집 모드 라이브러리 탭 — 둘은 같은 목록)
        for list in [libraryMode.sources, libraryTab.sources] {
            list.onSelect = { [weak self] source, title in self?.selectSource(source, title: title) }
            list.onAlbumsChanged = { [weak self] in self?.reloadSources() }
        }
        libraryTab.onImportCatalog = { [weak self] in self?.importExternalCatalog(nil) }

        // 라이브러리 격자
        let grid = libraryMode.grid
        grid.onSelectionChange = { [weak self] items in
            guard let self else { return }
            self.selection = items
            if let first = items.first { self.pendingItem = first }
            self.libraryMode.panel.show(items, clipboard: self.batchClipboardName)
        }
        grid.onOpen = { [weak self] item in self?.openInEditor(item) }
        grid.onRate = { [weak self] n in self?.rate(n) }
        browser.onRate = { [weak self] n in self?.rate(n) }
        tetherMode.strip.onRate = { [weak self] n in self?.rate(n) }
        tetherMode.strip.onSelect = { [weak self] item in self?.show(item) }

        let panel = libraryMode.panel
        panel.onRate = { [weak self] n in self?.rate(n) }
        panel.onColor = { [weak self] c in self?.tagColor(c) }
        panel.onOpen = { [weak self] in if let i = self?.selection.first { self?.openInEditor(i) } }
        panel.onCopyFromFirst = { [weak self] in self?.copyFromFirstSelected() }
        panel.onApplyClipboard = { [weak self] in self?.applyClipboardToSelection() }
        panel.onReset = { [weak self] in self?.resetSelection() }
        panel.albums = { [weak self] in (try? self?.library.catalog.albums()) ?? [] }
        panel.onAddToAlbum = { [weak self] id in self?.addSelection(toAlbum: id) }
        panel.onNewAlbum = { [weak self] in self?.newAlbumFromSelection() }
        panel.onRemoveFromAlbum = { [weak self] in self?.removeSelectionFromAlbum() }
        panel.onFlag = { [weak self] f in self?.flag(f) }
        panel.onAddKeywords = { [weak self] t in self?.addKeywords(t) }
        panel.onRemoveKeyword = { [weak self] id in self?.removeKeyword(id) }
        panel.keywordsFor = { [weak self] item in self?.library.catalog.keywords(of: item.id) ?? [] }
        panel.metadataFor = { [weak self] item in self?.library.catalog.metadata(item.id) ?? [:] }
        panel.onMeta = { [weak self] k, v in self?.setMetadata(k, v) }
        panel.onCommand = { [weak self] sel in _ = self?.perform(sel, with: nil) }
        BrowserCollectionView.onFlag = { [weak self] f in self?.flag(f) }
        // 촬영 정보 색인 (검색·스마트 앨범): 뒤에서 조금씩
        // (DB 연결은 주 스레드에서만 쓴다 → 주 스레드에서 조금씩)
        let cat = library.catalog
        if ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] == nil {
            // 파일 읽기는 뒤에서, DB 쓰기만 주 스레드에서 (예전에는 파일 읽기까지 주 스레드라 새 카탈로그 첫 1~2분에 화면이 끊겼다)
            func next() {
                let todo = cat.exifTodo(limit: 40)
                guard !todo.isEmpty else { return }
                DispatchQueue.global(qos: .background).async {
                    let rows = todo.map { Catalog.readExif($0.0, $0.1) }
                    DispatchQueue.main.async {
                        cat.storeExif(rows)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next() }
        }

        setupTether()
        setupStudio()
        let env = ProcessInfo.processInfo.environment
        let preferred = AppSettings.startMode >= 0 ? AppSettings.startMode : UserDefaults.standard.integer(forKey: "mode")
        let start = env["DUOCHROME_MODE"].flatMap(Int.init).flatMap(AppMode.init) ?? AppMode(rawValue: preferred) ?? .edit
        setMode(start)
    }

    /// 대표 사진: 라이브러리에서 고르기만 하고 아직 열지 않은 것.
    var pendingItem: PhotoItem? {
        get { objc_getAssociatedObject(self, &pendingKey) as? PhotoItem }
        set { objc_setAssociatedObject(self, &pendingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 격자 보기 ↔ 대량 보정 (오른쪽 사진 패널의 격자 단추, G 키와 같다)
    @objc func toggleGridView(_ sender: Any?) { setMode(mode == .library ? .edit : .library) }

    func setMode(_ m: AppMode) {
        guard let window else { return }
        let frame = window.frame
        // 떠나는 모드의 왼쪽·오른쪽 패널 폭 (새 모드가 이어받아 패널이 튀지 않게)
        let widths = sideWidths(mode)
        let leaving = mode
        mode = m
        // 심화 보정만 원본 크기, 나머지 모드는 미리보기만 (캔버스는 아래에서 다시 그린다)
        if let d = photo, d.previewOnly != (m != .studio) {
            d.previewOnly = m != .studio
            canvas.needsDisplay = true
            updateHistogram()
        }
        if leaving == .studio && m != .studio { leaveStudio() }
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        // 창 막대는 세 모드 공통 하나 (바꾸지 않는다). 모드마다 다른 것은 캔버스 위 모드별 막대에 있다.
        if let bar = bulkToolbar, window.toolbar !== bar { window.toolbar = bar }
        let vc: NSViewController = switch m {
        case .library: libraryMode
        case .edit: split
        case .tether: tetherMode
        case .studio: studioMode
        }
        if window.contentViewController !== vc {
            // 내용을 바꾸면 창이 새 뷰의 크기로 줄어든다 (처음 만든 뷰는 0×0이라 창이 사라졌다).
            // 새 뷰에 지금 크기를 먼저 주고 바꾼 뒤, 창 틀도 되돌린다.
            let content = window.contentLayoutRect.size
            vc.view.frame = NSRect(origin: .zero, size: content.width > 100 ? content : NSSize(width: 1560, height: 960))
            window.contentViewController = vc
            if frame.width > 400 && frame.height > 300 {
                window.setFrame(frame, display: true)
            } else {
                window.setContentSize(NSSize(width: 1560, height: 960))
                window.center()
            }
        }
        modeSegment = window.toolbar?.items.first { $0.itemIdentifier == .modeSwitch }?.view as? ModeSwitch
        modeSegment?.selectedSegment = m.segment
        syncMenuKeys()
        if ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil {
            NSLog("mode %@ frame %@ visible %d", m.title, NSStringFromRect(window.frame), window.isVisible ? 1 : 0)
        }
        switch m {
        case .library:
            // 목록은 화면이 처음 만들어지기 전에 채우려 하면 건너뛴다 → 들어올 때 채운다 (대량 보정에서 넘어오면 비어 있었다)
            libraryMode.sources.reload(select: library.source)
            libraryMode.grid.reload()
            if let item = photoItem { libraryMode.grid.mirror(item) }
            libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
            window.makeFirstResponder(nil)
            libraryMode.grid.focus()
        case .edit:
            // 라이브러리에서 고른 사진이 있으면 그걸 연다.
            if let p = pendingItem, p !== photoItem { show(p) }
            pendingItem = nil
            browser.reload()
            if let item = photoItem { browser.mirror(item) }
        case .tether:
            tetherMode.strip.reload()
            startTether()
        case .studio:
            enterStudio()
        }
        applySideWidths(widths, to: m)
        // 라이브러리(격자)에는 캔버스가 없어 확대 조절을 끈다
        studioZoomSlider?.isEnabled = m != .library
        if m == .library { studioZoomLabel?.stringValue = "" } else { activeCanvas.reportZoom() }
        // 마지막으로 창 틀을 처음 그대로 (모드마다 패널 최소 폭이 달라 밀리는 것까지 되돌린다)
        if frame.width > 400 && frame.height > 300, window.frame != frame { window.setFrame(frame, display: true) }
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        let m = AppMode.segments[max(0, min(sender.selectedSegment, AppMode.segments.count - 1))]
        setMode(m)
    }

    @objc func switchToLibrary(_ sender: Any?) { setMode(.library) }
    @objc func switchToEdit(_ sender: Any?) { setMode(.edit) }
    @objc func switchToTether(_ sender: Any?) { setMode(.tether) }
    @objc func switchToStudio(_ sender: Any?) { setMode(.studio) }

    func modeToolbarItem() -> NSToolbarItem {
        let seg = ModeSwitch(items: AppMode.segments.map {
            ($0.symbol, $0.title, "\($0.title) 모드 (\($0.key.uppercased()))" + ($0 == .edit ? " — 격자 보기는 G" : ""))
        })
        seg.selectedSegment = mode.segment
        seg.onPick = { [weak self] i in self?.setMode(AppMode.segments[max(0, min(i, AppMode.segments.count - 1))]) }
        modeSegment = seg
        let item = NSToolbarItem(itemIdentifier: .modeSwitch)
        item.label = "모드"
        item.view = seg
        item.isBordered = false
        return item
    }

    func openInEditor(_ item: PhotoItem) {
        pendingItem = item
        setMode(.edit)
    }

    // MARK: - 사진 묶음

    func selectSource(_ source: Catalog.Source, title: String) {
        leaveCurrentPhoto()
        library.show(source)
        sourceChanged(title: title)
    }

    /// 묶음이 바뀌면 세 모드의 브라우저를 다시 채운다.
    func sourceChanged(title: String) {
        window?.title = title
        window?.subtitle = "\(library.items.count)장"
        libraryMode.setTitle("\(title) · \(library.items.count)장")
        libraryMode.grid.reload()
        browser.reload()
        tetherMode.strip.reload()
        libraryMode.sources.reload(select: library.source)
        libraryTab.sources.reload(select: library.source)
        libraryMode.panel.show([], clipboard: batchClipboardName)
        selection = []
    }

    func reloadSources() {
        libraryMode.sources.reload(select: library.source)
        libraryTab.sources.reload(select: library.source)
    }

    /// 한 모드에서 고른 사진을 다른 모드 브라우저에도 표시한다.
    func mirrorSelection(_ item: PhotoItem) {
        browser.mirror(item)
        libraryMode.grid.mirror(item)
        tetherMode.strip.mirror(item)
        selection = libraryMode.grid.selectedItems
        libraryMode.panel.show(selection, clipboard: batchClipboardName)
    }

    func refreshItem(_ item: PhotoItem) {
        browser.refresh(item)
        libraryMode.grid.refresh(item)
        tetherMode.strip.refresh(item)
    }

    // MARK: - 별점·색 태그

    /// 지금 모드에서 대상이 되는 사진들: 라이브러리는 고른 것 전부, 나머지는 지금 사진.
    var targetItems: [PhotoItem] {
        if mode == .library { return libraryMode.grid.selectedItems }
        return photoItem.map { [$0] } ?? []
    }

    func rate(_ n: Int) {
        let items = targetItems
        guard !items.isEmpty else { return }
        library.setRating(items, n)
        items.forEach(refreshItem)
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
    }

    func tagColor(_ c: Int) {
        let items = targetItems
        guard !items.isEmpty else { return }
        library.setColor(items, c)
        items.forEach(refreshItem)
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
    }

    @objc func rateFromMenu(_ sender: NSMenuItem) { rate(sender.tag) }
    @objc func colorFromMenu(_ sender: NSMenuItem) { tagColor(sender.tag) }

    // MARK: - 여러 장 조정

    /// 사진마다 다른 것(리터칭 점·레이어·크롭)은 여러 장에 붙이지 않는다.
    static let batchExcluded: Set<String> = ["spots", "layers", "crop", "cropAspect"]

    func settingsDict(_ s: DevelopSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(s),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }

    func copyFromFirstSelected() {
        guard let item = libraryMode.grid.selectedItems.first else { return }
        var dict: [String: Any]
        if item === photoItem, let doc = photo {
            dict = settingsDict(doc.settings)
        } else if let data = library.rawSettings(for: item.url),
                  let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = saved
        } else {
            NSSound.beep(); return
        }
        batchClipboard = dict
        batchClipboardName = item.name
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
    }

    /// 편집 모드의 "조정 복사"도 여러 장 붙이기에 쓰이게 같이 담는다.
    func rememberForBatch(_ s: DevelopSettings, name: String) {
        batchClipboard = settingsDict(s)
        batchClipboardName = name
    }

    /// 붙일 갈래를 고르고 고른 사진 모두에 적용한다.
    func applyClipboardToSelection() {
        guard let window, batchClipboard != nil else { NSSound.beep(); return }
        let sheet = PasteGroupsSheet(title: "고른 사진 \(libraryMode.grid.selectedItems.count)장에 조정 적용", source: batchClipboardName)
        sheet.onApply = { [weak self] groups in self?.applyClipboardToSelection(groups) }
        pasteGroupsSheet = sheet
        window.beginSheet(sheet.window!)
    }

    var pasteGroupsSheet: PasteGroupsSheet? {
        get { objc_getAssociatedObject(self, &pasteKey) as? PasteGroupsSheet }
        set { objc_setAssociatedObject(self, &pasteKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func applyClipboardToSelection(_ groups: Set<AdjustGroup>) {
        guard let full = batchClipboard else { return }
        let keys = AdjustGroup.keys(groups)
        let clip = full.filter { keys.contains($0.key) }
        let items = libraryMode.grid.selectedItems
        for item in items {
            if item === photoItem, let doc = photo {
                var dict = settingsDict(doc.settings)
                for (k, v) in clip { dict[k] = v }
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let s = try? JSONDecoder().decode(DevelopSettings.self, from: data) {
                    replaceSettings(s, recordUndo: true)
                }
            } else {
                var dict = (library.rawSettings(for: item.url)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
                for (k, v) in clip { dict[k] = v }
                library.saveRawSettings(dict, for: item.url)
            }
            item.edited = true
            item.thumbnail = nil
            refreshItem(item)
        }
        refreshThumbnails(items)
    }

    func resetSelection() {
        let items = libraryMode.grid.selectedItems
        for item in items {
            if item === photoItem, let doc = photo {
                replaceSettings(doc.asShot, recordUndo: true)
            } else {
                library.removeSettings(for: item.url)
            }
            item.edited = false
            item.thumbnail = nil
            refreshItem(item)
        }
    }

    /// 조정을 바꾼 사진들의 썸네일을 차례로 새로 만든다 (원본이 있는 것만).
    func refreshThumbnails(_ items: [PhotoItem]) {
        let online = items.filter { !$0.offline && $0 !== photoItem }
        guard !online.isEmpty else { return }
        JobCenter.shared.add("thumbs", title: "썸네일 새로 만들기", count: online.count)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 두 장씩 함께 (RAW 해독은 안에서 한 줄로 서지만, 보정·그리기는 겹쳐 돈다)
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                for (n, item) in online.enumerated() where n % 2 == lane {
                    let tq = CACurrentMediaTime()
                    BackgroundGate.waitQuiet()
                    defer { JobCenter.shared.step("thumbs") }
                    let ti = CACurrentMediaTime()
                    guard let self, let doc = try? RawDocument(url: item.url) else { continue }
                    let tl = CACurrentMediaTime()
                    doc.quickDecode = true   // 썸네일(320px)이라 빠른 해독으로 충분하다
                    doc.approximateFromPreview = true   // 미리보기가 있으면 RAW를 풀지 않는다
                    if let s = DispatchQueue.main.sync(execute: { self.library.loadSettings(for: item.url, over: doc.asShot) }) { doc.settings = s }
                    // 썸네일 크기 그대로 푼다 (예전엔 1/8 = 긴 변 1024로 보정 전체를 돌린 뒤 줄여 한 장에 2초)
                    let scale = min(1.0 / 8, 360 / max(doc.nativeSize.width, doc.nativeSize.height, 1))
                    // 그리기는 이 스레드에서 (이 문서는 여기만 쓴다). 주 스레드에서 그리면 한 장에 1초씩 화면이 멈췄다
                    let ts = CACurrentMediaTime()
                    var tg = ts
                    let thumb = autoreleasepool { () -> NSImage? in
                        let img = doc.image(scale: scale)
                        tg = CACurrentMediaTime()
                        return Library.thumbnail(from: img)
                    }
                    if ProcessInfo.processInfo.environment["DUOCHROME_THUMBLOG"] != nil {
                        print(String(format: "썸네일 단계: 기다림 %.0f, 문서 %.0f, 설정 %.0f, 설계 %.0f, 그리기 %.0f ms", (ti - tq) * 1000, (tl - ti) * 1000, (ts - tl) * 1000, (tg - ts) * 1000, (CACurrentMediaTime() - tg) * 1000))
                    }
                    DispatchQueue.main.async {
                        if let thumb { item.thumbnail = thumb }
                        self.refreshItem(item)
                    }
                }
            }
        }
    }

    // MARK: - 앨범

    func addSelection(toAlbum id: Int64) {
        let ids = libraryMode.grid.selectedItems.map(\.id)
        try? library.catalog.addToAlbum(id, ids)
        reloadSources()
    }

    func newAlbumFromSelection() {
        let a = NSAlert()
        a.messageText = "새 앨범 이름"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "만들기")
        a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        guard let id = try? library.catalog.addAlbum(field.stringValue) else { return }
        addSelection(toAlbum: id)
    }

    func removeSelectionFromAlbum() {
        guard case .album(let id) = library.source else { NSSound.beep(); return }
        try? library.catalog.removeFromAlbum(id, libraryMode.grid.selectedItems.map(\.id))
        selectSource(library.source, title: window?.title ?? "")
    }

    // MARK: - 내보내기

    @objc func exportPhotos(_ sender: Any?) {
        guard let window else { return }
        let items = mode == .library ? libraryMode.grid.selectedItems : (photoItem.map { [$0] } ?? [])
        guard !items.isEmpty else { NSSound.beep(); return }
        let sheet = ExportSheet(count: items.count)
        sheet.library = library
        sheet.setJobs(items.map { ($0, $0 === photoItem ? photo : nil) })
        exportSheet = sheet
        window.beginSheet(sheet.window!)
    }

    var exportSheet: ExportSheet? {
        get { objc_getAssociatedObject(self, &exportKey) as? ExportSheet }
        set { objc_setAssociatedObject(self, &exportKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // MARK: - 외부 카탈로그

    @objc func importExternalCatalog(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "가져올 카탈로그(.cocatalog)를 고르세요. 카탈로그 파일은 읽기만 합니다."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "cocatalog" else {
            let a = NSAlert(); a.messageText = "카탈로그(.cocatalog)를 골라 주세요."; a.runModal(); return
        }
        runCatalogImport(url)
    }

    func runCatalogImport(_ url: URL) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "카탈로그 가져오는 중…")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let v = NSStackView(views: [spinner, label])
        v.edgeInsets = NSEdgeInsets(top: 30, left: 24, bottom: 30, right: 24)
        sheet.contentView = v
        window.beginSheet(sheet)
        let catalog = library.catalog, lib = library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CatalogImport.run(package: url, into: catalog, library: lib) { msg in
                DispatchQueue.main.async { label.stringValue = msg }
            } }
            DispatchQueue.main.async {
                window.endSheet(sheet)
                guard let self else { return }
                let a = NSAlert()
                switch result {
                case .success(let r):
                    a.messageText = "카탈로그를 가져왔습니다"
                    a.informativeText = r.summary + "\n\n원래 카탈로그 파일은 바뀌지 않았습니다. 오프라인 사진은 원본을 찾으면 다시 이을 수 있습니다 (다음 단계)."
                    self.reloadSources()
                    self.selectSource(.recentImport, title: "최근 가져오기")
                    self.setMode(.library)
                case .failure(let e):
                    a.messageText = "가져오지 못했습니다"
                    a.informativeText = e.localizedDescription
                }
                a.beginSheetModal(for: window)
            }
        }
    }

    // MARK: - 테더링

    var sessionFolder: URL {
        get {
            if let p = ProcessInfo.processInfo.environment["DUOCHROME_TETHER_FOLDER"] { return URL(fileURLWithPath: p) }
            if let p = UserDefaults.standard.string(forKey: "tether.folder") { return URL(fileURLWithPath: p) }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Duochrome/Tether/\(f.string(from: Date()))", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "tether.folder") }
    }

    func setupTether() {
        tetherMode.onShoot = { [weak self] in
            if let g = self?.gphoto, g.connected { g.shoot() } else { self?.tetherCamera?.shoot() }
        }
        tetherMode.onSetting = { [weak self] k, v in self?.gphoto?.set(k, v) }
        tetherMode.onLive = { [weak self] on in self?.gphoto?.live(on) }
        tetherMode.onAF = { [weak self] in self?.gphoto?.autofocus() }
        tetherMode.onFocus = { [weak self] s in self?.gphoto?.focus(s) }
        tetherMode.onZoom = { [weak self] z in self?.gphoto?.zoom(z) }
        tetherMode.onChooseFolder = { [weak self] in
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "이 폴더에 받기"
            guard p.runModal() == .OK, let url = p.url, let self else { return }
            self.sessionFolder = url
            self.tetherCamera?.folder = url
            self.gphoto?.folder = url
            self.hotFolder?.change(url)
            self.showSession()
        }
        tetherMode.onHotFolder = { [weak self] on in self?.setHotFolder(on) }
        tetherMode.onOpenInEditor = { [weak self] in self?.setMode(.edit) }
    }

    func startTether() {
        let folder = sessionFolder
        if gphoto == nil, tetherCamera == nil, ProcessInfo.processInfo.environment["DUOCHROME_NO_CAMERA"] == nil {
            // 기본: libgphoto2 (설정 변경·라이브 뷰·초점). 쓸 수 없으면 macOS 기본 방식으로
            let g = GPhotoCamera(folder: folder)
            g.onStatus = { [weak self] s in self?.tetherMode.setStatus(s) }
            g.onConnected = { [weak self] on in
                self?.tetherMode.setConnected(on)
                self?.tetherMode.setCanShoot(on)
            }
            g.onConfig = { [weak self] s in self?.tetherMode.showCameraSettings(s) }
            g.onCaps = { [weak self] c in self?.tetherMode.setCaps(c) }
            g.onLive = { [weak self] on in self?.tetherMode.setLive(on) }
            g.onFrame = { [weak self] img in self?.tetherMode.showFrame(img) }
            g.onDownloaded = { [weak self] url in self?.captured(url) }
            g.onUnavailable = { [weak self] why in
                guard let self else { return }
                self.gphoto = nil
                self.tetherMode.setStatus("테더링 도구를 쓸 수 없어 기본 방식으로: \(why)")
                self.startBasicTether(folder)
            }
            gphoto = g
            g.start()
        }
        setHotFolder(tetherMode.hotFolderOn || ProcessInfo.processInfo.environment["DUOCHROME_HOT"] != nil)
        showSession()
    }

    /// macOS 기본 ImageCaptureCore 테더링 (촬영·내려받기만)
    func startBasicTether(_ folder: URL) {
        if tetherCamera == nil {
            let cam = TetherCamera(folder: folder)
            cam.onStatus = { [weak self] s in
                self?.tetherMode.setStatus(s)
                self?.tetherMode.setCanShoot(cam.canShoot)
            }
            cam.onDownloaded = { [weak self] url in self?.captured(TetherNaming.rename(url)) }
            tetherCamera = cam
            cam.start()
        }
    }

    func setHotFolder(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
            if hotFolder == nil {
                let h = HotFolder(folder: sessionFolder)
                h.onNew = { [weak self] url in self?.captured(url) }
                hotFolder = h
            }
            hotFolder?.start()
        } else {
            hotFolder?.stop()
        }
    }

    /// 세션 폴더를 카탈로그에 등록하고 보여 준다.
    func showSession() {
        let folder = sessionFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if library.folder?.standardizedFileURL != folder.standardizedFileURL { openFolder(folder) }
        tetherMode.setFolder(folder, count: library.items.count)
    }

    /// 새로 찍혀 들어온 사진: 카탈로그에 넣고, 다음 촬영 조정을 붙이고, 바로 보여 준다.
    func captured(_ url: URL) {
        let previous = photo?.settings
        let previousName = photoItem?.name
        _ = try? library.catalog.addFolder(url.deletingLastPathComponent())
        library.show(library.source)
        sourceChanged(title: url.deletingLastPathComponent().lastPathComponent)
        tetherMode.setFolder(url.deletingLastPathComponent(), count: library.items.count)
        switch tetherMode.nextMode {
        case 1:
            if let p = previous {
                var d = settingsDict(p); for k in Self.batchExcluded { d[k] = nil }
                d["temperature"] = nil; d["tint"] = nil   // 화이트 밸런스는 사진마다 카메라 값 그대로
                library.saveRawSettings(d, for: url)
            }
        case 2:
            if let clip = batchClipboard { library.saveRawSettings(clip, for: url) }
        default: break
        }
        _ = previousName
        library.show(library.source)
        if let item = library.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            photoItem = nil
            show(item)
            tetherMode.strip.reload()
            tetherMode.strip.mirror(item)
        }
    }
}

private var pendingKey: UInt8 = 0
private var exportKey: UInt8 = 0
private var pasteKey: UInt8 = 0

// MARK: - 모드를 옮겨도 패널 폭 그대로

extension MainWindowController {
    /// 모드의 (왼쪽, 오른쪽) 패널 폭. 대량 보정·테더링은 분할 칸 폭, 심화 보정은 레이어 패널 + 여백(분할 칸과 같은 셈).
    /// 오른쪽은 사진 목록끼리(대량 보정·테더링)만 잇는다. 심화 보정 오른쪽은 다른 패널이라 따로 둔다.
    /// 모드의 (왼쪽, 오른쪽) 패널 폭 (유리 패널 자체 폭). 접혀 있으면 nil.
    func sideWidths(_ m: AppMode) -> (left: CGFloat?, right: CGFloat?) {
        func of(_ g: GlassLayoutController) -> (CGFloat?, CGFloat?) {
            (g.showsLeft ? g.leftWidth : nil, g.showsRight ? g.rightWidth : nil)
        }
        switch m {
        case .edit: return of(split)
        case .tether: return of(tetherMode.split)
        case .studio: return (studioMode.showsLayers ? studioMode.layersWidth.constant : nil,
                              studioMode.showsOptions ? studioMode.optionsWidth.constant : nil)
        case .library: return (nil, nil)
        }
    }

    /// 세 모드가 같은 패널 폭을 쓴다: 저장된 공통 폭을 들어가는 모드에 건다.
    /// (대량 보정·테더링은 같은 키로 저장하므로 끌어 바꾼 폭이 곧 공통 폭이다)
    func applySideWidths(_ w: (left: CGFloat?, right: CGFloat?), to m: AppMode) {
        let l = GlassLayoutController.sharedLeft, r = GlassLayoutController.sharedRight
        switch m {
        case .edit: split.leftWidth = l; split.rightWidth = r
        case .tether: tetherMode.split.leftWidth = l; tetherMode.split.rightWidth = r
        case .studio:
            studioMode.layersWidth.constant = l
            studioMode.optionsWidth.constant = r
            studioMode.updateCanvasInsets()
        case .library: break
        }
    }
}
