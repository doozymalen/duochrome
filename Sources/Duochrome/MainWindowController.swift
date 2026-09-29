import AppKit

/// Batch edit: left tool tabs (library, geometry, adjust, retouch, history, layers), photo in the center, photo list on the right.
/// Layer-edit mode is Studio.swift. All three modes share the same floating panel look.
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    /// Batch edit layout (GlassLayout.swift). Panel width = width of the glass panel itself.
    lazy var split = GlassLayoutController(content: viewer, left: tools, right: browser, key: GlassLayoutController.sharedKey,
                                           leftRange: GlassLayoutController.leftRange, rightRange: GlassLayoutController.rightRange,
                                           leftDefault: 288, rightDefault: 290)
    let library = Library(catalog: MainWindowController.openCatalog())

    /// Opens the default catalog. Test runs (DUOCHROME_SNAPSHOT, DUOCHROME_CATALOG) use their own — never touching the user catalog.
    static func openCatalog() -> Catalog {
        let env = ProcessInfo.processInfo.environment
        var url = AppSettings.catalogPath.map { URL(fileURLWithPath: $0) } ?? Catalog.defaultURL
        if let custom = env["DUOCHROME_CATALOG"] {
            url = URL(fileURLWithPath: custom)
        } else if env["DUOCHROME_SNAPSHOT"] != nil {
            url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test.duochromecatalog")
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let c = try Catalog(url: url)
            LayerImageStore.catalogURL = c.url
            CatalogMigration.run(c)
            return c
        } catch {
            NSLog("카탈로그를 열 수 없음: \(error) — 임시 카탈로그를 씁니다")
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-fallback.duochromecatalog")
            return try! Catalog(url: tmp)
        }
    }
    let libraryTab = LibraryTabController()
    let layersTab = LayersTabController()
    let inspector = InspectorViewController()
    let shape = ShapeTabController()
    /// Starting position while dragging an image layer.
    var imageMoveOrigin: CGPoint?
    var shapeMoveOrigin: VectorPath?
    /// Photo tabs in layer edit (in open order)
    var studioTabs: [PhotoItem] = []
    lazy var arrangeOptions = ArrangeOptionsView(host: self)
    lazy var adjustContainer = AdjustOptionsContainer(host: self)
    let retouch = RetouchTabController()
    lazy var tools = ToolPanelController(tabs: [
        .init(title: "라이브러리", symbol: "folder", controller: libraryTab),
        .init(title: "형태", symbol: "crop.rotate", controller: shape),
        .init(title: "조정", symbol: "slider.horizontal.3", controller: inspector),
        .init(title: "리터칭", symbol: "bandage", controller: retouch),
        .init(title: "내역", symbol: "clock.arrow.circlepath", controller: historyTab),
        .init(title: "레이어", symbol: "square.3.layers.3d", controller: layersTab),
    ])
    let viewer = ViewerController()
    let browser = BrowserViewController(header: true)
    private(set) var photo: RawDocument? {
        didSet { if photo !== oldValue { studioSelection = nil } }
    }
    var photoItem: PhotoItem?

    // the three modes (Modes.swift)
    let libraryMode = LibraryModeController()
    /// Layer-edit mode (Studio.swift)
    let studioMode = StudioModeController()
    /// Layer editor (Retouch/): replaces the older layer-edit view
    let retouchEditor = RetouchEditor()
    /// One toolbar shared by the three modes (mode-specific items live in per-mode bars over the canvas).
    var bulkToolbar: NSToolbar?
    /// Cursor tool buttons in the batch-edit mode bar (CanvasView.Tool order)
    var cursorButtons: [ModeBarButton] = []
    weak var clippingButton: ModeBarButton?
    weak var bulkSearchField: NSSearchField?
    weak var studioZoomSlider: NSSlider?
    weak var studioZoomLabel: NSTextField?
    /// Color picked with the color picker (shown in layer-edit tool options)
    lazy var pickerView: StudioPickerView = {
        let v = StudioPickerView()
        v.swatches.onPick = { [weak self] c in self?.applySwatch(c) }
        return v
    }()
    /// Layer-edit effects tool options (effect picker + editing the selected layer's effects)
    lazy var studioEffects = StudioEffectsPanel()
    /// Layer-edit styles tool options
    lazy var studioStyles = LayerStylesEditor()
    /// Pixel selection computation (rebuilt when the photo or settings change)
    var selectionEngineCache: (String, SelectionEngine)?
    /// Layer-edit selection (StudioSelection.swift). Belongs to the open photo, not saved.
    var studioSelection: LayerMask? {
        didSet { viewer.canvas.selectionMask = mode == .studio ? studioSelection : nil }
    }
    var selectAndMaskPanel: SelectAndMaskPanel?
    lazy var selectionOptions = SelectionOptionsView(host: self)
    /// Pen/shape/text tool options (VectorTools.swift)
    lazy var penOptions = PenOptionsView(host: self)
    lazy var shapeOptions = ShapeOptionsView(host: self)
    lazy var textOptions = TextOptionsView(host: self)
    /// Measure/count options, focus loupe (Workspace.swift)
    lazy var measureOptions = MeasureOptionsView(host: self)
    var focusLoupe: FocusLoupe?
    lazy var paintOptions: PaintOptionsView = {
        let v = PaintOptionsView()
        v.onTool = { [weak self] m in self?.startPainting(mode: m) }
        return v
    }()
    /// Selection add: the combine added in this drag (later updates in the same drag edit it)
    var comboGesture: Int = -1
    /// What couldn't be carried over from the last imported PSD (for self tests and alerts)
    var psdNotes: [String] = []
    var studioThumbCache: (url: URL, settings: DevelopSettings, image: NSImage)?
    var studioThumbPending: DevelopSettings?
    /// Jobs panel (JobCenter.swift)
    var jobsPanel: JobsPanel?
    /// Second display view
    var secondViewer: SecondViewerWindow?
    let tetherMode = TetherModeController()
    var mode: AppMode = .edit
    var tetherCamera: TetherCamera?
    var gphoto: GPhotoCamera?
    var hotFolder: HotFolder?
    weak var modeSegment: ModeSwitch?
    /// Photos selected in library mode (edit mode opens the primary one).
    var selection: [PhotoItem] = []
    /// Adjustments to paste to many photos (JSON dictionary — so they can be written to offline photos too).
    var batchClipboard: [String: Any]?
    var batchClipboardName: String?

    /// Adjustment undo. Nothing is pushed while dragging a slider; on release, one pre-drag value is pushed.
    var history = AdjustHistory()
    var colorPickPurpose = 0
    let historyTab = HistoryTabController()
    private var dragStart: DevelopSettings?
    private var clipboard: DevelopSettings?
    private var clipboardName: String?
    private var pasteSheet: PasteGroupsSheet?

    var canvas: CanvasView { viewer.canvas }

    init() {
        let window = DropWindow(contentRect: NSRect(x: 0, y: 0, width: 1560, height: 960),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.title = "Duochrome"
        window.minSize = NSSize(width: 1000, height: 600)
        window.toolbarStyle = .unified
        super.init(window: window)

        browser.library = library
        // Layout: left tool tabs, photo in the center, photo list on the right
        // Liquid Glass layout: the photo spans the window and the tool tabs (left) and photo list (right) float as glass
        split.onInsetsChange = { [weak self] l, r in self?.viewer.setSideInsets(left: l, right: r) }
        // Transparent toolbar too: the photo shows under the toolbar
        window.titlebarAppearsTransparent = true
        // Setting contentViewController shrinks the window to the view size. Reset the frame afterwards.
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1560, height: 960))
        window.center()
        window.setFrameAutosaveName("DuochromeMain")
        if UserDefaults.standard.object(forKey: "NSWindow Frame DuochromeMain") == nil { window.center() }

        let toolbar = NSToolbar(identifier: "DuochromeToolbar")
        toolbar.delegate = self
        // Guidelines: toolbar shows icons only, descriptions as tooltips
        toolbar.displayMode = .iconOnly
        // If a saved item configuration beats the code's default list, new items never appear (learned in Meridian).
        toolbar.autosavesConfiguration = false
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.modeSwitch]
        window.toolbar = toolbar
        bulkToolbar = toolbar
        viewer.bar = makeBulkBar()

        window.onDrop = { [weak self] url in self?.openFileOrFolder(url) }
        jobsPanel = JobsPanel(host: window)
        // If it was open at quit, reopen on next launch (after the window settles)
        if jobsPanel?.visibility == .open { DispatchQueue.main.async { [weak self] in self?.jobsPanel?.reload() } }
        libraryTab.onOpenFolder = { [weak self] in self?.chooseFolder() }
        libraryTab.onPickRecent = { [weak self] url in self?.openFolder(url) }
        browser.onSelect = { [weak self] item in self?.show(item) }
        // Redraw when the document finishes measuring values in the background (dehaze airlight etc.)
        NotificationCenter.default.addObserver(forName: RawDocument.needsRedraw, object: nil, queue: .main) { [weak self] n in
            guard let self, let d = n.object as? RawDocument, d === self.photo else { return }
            self.canvas.needsDisplay = true
            self.updateHistogram()
            self.secondViewer?.refresh()
        }
        browser.onSearch = { [weak self] field in self?.searchPhotos(field) }
        browser.onGridToggle = { [weak self] in self?.toggleGridView(nil) }
        canvas.onSample = { [weak self] rgb in self?.inspector.showSample(rgb) }
        inspector.onChange = { [weak self] settings, dragging in
            guard let self, let doc = self.photo else { return }
            var merged = settings
            merged.adoptNonAdjust(from: doc.settings)
            self.apply(merged, dragging: dragging)
        }
        inspector.layerList = { [weak self] in
            [(nil, "배경 (RAW 현상)")] + (self?.photo?.settings.layers.reversed().map { ($0.id, $0.name) } ?? [])
        }
        inspector.currentLayer = { [weak self] in self?.layersTab.selectedID }
        inspector.onPickLayer = { [weak self] id in
            guard let self else { return }
            self.layersTab.select(id)
            if id != nil { self.tools.select(self.tools.index(of: "레이어")) }
        }
        inspector.addLayerMenu = { [weak self] in self?.layerContextMenu(nil) ?? NSMenu() }
        inspector.moreMenu = { [weak self] in
            let m = NSMenu()
            guard let self else { return m }
            m.addItem(ClosureMenuItem("자동 조정", key: "l") { [weak self] in self?.autoAdjust(nil) })
            m.addItem(ClosureMenuItem("조정 복사", key: "c", modifiers: [.command, .shift]) { [weak self] in self?.copyAdjustments(nil) })
            m.addItem(ClosureMenuItem("조정 적용", key: "v", modifiers: [.command, .shift]) { [weak self] in self?.pasteAdjustments(nil) })
            m.addItem(ClosureMenuItem("조정 골라 적용…") { [weak self] in self?.pasteAdjustmentsChoosing(nil) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("지금 조정을 스타일로 저장…") { [weak self] in self?.saveStyle(nil) })
            let st = NSMenuItem(title: "스타일 적용", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            for n in MainWindowController.styleNames() {
                sm.addItem(ClosureMenuItem(n) { [weak self] in
                    self?.applyStyle(named: n, strength: UserDefaults.standard.object(forKey: "styleStrength") as? Double ?? 1)
                })
            }
            if sm.items.isEmpty { sm.addItem(ClosureMenuItem("저장한 스타일 없음", enabled: false) {}) }
            st.submenu = sm
            m.addItem(st)
            return m
        }
        inspector.onResetAll = { [weak self] in self?.resetAdjustments(nil) }
        setupLayers()
        historyTab.onSnapshot = { [weak self] i in self?.restoreSnapshot(i) }
        historyTab.onMakeSnapshot = { [weak self] in self?.makeSnapshot() }
        historyTab.onDeleteSnapshot = { [weak self] i in self?.deleteSnapshot(i) }
        historyTab.onJump = { [weak self] i in
            guard let self, let s = self.history.jump(i) else { return }
            self.replaceSettings(s, recordUndo: false)
            self.syncHistory()
        }
        shape.current = { [weak self] in self?.photo?.settings }
        shape.onChange = { [weak self] settings, dragging in
            self?.inspector.adoptGeometry(settings)
            self?.apply(settings, dragging: dragging)
        }
        canvas.overlay.onCrop = { [weak self] crop, dragging in
            guard let self, var s = self.photo?.settings else { return }
            s.crop = crop
            self.inspector.adoptGeometry(s)
            self.apply(s, dragging: dragging)
        }
        setupRetouch()
        canvas.overlay.onKeystoneLines = { [weak self] vertical, horizontal in
            guard let self else { return }
            let c = self.canvas
            self.applyKeystoneLines(vertical.map { (c.imagePoint(at: $0.0), c.imagePoint(at: $0.1)) },
                                    horizontal: horizontal.map { (c.imagePoint(at: $0.0), c.imagePoint(at: $0.1)) })
        }
        shape.onKeystoneMode = { [weak self] m in self?.canvas.overlay.keystoneMode = m }
        shape.onAutoKeystone = { [weak self] m in self?.autoKeystone(m) }
        canvas.onPick = { [weak self] tool, point in
            if tool == .whiteBalance { self?.pickWhiteBalance(at: point) }
            if tool == .colorPick { self?.pickColor(at: point) }
        }
        inspector.onAutoWB = { [weak self] in self?.pickWhiteBalance(at: nil) }
        inspector.onAutoCard = { [weak self] id in self?.autoCard(id) }
        inspector.onViewRange = { [weak self] r in self?.viewer.canvas.rangePreview = r }
        inspector.onLevelPick = { [weak self] purpose in
            self?.colorPickPurpose = purpose
            self?.enterTool(purpose == 4 ? .whiteBalance : .colorPick)
        }
        inspector.onPickColor = { [weak self] purpose in
            self?.colorPickPurpose = purpose
            self?.enterTool(.colorPick)
        }
        canvas.overlay.onStraighten = { [weak self] deg in
            guard let self, var s = self.photo?.settings else { return }
            s.rotation = min(max(s.rotation + deg, -45), 45)
            self.inspector.adoptGeometry(s)
            self.apply(s, dragging: false)
        }

        if let tab = ProcessInfo.processInfo.environment["DUOCHROME_TAB"].flatMap(Int.init) {
            _ = tools.view
            tools.select(tab)
        }
        if let w = ProcessInfo.processInfo.environment["DUOCHROME_SIDEBAR"].flatMap(Double.init) {
            DispatchQueue.main.async { self.split.leftWidth = w - 12 }
        }
        setupModes()
        installDragAndDrop()
        if let last = UserDefaults.standard.string(forKey: "lastFolder"),
           FileManager.default.fileExists(atPath: last) {
            openFolder(URL(fileURLWithPath: last))
        } else {
            selectSource(.all, title: "모든 사진")
        }
    }

    required init?(coder: NSCoder) { fatalError("코드로만 만든다") }

    // MARK: - Folders and photos

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "열기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    func openFolder(_ url: URL) {
        leaveCurrentPhoto()
        library.open(folder: url)
        sourceChanged(title: url.lastPathComponent)
        libraryTab.showFolder(url, count: library.items.count)
    }

    /// For a file, opens its folder and selects the photo. For a folder, opens the folder.
    func openFileOrFolder(_ url: URL) {
        if url.pathExtension == DuochromeDocument.ext { openDuochromeDocument(url); return }
        if url.pathExtension == "cocatalog" { runCatalogImport(url); return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { openFolder(url); return }
        if library.folder?.standardizedFileURL.path != url.deletingLastPathComponent().standardizedFileURL.path {
            openFolder(url.deletingLastPathComponent())
        }
        browser.select(url)
    }

    func show(_ item: PhotoItem) {
        guard item !== photoItem else { return }
        BackgroundGate.touch()
        let openLog = ProcessInfo.processInfo.environment["DUOCHROME_OPENLOG"] != nil
        var tMark = CACurrentMediaTime(), marks: [String] = []
        func mark(_ n: String) { if openLog { let t = CACurrentMediaTime(); marks.append(String(format: "%@ %.0f", n, (t - tMark) * 1000)); tMark = t } }
        defer { if openLog { NSLog("열기 단계(ms): %@", marks.joined(separator: ", ")) } }
        leaveCurrentPhoto()
        mark("떠나기")
        if item.offline {
            // The source isn't at its path. Only show the imported thumbnail (adjustments wait for the source to return).
            photo = nil
            LayerThumbs.doc = nil
            photoItem = item
            viewer.showOffline(item)
            tetherMode.viewer.showOffline(item)
            window?.subtitle = item.name + " (오프라인)"
            libraryTab.showInfo(nil)
            mirrorSelection(item)
            return
        }
        do {
            let doc = try RawDocument(url: item.url)
            mark("문서")
            if let saved = library.loadSettings(for: item.url, over: doc.asShot) {
                doc.settings = saved
                if doc.applyImportedWB() { library.saveSettings(doc.settings, asShot: doc.asShot, for: item.url) }
            } else if let f = doc.psd {
                // On first open of a PSD, carry the layers over and save right away (later opens use the saved layers)
                let res = PSDImport.convert(f)
                doc.settings.layers = res.layers
                doc.settings.gammaBlend = true
                library.saveSettings(doc.settings, asShot: doc.asShot, for: item.url)
                item.edited = true
                if !res.notes.isEmpty { NSLog("PSD 가져오기: %@", res.notes.joined(separator: " / ")) }
                psdNotes = res.notes
            }
            doc.releasePSD()
            // Batch edit, grid, and tethering use previews only; only layer edit adjusts at full size
            doc.previewOnly = mode != .studio
            mark("설정")
            photo = doc
            LayerThumbs.doc = doc; LayerThumbs.backgroundThumb = nil
            rememberTab(item)
            DispatchQueue.main.async { [weak self] in self?.syncGuides(); self?.syncCounts() }
            photoItem = item
            history.reset(doc.settings)
            // Continue saved history if present (only when the last state matches the current settings)
            if let h = library.catalog.history(Library.key(for: item.url)) { _ = history.restore(h, current: doc.settings) }
            syncHistory()
            mark("내역")
            window?.subtitle = item.name
            window?.representedURL = item.url
            let beforeHooks = doc.settings
            applyDevHooks(doc)
            // Dev only: with DUOCHROME_COMMIT=1, values injected by hooks are saved as if the user changed them.
            if ProcessInfo.processInfo.environment["DUOCHROME_COMMIT"] != nil, doc.settings != beforeHooks {
                history.record("시험 값", doc.settings)
                commit()
            }
            NSLog("opened %@ exposure=%.2f clarity=%.0f edited=%d", item.name, doc.settings.exposure,
                  doc.settings.clarity, item.edited ? 1 : 0)
            // If there's no preview and the RAW must be decoded, show the thumbnail large first
            if !PreviewCache.shared.hasPreview(url: item.url, settings: SliderResponse.effective(doc.settings)),
               let cg = item.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                viewer.canvas.placeholder = cg
            }
            viewer.show(doc)
            mark("뷰어")
            tetherMode.viewer.show(doc)
            secondViewer?.show(doc)
            mirrorSelection(item)
            layersTab.nativeSizeHint = doc.nativeSize
            layersTab.select(nil)
            canvas.maskLayerID = nil
            libraryTab.showInfo(doc.info)
            inspector.show(doc)
            mark("조정 패널")
            shape.nativeSize = doc.nativeSize
            shape.sync(doc.settings)
            canvas.retouchOverlay.selected = nil
            syncRetouch(doc.settings)
            mark("형태·리터칭")
            enterTool(canvas.tool)
            updateHistogram()
            mark("히스토그램")
            if mode == .studio { studioMode.layersPanel.reload() }
            prefetchPreviews(around: item, current: doc)
            mark("미리 준비")
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
    }

    /// Before moving to another photo, update the thumbnail to the adjusted result (only planning here, rendering in the background — no stall when stepping)
    func leaveCurrentPhoto() {
        guard let doc = photo, let item = photoItem, item.edited else { return }
        let image = doc.image(scale: 1.0 / 8)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            BackgroundGate.waitQuiet()
            let thumb = Library.thumbnail(from: image)
            DispatchQueue.main.async {
                guard let self, let thumb else { return }
                item.thumbnail = thumb
                self.refreshItem(item)
            }
        }
    }

    // MARK: - Adjustments

    func apply(_ settings: DevelopSettings, dragging: Bool) {
        guard let doc = photo else { return }
        let settings = dragging ? settings : maskingNewLayers(settings, old: doc.settings)
        BackgroundGate.touch()
        if dragging && dragStart == nil { dragStart = doc.settings }
        let before = dragStart ?? doc.settings
        let oldSize = doc.pixelSize
        doc.draft = dragging
        doc.settings = settings
        if doc.pixelSize != oldSize && !doc.showFullFrame { canvas.zoomToFit() }
        canvas.overlay.crop = settings.crop
        syncRetouch(settings)
        syncLayers(settings, dragging: dragging)
        if !dragging { shape.sync(settings) }
        canvas.needsDisplay = true
        secondViewer?.refresh()
        updateHistogram()
        guard !dragging else { return }
        dragStart = nil
        if before != settings { recordHistory(from: before, to: settings) }
        commit()
        if before != settings { propagateMultiEdit(from: before, to: settings) }
    }

    /// Saves the released value and updates the browser badge.
    private func commit() {
        guard let doc = photo, let item = photoItem else { return }
        // Test runs don't touch the user's adjustments. Only the save test opens it via DUOCHROME_COMMIT.
        let env = ProcessInfo.processInfo.environment
        if env["DUOCHROME_SNAPSHOT"] != nil && env["DUOCHROME_COMMIT"] == nil { return }
        let wasEdited = item.edited
        library.saveSettings(doc.settings, asShot: doc.asShot, for: doc.url)
        if wasEdited != item.edited { refreshItem(item) }
        if item.edited, let h = history.encoded() { library.catalog.setHistory(Library.key(for: doc.url), h) }
        PreviewCache.shared.ensure(url: doc.url, settings: doc.settings)
    }

    /// When values change from outside the panel, like undo or paste.
    func replaceSettings(_ s: DevelopSettings, recordUndo: Bool, label: String? = nil) {
        guard let doc = photo else { return }
        BackgroundGate.touch()
        let previous = doc.settings
        defer { if recordUndo { propagateMultiEdit(from: previous, to: s) } }
        if recordUndo { recordHistory(from: doc.settings, to: s, label: label) }
        let oldSize = doc.pixelSize
        doc.draft = false
        doc.settings = s
        if doc.pixelSize != oldSize { canvas.zoomToFit() }
        inspector.show(doc)
        shape.sync(s)
        syncRetouch(s)
        syncLayers(s, dragging: false)
        canvas.overlay.crop = s.crop
        canvas.needsDisplay = true
        updateHistogram()
        commit()
    }

    @objc func undoAdjust(_ sender: Any?) {
        guard photo != nil, let prev = history.undo() else { return }
        replaceSettings(prev, recordUndo: false)
        syncHistory()
    }

    @objc func redoAdjust(_ sender: Any?) {
        guard photo != nil, let next = history.redo() else { return }
        replaceSettings(next, recordUndo: false)
        syncHistory()
    }

    /// Adds a history entry. Named from the changed groups ("노출·대비…", "리터칭 점", etc.).
    func recordHistory(from before: DevelopSettings, to after: DevelopSettings, label: String? = nil) {
        let name = label ?? {
            // If only overall strength changed, "강도 71%" (strength belongs to the exposure group for copying, so it got that name)
            if before.intensity != after.intensity {
                var b = before; b.intensity = after.intensity
                if b == after { return "강도 \(Int((after.intensity * 100).rounded()))%" }
            }
            let groups = AdjustGroup.changed(settingsDict(before), settingsDict(after))
            return groups.isEmpty ? "조정" : groups.map(\.title).joined(separator: " · ")
        }()
        history.record(name, after)
        recordActionStep(from: before, to: after, label: name)
        syncHistory()
    }

    func syncHistory() {
        historyTab.snapshots = history.snapshots.map(\.label)
        historyTab.entries = history.labels
        historyTab.current = history.index
    }

    @objc func resetAdjustments(_ sender: Any?) {
        guard let doc = photo else { return }
        replaceSettings(doc.asShot, recordUndo: true, label: "초기화")
    }

    /// Copy/apply adjustments. Per-photo camera values like white balance are carried over as is.
    @objc func copyAdjustments(_ sender: Any?) {
        clipboard = photo?.settings
        clipboardName = photoItem?.name
        if let s = photo?.settings, let name = photoItem?.name { rememberForBatch(s, name: name) }
    }

    /// Pastes only the remembered groups (initially everything except geometry, retouching, and layers).
    @objc func pasteAdjustments(_ sender: Any?) {
        guard let c = clipboard else { return }
        let saved = Set((UserDefaults.standard.stringArray(forKey: "pasteGroups") ?? []).compactMap(AdjustGroup.init))
        pasteGroups(c, saved.isEmpty ? Set(AdjustGroup.allCases.filter(\.defaultOn)) : saved)
    }

    /// Pick groups to paste (⌥⇧⌘V).
    @objc func pasteAdjustmentsChoosing(_ sender: Any?) {
        guard let window, let c = clipboard else { NSSound.beep(); return }
        let sheet = PasteGroupsSheet(title: "조정 적용", source: clipboardName)
        sheet.onApply = { [weak self] groups in self?.pasteGroups(c, groups) }
        pasteSheet = sheet
        window.beginSheet(sheet.window!)
    }

    func pasteGroups(_ c: DevelopSettings, _ groups: Set<AdjustGroup>) {
        guard let doc = photo else { return }
        var dict = settingsDict(doc.settings)
        let clip = settingsDict(c)
        for k in AdjustGroup.keys(groups) { dict[k] = clip[k] }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = try? JSONDecoder().decode(DevelopSettings.self, from: data) else { return }
        inspector.adoptGeometry(s)
        replaceSettings(s, recordUndo: true, label: "조정 적용 (\(groups.count)갈래)")
    }

    @objc func setCursorTool(_ sender: ModeBarButton) {
        guard let i = cursorButtons.firstIndex(of: sender) else { return }
        enterTool(CanvasView.Tool.allCases[i])
    }

    /// The crop tool shows the whole frame with the crop rect overlaid. Other tools show the cropped result.
    func enterTool(_ tool: CanvasView.Tool) {
        canvas.tool = tool
        // For tools not in the bar (color editor eyedropper etc.), no button lights up.
        for (i, b) in cursorButtons.enumerated() { b.isOn = CanvasView.Tool.allCases[i] == tool }
        guard let doc = photo else { return }
        let full = tool == .crop
        if doc.showFullFrame != full {
            doc.showFullFrame = full
            canvas.zoomToFit()
            updateHistogram()
        }
        canvas.overlay.crop = doc.settings.crop
        canvas.overlay.aspect = doc.settings.cropAspect > 0 ? CGFloat(doc.settings.cropAspect) : 0
        canvas.needsDisplay = true
    }

    /// Finds and applies keystone and fine rotation that make drawn lines (displayed image coordinates) vertical/horizontal.
    func applyKeystoneLines(_ vertical: [(CGPoint, CGPoint)], horizontal: [(CGPoint, CGPoint)] = []) {
        guard let doc = photo else { return }
        let s = doc.settings, native = doc.nativeSize, full = doc.showFullFrame
        applyKeystone(vertical: Geometry.framedLines(vertical, s, native: native, fullFrame: full),
                      horizontal: Geometry.framedLines(horizontal, s, native: native, fullFrame: full), robust: false)
    }

    /// Solved and applied as frame-coordinate lines.
    private func applyKeystone(vertical: [(CGPoint, CGPoint)], horizontal: [(CGPoint, CGPoint)], robust: Bool) {
        guard let doc = photo, !(vertical.isEmpty && horizontal.isEmpty) else { NSSound.beep(); return }
        var s = doc.settings
        let r = Geometry.solveKeystone(vertical: vertical, horizontal: horizontal, s, native: doc.nativeSize, robust: robust)
        if ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil {
            NSLog("keystone in: V %@ H %@ -> V %.2f H %.2f rot %.2f", "\(vertical)", "\(horizontal)", r.v, r.h, r.rotation)
        }
        s.keystoneV = r.v
        s.keystoneH = r.h
        s.rotation = r.rotation
        inspector.adoptGeometry(s)
        apply(s, dragging: false)
        shape.sync(s)
    }

    /// Auto keystone: finds straight lines in the 1/8 preview and solves. Uses only verticals or horizontals depending on the mode.
    func autoKeystone(_ mode: Geometry.KeystoneMode) {
        guard let doc = photo else { return }
        let found = doc.detectFramedLines()
        let v = mode == .horizontal ? [] : found.vertical
        let h = mode == .vertical ? [] : found.horizontal
        if ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil {
            NSLog("auto keystone %@: %d vertical, %d horizontal", mode.title, v.count, h.count)
        }
        guard !(v.isEmpty && h.isEmpty) else {
            NSSound.beep(); NSLog("자동 키스톤: 곧은 선을 찾지 못했습니다")
            return
        }
        applyKeystone(vertical: v, horizontal: h, robust: true)
    }

    /// Color editor / skin tone eyedropper: picks the color at that point (5×5 mean) from the current rendered result.
    func pickColor(at point: CGPoint) {
        guard let doc = photo else { return }
        let scale = Develop.guideScale
        let img = doc.image(scale: scale)
        var px = [Float](repeating: 0, count: 25 * 4)
        let r = CGRect(x: (point.x * scale - 2).rounded(.down), y: (point.y * scale - 2).rounded(.down), width: 5, height: 5)
        Render.context.render(img, toBitmap: &px, rowBytes: 5 * 16, bounds: r, format: .RGBAf, colorSpace: Render.displaySpace)
        var c = SIMD3<Float>(0, 0, 0)
        for i in 0..<25 { c += SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) }
        let avg = c / 25
        if colorPickPurpose == 20 || colorPickPurpose == 21 { normalizePicked(avg); return }
        if colorPickPurpose == 9 {
            // Layer-edit color picker: keeps the tool and just shows the picked color.
            pickerView.show(avg)
            return
        }
        if (30...32).contains(colorPickPurpose) {
            inspector.pickedCurve(colorPickPurpose, rgb: avg)
            enterTool(.pan)
            return
        }
        if colorPickPurpose == 2 || colorPickPurpose == 3 {
            // Levels black point uses the brightest channel, white point the darkest (so color doesn't blow to one side)
            inspector.pickedLevel(colorPickPurpose, value: colorPickPurpose == 2 ? max(avg.x, avg.y, avg.z) : min(avg.x, avg.y, avg.z))
            enterTool(.pan)
            return
        }
        let (h, s, v) = ColorLUT.hsv(avg)
        inspector.pickedColor(hue: h, sat: s, value: v, purpose: colorPickPurpose)
        enterTool(.pan)
    }

    /// A nil point means auto white balance.
    func pickWhiteBalance(at point: CGPoint?, done: (() -> Void)? = nil) {
        guard let doc = photo else { return }
        NSCursor.operationNotAllowed.push()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wb = doc.neutralWhiteBalance(at: point)
            DispatchQueue.main.async {
                NSCursor.pop()
                // Discard if the user moved to another photo during the computation.
                guard let self, self.photo === doc, var s = self.photo?.settings else { return }
                guard let wb else { NSSound.beep(); return }
                s.temperature = wb.temperature
                s.tint = wb.tint
                self.apply(s, dragging: false)
                self.inspector.show(doc)
                done?()
            }
        }
    }

    // MARK: - Retouching

    private func setupRetouch() {
        let o = canvas.retouchOverlay
        o.brushRadius = retouch.brush.radius
        o.toView = { [weak self] p in
            guard let self, let doc = self.photo else { return p }
            return self.canvas.viewPoint(forImage: doc.toDisplay(p))
        }
        o.fromView = { [weak self] p in
            guard let self, let doc = self.photo else { return p }
            return doc.toNative(self.canvas.imagePoint(at: p))
        }
        o.onAdd = { [weak self] p in self?.addSpot(at: p) }
        o.onAddStroke = { [weak self] pts in self?.addStroke(pts) }
        o.onAddPatch = { [weak self] pts in self?.addPatch(pts) }
        o.patchMode = retouch.brush.patch
        o.onEdit = { [weak self] i, spot, dragging in
            guard let self, let s = self.photo?.settings, self.targetSpots(s).indices.contains(i) else { return }
            self.editSpots(dragging: dragging) { $0[i] = spot }
        }
        o.onDelete = { [weak self] i in self?.removeSpot(i) }
        retouch.onBrushChange = { [weak self] b in
            self?.canvas.retouchOverlay.brushRadius = b.radius
            self?.canvas.retouchOverlay.patchMode = b.patch
            // Layer-edit mode: switching heal/clone/patch in the panel updates the tool bar too.
            if let self, self.mode == .studio, ["repair", "clone", "patch"].contains(self.studioMode.currentTool) {
                let id = b.patch ? "patch" : (b.kind == .heal ? "repair" : "clone")
                if id != self.studioMode.currentTool { self.studioMode.noteTool(id) }
            }
        }
        retouch.onRemoveLast = { [weak self] in
            guard let self, let s = self.photo?.settings, !self.targetSpots(s).isEmpty else { return }
            self.removeSpot(self.targetSpots(s).count - 1)
        }
        retouch.onRemoveSelected = { [weak self] in
            guard let i = self?.canvas.retouchOverlay.selected else { return }
            self?.removeSpot(i)
        }
        retouch.onRemoveAll = { [weak self] in
            guard let self, let s = self.photo?.settings, !self.targetSpots(s).isEmpty else { return }
            self.canvas.retouchOverlay.selected = nil
            self.editSpots { $0.removeAll() }
        }
        tools.onSelect = { [weak self] i in
            guard let self else { return }
            // Picking the retouch tab switches to the retouch tool; leaving it switches to the move tool.
            let title = self.tools.tabTitle(i)
            if title == "리터칭" { self.enterTool(.retouch) }
            else if title == "레이어" { if self.layersTab.selectedID != nil { self.enterTool(.mask) } }
            else if self.canvas.tool == .retouch || self.canvas.tool == .mask { self.enterTool(.pan) }
        }
    }

    /// Places a spot in source coordinates. The source position is chosen automatically where texture is similar.
    func addSpot(at p: CGPoint) {
        guard let doc = photo else { return }
        let b = retouch.brush
        let src = doc.autoSource(target: p, radius: b.radius)
        let n = editSpots { $0.append(RetouchSpot(kind: b.kind, targetX: p.x, targetY: p.y, sourceX: src.x, sourceY: src.y,
                                                  radius: b.radius, feather: b.feather, opacity: b.opacity)) }
        canvas.retouchOverlay.selected = n - 1
    }

    /// Adds one stroke. The source is the most similar spot among positions offset sideways along the stroke.
    func addStroke(_ pts: [CGPoint]) {
        guard let doc = photo, let first = pts.first else { return }
        let b = retouch.brush
        let o = doc.autoStrokeOffset(path: pts, radius: b.radius)
        let n = editSpots { $0.append(RetouchSpot(kind: b.kind, targetX: first.x, targetY: first.y,
                                                  sourceX: first.x + o.x, sourceY: first.y + o.y, radius: b.radius,
                                                  feather: b.feather, opacity: b.opacity, path: pts.flatMap { [$0.x, $0.y] })) }
        canvas.retouchOverlay.selected = n - 1
    }

    /// Adds one patch (source-coordinate lasso). The source is picked by texture similarity with a circle of the lasso's size.
    func addPatch(_ pts: [CGPoint]) {
        guard let doc = photo, pts.count >= 3 else { return }
        var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst() + [pts[0]]) {
            let c = a.x * b.y - b.x * a.y
            area += c; cx += (a.x + b.x) * c; cy += (a.y + b.y) * c
        }
        area /= 2
        guard abs(area) > 16 else { return }
        let center = CGPoint(x: cx / (6 * area), y: cy / (6 * area))
        let eqR = sqrt(abs(area) / .pi)
        let src = doc.autoSource(target: center, radius: eqR)
        let b = retouch.brush
        let n = editSpots { $0.append(RetouchSpot(kind: .heal, targetX: pts[0].x, targetY: pts[0].y,
                                                  sourceX: pts[0].x + src.x - center.x, sourceY: pts[0].y + src.y - center.y,
                                                  radius: min(max(eqR * 0.15, 6), 80), feather: b.feather, opacity: b.opacity,
                                                  path: pts.flatMap { [$0.x, $0.y] }, patch: true)) }
        canvas.retouchOverlay.selected = n - 1
    }

    func removeSpot(_ i: Int) {
        guard let s = photo?.settings, targetSpots(s).indices.contains(i) else { return }
        canvas.retouchOverlay.selected = nil
        editSpots { $0.remove(at: i) }
    }

    private func syncRetouch(_ s: DevelopSettings) {
        canvas.retouchOverlay.spots = targetSpots(s)
        retouch.showCount(targetSpots(s).count)
    }

    /// Where retouch spots go: the selected layer if it's a background copy, else the background (RAW develop).
    var retouchLayerID: String? {
        guard let id = layersTab.selectedID, photo?.settings.layers.first(where: { $0.id == id })?.isCopy == true else { return nil }
        return id
    }

    func targetSpots(_ s: DevelopSettings) -> [RetouchSpot] {
        if let id = retouchLayerID, let l = s.layers.first(where: { $0.id == id }) { return l.spots }
        return s.spots
    }

    /// Edits and applies the current target's retouch spots. Returns the spot count afterwards.
    @discardableResult
    func editSpots(dragging: Bool = false, _ f: (inout [RetouchSpot]) -> Void) -> Int {
        guard var s = photo?.settings else { return 0 }
        var n = 0
        if let id = retouchLayerID, let i = s.layers.firstIndex(where: { $0.id == id }) {
            f(&s.layers[i].spots); n = s.layers[i].spots.count
        } else {
            f(&s.spots); n = s.spots.count
        }
        apply(s, dragging: dragging)
        return n
    }

    @objc func toolRetouch(_ sender: Any?) { enterTool(.retouch) }
    @objc func toolMask(_ sender: Any?) { enterTool(.mask) }

    // MARK: - Layers

    private func setupLayers() {
        layersTab.current = { [weak self] in self?.photo?.settings }
        layersTab.onChange = { [weak self] s, dragging in self?.apply(s, dragging: dragging) }
        layersTab.onSelect = { [weak self] id in
            guard let self else { return }
            if self.mode == .studio { DispatchQueue.main.async { self.retouchEditor.reload() } }
            self.canvas.maskOverlay.adjustLayer = self.photo?.settings.layers.first { $0.id == id }
            if self.canvas.maskLayerID != nil { self.canvas.maskLayerID = id }
            if id != nil, self.mode != .studio, self.tools.tabTitle(self.tools.selected) == "레이어" { self.enterTool(.mask) }
        }
        layersTab.onShowMask = { [weak self] on in
            guard let self else { return }
            self.canvas.maskLayerID = on ? self.layersTab.selectedID : nil
        }
        let o = canvas.maskOverlay
        o.toView = { [weak self] p in
            guard let self, let doc = self.photo else { return p }
            return self.canvas.viewPoint(forImage: doc.toDisplay(p))
        }
        o.fromView = { [weak self] p in
            guard let self, let doc = self.photo else { return p }
            return doc.toNative(self.canvas.imagePoint(at: p))
        }
        o.onStroke = { [weak self] pts, optionErase in
            guard let self, var s = self.photo?.settings, let id = self.layersTab.selectedID,
                  let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
            guard !s.layers[i].locked else { NSSound.beep(); return }
            let t = self.layersTab
            var stroke = MaskStroke(points: pts.flatMap { [$0.x, $0.y] }, radius: t.brushRadius,
                                    hardness: t.brushHardness, flow: t.brushFlow, erase: optionErase || t.erase)
            if let tip = t.brushTip { stroke.tip = tip.file; stroke.spacing = Double(tip.spacing) / 100 }
            s.layers[i].mask.strokes.append(stroke)
            self.apply(s, dragging: false)
        }
        layersTab.onPlaceImage = { [weak self] in self?.placeImageLayer(nil) }
        o.onPoint = { [weak self] p, flags in
            guard let self else { return }
            switch self.studioMode.currentTool {
            case "selRow": self.rowColumnSelect(at: p, column: false, flags: flags)
            case "selColumn": self.rowColumnSelect(at: p, column: true, flags: flags)
            case "selWand": self.wandSelect(at: p, flags: flags)
            case "selColor": self.colorRangeSelect(at: p, flags: flags)
            default: break
            }
        }
        o.onPolygonFlags = { [weak self] pts, flags in
            var m = LayerMask(); m.kind = .polygon; m.polygon = pts.flatMap { [$0.x, $0.y] }
            self?.commitSelection(m, flags: flags, label: "다각형 선택")
        }
        o.onQuickStroke = { [weak self] pts, flags in self?.quickSelect(pts, flags: flags) }
        o.snapView = { [weak self] p in
            guard let self, let doc = self.photo, let eng = self.selectionEngine else { return p }
            let native = doc.toNative(self.canvas.imagePoint(at: p))
            let r = 12 / max(self.canvas.zoom, 0.01) / Develop.guideScale * Develop.guideScale
            let snapped = eng.snap(native, radius: r)
            return self.canvas.viewPoint(forImage: doc.toDisplay(snapped))
        }
        for r in [canvas.rulerTop, canvas.rulerLeft] {
            r.onGuide = { [weak self] vertical, v, dragging in self?.guideDragged(vertical: vertical, at: v, dragging: dragging) }
        }
        o.onMoveImage = { [weak self] a, b, dragging in
            guard let self, var s = self.photo?.settings, let id = self.layersTab.selectedID,
                  let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
            // Shape layer: move the whole path (snapping its center to guides/edges)
            if s.layers[i].kind == "shape", let v = s.layers[i].vector {
                guard !s.layers[i].locked else { if !dragging { NSSound.beep() }; return }
                let origin = self.shapeMoveOrigin ?? v.path
                self.shapeMoveOrigin = dragging ? origin : nil
                let c0 = CGPoint(x: origin.bounds.midX, y: origin.bounds.midY)
                let c1 = self.snapNative(CGPoint(x: c0.x + b.x - a.x, y: c0.y + b.y - a.y))
                var moved = origin
                for k in moved.anchors.indices {
                    var an = moved.anchors[k]
                    let dx = Double(c1.x - c0.x), dy = Double(c1.y - c0.y)
                    an.x += dx; an.y += dy; an.inX += dx; an.inY += dy; an.outX += dx; an.outY += dy
                    moved.anchors[k] = an
                }
                s.layers[i].vector?.path = moved
                self.apply(s, dragging: dragging)
                return
            }
            guard s.layers[i].image != nil || s.layers[i].text != nil else { return }
            guard !s.layers[i].locked else { if !dragging { NSSound.beep() }; return }
            // Text layers move the text anchor together with the imported image (if any)
            let start = s.layers[i].image.map { CGPoint(x: $0.cx, y: $0.cy) } ?? CGPoint(x: s.layers[i].text!.x, y: s.layers[i].text!.y)
            let origin = self.imageMoveOrigin ?? start
            self.imageMoveOrigin = dragging ? origin : nil
            let target = self.snapNative(CGPoint(x: origin.x + (b.x - a.x), y: origin.y + (b.y - a.y)))
            let dx = target.x - start.x, dy = target.y - start.y
            s.layers[i].image?.cx += dx
            s.layers[i].image?.cy += dy
            s.layers[i].text?.x += dx
            s.layers[i].text?.y += dy
            self.apply(s, dragging: dragging)
        }
        o.onPolygon = { [weak self] pts in
            guard let self, var s = self.photo?.settings, let id = self.layersTab.selectedID,
                  let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
            guard !s.layers[i].locked else { NSSound.beep(); return }
            let cur = s.layers[i].mask
            if let op = self.selectionOp(self.canvas.maskOverlay.startFlags), cur.kind != .full, !(cur.kind == .polygon && cur.polygon.isEmpty) {
                var sub = LayerMask(); sub.kind = .polygon; sub.polygon = pts.flatMap { [$0.x, $0.y] }
                s.layers[i].mask.combos = (cur.combos ?? []) + [MaskCombo(op: op, mask: sub)]
            } else {
                if cur.kind == .full { s.layers[i].mask.kind = .polygon }
                s.layers[i].mask.polygon = pts.flatMap { [$0.x, $0.y] }
            }
            self.apply(s, dragging: false)
        }
        o.onGradient = { [weak self] a, b, dragging in
            guard let self, var s = self.photo?.settings, let id = self.layersTab.selectedID,
                  let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
            guard !s.layers[i].locked else { if !dragging { NSSound.beep() }; return }
            if s.layers[i].isFill, s.layers[i].mask.kind == .full {
                // Fill layer: drag direction is the gradient direction
                s.layers[i].fillPoints = [a.x, a.y, b.x, b.y]
                self.apply(s, dragging: dragging)
                return
            }
            let o = self.canvas.maskOverlay
            let toolKind: LayerMask.Kind? = self.mode == .studio ? ["selRect": .rect, "selOval": .ellipse][self.studioMode.currentTool] : nil
            let cur = s.layers[i].mask
            let hasShape = (cur.kind == .rect || cur.kind == .ellipse) && (cur.box[0] != cur.box[2] || cur.box[1] != cur.box[3])
            if let op = self.selectionOp(o.startFlags), hasShape || (toolKind != nil && toolKind != cur.kind && cur.kind != .full) {
                // Selection add/subtract/intersect: one combine per drag
                var sub = LayerMask(); sub.kind = toolKind ?? cur.kind; sub.box = [a.x, a.y, b.x, b.y]
                var combos = cur.combos ?? []
                if self.comboGesture == o.gesture, !combos.isEmpty { combos[combos.count - 1] = MaskCombo(op: op, mask: sub) }
                else { combos.append(MaskCombo(op: op, mask: sub)); self.comboGesture = o.gesture }
                s.layers[i].mask.combos = combos
                self.apply(s, dragging: dragging)
                return
            }
            if let tk = toolKind, cur.kind == .full { s.layers[i].mask.kind = tk }
            switch s.layers[i].mask.kind {
            case .linear: s.layers[i].mask.linear = [a.x, a.y, b.x, b.y]
            case .rect, .ellipse: s.layers[i].mask.box = [a.x, a.y, b.x, b.y]
            case .radial:
                let r = hypot(b.x - a.x, b.y - a.y)
                s.layers[i].mask.radial = [a.x, a.y, r, r]
            default: return
            }
            self.apply(s, dragging: dragging)
        }
    }

    /// Picks a file as an image layer (import).
    @objc func placeImageLayer(_ sender: Any?) {
        guard photo != nil, let window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "이미지 레이어로 넣을 그림을 고르세요. 파일은 복사해 둡니다."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = panel.url, let self else { return }
            do {
                let file = try LayerImageStore.importFile(u)
                self.layersTab.addImageLayer(file: file, name: u.deletingPathExtension().lastPathComponent)
            } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func pasteImageLayer(_ sender: Any?) { guard photo != nil else { NSSound.beep(); return }; layersTab.pasteImage() }
    @objc func groupLayer(_ sender: Any?) { layersTab.groupSelected() }
    @objc func ungroupLayer(_ sender: Any?) { layersTab.ungroupSelected() }

    private func syncLayers(_ s: DevelopSettings, dragging: Bool) {
        canvas.maskOverlay.adjustLayer = s.layers.first { $0.id == layersTab.selectedID }
        canvas.maskOverlay.brushRadius = layersTab.brushRadius
        if !dragging { layersTab.sync(s); inspector.refreshLayers() }
        if !dragging, mode == .studio { retouchEditor.reload() }
        if !dragging, mode == .studio, studioMode.currentTool == "effects" { syncStudioEffects() }
        if !dragging, mode == .studio, studioMode.currentTool == "style" { syncStudioStyles() }
    }

    @objc func toggleMaskView(_ sender: Any?) {
        guard let id = layersTab.selectedID else { return }
        let on = canvas.maskLayerID == nil
        canvas.maskLayerID = on ? id : nil
        layersTab.setShowMask(on)
    }

    @objc func toolPan(_ sender: Any?) { enterTool(.pan) }
    @objc func toolKeystone(_ sender: Any?) { enterTool(.keystone) }
    @objc func toolWhiteBalance(_ sender: Any?) { enterTool(.whiteBalance) }
    @objc func toolZoom(_ sender: Any?) { enterTool(.zoom) }
    @objc func toolCrop(_ sender: Any?) { enterTool(.crop) }
    @objc func toolStraighten(_ sender: Any?) { enterTool(.straighten) }

    private var histogramGeneration = 0

    /// Called many times while dragging a slider, applies only the last request.
    func updateHistogram() {
        guard let doc = photo else { return }
        histogramGeneration += 1
        let gen = histogramGeneration
        let image = doc.analysisImage()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = HistogramData.compute(image, context: Render.context, space: Render.displaySpace)
            DispatchQueue.main.async {
                guard let self, gen == self.histogramGeneration else { return }
                self.inspector.histogram.data = data
                self.tetherMode.histogram.data = data
                self.inspector.curveEditor.histogram = data.luma
            }
        }
    }

    // MARK: - Toolbar

    /// Toolbar shared by the three modes: [left panel · zoom] … [mode switch (window center)] … [undo · compare · export · right panel].
    /// Mode-only tools live in the per-mode bar over the canvas (ModeBar).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        titleBarItems
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        if let item = titleBarItem(id) { return item }
        switch id {
        case .openFolder: return button("폴더 열기", "square.and.arrow.down", #selector(chooseFolderAction(_:)))
        case .resetAdjust: return button("초기화", "arrow.uturn.backward.circle", #selector(resetAdjustments(_:)))
        case .undoAdjust: return button("실행 취소", "arrow.uturn.backward", #selector(undoAdjust(_:)))
        case .redoAdjust: return button("다시 실행", "arrow.uturn.forward", #selector(redoAdjust(_:)))
        case .beforeAfter: return button("보정 전과 비교", "square.split.2x1", #selector(toggleOriginal(_:)))
        case .autoAdjust: return button("자동 조정 (⇧⌘A)", "wand.and.stars", #selector(autoAdjust(_:)))
        case .panelLeft: return button("왼쪽 패널 보기", "sidebar.left", #selector(toggleLeftPanel(_:)))
        case .panelRight: return button("오른쪽 패널 보기", "sidebar.right", #selector(toggleRightPanel(_:)))
        case .modeSwitch: return modeToolbarItem()
        default: return studioToolbarItem(id)
        }
    }

    @objc func chooseFolderAction(_ sender: Any?) { chooseFolder() }

    /// Dev only: DUOCHROME_DEVELOP="exposure=1.5,temperature=3800,tint=5", DUOCHROME_CLIPPING=1, DUOCHROME_ZOOM=actual
    private func applyDevHooks(_ doc: RawDocument) {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["DUOCHROME_DEVELOP"] {
            var s = doc.settings
            for pair in spec.split(separator: ",") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2, let v = Float(kv[1]) else { continue }
                let keys: [String: WritableKeyPath<DevelopSettings, Float>] = [
                    "exposure": \.exposure, "temperature": \.temperature, "tint": \.tint,
                    "contrast": \.contrast, "brightness": \.brightness, "saturation": \.saturation,
                    "highlight": \.highlightTone, "shadow": \.shadow, "white": \.white, "black": \.black,
                    "sharpness": \.sharpness, "detail": \.detail, "lumaNoise": \.lumaNoise,
                    "colorNoise": \.colorNoise, "moire": \.moire, "lens": \.lensCorrection,
                    "vignette": \.vignette, "inBlack": \.levelInBlack, "inWhite": \.levelInWhite,
                    "gamma": \.levelGamma, "outBlack": \.levelOutBlack, "outWhite": \.levelOutWhite,
                    "masterHue": \.color.master.hue, "masterAmount": \.color.master.amount,
                    "shadowHue": \.color.shadow.hue, "shadowAmount": \.color.shadow.amount,
                    "highHue": \.color.high.hue, "highAmount": \.color.high.amount,
                    "midLight": \.color.mid.lightness,
                    "clarity": \.clarity, "structure": \.structure, "dehaze": \.dehaze,
                    "edBlueSat": \.color.editor[5].dSat, "edBlueLight": \.color.editor[5].dLight,
                    "edGreenHue": \.color.editor[3].dHue, "skinHue": \.color.skin.hueAmount,
                    "filmCurve": \.filmCurve, "clarityMethod": \.clarityMethod, "dehazeHue": \.dehazeHue,
                    "dehazeTint": \.dehazeTint, "usm": \.sharpenAmount, "usmRadius": \.sharpenRadius,
                    "usmThreshold": \.sharpenThreshold, "usmHalo": \.sharpenHalo, "hotPixels": \.hotPixels,
                    "lensDistortion": \.lensDistortion, "lensCA": \.lensCA, "lensCABlue": \.lensCABlue, "lensVignette": \.lensVignette, "lensSharp": \.lensSharpFalloff,
                    "grainType": \.grainType, "grain": \.grainAmount, "grainSize": \.grainSize,
                    "rotation": \.rotation, "keystoneV": \.keystoneV, "keystoneH": \.keystoneH,
                    "keystoneAspect": \.keystoneAspect, "turns": \.quarterTurns, "flipH": \.flipH,
                    "bwRed": \.color.bw.red, "look": \.look, "bwBlue": \.color.bw.blue, "bwGreen": \.color.bw.green,
                ]
                if let k = keys[String(kv[0])] { s[keyPath: k] = v }
            }
            if env["DUOCHROME_BW"] != nil { s.color.bw.enabled = true }
            if env["DUOCHROME_NO_HLREC"] != nil { s.highlightRecoveryOn = false }
            doc.settings = s
        }
        // DUOCHROME_CURVE="rgb:0.25/0.15;0.75/0.85|red:0.5/0.6" — end points are added automatically.
        if let spec = env["DUOCHROME_CURVE"] {
            var set = doc.settings.curves
            for part in spec.split(separator: "|") {
                let kv = part.split(separator: ":")
                guard kv.count == 2, let ch = CurveSet.channels.first(where: { $0.0.lowercased() == kv[0].prefix(1).lowercased() || $0.0.lowercased() == kv[0].lowercased() }) else { continue }
                var pts = [CGPoint(x: 0, y: 0)]
                for p in kv[1].split(separator: ";") {
                    let xy = p.split(separator: "/").compactMap { Double($0) }
                    if xy.count == 2 { pts.append(CGPoint(x: xy[0], y: xy[1])) }
                }
                pts.append(CGPoint(x: 1, y: 1))
                set[keyPath: ch.1] = ToneCurve(points: pts)
            }
            doc.settings.curves = set
        }
        if env["DUOCHROME_CLIPPING"] != nil { canvas.showClipping = true }
        if env["DUOCHROME_SPLIT"] != nil { canvas.splitCompare = true }
        if env["DUOCHROME_MASKGRAY"] != nil { canvas.maskGray = true }
        // DUOCHROME_CROP="x,y,w,h" (0–1), DUOCHROME_TOOL=0–3 (move, zoom, crop, straighten)
        if let c = env["DUOCHROME_CROP"]?.split(separator: ",").compactMap({ Double($0) }), c.count == 4 {
            doc.settings.crop = CropRect(CGRect(x: c[0], y: c[1], width: c[2], height: c[3]))
        }
        // DUOCHROME_WB_PICK="x,y", DUOCHROME_KEYSTONE_LINES="x1,y1,x2,y2;x3,y3,x4,y4" (displayed image coordinates, source pixels)
        if let v = env["DUOCHROME_WB_PICK"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 2 {
            DispatchQueue.main.async {
                let t0 = CACurrentMediaTime()
                self.pickWhiteBalance(at: CGPoint(x: v[0], y: v[1])) {
                let ms = (CACurrentMediaTime() - t0) * 1000
                // Check the result: color of that point in the final view (1/8)
                let img = doc.image(scale: 1.0 / 8)
                var px = [UInt8](repeating: 0, count: 4 * 9)
                Render.context.render(img, toBitmap: &px, rowBytes: 12,
                                      bounds: CGRect(x: (v[0] / 8).rounded(.down) - 1, y: (v[1] / 8).rounded(.down) - 1, width: 3, height: 3),
                                      format: .RGBA8, colorSpace: Render.displaySpace)
                let rgb = (0..<3).map { c in (0..<9).map { Int(px[$0 * 4 + c]) }.reduce(0, +) / 9 }
                NSLog("wb pick -> %.0fK tint %.1f (%.0f ms) result RGB %d %d %d", doc.settings.temperature,
                      doc.settings.tint, ms, rgb[0], rgb[1], rgb[2])
                }
            }
        }
        if let spec = env["DUOCHROME_KEYSTONE_LINES"] {
            let lines = spec.split(separator: ";").compactMap { l -> (CGPoint, CGPoint)? in
                let v = l.split(separator: ",").compactMap { Double($0) }
                return v.count == 4 ? (CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3])) : nil
            }
            DispatchQueue.main.async {
                self.applyKeystoneLines(lines)
                NSLog("keystone lines -> V %.1f rot %.2f", doc.settings.keystoneV, doc.settings.rotation)
            }
        }
        // DUOCHROME_RENDER_DUMP="x,y,w,h:scale:path" — a region rendered at that scale with saved adjustments (source pixel coordinates)
        if let d = env["DUOCHROME_RENDER_DUMP"]?.split(separator: ":"), d.count == 3, let sc = Double(d[1]) {
            let v = d[0].split(separator: ",").compactMap { Double($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let k = CGFloat(sc)
                let r = CGRect(x: v[0] * k, y: v[1] * k, width: v[2] * k, height: v[3] * k)
                try? Render.context.writePNGRepresentation(of: doc.image(scale: k).cropped(to: r),
                    to: URL(fileURLWithPath: String(d[2])), format: .RGBA8, colorSpace: Render.displaySpace)
                NSLog("render dump %@ at %.3f", String(d[2]), sc)
            }
        }
        // DUOCHROME_AI_SELECT=subject|background|person — one AI selection layer, mask shown in grayscale
        if let t = env["DUOCHROME_AI_SELECT"], let target = ["subject": AISelect.Target.subject, "background": .background, "person": .person][t] {
            DispatchQueue.main.async {
                let started = CACurrentMediaTime()
                self.addAISelection(target) {
                    NSLog("AI 선택 %@: %.0f ms", t, (CACurrentMediaTime() - started) * 1000)
                    self.canvas.maskGray = true
                    self.canvas.maskLayerID = self.photo?.settings.layers.last?.id
                }
            }
        }
        // DUOCHROME_STUDIO_TOOL=tool id, DUOCHROME_STUDIO_CUSTOMIZE=1 — for checking the layer-edit mode look
        if let t = env["DUOCHROME_STUDIO_TOOL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if self.mode == .studio { self.studioMode.selectTool(t) } }
        }
        if env["DUOCHROME_STUDIO_CUSTOMIZE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.mode == .studio { self.studioMode.customize() } }
        }
        // DUOCHROME_AUTO_KEYSTONE=0|1|2 (vertical, horizontal, both)
        if let m = env["DUOCHROME_AUTO_KEYSTONE"].flatMap(Int.init).flatMap(Geometry.KeystoneMode.init) {
            DispatchQueue.main.async {
                self.autoKeystone(m)
                NSLog("auto keystone -> V %.1f H %.1f rot %.2f", doc.settings.keystoneV, doc.settings.keystoneH, doc.settings.rotation)
            }
        }
        // DUOCHROME_SPOTS="x,y,r;x,y,r" (decoded source coordinates) — source positions automatic
        if let spec = env["DUOCHROME_SPOTS"] {
            DispatchQueue.main.async {
                for part in spec.split(separator: ";") {
                    let v = part.split(separator: ",").compactMap { Double($0) }
                    guard v.count == 3 else { continue }
                    self.retouch.brush.radius = v[2]
                    self.addSpot(at: CGPoint(x: v[0], y: v[1]))
                }
                // DUOCHROME_DUMP_REGION="x,y,w,h:path" — saves a region of the full-resolution result (displayed image coordinates)
                if let d = env["DUOCHROME_DUMP_REGION"]?.split(separator: ":"), d.count == 2 {
                    let v = d[0].split(separator: ",").compactMap { Double($0) }
                    let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                    try? Render.context.writePNGRepresentation(of: doc.image(scale: 1).cropped(to: r),
                        to: URL(fileURLWithPath: String(d[1])), format: .RGBA8, colorSpace: Render.displaySpace)
                    try? Render.context.writePNGRepresentation(of: doc.originalImage(scale: 1).cropped(to: r),
                        to: URL(fileURLWithPath: String(d[1]) + ".before.png"), format: .RGBA8, colorSpace: Render.displaySpace)
                }
                // DUOCHROME_MERGE_TEST=1: simulates the adjust tab moving a slider with pre-spot values → spots must survive
                if env["DUOCHROME_MERGE_TEST"] != nil {
                    var stale = doc.settings
                    stale.spots = []
                    stale.exposure += 0.5
                    self.inspector.onChange?(stale, false)
                    NSLog("merge test: spots %d exposure %.2f", doc.settings.spots.count, doc.settings.exposure)
                }
                NSLog("spots: %@", doc.settings.spots.map { String(format: "(%.0f,%.0f)←(%.0f,%.0f) r%.0f", $0.targetX, $0.targetY, $0.sourceX, $0.sourceY, $0.radius) }.joined(separator: " "))
            }
        }
        // DUOCHROME_STROKE="x,y;x,y;…|r" (source coordinates) — one stroke
        if let spec = env["DUOCHROME_STROKE"]?.split(separator: "|"), spec.count == 2, let r = Double(spec[1]) {
            let pts = spec[0].split(separator: ";").compactMap { p -> CGPoint? in
                let v = p.split(separator: ",").compactMap { Double($0) }
                return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
            }
            DispatchQueue.main.async {
                self.retouch.brush.radius = r
                self.addStroke(pts)
                if let s = doc.settings.spots.last { NSLog("stroke: %d pts offset (%.0f, %.0f)", pts.count, s.offset.x, s.offset.y) }
                if let d = env["DUOCHROME_DUMP_REGION"]?.split(separator: ":"), d.count == 2 {
                    let v = d[0].split(separator: ",").compactMap { Double($0) }
                    let rect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                    // DUOCHROME_DUMP_SCALE=0.5 etc.: result rendered at the draft stage (coordinates in source pixels)
                    let sc = CGFloat(Double(env["DUOCHROME_DUMP_SCALE"] ?? "") ?? 1)
                    let r2 = CGRect(x: rect.minX * sc, y: rect.minY * sc, width: rect.width * sc, height: rect.height * sc)
                    try? Render.context.writePNGRepresentation(of: doc.image(scale: sc).cropped(to: r2),
                        to: URL(fileURLWithPath: String(d[1])), format: .RGBA8, colorSpace: Render.displaySpace)
                    try? Render.context.writePNGRepresentation(of: doc.originalImage(scale: 1).cropped(to: rect),
                        to: URL(fileURLWithPath: String(d[1]) + ".before.png"), format: .RGBA8, colorSpace: Render.displaySpace)
                }
            }
        }
        // DUOCHROME_IMAGE_LAYER="image path[:blend[:opacity[:fill]]]" — one image layer
        if let spec = env["DUOCHROME_IMAGE_LAYER"]?.split(separator: ":").map(String.init), let path = spec.first {
            DispatchQueue.main.async {
                guard let file = try? LayerImageStore.importFile(URL(fileURLWithPath: path)) else { NSLog("이미지 레이어 실패"); return }
                self.layersTab.addImageLayer(file: file, name: "시험 그림")
                guard var s = self.photo?.settings, let i = s.layers.indices.last else { return }
                if spec.count > 1 { s.layers[i].blend = spec[1] }
                if spec.count > 2, let o = Float(spec[2]) { s.layers[i].opacity = o }
                if spec.count > 3, let f = Float(spec[3]) { s.layers[i].fill = f }
                if env["DUOCHROME_GROUP_IT"] != nil { _ = LayerTree.groupLayer(&s.layers, i, name: "시험 그룹"); s.layers[s.layers.count - 1].opacity = 0.5 }
                self.apply(s, dragging: false)
            }
        }
        // DUOCHROME_LAYER="linear:exposure=-1.5,saturation=40" — one layer with the default shape, DUOCHROME_SHOWMASK=1
        // Dev only: check layer style looks (shadow, stroke, bevel on an ellipse fill layer)
        if env["DUOCHROME_STYLE_DEMO"] != nil {
            DispatchQueue.main.async {
                guard var s = self.photo?.settings else { return }
                var l = AdjustLayer(name: "스타일 시험")
                l.kind = "fill"
                l.fillColor = [0.95, 0.55, 0.2]
                l.mask.kind = .ellipse
                let n = doc.nativeSize
                l.mask.box = [n.width * 0.3, n.height * 0.3, n.width * 0.6, n.height * 0.7]
                var st = LayerStyles()
                st.dropShadow.enabled = true; st.dropShadow.distance = 60; st.dropShadow.size = 80
                st.stroke.enabled = true; st.stroke.size = 25
                st.bevel.enabled = true; st.bevel.size = 60
                l.styles = st
                s.layers.append(l)
                self.apply(s, dragging: false)
            }
        }
        // Dev only: three layers for checking drag and drop (three full layers, the last inside a group)
        if env["DUOCHROME_TEST_LAYERS"] != nil, doc.settings.layers.isEmpty {
            DispatchQueue.main.async {
                for _ in 0..<3 { self.layersTab.addLayer(.full, native: doc.nativeSize) }
                self.layersTab.groupSelected()
                if self.mode == .studio { self.studioMode.layersPanel.reload() }
            }
        }
        if let spec = env["DUOCHROME_LAYER"]?.split(separator: ":"), spec.count >= 1,
           let kind = LayerMask.Kind(rawValue: String(spec[0])) {
            DispatchQueue.main.async {
                self.layersTab.addLayer(kind, native: doc.nativeSize)
                guard var s = self.photo?.settings, let i = s.layers.indices.last else { return }
                if spec.count > 1 {
                    let keys: [String: WritableKeyPath<LocalAdjust, Float>] = [
                        "exposure": \.exposure, "contrast": \.contrast, "brightness": \.brightness, "saturation": \.saturation,
                        "highlight": \.highlightTone, "shadow": \.shadow, "clarity": \.clarity, "dehaze": \.dehaze,
                        "temperature": \.temperature, "tint": \.tint]
                    for kv in spec[1].split(separator: ",") {
                        let p = kv.split(separator: "=")
                        if p.count == 2, let k = keys[String(p[0])], let v = Float(p[1]) { s.layers[i].adjust[keyPath: k] = v }
                    }
                }
                if let stroke = env["DUOCHROME_MASK_STROKE"] {
                    let v = stroke.split(separator: ",").compactMap { Double($0) }
                    s.layers[i].mask.strokes = [MaskStroke(points: Array(v.dropLast()), radius: v.last ?? 100, hardness: 0.3)]
                }
                self.apply(s, dragging: false)
                if env["DUOCHROME_SHOWMASK"] != nil { self.toggleMaskView(nil) }
            }
        }
        // DUOCHROME_SAVE_DOC=path.duochrome — saves the current photo as a document
        if let path = env["DUOCHROME_SAVE_DOC"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do { try DuochromeDocument.save(doc, to: URL(fileURLWithPath: path)); NSLog("saved doc %@", path) }
                catch { NSLog("save doc failed %@", "\(error)") }
            }
        }
        if env["DUOCHROME_AUTOWB"] != nil {
            DispatchQueue.main.async {
                let t0 = CACurrentMediaTime()
                let wb = doc.neutralWhiteBalance(at: nil)
                NSLog("auto wb -> %.0fK tint %.1f (촬영 %.0fK) %.0f ms", wb?.temperature ?? 0, wb?.tint ?? 0, doc.asShot.temperature, (CACurrentMediaTime() - t0) * 1000)
            }
        }
        if env["DUOCHROME_UITEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.runUITests() }
        }
        if env["DUOCHROME_FIELDTEST"] != nil {
            // Running inside a main-queue block keeps background work from returning to the main queue → start from a timer (run loop)
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in self.runFieldTest() }
        }
        if env["DUOCHROME_EXPORT_SHEET"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.exportPhotos(nil)
                if env["DUOCHROME_EXPORT_GO"] != nil {
                    self.exportSheet?.onDone = { urls in NSLog("sheet exported %@", urls.map(\.lastPathComponent).joined(separator: ", ")) }
                    self.exportSheet?.start()
                }
            }
        }
        // DUOCHROME_EXPORT="tiff16|jpeg|png|heic,folder,long side,color space" — exports the current photo and logs the path
        if let spec = env["DUOCHROME_EXPORT"]?.split(separator: ","), spec.count >= 2,
           let f = ExportRecipe.Format(rawValue: String(spec[0])) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var r = ExportRecipe()
                r.format = f
                r.folder = String(spec[1])
                if spec.count > 2 { r.longSide = Int(spec[2]) ?? 0 }
                if spec.count > 3, let sp = ExportRecipe.Space(rawValue: String(spec[3])) { r.space = sp }
                let t0 = CACurrentMediaTime()
                do {
                    let url = try Exporter.export(doc, recipe: r, name: doc.url.lastPathComponent)
                    NSLog("exported %@ (%.0f ms)", url.path, (CACurrentMediaTime() - t0) * 1000)
                } catch { NSLog("export failed %@", "\(error)") }
            }
        }
        if let t = env["DUOCHROME_TOOL"].flatMap(Int.init) {
            DispatchQueue.main.async { self.enterTool(CanvasView.Tool.allCases[t]) }
        }
        if let id = env["DUOCHROME_REVEAL"] {
            DispatchQueue.main.async { self.inspector.reveal(id) }
        }
        if let ch = env["DUOCHROME_CURVE_CHANNEL"].flatMap(Int.init) {
            DispatchQueue.main.async { self.inspector.selectCurveChannel(ch) }
        }
        if env["DUOCHROME_ZOOM"] == "actual" {
            DispatchQueue.main.async { self.canvas.zoomToActual() }
        }
        // Simulates dragging a slider: changes exposure 8 times at 0.15 s intervals and releases at the end.
        if env["DUOCHROME_BENCH_SLIDER"] != nil {
            for i in 1...9 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.15) { [weak self] in
                    guard let self, let doc = self.photo else { return }
                    doc.draft = i < 9
                    doc.settings.exposure = Float(i) * 0.1
                    self.canvas.needsDisplay = true
                }
            }
        }
    }

    // MARK: - View menu

    @objc func toggleClipping(_ sender: Any?) {
        if mode == .tether { tetherMode.toggleClipping(); return }
        canvas.showClipping.toggle()
        clippingButton?.isOn = canvas.showClipping
    }

    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    @objc func zoomToActual(_ sender: Any?) { canvas.zoomToActual() }
    @objc func zoomIn(_ sender: Any?) { canvas.zoomBy(2) }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomBy(0.5) }

    @objc func toggleSplitCompare(_ sender: Any?) { canvas.splitCompare.toggle(); canvas.showOriginal = false }
    @objc func toggleMaskGray(_ sender: Any?) {
        canvas.maskGray.toggle()
        if canvas.maskLayerID == nil { toggleMaskView(nil) }
    }

    /// Brush size ([ smaller, ] larger): the retouch brush for retouch tools, the mask brush for mask tools.
    @objc func brushSmaller(_ sender: Any?) { resizeBrush(1 / 1.25) }
    @objc func brushLarger(_ sender: Any?) { resizeBrush(1.25) }
    private func resizeBrush(_ k: Double) {
        if canvas.tool == .retouch {
            retouch.brush.radius = min(max(retouch.brush.radius * k, 4), 400)
            canvas.retouchOverlay.brushRadius = retouch.brush.radius
            canvas.retouchOverlay.needsDisplay = true
        } else {
            layersTab.brushRadius = min(max(layersTab.brushRadius * k, 5), 1500)
            canvas.maskOverlay.brushRadius = layersTab.brushRadius
            canvas.maskOverlay.needsDisplay = true
            layersTab.sync(photo?.settings)
        }
    }

    @objc func showSupportedCameras(_ sender: Any?) { SupportedCameras.show() }
    @objc func showShortcuts(_ sender: Any?) { SettingsWindowController.shared.host = self; SettingsWindowController.shared.show(tab: 5) }

    @objc func toggleOriginal(_ sender: Any?) {
        canvas.showOriginal.toggle()
        (sender as? NSMenuItem)?.state = canvas.showOriginal ? .on : .off
    }

    /// Toggle the jobs panel (Window menu · ⌥⌘J)
    @objc func toggleJobsPanel(_ sender: Any?) { jobsPanel?.toggle() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleOriginal(_:)) { item.state = canvas.showOriginal ? .on : .off }
        if item.action == #selector(toggleClipping(_:)) { item.state = canvas.showClipping ? .on : .off }
        if item.action == #selector(toggleSplitCompare(_:)) { item.state = canvas.splitCompare ? .on : .off }
        if item.action == #selector(toggleMaskGray(_:)) { item.state = canvas.maskGray ? .on : .off }
        if item.action == #selector(showShortcuts(_:)) { return true }
        if item.action == #selector(showSupportedCameras(_:)) { return true }
        if item.action == #selector(toggleJobsPanel(_:)) { item.state = jobsPanel?.isShown == true ? .on : .off; return true }
        let always: [Selector] = [#selector(switchToLibrary(_:)), #selector(switchToEdit(_:)), #selector(switchToTether(_:)),
                                  #selector(importExternalCatalog(_:)), #selector(showSettings(_:)), #selector(stopColab(_:)), #selector(reinstallAIEngine(_:)), #selector(toggleAIEngine(_:))]
        if always.contains(item.action!) {
            if item.action == #selector(switchToLibrary(_:)) { item.state = mode == .library ? .on : .off }
            if item.action == #selector(switchToEdit(_:)) { item.state = mode == .edit ? .on : .off }
            if item.action == #selector(switchToTether(_:)) { item.state = mode == .tether ? .on : .off }
            return true
        }
        if item.action == #selector(rateFromMenu(_:)) || item.action == #selector(colorFromMenu(_:))
            || item.action == #selector(exportPhotos(_:)) { return !targetItems.isEmpty }
        if item.action == #selector(undoAdjust(_:)) { return history.canUndo }
        if item.action == #selector(redoAdjust(_:)) { return history.canRedo }
        if item.action == #selector(pasteAdjustments(_:)) { return photo != nil && clipboard != nil }
        return photo != nil
    }
}


