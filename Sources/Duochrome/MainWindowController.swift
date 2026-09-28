import AppKit

/// 대량 보정: 왼쪽 도구 탭(라이브러리·형태·조정·리터칭·내역·레이어), 가운데 사진, 오른쪽 사진 목록.
/// 심화 보정 모드는 Studio.swift. 세 모드가 같은 떠 있는 패널 모양을 쓴다.
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    /// 대량 보정 배치 (GlassLayout.swift). 패널 폭 = 유리 패널 자체 폭.
    lazy var split = GlassLayoutController(content: viewer, left: tools, right: browser, key: GlassLayoutController.sharedKey,
                                           leftRange: GlassLayoutController.leftRange, rightRange: GlassLayoutController.rightRange,
                                           leftDefault: 288, rightDefault: 290)
    let library = Library(catalog: MainWindowController.openCatalog())

    /// 기본 카탈로그를 연다. 시험 실행(DUOCHROME_SNAPSHOT·DUOCHROME_CATALOG)은 따로 쓴다 — 사용자 카탈로그를 건드리지 않게.
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
    /// 이미지 레이어를 끄는 동안의 처음 자리.
    var imageMoveOrigin: CGPoint?
    var shapeMoveOrigin: VectorPath?
    /// 심화 보정의 사진 탭 (연 순서)
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
    private(set) var photo: RawDocument?
    var photoItem: PhotoItem?

    // 세 가지 모드 (Modes.swift)
    let libraryMode = LibraryModeController()
    /// 심화 보정 모드 (Studio.swift)
    let studioMode = StudioModeController()
    /// 창 막대 하나를 세 모드가 같이 쓴다 (모드마다 다른 것은 캔버스 위의 모드별 막대로).
    var bulkToolbar: NSToolbar?
    /// 대량 보정 모드별 막대의 커서 도구 단추 (CanvasView.Tool 순서)
    var cursorButtons: [ModeBarButton] = []
    weak var clippingButton: ModeBarButton?
    weak var bulkSearchField: NSSearchField?
    weak var studioZoomSlider: NSSlider?
    weak var studioZoomLabel: NSTextField?
    /// 색상 피커로 집은 색 (심화 보정 모드 도구 옵션에 보인다)
    lazy var pickerView: StudioPickerView = {
        let v = StudioPickerView()
        v.swatches.onPick = { [weak self] c in self?.applySwatch(c) }
        return v
    }()
    /// 심화 보정 효과 도구 옵션 (효과 고르기 + 고른 레이어의 효과 편집)
    lazy var studioEffects = StudioEffectsPanel()
    /// 심화 보정 스타일 도구 옵션
    lazy var studioStyles = LayerStylesEditor()
    /// 픽셀 선택 계산 (사진·설정이 바뀌면 다시 만든다)
    var selectionEngineCache: (String, SelectionEngine)?
    var selectAndMaskPanel: SelectAndMaskPanel?
    lazy var selectionOptions = SelectionOptionsView(host: self)
    /// 펜·모양·글자 도구 옵션 (VectorTools.swift)
    lazy var penOptions = PenOptionsView(host: self)
    lazy var shapeOptions = ShapeOptionsView(host: self)
    lazy var textOptions = TextOptionsView(host: self)
    /// 측정·계수 옵션, 초점 확인 창 (Workspace.swift)
    lazy var measureOptions = MeasureOptionsView(host: self)
    var focusLoupe: FocusLoupe?
    lazy var paintOptions: PaintOptionsView = {
        let v = PaintOptionsView()
        v.onTool = { [weak self] m in self?.startPainting(mode: m) }
        return v
    }()
    /// 선택 더하기: 이번 끌기에 새로 붙인 합치기 (같은 끌기의 다음 갱신은 이걸 고친다)
    var comboGesture: Int = -1
    /// 마지막으로 가져온 PSD에서 옮기지 못한 것 (자체 검사·알림용)
    var psdNotes: [String] = []
    var studioThumbCache: (url: URL, settings: DevelopSettings, image: NSImage)?
    var studioThumbPending: DevelopSettings?
    /// 작업 진행 창 (JobCenter.swift)
    var jobsPanel: JobsPanel?
    /// 두 번째 화면 보기
    var secondViewer: SecondViewerWindow?
    let tetherMode = TetherModeController()
    var mode: AppMode = .edit
    var tetherCamera: TetherCamera?
    var gphoto: GPhotoCamera?
    var hotFolder: HotFolder?
    weak var modeSegment: ModeSwitch?
    /// 라이브러리 모드에서 고른 사진들 (편집 모드는 그중 대표 한 장을 연다).
    var selection: [PhotoItem] = []
    /// 여러 사진에 붙일 조정 (JSON 사전 — 오프라인 사진에도 적을 수 있게).
    var batchClipboard: [String: Any]?
    var batchClipboardName: String?

    /// 조정값 되돌리기. 슬라이더를 끄는 동안은 쌓지 않고, 손을 뗄 때 끄기 전 값 하나만 쌓는다.
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
        // 배치: 왼쪽 도구 탭, 가운데 사진, 오른쪽 사진 목록
        // 리퀴드 글래스 배치: 사진이 창 전체에 깔리고 도구 탭(왼쪽)·사진 목록(오른쪽)이 유리로 뜬다
        split.onInsetsChange = { [weak self] l, r in self?.viewer.setSideInsets(left: l, right: r) }
        // 창 막대도 투명하게: 사진이 창 막대 밑까지 보인다
        window.titlebarAppearsTransparent = true
        // contentViewController를 넣으면 창 크기가 뷰 크기로 줄어든다. 넣은 뒤에 다시 잡는다.
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1560, height: 960))
        window.center()
        window.setFrameAutosaveName("DuochromeMain")
        if UserDefaults.standard.object(forKey: "NSWindow Frame DuochromeMain") == nil { window.center() }

        let toolbar = NSToolbar(identifier: "DuochromeToolbar")
        toolbar.delegate = self
        // 가이드라인: 창 막대는 아이콘만, 설명은 풍선 도움말로
        toolbar.displayMode = .iconOnly
        // 저장된 항목 구성이 코드의 기본 목록을 이기면 새 항목이 영영 안 보인다 (Meridian에서 겪음).
        toolbar.autosavesConfiguration = false
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.modeSwitch]
        window.toolbar = toolbar
        bulkToolbar = toolbar
        viewer.bar = makeBulkBar()

        window.onDrop = { [weak self] url in self?.openFileOrFolder(url) }
        jobsPanel = JobsPanel(host: window)
        // 열어 둔 채 끝냈으면 다음에 켤 때도 연다 (창이 자리 잡은 뒤에)
        if jobsPanel?.visibility == .open { DispatchQueue.main.async { [weak self] in self?.jobsPanel?.reload() } }
        libraryTab.onOpenFolder = { [weak self] in self?.chooseFolder() }
        libraryTab.onPickRecent = { [weak self] url in self?.openFolder(url) }
        browser.onSelect = { [weak self] item in self?.show(item) }
        // 문서가 뒤에서 값을 다 재면(디헤이즈 안개 빛 등) 다시 그린다
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

    // MARK: - 폴더와 사진

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

    /// 파일이면 그 폴더를 열고 그 사진을 고른다. 폴더면 폴더를 연다.
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
            // 원본이 지금 경로에 없다. 가져온 썸네일로 보여 주기만 한다 (조정은 원본이 돌아오면).
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
                // PSD를 처음 열면 레이어를 옮기고 바로 저장한다 (다음부터는 저장된 레이어를 쓴다)
                let res = PSDImport.convert(f)
                doc.settings.layers = res.layers
                doc.settings.gammaBlend = true
                library.saveSettings(doc.settings, asShot: doc.asShot, for: item.url)
                item.edited = true
                if !res.notes.isEmpty { NSLog("PSD 가져오기: %@", res.notes.joined(separator: " / ")) }
                psdNotes = res.notes
            }
            doc.releasePSD()
            // 대량 보정·격자·테더링은 미리보기만, 심화 보정만 원본 크기로 보정한다
            doc.previewOnly = mode != .studio
            mark("설정")
            photo = doc
            LayerThumbs.doc = doc; LayerThumbs.backgroundThumb = nil
            rememberTab(item)
            DispatchQueue.main.async { [weak self] in self?.syncGuides(); self?.syncCounts() }
            photoItem = item
            history.reset(doc.settings)
            // 저장된 작업 내역이 있으면 이어서 (마지막 상태가 지금 설정과 같을 때만)
            if let h = library.catalog.history(Library.key(for: item.url)) { _ = history.restore(h, current: doc.settings) }
            syncHistory()
            mark("내역")
            window?.subtitle = item.name
            window?.representedURL = item.url
            let beforeHooks = doc.settings
            applyDevHooks(doc)
            // 개발용: DUOCHROME_COMMIT=1이면 훅으로 넣은 값을 사용자가 바꾼 것처럼 저장한다.
            if ProcessInfo.processInfo.environment["DUOCHROME_COMMIT"] != nil, doc.settings != beforeHooks {
                history.record("시험 값", doc.settings)
                commit()
            }
            NSLog("opened %@ exposure=%.2f clarity=%.0f edited=%d", item.name, doc.settings.exposure,
                  doc.settings.clarity, item.edited ? 1 : 0)
            // 미리보기가 없어 RAW를 풀어야 하면 썸네일을 먼저 크게 보인다
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

    /// 다른 사진으로 넘어가기 전에 썸네일을 조정 결과로 바꿔 둔다 (그림 계획만 여기서, 그리기는 뒤에서 — 넘길 때 멈추지 않게)
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

    // MARK: - 조정

    func apply(_ settings: DevelopSettings, dragging: Bool) {
        guard let doc = photo else { return }
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

    /// 손을 뗀 값을 저장하고 브라우저 표시를 고친다.
    private func commit() {
        guard let doc = photo, let item = photoItem else { return }
        // 시험 실행은 사용자의 조정값을 건드리지 않는다. 저장 시험만 DUOCHROME_COMMIT으로 연다.
        let env = ProcessInfo.processInfo.environment
        if env["DUOCHROME_SNAPSHOT"] != nil && env["DUOCHROME_COMMIT"] == nil { return }
        let wasEdited = item.edited
        library.saveSettings(doc.settings, asShot: doc.asShot, for: doc.url)
        if wasEdited != item.edited { refreshItem(item) }
        if item.edited, let h = history.encoded() { library.catalog.setHistory(Library.key(for: doc.url), h) }
        PreviewCache.shared.ensure(url: doc.url, settings: doc.settings)
    }

    /// 되돌리기·붙여넣기처럼 패널 밖에서 값을 바꿀 때.
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

    /// 작업 내역에 한 줄 더한다. 이름은 바뀐 갈래에서 짓는다 ("노출·대비…", "리터칭 점" 등).
    func recordHistory(from before: DevelopSettings, to after: DevelopSettings, label: String? = nil) {
        let name = label ?? {
            // 전체 강도만 바꿨으면 "강도 71%" (강도는 복사 갈래로는 노출 묶음이라 그 이름이 붙었다)
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

    /// 조정 복사/적용. 화이트 밸런스처럼 사진마다 다른 카메라 값도 그대로 옮긴다.
    @objc func copyAdjustments(_ sender: Any?) {
        clipboard = photo?.settings
        clipboardName = photoItem?.name
        if let s = photo?.settings, let name = photoItem?.name { rememberForBatch(s, name: name) }
    }

    /// 기억해 둔 갈래만 붙인다 (처음엔 형태·리터칭·레이어를 뺀 전부).
    @objc func pasteAdjustments(_ sender: Any?) {
        guard let c = clipboard else { return }
        let saved = Set((UserDefaults.standard.stringArray(forKey: "pasteGroups") ?? []).compactMap(AdjustGroup.init))
        pasteGroups(c, saved.isEmpty ? Set(AdjustGroup.allCases.filter(\.defaultOn)) : saved)
    }

    /// 갈래를 골라 붙인다 (⌥⇧⌘V).
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

    /// 크롭 도구에서는 틀 전체를 보이고 크롭 사각형을 겹친다. 다른 도구로 가면 크롭 결과를 보인다.
    func enterTool(_ tool: CanvasView.Tool) {
        canvas.tool = tool
        // 막대에 없는 도구(컬러 에디터 스포이트 등)면 아무 단추도 켜지 않는다.
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

    /// 그은 선(화면에 보이는 이미지 좌표)이 세로·가로가 되는 키스톤과 미세 회전을 찾아 건다.
    func applyKeystoneLines(_ vertical: [(CGPoint, CGPoint)], horizontal: [(CGPoint, CGPoint)] = []) {
        guard let doc = photo else { return }
        let s = doc.settings, native = doc.nativeSize, full = doc.showFullFrame
        applyKeystone(vertical: Geometry.framedLines(vertical, s, native: native, fullFrame: full),
                      horizontal: Geometry.framedLines(horizontal, s, native: native, fullFrame: full), robust: false)
    }

    /// 틀 좌표 선으로 풀어서 건다.
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

    /// 자동 키스톤: 1/8 미리보기에서 곧은 선을 찾아 푼다. 방식에 따라 세로선·가로선만 쓴다.
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

    /// 컬러 에디터·스킨 톤 스포이트: 지금 화면 결과에서 그 점(둘레 5×5 평균)의 색을 집는다.
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
            // 심화 보정 모드의 색상 피커: 도구를 그대로 두고 집은 색만 보여 준다.
            pickerView.show(avg)
            return
        }
        if (30...32).contains(colorPickPurpose) {
            inspector.pickedCurve(colorPickPurpose, rgb: avg)
            enterTool(.pan)
            return
        }
        if colorPickPurpose == 2 || colorPickPurpose == 3 {
            // 레벨 검정 점은 가장 밝은 채널, 흰 점은 가장 어두운 채널을 기준으로 (색이 한쪽으로 날아가지 않게)
            inspector.pickedLevel(colorPickPurpose, value: colorPickPurpose == 2 ? max(avg.x, avg.y, avg.z) : min(avg.x, avg.y, avg.z))
            enterTool(.pan)
            return
        }
        let (h, s, v) = ColorLUT.hsv(avg)
        inspector.pickedColor(hue: h, sat: s, value: v, purpose: colorPickPurpose)
        enterTool(.pan)
    }

    /// point가 nil이면 자동 화이트 밸런스.
    func pickWhiteBalance(at point: CGPoint?, done: (() -> Void)? = nil) {
        guard let doc = photo else { return }
        NSCursor.operationNotAllowed.push()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wb = doc.neutralWhiteBalance(at: point)
            DispatchQueue.main.async {
                NSCursor.pop()
                // 계산하는 동안 다른 사진으로 넘어갔으면 버린다.
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

    // MARK: - 리터칭

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
            // 심화 보정 모드: 패널에서 복구·복제·패치를 바꾸면 도구 막대도 따라간다.
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
            // 리터칭 탭을 고르면 리터칭 도구로, 떠나면 이동 도구로.
            let title = self.tools.tabTitle(i)
            if title == "리터칭" { self.enterTool(.retouch) }
            else if title == "레이어" { if self.layersTab.selectedID != nil { self.enterTool(.mask) } }
            else if self.canvas.tool == .retouch || self.canvas.tool == .mask { self.enterTool(.pan) }
        }
    }

    /// 원본 좌표에 점을 찍는다. 원본 자리는 결이 닮은 곳으로 자동으로 고른다.
    func addSpot(at p: CGPoint) {
        guard let doc = photo else { return }
        let b = retouch.brush
        let src = doc.autoSource(target: p, radius: b.radius)
        let n = editSpots { $0.append(RetouchSpot(kind: b.kind, targetX: p.x, targetY: p.y, sourceX: src.x, sourceY: src.y,
                                                  radius: b.radius, feather: b.feather, opacity: b.opacity)) }
        canvas.retouchOverlay.selected = n - 1
    }

    /// 붓질 하나를 더한다. 원본 자리는 획과 나란히 옆으로 옮긴 곳 중 가장 닮은 곳.
    func addStroke(_ pts: [CGPoint]) {
        guard let doc = photo, let first = pts.first else { return }
        let b = retouch.brush
        let o = doc.autoStrokeOffset(path: pts, radius: b.radius)
        let n = editSpots { $0.append(RetouchSpot(kind: b.kind, targetX: first.x, targetY: first.y,
                                                  sourceX: first.x + o.x, sourceY: first.y + o.y, radius: b.radius,
                                                  feather: b.feather, opacity: b.opacity, path: pts.flatMap { [$0.x, $0.y] })) }
        canvas.retouchOverlay.selected = n - 1
    }

    /// 패치 하나를 더한다 (원본 좌표 올가미). 원본 자리는 올가미 크기의 원으로 결이 닮은 곳을 고른다.
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

    private func removeSpot(_ i: Int) {
        guard let s = photo?.settings, targetSpots(s).indices.contains(i) else { return }
        canvas.retouchOverlay.selected = nil
        editSpots { $0.remove(at: i) }
    }

    private func syncRetouch(_ s: DevelopSettings) {
        canvas.retouchOverlay.spots = targetSpots(s)
        retouch.showCount(targetSpots(s).count)
    }

    /// 리터칭 점이 들어갈 곳: 고른 레이어가 배경 복사면 그 레이어, 아니면 배경(RAW 현상).
    var retouchLayerID: String? {
        guard let id = layersTab.selectedID, photo?.settings.layers.first(where: { $0.id == id })?.isCopy == true else { return nil }
        return id
    }

    func targetSpots(_ s: DevelopSettings) -> [RetouchSpot] {
        if let id = retouchLayerID, let l = s.layers.first(where: { $0.id == id }) { return l.spots }
        return s.spots
    }

    /// 지금 대상의 리터칭 점을 고치고 적용한다. 고친 뒤 점 수를 돌려준다.
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

    // MARK: - 레이어

    private func setupLayers() {
        layersTab.current = { [weak self] in self?.photo?.settings }
        layersTab.onChange = { [weak self] s, dragging in self?.apply(s, dragging: dragging) }
        layersTab.onSelect = { [weak self] id in
            guard let self else { return }
            if self.mode == .studio { DispatchQueue.main.async { self.studioMode.refreshOptionsForSelection() } }
            self.canvas.maskOverlay.adjustLayer = self.photo?.settings.layers.first { $0.id == id }
            if self.canvas.maskLayerID != nil { self.canvas.maskLayerID = id }
            if id != nil, self.tools.tabTitle(self.tools.selected) == "레이어" { self.enterTool(.mask) }
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
            // 모양 레이어: 패스를 통째로 옮긴다 (가운데를 안내선·가장자리에 붙인다)
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
            // 글자 레이어는 글자 기준점과 (있으면) 가져온 그림을 같이 옮긴다
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
                // 칠 레이어: 끈 방향이 그라디언트 방향
                s.layers[i].fillPoints = [a.x, a.y, b.x, b.y]
                self.apply(s, dragging: dragging)
                return
            }
            let o = self.canvas.maskOverlay
            let toolKind: LayerMask.Kind? = self.mode == .studio ? ["selRect": .rect, "selOval": .ellipse][self.studioMode.currentTool] : nil
            let cur = s.layers[i].mask
            let hasShape = (cur.kind == .rect || cur.kind == .ellipse) && (cur.box[0] != cur.box[2] || cur.box[1] != cur.box[3])
            if let op = self.selectionOp(o.startFlags), hasShape || (toolKind != nil && toolKind != cur.kind && cur.kind != .full) {
                // 선택 더하기·빼기·교차: 끌기마다 합치기 하나
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

    /// 파일을 골라 이미지 레이어로 (가져오기).
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
        if !dragging, mode == .studio { studioMode.layersPanel.reload() }
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

    /// 슬라이더를 끄는 동안 여러 번 불려도 마지막 요청만 반영한다.
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

    // MARK: - 툴바

    /// 세 모드 공통 창 막대: [왼쪽 패널 · 확대] … [모드 전환(창 가운데)] … [실행 취소 · 비교 · 내보내기 · 오른쪽 패널].
    /// 모드에만 필요한 도구는 캔버스 위 모드별 막대(ModeBar)에 있다.
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

    /// 개발용: DUOCHROME_DEVELOP="exposure=1.5,temperature=3800,tint=5", DUOCHROME_CLIPPING=1, DUOCHROME_ZOOM=actual
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
        // DUOCHROME_CURVE="rgb:0.25/0.15;0.75/0.85|red:0.5/0.6" — 양끝 점은 자동으로 붙는다.
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
        // DUOCHROME_CROP="x,y,w,h" (0~1), DUOCHROME_TOOL=0~3 (이동, 확대, 크롭, 수평)
        if let c = env["DUOCHROME_CROP"]?.split(separator: ",").compactMap({ Double($0) }), c.count == 4 {
            doc.settings.crop = CropRect(CGRect(x: c[0], y: c[1], width: c[2], height: c[3]))
        }
        // DUOCHROME_WB_PICK="x,y", DUOCHROME_KEYSTONE_LINES="x1,y1,x2,y2;x3,y3,x4,y4" (화면 이미지 좌표, 원본 픽셀)
        if let v = env["DUOCHROME_WB_PICK"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 2 {
            DispatchQueue.main.async {
                let t0 = CACurrentMediaTime()
                self.pickWhiteBalance(at: CGPoint(x: v[0], y: v[1])) {
                let ms = (CACurrentMediaTime() - t0) * 1000
                // 결과 확인: 최종 화면(1/8)에서 그 점의 색
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
        // DUOCHROME_RENDER_DUMP="x,y,w,h:배율:경로" — 저장된 조정 그대로, 그 배율에서 그린 한 부분 (원본 픽셀 좌표)
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
        // DUOCHROME_AI_SELECT=subject|background|person — AI 선택 레이어 하나, 마스크를 흑백으로 보여 준다
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
        // DUOCHROME_STUDIO_TOOL=도구 id, DUOCHROME_STUDIO_CUSTOMIZE=1 — 심화 보정 모드 모양 확인용
        if let t = env["DUOCHROME_STUDIO_TOOL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if self.mode == .studio { self.studioMode.selectTool(t) } }
        }
        if env["DUOCHROME_STUDIO_CUSTOMIZE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.mode == .studio { self.studioMode.customize() } }
        }
        // DUOCHROME_AUTO_KEYSTONE=0|1|2 (세로·가로·전체)
        if let m = env["DUOCHROME_AUTO_KEYSTONE"].flatMap(Int.init).flatMap(Geometry.KeystoneMode.init) {
            DispatchQueue.main.async {
                self.autoKeystone(m)
                NSLog("auto keystone -> V %.1f H %.1f rot %.2f", doc.settings.keystoneV, doc.settings.keystoneH, doc.settings.rotation)
            }
        }
        // DUOCHROME_SPOTS="x,y,r;x,y,r" (디코딩 원본 좌표) — 원본 자리는 자동
        if let spec = env["DUOCHROME_SPOTS"] {
            DispatchQueue.main.async {
                for part in spec.split(separator: ";") {
                    let v = part.split(separator: ",").compactMap { Double($0) }
                    guard v.count == 3 else { continue }
                    self.retouch.brush.radius = v[2]
                    self.addSpot(at: CGPoint(x: v[0], y: v[1]))
                }
                // DUOCHROME_DUMP_REGION="x,y,w,h:경로" — 원본 해상도 결과의 한 부분을 저장 (화면 이미지 좌표)
                if let d = env["DUOCHROME_DUMP_REGION"]?.split(separator: ":"), d.count == 2 {
                    let v = d[0].split(separator: ",").compactMap { Double($0) }
                    let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                    try? Render.context.writePNGRepresentation(of: doc.image(scale: 1).cropped(to: r),
                        to: URL(fileURLWithPath: String(d[1])), format: .RGBA8, colorSpace: Render.displaySpace)
                    try? Render.context.writePNGRepresentation(of: doc.originalImage(scale: 1).cropped(to: r),
                        to: URL(fileURLWithPath: String(d[1]) + ".before.png"), format: .RGBA8, colorSpace: Render.displaySpace)
                }
                // DUOCHROME_MERGE_TEST=1: 조정 탭이 점 찍기 전 값으로 슬라이더를 움직인 상황 흉내 → 점이 남아야 한다
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
        // DUOCHROME_STROKE="x,y;x,y;…|r" (원본 좌표) — 붓질 하나
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
                    // DUOCHROME_DUMP_SCALE=0.5 등: 미리보기 단계에서 그린 결과 (좌표는 원본 픽셀)
                    let sc = CGFloat(Double(env["DUOCHROME_DUMP_SCALE"] ?? "") ?? 1)
                    let r2 = CGRect(x: rect.minX * sc, y: rect.minY * sc, width: rect.width * sc, height: rect.height * sc)
                    try? Render.context.writePNGRepresentation(of: doc.image(scale: sc).cropped(to: r2),
                        to: URL(fileURLWithPath: String(d[1])), format: .RGBA8, colorSpace: Render.displaySpace)
                    try? Render.context.writePNGRepresentation(of: doc.originalImage(scale: 1).cropped(to: rect),
                        to: URL(fileURLWithPath: String(d[1]) + ".before.png"), format: .RGBA8, colorSpace: Render.displaySpace)
                }
            }
        }
        // DUOCHROME_IMAGE_LAYER="그림경로[:혼합[:불투명도[:칠]]]" — 이미지 레이어 하나
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
        // DUOCHROME_LAYER="linear:exposure=-1.5,saturation=40" — 기본 모양의 레이어 하나, DUOCHROME_SHOWMASK=1
        // 개발용: 레이어 스타일 모습 확인 (타원 칠 레이어에 그림자·획·경사)
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
        // 개발용: 끌어 놓기 확인용 레이어 셋 (전체 레이어 3개, 마지막 것은 그룹 안)
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
        // DUOCHROME_SAVE_DOC=경로.duochrome — 지금 사진을 문서로 저장
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
            // 주 큐 블록 안에서 돌리면 뒤 작업이 주 큐로 돌아오지 못한다 → 타이머(런루프)에서 시작
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
        // DUOCHROME_EXPORT="tiff16|jpeg|png|heic,폴더,긴변,색공간" — 지금 사진을 내보내고 경로를 로그로
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
        // 슬라이더를 끄는 상황 흉내: 0.15초 간격으로 노출을 8번 바꾸고 마지막에 손을 뗀다.
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

    // MARK: - 보기 메뉴

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

    /// 붓 크기 ([ 작게, ] 크게): 지금 도구가 리터칭이면 리터칭 붓, 마스크면 마스크 붓.
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

    /// 작업 진행 창 여닫기 (윈도우 메뉴 · ⌥⌘J)
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


/// 파일을 창 어디에 떨어뜨려도 연다. 분할 뷰의 loadView를 가로채면 세 칸이 붙지 않으므로
/// 드롭은 창이 받는다.
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

/// 작업 내역 (되돌리기 목록). 첫 줄은 사진을 열었을 때. 사진을 바꾸면 새로 시작한다.
struct AdjustHistory {
    var states: [(label: String, settings: DevelopSettings)] = []
    /// 스냅샷: 이름 붙여 남긴 상태. 내역이 넘쳐도 지워지지 않는다
    var snapshots: [(label: String, settings: DevelopSettings)] = []
    var index = 0
    var labels: [String] { states.map(\.label) }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < states.count - 1 }

    mutating func reset(_ s: DevelopSettings) { states = [("사진 열기", s)]; index = 0; snapshots = [] }

    /// 되돌린 뒤에 새로 조정하면 그 뒤의 내역은 버린다.
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

/// 가운데 뷰어. 위에 파일 이름과 배율, 사진이 없으면 안내 문구.
final class ViewerController: NSViewController {
    let canvas = CanvasView()
    private let empty = NSTextField(labelWithString: "선택된 사진이 없습니다")
    private let offlineImage = NSImageView()
    /// 캔버스 위에 뜨는 모드별 막대 (대량 보정·테더링). 배율은 창 막대의 공통 확대 조절로 옮겼다.
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
        // 막대(strip)를 맨 위에 둔다: 캔버스가 유리 막대 밑까지 깔린다
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
    /// 유리 패널에 가려진 왼쪽·오른쪽 폭. 막대는 그 사이 가운데, 맞춤 보기 사진도 그 사이에 놓인다.
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
    /// 배율이 바뀔 때 (심화 보정 모드의 확대 슬라이더도 따라오게).
    var onZoom: (((fitting: Bool, percent: CGFloat)) -> Void)?

    /// 심화 보정 모드에서 옮겨 간 캔버스를 되찾는다.
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
            // 캔버스는 창 막대 밑까지 깔린다 (리퀴드 글래스: 창 막대·막대·패널이 사진 위에 뜬다)
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

    /// 원본이 오프라인인 사진: 가져온 썸네일만 보여 준다.
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
