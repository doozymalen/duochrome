import AppKit

/// ① Library mode (bulk work): catalog list on the left, large grid in the center, selected photos on the right.
/// Select many photos and set rating, color tag, apply adjustments, add to album at once. Double-click goes to edit mode.
final class LibraryModeController: NSViewController {
    let sources = SourceListController()
    let grid = BrowserViewController(grid: true)
    let panel = SelectionPanelController()
    private let centerVC = NSViewController()
    /// Library layout (GlassLayout.swift): left catalog and right selection panels float as glass. The grid sits between them.
    lazy var split = GlassLayoutController(content: centerVC, left: sources, right: panel, key: "library",
                                           leftRange: 208...348, rightRange: 268...368, leftDefault: 220, rightDefault: 280)
    private var sideL: [NSLayoutConstraint] = []
    private var sideR: [NSLayoutConstraint] = []
    private let sizeSlider = NSSlider(value: 230, minValue: 120, maxValue: 480, target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let center = centerVC
        // Per-mode bar like the other modes: [collection name] [thumbnail size] [photo search]
        let top = NSView()
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let small = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!)
        let big = NSImageView(image: NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)!)
        small.contentTintColor = .secondaryLabelColor; big.contentTintColor = .secondaryLabelColor
        let search = ModeBarSearchField(placeholder: "사진 검색 (이름·폴더, ★3)", width: 190, target: self, action: #selector(searchChanged(_:)))
        searchField = search
        let back = ModeBarButton("square.grid.2x2.fill", "대량 보정으로 (G 또는 E)", target: self, action: #selector(backTapped))
        let bar = ModeBar([ModeBar.gap(4), titleLabel, ModeBar.gap(16), small, sizeSlider, big, ModeBar.gap(16), search, ModeBar.gap(6), back])
        ModeBar.place(bar, in: top)
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = StudioStyle.window.cgColor
        center.addChild(grid)
        compare.isHidden = true
        for v in [top, grid.view, compare] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            top.heightAnchor.constraint(equalToConstant: ModeBar.slot),
            grid.view.topAnchor.constraint(equalTo: top.bottomAnchor),
            grid.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            compare.topAnchor.constraint(equalTo: grid.view.topAnchor),
            compare.bottomAnchor.constraint(equalTo: grid.view.bottomAnchor),
            compare.leadingAnchor.constraint(equalTo: grid.view.leadingAnchor),
            compare.trailingAnchor.constraint(equalTo: grid.view.trailingAnchor),
        ])
        // Bar and grid between the glass panels (wider when panels collapse)
        sideL = [top.leadingAnchor.constraint(equalTo: root.leadingAnchor), grid.view.leadingAnchor.constraint(equalTo: root.leadingAnchor)]
        sideR = [top.trailingAnchor.constraint(equalTo: root.trailingAnchor), grid.view.trailingAnchor.constraint(equalTo: root.trailingAnchor)]
        NSLayoutConstraint.activate(sideL + sideR)
        center.view = root

        split.onInsetsChange = { [weak self] l, r in
            self?.sideL.forEach { $0.constant = l }
            self?.sideR.forEach { $0.constant = -r }
        }
        addChild(split)
        view = split.view
        let saved = UserDefaults.standard.double(forKey: "gridSize")
        if saved > 0 { sizeSlider.doubleValue = saved; grid.setThumbSize(saved) }
    }

    func setTitle(_ s: String) { titleLabel.stringValue = s }

    /// Compare view: selected photos (2–4) side by side, large. nil returns to the grid.
    let compare = CompareView()
    var isComparing: Bool { !compare.isHidden }
    func showCompare(_ items: [PhotoItem]?, library: Library) {
        guard let items, items.count >= 2 else { compare.isHidden = true; grid.view.isHidden = false; return }
        compare.show(Array(items.prefix(4)), library: library)
        compare.isHidden = false
        grid.view.isHidden = true
    }

    /// Photo search (moved from the toolbar)
    var onSearch: ((NSSearchField) -> Void)?
    private(set) weak var searchField: NSSearchField?
    @objc private func searchChanged(_ sender: NSSearchField) { onSearch?(sender) }
    /// Grid view button: back to batch edit
    var onBack: (() -> Void)?
    @objc private func backTapped() { onBack?() }

    @objc private func sizeChanged() {
        grid.setThumbSize(sizeSlider.doubleValue)
        UserDefaults.standard.set(sizeSlider.doubleValue, forKey: "gridSize")
    }
}

