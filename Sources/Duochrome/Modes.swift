import AppKit

/// Three work modes sharing the same catalog and photo selection.
/// Three modes: ① batch edit (including grid view) ② layer edit (layers) ③ tethering.
/// Numbers are kept to match saved settings (library = batch edit's grid view).
enum AppMode: Int, CaseIterable {
    case library, edit, tether, studio
    var title: String { ["격자 보기", "대량 보정", "테더링", "심화 보정"][rawValue] }
    var symbol: String { ["square.grid.3x3", "slider.horizontal.below.rectangle", "camera", "paintbrush.pointed"][rawValue] }
    /// Mode switch key (single letter)
    var key: String { ["g", "e", "t", "p"][rawValue] }
    /// Mode button segments: batch edit (with grid) · layer edit · tethering
    var segment: Int { [0, 0, 2, 1][rawValue] }
    static let segments: [AppMode] = [.edit, .studio, .tether]
}

extension MainWindowController {
    // MARK: - Modes

    func setupModes() {
        libraryMode.grid.library = library
        libraryMode.onSearch = { [weak self] field in self?.searchPhotos(field) }
        libraryMode.onBack = { [weak self] in self?.toggleGridView(nil) }
        libraryMode.sources.catalog = library.catalog
        tetherMode.strip.library = library
        libraryTab.sources.catalog = library.catalog

        // Collection picker (library mode left, edit mode library tab — the same list)
        for list in [libraryMode.sources, libraryTab.sources] {
            list.onSelect = { [weak self] source, title in self?.selectSource(source, title: title) }
            list.onAlbumsChanged = { [weak self] in self?.reloadSources() }
        }
        libraryTab.onImportCatalog = { [weak self] in self?.importExternalCatalog(nil) }

        // library grid
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
        // Capture info index (search, smart albums): a little at a time in the background
        // (the DB connection is used only on the main thread → a little at a time there)
        let cat = library.catalog
        if ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] == nil {
            // File reads in the background, only DB writes on the main thread (file reads used to run on main too, so the UI stuttered for the first 1–2 minutes of a new catalog)
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

    /// Primary photo: selected in the library but not opened yet.
    var pendingItem: PhotoItem? {
        get { objc_getAssociatedObject(self, &pendingKey) as? PhotoItem }
        set { objc_setAssociatedObject(self, &pendingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Grid view ↔ batch edit (grid button on the right photo panel, same as the G key)
    @objc func toggleGridView(_ sender: Any?) { setMode(mode == .library ? .edit : .library) }

    func setMode(_ m: AppMode) {
        guard let window else { return }
        let frame = window.frame
        // Left/right panel widths of the mode being left (the new mode inherits them so panels don't jump)
        let widths = sideWidths(mode)
        let leaving = mode
        mode = m
        // Only layer edit uses full size; other modes use previews only (the canvas redraws below)
        if let d = photo, d.previewOnly != (m != .studio) {
            d.previewOnly = m != .studio
            canvas.needsDisplay = true
            updateHistogram()
        }
        if leaving == .studio && m != .studio { leaveStudio() }
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        // One toolbar shared by all modes (not swapped). Mode-specific items are in per-mode bars over the canvas.
        if let bar = bulkToolbar, window.toolbar !== bar { window.toolbar = bar }
        let vc: NSViewController = switch m {
        case .library: libraryMode
        case .edit: split
        case .tether: tetherMode
        case .studio: retouchEditor
        }
        if window.contentViewController !== vc {
            // Swapping content shrinks the window to the new view's size (the first view was 0×0, so the window vanished).
            // Give the new view the current size before swapping, then restore the window frame.
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
            // Filling the list before the UI is first built is skipped → fill on entry (it was empty coming from batch edit)
            libraryMode.sources.reload(select: library.source)
            libraryMode.grid.reload()
            if let item = photoItem { libraryMode.grid.mirror(item) }
            libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
            window.makeFirstResponder(nil)
            libraryMode.grid.focus()
        case .edit:
            // Open the photo selected in the library, if any.
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
        // The library (grid) has no canvas, so disable the zoom control
        studioZoomSlider?.isEnabled = m != .library
        if m == .library { studioZoomLabel?.stringValue = "" } else { activeCanvas.reportZoom() }
        // Finally restore the original window frame (also undoing shifts from different minimum panel widths per mode)
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

    // MARK: - Collections

    func selectSource(_ source: Catalog.Source, title: String) {
        leaveCurrentPhoto()
        library.show(source)
        sourceChanged(title: title)
    }

    /// When the collection changes, refill the browsers of all three modes.
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

    /// Mirrors a photo selected in one mode in the other modes' browsers.
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

    // MARK: - Ratings · color tags

    /// Photos targeted in the current mode: all selected in the library, the current photo elsewhere.
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

    // MARK: - Multi-photo adjustments

    /// Per-photo things (retouch spots, layers, crop) aren't pasted to many photos.
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

    /// Also stored so edit mode's "Copy Adjustments" works for multi-photo paste.
    func rememberForBatch(_ s: DevelopSettings, name: String) {
        batchClipboard = settingsDict(s)
        batchClipboardName = name
    }

    /// Pick groups to paste and apply to all selected photos.
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

    /// Rebuilds thumbnails of photos whose adjustments changed, in turn (only those with sources).
    func refreshThumbnails(_ items: [PhotoItem]) {
        let online = items.filter { !$0.offline && $0 !== photoItem }
        guard !online.isEmpty else { return }
        JobCenter.shared.add("thumbs", title: "썸네일 새로 만들기", count: online.count)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Two at a time (RAW decoding serializes internally, but adjusting and rendering overlap)
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                for (n, item) in online.enumerated() where n % 2 == lane {
                    let tq = CACurrentMediaTime()
                    BackgroundGate.waitQuiet()
                    defer { JobCenter.shared.step("thumbs") }
                    let ti = CACurrentMediaTime()
                    guard let self, let doc = try? RawDocument(url: item.url) else { continue }
                    let tl = CACurrentMediaTime()
                    doc.quickDecode = true   // Thumbnails (320 px) are fine with the fast decode
                    doc.approximateFromPreview = true   // If a preview exists, don't decode the RAW
                    if let s = DispatchQueue.main.sync(execute: { self.library.loadSettings(for: item.url, over: doc.asShot) }) { doc.settings = s }
                    // Decode at thumbnail size (it used to run the whole develop at 1/8 = 1024 long side and then shrink, 2 s per photo)
                    let scale = min(1.0 / 8, 360 / max(doc.nativeSize.width, doc.nativeSize.height, 1))
                    // Render on this thread (only this thread uses this document). Rendering on main froze the UI for a second per photo
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

    // MARK: - Albums

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
        a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        guard let id = try? library.catalog.addAlbum(field.stringValue) else { return }
        addSelection(toAlbum: id)
    }

    func removeSelectionFromAlbum() {
        guard case .album(let id) = library.source else { NSSound.beep(); return }
        try? library.catalog.removeFromAlbum(id, libraryMode.grid.selectedItems.map(\.id))
        selectSource(library.source, title: window?.title ?? "")
    }

    // MARK: - Export

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

    // MARK: - External catalogs

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

    // MARK: - Tethering

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
            // Default: libgphoto2 (settings, live view, focus). Falls back to the macOS built-in path if unavailable
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

    /// macOS built-in ImageCaptureCore tethering (capture and download only)
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

    /// Registers the session folder in the catalog and shows it.
    func showSession() {
        let folder = sessionFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if library.folder?.standardizedFileURL != folder.standardizedFileURL { openFolder(folder) }
        tetherMode.setFolder(folder, count: library.items.count)
    }

    /// Newly captured photo: add to the catalog, apply next-capture adjustments, and show it right away.
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
                d["temperature"] = nil; d["tint"] = nil   // White balance stays the camera value per photo
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

// MARK: - Panel widths persist across modes

extension MainWindowController {
    /// A mode's (left, right) panel widths. Batch edit and tethering use split pane widths; layer edit uses layers panel + margin (same accounting as split panes).
    /// Right side links only the photo lists (batch edit, tethering). Layer edit's right side is a different panel, kept separate.
    /// A mode's (left, right) panel widths (glass panel widths). nil when collapsed.
    func sideWidths(_ m: AppMode) -> (left: CGFloat?, right: CGFloat?) {
        func of(_ g: GlassLayoutController) -> (CGFloat?, CGFloat?) {
            (g.showsLeft ? g.leftWidth : nil, g.showsRight ? g.rightWidth : nil)
        }
        switch m {
        case .edit: return of(split)
        case .tether: return of(tetherMode.split)
        case .studio: return (retouchEditor.layersWidth.constant, retouchEditor.optionsWidth.constant)
        case .library: return (nil, nil)
        }
    }

    /// All three modes share panel widths: apply the saved shared width to the mode being entered.
    /// (batch edit and tethering save under the same key, so a dragged width becomes the shared width)
    func applySideWidths(_ w: (left: CGFloat?, right: CGFloat?), to m: AppMode) {
        let l = GlassLayoutController.sharedLeft, r = GlassLayoutController.sharedRight
        switch m {
        case .edit: split.leftWidth = l; split.rightWidth = r
        case .tether: tetherMode.split.leftWidth = l; tetherMode.split.rightWidth = r
        case .studio:
            retouchEditor.layersWidth.constant = l
            retouchEditor.optionsWidth.constant = r
            retouchEditor.updateCanvasInsets()
        case .library: break
        }
    }
}