/// Opens files dropped anywhere on the window. Intercepting the split view's loadView keeps the three panes from attaching,
/// so the window receives drops.
final class DropWindow: NSWindow {
    var onDrop: ((URL) -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(sender) == nil ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }
}

extension NSToolbarItem.Identifier {
    static let openFolder = Self("openFolder")
    static let modeSwitch = Self("modeSwitch")
    static let resetAdjust = Self("resetAdjust")
    static let undoAdjust = Self("undoAdjust")
    static let redoAdjust = Self("redoAdjust")
    static let cursorTools = Self("cursorTools")
    static let beforeAfter = Self("beforeAfter")
    static let clipping = Self("clipping")
    static let copyAdjust = Self("copyAdjust")
    static let pasteAdjust = Self("pasteAdjust")
    static let autoAdjust = Self("autoAdjust")
    static let photoSearch = Self("photoSearch")
    static let panelLeft = Self("panelLeft")
    static let panelRight = Self("panelRight")
}

/// History (undo list). The first entry is the photo open. Switching photos starts a new one.
struct AdjustHistory {
    var states: [(label: String, settings: DevelopSettings)] = []
    /// Snapshot: a named saved state. Not removed when history overflows
    var snapshots: [(label: String, settings: DevelopSettings)] = []
    var index = 0
    var labels: [String] { states.map(\.label) }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < states.count - 1 }

    mutating func reset(_ s: DevelopSettings) { states = [("사진 열기", s)]; index = 0; snapshots = [] }

    /// Adjusting after an undo discards the history after that point.
    mutating func record(_ label: String, _ s: DevelopSettings) {
        if states.isEmpty { states = [("사진 열기", s)]; index = 0; return }
        states = Array(states[...index])
        states.append((label, s))
        if states.count > 200 { states.removeFirst(states.count - 200) }
        index = states.count - 1
    }

    mutating func undo() -> DevelopSettings? { guard canUndo else { return nil }; index -= 1; return states[index].settings }
    mutating func redo() -> DevelopSettings? { guard canRedo else { return nil }; index += 1; return states[index].settings }
    mutating func jump(_ i: Int) -> DevelopSettings? {
        guard states.indices.contains(i), i != index else { return nil }
        index = i
        return states[i].settings
    }
}