/// Library mode right side: actions for all selected photos at once.
final class SelectionPanelController: NSViewController {
    var onRate: ((Int) -> Void)?
    var onColor: ((Int) -> Void)?
    var onOpen: (() -> Void)?
    var onApplyClipboard: (() -> Void)?
    var onCopyFromFirst: (() -> Void)?
    var onReset: (() -> Void)?
    var onAddToAlbum: ((Int64) -> Void)?
    var onNewAlbum: (() -> Void)?
    var onRemoveFromAlbum: (() -> Void)?
    var albums: (() -> [Catalog.Album])?
    // manage
    var onFlag: ((Int) -> Void)?
    var onAddKeywords: ((String) -> Void)?
    var onRemoveKeyword: ((Int64) -> Void)?
    var keywordsFor: ((PhotoItem) -> [(Int64, String)])?
    var metadataFor: ((PhotoItem) -> [String: String])?
    var onMeta: ((String, String) -> Void)?
    var onCommand: ((Selector) -> Void)?
    private var flagButtons: [NSButton] = []
    private let keywordField = NSTextField()
    private let keywordChips = FlippedStackView()
    private var metaFields: [String: NSTextField] = [:]

    private let preview = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private var starButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private let albumPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let clipLabel = NSTextField(labelWithString: "")
    private var buttonsNeedingSelection: [NSControl] = []

    override func loadView() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 16, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        preview.layer?.cornerRadius = 6
        countLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor

