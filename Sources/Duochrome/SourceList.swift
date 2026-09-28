import AppKit

/// 카탈로그의 사진 묶음 목록.
/// 카탈로그 · 폴더 · 앨범 세 갈래. 라이브러리 모드 왼쪽과 편집 모드의 라이브러리 탭에서 같이 쓴다.
final class SourceListController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let title: String
        let symbol: String
        let source: Catalog.Source?
        var count: Int?
        var children: [Node] = []
        var albumID: Int64?
        var keywordID: Int64?
        init(_ title: String, _ symbol: String, _ source: Catalog.Source?, count: Int? = nil) {
            self.title = title; self.symbol = symbol; self.source = source; self.count = count
        }
    }

    var catalog: Catalog!
    var onSelect: ((Catalog.Source, String) -> Void)?
    /// 사진을 앨범에 끌어 놓았을 때 (사진 경로들, 앨범 번호)
    var onDropPhotos: (([String], Int64) -> Void)?
    /// 앨범 메뉴 (새 앨범·이름 바꾸기·삭제)
    var onAlbumsChanged: (() -> Void)?

    private let outline = NSOutlineView()
    private var roots: [Node] = []
    /// 코드로 고르는 중. 이때 알리면 "고름 → 다시 채움 → 고름"이 끝없이 돈다.
    private var programmatic = false

    override func loadView() {
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        // sourceList 스타일은 자기 사이드바 바탕을 칠해 유리 패널을 가린다 (라이브러리 탭만 유리가 안 보였다)
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.floatsGroupRows = false
        outline.menu = albumMenu()
        outline.registerForDraggedTypes([.duochromePhotos])
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    func reload(select source: Catalog.Source? = nil) {
        guard let catalog, isViewLoaded else { return }
        programmatic = true
        defer { programmatic = false }
        func n(_ s: Catalog.Source) -> Int? { try? catalog.count(s) }
        let lib = Node("카탈로그", "", nil)
        lib.children = [
            Node("모든 사진", "photo.on.rectangle", .all, count: n(.all)),
            Node("최근 가져오기", "clock", .recentImport, count: n(.recentImport)),
            Node("별점 3개 이상", "star", .rated(3), count: n(.rated(3))),
            Node("채택", "flag.fill", .flag(1), count: n(.flag(1))),
            Node("거부", "xmark.circle", .flag(-1), count: n(.flag(-1))),
            Node("조정한 사진", "slider.horizontal.3", .edited, count: n(.edited)),
            Node("오프라인 (원본 없음)", "icloud.slash", .offline, count: n(.offline)),
        ]
        let folders = Node("폴더", "", nil)
        for f in (try? catalog.folders()) ?? [] {
            let c = n(.folder(f.id)) ?? 0
            guard c > 0 else { continue }
            let url = URL(fileURLWithPath: f.path)
            folders.children.append(Node("\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)",
                                         "folder", .folder(f.id), count: c))
        }
        let albums = Node("앨범", "", nil)
        let all = (try? catalog.albums()) ?? []
        func build(_ parent: Int64?) -> [Node] {
            all.filter { $0.parent == parent }.map { a in
                let node = Node(a.name, a.kind == 2 ? "gearshape" : a.kind == 0 ? (a.source == "import" ? "tray.and.arrow.down" : "folder.badge.gearshape") : "rectangle.stack",
                                .album(a.id), count: n(.album(a.id)))
                node.albumID = a.id
                node.children = build(a.id)
                return node
            }
        }
        albums.children = build(nil)
        // 키워드 (계층)
        let kw = Node("키워드", "", nil)
        let kws = catalog.allKeywords()
        func kbuild(_ parent: Int64?) -> [Node] {
            kws.filter { $0.parent == parent }.map { k in
                let node = Node(k.name, "tag", .keyword(k.id), count: n(.keyword(k.id)))
                node.keywordID = k.id
                node.children = kbuild(k.id)
                return node
            }
        }
        kw.children = kbuild(nil)
        roots = kw.children.isEmpty ? [lib, folders, albums] : [lib, folders, albums, kw]
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
        if let source { selectSource(source) }
    }

    func selectSource(_ source: Catalog.Source) {
        func find(_ nodes: [Node]) -> Node? {
            for n in nodes {
                if n.source == source { return n }
                if let c = find(n.children) { return c }
            }
            return nil
        }
        guard let node = find(roots) else { return }
        var p = outline.parent(forItem: node)
        while let pp = p { outline.expandItem(pp); p = outline.parent(forItem: pp) }
        let row = outline.row(forItem: node)
        programmatic = true
        defer { programmatic = false }
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
    }

    // MARK: - 개요 보기

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }

    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.source == nil }

    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.source != nil }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if node.source == nil {
            let t = NSTextField(labelWithString: node.title)
            t.font = .systemFont(ofSize: 11, weight: .semibold)
            t.textColor = .secondaryLabelColor
            return t
        }
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: node.title)
        name.lineBreakMode = .byTruncatingMiddle
        let count = NSTextField(labelWithString: node.count.map { "\($0)" } ?? "")
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .tertiaryLabelColor
        let h = NSStackView(views: [icon, name, NSView(), count])
        h.spacing = 5
        h.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(h)
        cell.textField = name
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            h.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        return cell
    }

    // 사진을 앨범 위에 놓으면 그 앨범에 넣는다
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: .duochromePhotos) != nil,
              let node = item as? Node, case .album = node.source else { return [] }
        o.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? Node, case .album(let id) = node.source else { return false }
        let paths = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .duochromePhotos) }
        guard !paths.isEmpty else { return false }
        onDropPhotos?(paths, id)
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !programmatic, let node = outline.item(atRow: outline.selectedRow) as? Node, let s = node.source else { return }
        onSelect?(s, node.title)
    }

    // MARK: - 앨범 메뉴

    private func albumMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "새 앨범…", action: #selector(newAlbum), keyEquivalent: "").target = self
        m.addItem(withTitle: "새 그룹…", action: #selector(newGroup), keyEquivalent: "").target = self
        m.addItem(withTitle: "새 스마트 앨범…", action: #selector(newSmartAlbum), keyEquivalent: "").target = self
        m.addItem(withTitle: "스마트 앨범 조건 고치기…", action: #selector(editSmartAlbum), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "키워드 지우기", action: #selector(deleteKeyword), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "이름 바꾸기…", action: #selector(renameAlbum), keyEquivalent: "").target = self
        m.addItem(withTitle: "삭제 (사진은 지우지 않음)", action: #selector(deleteAlbum), keyEquivalent: "").target = self
        return m
    }

    private var clickedAlbum: Node? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? Node
    }

    private func ask(_ title: String, _ initial: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        a.addButton(withTitle: "확인")
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty ? field.stringValue : nil
    }

    /// 고른 곳이 그룹이면 그 안에, 앨범이면 같은 그룹에 만든다.
    private var parentForNew: Int64? {
        guard let node = clickedAlbum, let id = node.albumID,
              let a = (try? catalog.albums())?.first(where: { $0.id == id }) else { return nil }
        return a.kind == 0 ? a.id : a.parent
    }

    @objc func newAlbum() {
        guard let name = ask("새 앨범 이름") else { return }
        _ = try? catalog.addAlbum(name, parent: parentForNew, kind: 1)
        reload(); onAlbumsChanged?()
    }

    @objc func newGroup() {
        guard let name = ask("새 그룹 이름") else { return }
        _ = try? catalog.addAlbum(name, parent: parentForNew, kind: 0)
        reload(); onAlbumsChanged?()
    }

    @objc func newSmartAlbum() {
        guard let (name, rule) = SmartRuleEditor.run(name: "스마트 앨범", rule: Catalog.SmartRule(minRating: 3)) else { return }
        _ = try? catalog.addSmartAlbum(name, rule: rule, parent: parentForNew)
        reload(); onAlbumsChanged?()
    }

    @objc private func editSmartAlbum() {
        guard let node = clickedAlbum, let id = node.albumID, let rule = catalog.smartRule(id),
              let (name, r) = SmartRuleEditor.run(name: node.title, rule: rule) else { NSSound.beep(); return }
        try? catalog.setSmartRule(id, r)
        try? catalog.renameAlbum(id, name)
        reload(select: .album(id)); onAlbumsChanged?()
        onSelect?(.album(id), name)
    }

    @objc private func deleteKeyword() {
        guard let node = clickedAlbum, let id = node.keywordID else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "\"\(node.title)\" 키워드와 그 아래 키워드를 지울까요?"
        a.informativeText = "사진에서 키워드만 떼어 냅니다. 사진은 그대로입니다."
        a.addButton(withTitle: "지우기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? catalog.deleteKeyword(id)
        reload(); onAlbumsChanged?()
    }

    @objc private func renameAlbum() {
        guard let node = clickedAlbum, let id = node.albumID, let name = ask("새 이름", node.title) else { return }
        try? catalog.renameAlbum(id, name)
        reload(); onAlbumsChanged?()
    }

    @objc private func deleteAlbum() {
        guard let node = clickedAlbum, let id = node.albumID else { return }
        let a = NSAlert()
        a.messageText = "\"\(node.title)\" 앨범을 지울까요?"
        a.informativeText = "앨범만 지웁니다. 사진 파일과 다른 앨범은 그대로입니다."
        a.addButton(withTitle: "지우기")
        a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? catalog.deleteAlbum(id)
        reload(); onAlbumsChanged?()
    }
}

/// 스마트 앨범 조건 고르기 (알림 창 하나에 칸들)
enum SmartRuleEditor {
    static func run(name: String, rule: Catalog.SmartRule) -> (String, Catalog.SmartRule)? {
        let a = NSAlert()
        a.messageText = "스마트 앨범"
        a.informativeText = "조건에 맞는 사진이 저절로 들어갑니다. 빈 칸은 따지지 않습니다."
        func field(_ v: String, _ ph: String) -> NSTextField {
            let f = NSTextField(string: v); f.placeholderString = ph
            f.widthAnchor.constraint(equalToConstant: 200).isActive = true
            return f
        }
        let nameF = field(name, "이름")
        let rating = NSPopUpButton(); rating.addItems(withTitles: ["별점 상관없음", "★1 이상", "★2 이상", "★3 이상", "★4 이상", "★5"])
        rating.selectItem(at: rule.minRating)
        let color = NSPopUpButton(); color.addItems(withTitles: ["색 상관없음", "빨강", "주황", "노랑", "초록", "파랑", "분홍", "보라"])
        color.selectItem(at: rule.color)
        let flag = NSPopUpButton(); flag.addItems(withTitles: ["채택·거부 상관없음", "채택만", "거부만", "거부 빼고"])
        flag.selectItem(at: [0: 0, 1: 1, -1: 2, 2: 3][rule.flag] ?? 0)
        let kw = field(rule.keyword, "키워드 (일부)"), cam = field(rule.camera, "카메라 (일부)"), lens = field(rule.lens, "렌즈 (일부)")
        let fname = field(rule.name, "파일·폴더 이름 (일부)")
        let isoMin = field(rule.isoMin > 0 ? "\(Int(rule.isoMin))" : "", "ISO 이상"), isoMax = field(rule.isoMax > 0 ? "\(Int(rule.isoMax))" : "", "ISO 이하")
        let days = field(rule.daysRecent > 0 ? "\(rule.daysRecent)" : "", "최근 며칠 안에 찍은 것")
        let edited = NSButton(checkboxWithTitle: "조정한 사진만", target: nil, action: nil)
        edited.state = rule.editedOnly ? .on : .off
        let st = NSStackView(views: [nameF, rating, color, flag, kw, cam, lens, fname, isoMin, isoMax, days, edited])
        st.orientation = .vertical; st.alignment = .leading; st.spacing = 6
        st.frame = NSRect(x: 0, y: 0, width: 220, height: 380)
        a.accessoryView = st
        a.addButton(withTitle: "확인"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        var r = Catalog.SmartRule()
        r.minRating = rating.indexOfSelectedItem
        r.color = color.indexOfSelectedItem
        r.flag = [0, 1, -1, 2][flag.indexOfSelectedItem]
        r.keyword = kw.stringValue; r.camera = cam.stringValue; r.lens = lens.stringValue; r.name = fname.stringValue
        r.isoMin = Double(isoMin.stringValue) ?? 0; r.isoMax = Double(isoMax.stringValue) ?? 0
        r.daysRecent = Int(days.stringValue) ?? 0
        r.editedOnly = edited.state == .on
        return (nameF.stringValue.isEmpty ? "스마트 앨범" : nameF.stringValue, r)
    }
}