/// Center viewer. File name and zoom on top; a hint when there's no photo.
final class ViewerController: NSViewController {
    let canvas = CanvasView()
    private let empty = NSTextField(labelWithString: "선택된 사진이 없습니다")
    private let offlineImage = NSImageView()
    /// Per-mode bar floating over the canvas (batch edit, tethering). Zoom moved to the shared zoom control in the toolbar.
    var bar: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if isViewLoaded, let bar { ModeBar.place(bar, in: strip) }
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = StudioStyle.window.cgColor
        empty.font = .systemFont(ofSize: 20, weight: .regular)
        empty.textColor = .secondaryLabelColor
        let strip = NSView()
        offlineImage.imageScaling = .scaleProportionallyUpOrDown
        offlineImage.alphaValue = 0.8
        // Strip at the very top: the canvas extends under the glass bar
        for v in [canvas, offlineImage, empty, strip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        self.strip = strip
        stripLeading = strip.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        stripTrailing = strip.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stripLeading, stripTrailing,
            strip.heightAnchor.constraint(equalToConstant: ModeBar.slot),
        ])
        view = root
        if let bar { ModeBar.place(bar, in: strip) }
        pinCanvas()
        canvas.onZoomChange = { [weak self] z in self?.onZoom?(z) }
        show(nil)
    }

    private var strip: NSView!
    private var stripLeading: NSLayoutConstraint!
    private var stripTrailing: NSLayoutConstraint!
    private var emptyX: NSLayoutConstraint?
    /// Left/right widths covered by glass panels. The bar sits centered between them, and so does the fitted photo.
    private var side: (left: CGFloat, right: CGFloat) = (0, 0)

    func setSideInsets(left: CGFloat, right: CGFloat) {
        side = (left, right)
        _ = view
        stripLeading.constant = left
        stripTrailing.constant = -right
        emptyX?.constant = (left - right) / 2
        applyFitInsets()
    }

    private func applyFitInsets() {
        canvas.fitInsets = NSEdgeInsets(top: ModeBar.slot - 12, left: side.left, bottom: 0, right: side.right)
    }
    /// When zoom changes (so the layer-edit zoom slider follows).
    var onZoom: (((fitting: Bool, percent: CGFloat)) -> Void)?

    /// Takes back the canvas that moved to layer-edit mode.
    func reclaimCanvas() {
        guard isViewLoaded, canvas.superview !== view else { return }
        canvas.removeFromSuperview()
        view.addSubview(canvas, positioned: .below, relativeTo: offlineImage)
        pinCanvas()
    }

    private func emptyCenter(_ root: NSView) -> NSLayoutConstraint {
        emptyX?.isActive = false
        let c = empty.centerXAnchor.constraint(equalTo: canvas.centerXAnchor, constant: (side.left - side.right) / 2)
        emptyX = c
        return c
    }

    private func pinCanvas() {
        let root = view
        applyFitInsets()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // The canvas extends under the toolbar (Liquid Glass: toolbar, bars, and panels float over the photo)
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            offlineImage.topAnchor.constraint(equalTo: canvas.topAnchor, constant: ModeBar.slot + 24),
            offlineImage.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -80),
            offlineImage.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 40),
            offlineImage.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -40),
            emptyCenter(root),
            empty.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
        ])
    }

    /// Photo whose source is offline: show only the imported thumbnail.
    func showOffline(_ item: PhotoItem) {
        _ = view
        canvas.document = nil
        canvas.isHidden = true
        offlineImage.isHidden = false
        offlineImage.image = item.thumbnail ?? item.importThumb.flatMap(NSImage.init(contentsOfFile:))
        empty.isHidden = false
        empty.stringValue = "원본 파일이 지금 경로에 없습니다 (오프라인) — 가져온 썸네일만 보여 줍니다"
        empty.font = .systemFont(ofSize: 13)
    }

    func show(_ doc: RawDocument?) {
        _ = view
        offlineImage.isHidden = true
        empty.stringValue = "선택된 사진이 없습니다"
        empty.font = .systemFont(ofSize: 20)
        canvas.document = doc
        canvas.isHidden = doc == nil
        empty.isHidden = doc != nil
    }
}