        // rating
        let starRow = NSStackView()
        starRow.spacing = 4
        for n in 0...5 {
            // One star each (clicking the nth star sets rating n, 0 clears) — within the panel width
            let b = NSButton(title: "", target: self, action: #selector(starTapped(_:)))
            b.image = NSImage(systemSymbolName: n == 0 ? "xmark.circle" : "star", accessibilityDescription: n == 0 ? "별점 지우기" : "별점 \(n)")
            b.tag = n
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.toolTip = n == 0 ? "별점 지우기 (0)" : "별점 \(n) (\(n))"
            starButtons.append(b)
            starRow.addArrangedSubview(b)
        }
        // color tag
        let colorRow = NSStackView()
        colorRow.spacing = 4
        for (i, (name, color)) in colorTags.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.layer?.backgroundColor = (i == 0 ? NSColor.white.withAlphaComponent(0.15) : color).cgColor
            b.toolTip = "색 태그: \(name)"
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(b)
            colorRow.addArrangedSubview(b)
        }

        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .appPush
            b.controlSize = .regular
            buttonsNeedingSelection.append(b)
            return b
        }
        let open = button("뷰어에서 열기 (↩)", #selector(openTapped))
        open.keyEquivalent = ""
        let copyFirst = button("첫 사진 조정 복사", #selector(copyTapped))
        let apply = button("복사한 조정을 모두에 적용", #selector(applyTapped))
        let reset = button("조정 초기화", #selector(resetTapped))
        clipLabel.font = .systemFont(ofSize: 11)
        clipLabel.textColor = .tertiaryLabelColor

        albumPopup.addItem(withTitle: "앨범에 넣기")
        albumPopup.controlSize = .regular
        albumPopup.menu?.delegate = self
        buttonsNeedingSelection.append(albumPopup)
        let newAlbum = button("고른 사진으로 새 앨범…", #selector(newAlbumTapped))
        let removeAlbum = button("지금 앨범에서 빼기", #selector(removeTapped))

        // pick · reject
        let flagRow = NSStackView()
        flagRow.spacing = 4
        for (title, tag, tip) in [("⚑ 채택", 1, "채택 (P)"), ("✕ 거부", -1, "거부 (X)"), ("표시 없음", 0, "표시 지우기 (U)")] {
            let b = NSButton(title: title, target: self, action: #selector(flagTapped(_:)))
            b.tag = tag; b.bezelStyle = .appPush; b.controlSize = .small; b.toolTip = tip
            flagButtons.append(b); flagRow.addArrangedSubview(b)
        }
        // keywords
        keywordField.placeholderString = "키워드 더하기: 여행, 장소>서울 (리턴)"
        keywordField.target = self; keywordField.action = #selector(keywordEntered)
        keywordChips.orientation = .vertical; keywordChips.alignment = .leading; keywordChips.spacing = 2
        // IPTC
        let metaStack = FlippedStackView()
        metaStack.orientation = .vertical; metaStack.alignment = .leading; metaStack.spacing = 4
        for (key, title) in Catalog.metaFields {
            let f = NSTextField()
            f.placeholderString = title
            f.controlSize = .small
            f.font = .systemFont(ofSize: 11)
            f.identifier = NSUserInterfaceItemIdentifier(key)
            f.target = self; f.action = #selector(metaEntered(_:))
            metaFields[key] = f
            metaStack.addArrangedSubview(f)
            f.widthAnchor.constraint(equalTo: metaStack.widthAnchor).isActive = true
        }
        // management commands
        let manage = NSPopUpButton(frame: .zero, pullsDown: true)
        manage.addItem(withTitle: "관리")
        for (title, sel) in [("변형본 만들기", #selector(MainWindowController.makeVariant(_:))),
                             ("일괄 이름 바꾸기…", #selector(MainWindowController.batchRename(_:))),
                             ("촬영 시각 고치기…", #selector(MainWindowController.adjustCaptureTime(_:))),
                             ("XMP 사이드카 쓰기", #selector(MainWindowController.writeXMPSidecars(_:))),
                             ("XMP 사이드카 읽기", #selector(MainWindowController.readXMPSidecars(_:))),
                             ("오프라인 원본 다시 잇기…", #selector(MainWindowController.relinkOffline(_:))),
                             ("고른 사진 비교 보기", #selector(MainWindowController.toggleCompare(_:)))] {
            let it = NSMenuItem(title: title, action: #selector(commandPicked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSStringFromSelector(sel)
            manage.menu?.addItem(it)
        }
        buttonsNeedingSelection.append(manage)

        let sections: [NSView] = [
            preview, countLabel, infoLabel,
            sectionTitle("별점 (숫자 키 0~5)"), starRow,
            sectionTitle("채택·거부"), flagRow,
            sectionTitle("색 태그"), colorRow,
            sectionTitle("키워드"), keywordField, keywordChips,
            sectionTitle("메타데이터 (IPTC)"), metaStack, manage,
            sectionTitle("조정"), open, copyFirst, apply, clipLabel, reset,
            sectionTitle("앨범"), albumPopup, newAlbum, removeAlbum,
        ]
        for v in sections { stack.addArrangedSubview(v) }
        preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.7).isActive = true
        infoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        for v in [open, copyFirst, apply, reset, albumPopup, newAlbum, removeAlbum, keywordField, keywordChips, metaStack, manage] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.setCustomSpacing(16, after: infoLabel)
        stack.setCustomSpacing(16, after: starRow)
        stack.setCustomSpacing(16, after: colorRow)
        stack.setCustomSpacing(16, after: reset)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view = scroll
        show([], clipboard: nil)
    }

    func show(_ items: [PhotoItem], clipboard: String?) {
        guard isViewLoaded else { return }
        preview.image = items.first?.thumbnail
        switch items.count {
        case 0: countLabel.stringValue = "고른 사진 없음"
        case 1: countLabel.stringValue = items[0].name
        default: countLabel.stringValue = "\(items.count)장 고름"
        }
        let offline = items.filter(\.offline).count
        let edited = items.filter(\.edited).count
        var info: [String] = []
        if let first = items.first, items.count == 1 { info.append(first.url.deletingLastPathComponent().path) }
        if edited > 0 { info.append("조정한 사진 \(edited)장") }
        if offline > 0 { info.append("오프라인 \(offline)장 — 원본 파일이 지금 경로에 없습니다") }
        infoLabel.stringValue = info.joined(separator: "\n")
        let rating = items.first.map(\.rating)
        let same = items.allSatisfy { $0.rating == rating }
        for b in starButtons where b.tag > 0 {
            let lit = same && b.tag <= (rating ?? 0)
            b.image = NSImage(systemSymbolName: lit ? "star.fill" : "star", accessibilityDescription: "별점 \(b.tag)")
            b.contentTintColor = lit ? .controlAccentColor : .secondaryLabelColor
        }
        for (i, b) in colorButtons.enumerated() {
            b.layer?.borderWidth = !items.isEmpty && items.allSatisfy({ $0.color == i }) ? 2 : 0
            b.layer?.borderColor = NSColor.white.cgColor
        }
        clipLabel.stringValue = clipboard.map { "복사해 둔 조정: \($0)" } ?? "복사해 둔 조정 없음"
        let flag = items.first.map(\.flag)
        for b in flagButtons { b.state = !items.isEmpty && items.allSatisfy({ $0.flag == flag }) && b.tag == flag && flag != 0 ? .on : .off; b.isEnabled = !items.isEmpty }
        keywordField.isEnabled = !items.isEmpty
        keywordChips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if items.count == 1, let first = items.first {
            for (id, path) in keywordsFor?(first) ?? [] {
                let b = NSButton(title: "✕  " + path.replacingOccurrences(of: ">", with: " › "), target: self, action: #selector(keywordRemoved(_:)))
                b.tag = Int(id); b.isBordered = false; b.font = .systemFont(ofSize: 11); b.contentTintColor = .secondaryLabelColor
                b.toolTip = "이 키워드 떼기"
                keywordChips.addArrangedSubview(b)
            }
        }
        let meta = items.count == 1 ? (metadataFor?(items[0]) ?? [:]) : [:]
        for (k, f) in metaFields {
            if f.currentEditor() == nil { f.stringValue = meta[k] ?? "" }
            f.isEnabled = !items.isEmpty
            f.placeholderString = (Catalog.metaFields.first { $0.key == k }?.title ?? k) + (items.count > 1 ? " (고른 사진 모두)" : "")
        }
        buttonsNeedingSelection.forEach { $0.isEnabled = !items.isEmpty }
        starButtons.forEach { $0.isEnabled = !items.isEmpty }
        colorButtons.forEach { $0.isEnabled = !items.isEmpty }
    }

    @objc private func starTapped(_ b: NSButton) { onRate?(b.tag) }
    @objc private func flagTapped(_ b: NSButton) { onFlag?(b.tag) }
    @objc private func keywordEntered() {
        let t = keywordField.stringValue
        guard !t.isEmpty else { return }
        keywordField.stringValue = ""
        onAddKeywords?(t)
    }
    @objc private func keywordRemoved(_ b: NSButton) { onRemoveKeyword?(Int64(b.tag)) }
    @objc private func metaEntered(_ f: NSTextField) { if let k = f.identifier?.rawValue { onMeta?(k, f.stringValue) } }
    @objc private func commandPicked(_ item: NSMenuItem) {
        if let s = item.representedObject as? String { onCommand?(NSSelectorFromString(s)) }
    }
    @objc private func colorTapped(_ b: NSButton) { onColor?(b.tag) }
    @objc private func openTapped() { onOpen?() }
    @objc private func copyTapped() { onCopyFromFirst?() }
    @objc private func applyTapped() { onApplyClipboard?() }
    @objc private func resetTapped() { onReset?() }
    @objc private func newAlbumTapped() { onNewAlbum?() }
    @objc private func removeTapped() { onRemoveFromAlbum?() }
    @objc fileprivate func albumPicked(_ item: NSMenuItem) { onAddToAlbum?(Int64(item.tag)) }
}

extension SelectionPanelController: NSMenuDelegate {
    /// The album list is refilled each time it opens (albums under groups are indented).
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let all = albums?() ?? []
        func add(_ parent: Int64?, _ depth: Int) {
            for a in all where a.parent == parent {
                let item = NSMenuItem(title: a.name, action: a.kind == 1 ? #selector(albumPicked(_:)) : nil, keyEquivalent: "")
                item.target = self
                item.tag = Int(a.id)
                item.indentationLevel = depth
                item.isEnabled = a.kind == 1
                menu.addItem(item)
                add(a.id, depth + 1)
            }
        }
        add(nil, 0)
        if menu.items.count == 1 { menu.addItem(withTitle: "앨범이 없습니다", action: nil, keyEquivalent: "") }
    }
}

/// Side-by-side view of several photos (compare view). The first is the reference (border).
final class CompareView: NSView {
    private var views: [NSImageView] = []
    private var labels: [NSTextField] = []
    var onClose: (() -> Void)?

    func show(_ items: [PhotoItem], library: Library) {
        subviews.forEach { $0.removeFromSuperview() }
        views = []; labels = []
        for (i, item) in items.enumerated() {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.image = item.thumbnail
            iv.wantsLayer = true
            iv.layer?.borderWidth = i == 0 ? 2 : 0
            iv.layer?.borderColor = NSColor.controlAccentColor.cgColor
            let l = NSTextField(labelWithString: (i == 0 ? "기준 · " : "") + item.name + (item.rating > 0 ? "  " + String(repeating: "★", count: item.rating) : ""))
            l.font = .systemFont(ofSize: 11, weight: i == 0 ? .semibold : .regular)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            addSubview(iv); addSubview(l)
            views.append(iv); labels.append(l)
            // Reload large (preview with adjustments)
            library.loadThumbnail(item, size: 1600) { [weak iv] img in DispatchQueue.main.async { if let img { iv?.image = img } } }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = views.count
        guard n > 0 else { return }
        let cols = n <= 2 ? n : 2, rows = (n + cols - 1) / cols
        let w = bounds.width / CGFloat(cols), h = bounds.height / CGFloat(rows)
        for i in 0 ..< n {
            let c = i % cols, r = i / cols
            let cell = NSRect(x: CGFloat(c) * w, y: bounds.height - CGFloat(r + 1) * h, width: w, height: h).insetBy(dx: 8, dy: 8)
            labels[i].frame = NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: 16)
            views[i].frame = NSRect(x: cell.minX, y: cell.minY + 20, width: cell.width, height: cell.height - 20)
        }
    }
}
