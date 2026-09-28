import AppKit

/// 사진 브라우저. 두 가지로 쓴다.
/// - 편집 모드 오른쪽 필름스트립: 한 장씩 고른다.
/// - 라이브러리 모드 가운데 격자: 여러 장을 고르고, 두 번 누르면 편집 모드로 연다.
/// 썸네일 아래 파일 이름, 별점, 색 태그, 조정·오프라인 표시가 붙는다.
final class BrowserViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var library: Library!
    /// 대표로 고른 한 장 (편집 모드에서 여는 사진).
    var onSelect: ((PhotoItem) -> Void)?
    /// 고른 사진 전부가 바뀌었을 때.
    var onSelectionChange: (([PhotoItem]) -> Void)?
    /// 두 번 눌렀을 때 (라이브러리 → 편집).
    var onOpen: ((PhotoItem) -> Void)?
    /// 사진을 다른 사진 위에 끌어 놓았을 때 (끌어 온 사진 경로, 놓인 사진)
    var onDropAdjustments: ((String, PhotoItem) -> Void)?
    /// 숫자 키로 별점 (0~5).
    var onRate: ((Int) -> Void)?

    let grid: Bool
    /// 뷰어 아래 가로 필름 스트립
    let horizontal: Bool
    private let collection = BrowserCollectionView()
    private let countLabel = NSTextField(labelWithString: "")
    private static let itemID = NSUserInterfaceItemIdentifier("PhotoCell")
    private let layout = NSCollectionViewFlowLayout()

    /// 오른쪽 사진 목록 위 머리줄 (검색칸 + 격자 보기 단추). 대량 보정 모드에서만 쓴다.
    let header: Bool
    var onSearch: ((NSSearchField) -> Void)?
    var onGridToggle: (() -> Void)?
    private(set) var searchField: NSSearchField?

    init(grid: Bool = false, horizontal: Bool = false, header: Bool = false) {
        self.grid = grid
        self.horizontal = horizontal
        self.header = header
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        layout.itemSize = grid ? NSSize(width: 230, height: 210) : (horizontal ? NSSize(width: 112, height: 96) : NSSize(width: 170, height: 162))
        if horizontal { layout.scrollDirection = .horizontal }
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = horizontal ? NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8) : NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = grid || UserDefaults.standard.bool(forKey: "multiEdit")
        collection.backgroundColors = [.clear]
        collection.register(PhotoCell.self, forItemWithIdentifier: Self.itemID)
        collection.singleStep = !grid
        // 끌기: 앱 안(앨범·다른 사진 위)과 Finder(파일 복사) 모두
        collection.setDraggingSourceOperationMask(.every, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.registerForDraggedTypes([.duochromePhotos])
        collection.onRate = { [weak self] n in self?.onRate?(n) }
        collection.onOpen = { [weak self] in
            guard let self, let i = self.collection.selectionIndexPaths.first?.item else { return }
            self.onOpen?(self.library.items[i])
        }

        let scroll = NSScrollView()
        listScroll = scroll
        scroll.documentView = collection
        scroll.hasVerticalScroller = !horizontal
        scroll.hasHorizontalScroller = horizontal
        scroll.drawsBackground = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        let root = NSView()
        for v in [countLabel, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        if horizontal {
            // 필름 스트립: 장 수는 왼쪽 위에 작게
            countLabel.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                countLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
                countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
                scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 2),
                scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            view = root
            return
        }
        countLabel.textColor = .controlAccentColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        var countTop = root.safeAreaLayoutGuide.topAnchor
        if header {
            // 머리줄: [사진 검색 ········] [격자 보기]
            let search = ModeBarSearchField(placeholder: "사진 검색 (이름·폴더, ★3)", width: 0, target: self, action: #selector(searchChanged(_:)))
            search.constraints.filter { $0.firstAttribute == .width }.forEach { search.removeConstraint($0) }
            search.controlSize = .small
            searchField = search
            let gridButton = ModeBarButton("square.grid.2x2", "격자 보기 (G) — 다시 누르면 대량 보정으로", target: self, action: #selector(gridToggle))
            let row = NSStackView(views: [search, gridButton])
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
                row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            ])
            countTop = row.bottomAnchor
        }
        if header {
            // 장 수 아래 가는 선: 목록이 이 선 밑으로 들어가는 게 보이게 (썸네일이 장 수에 걸려 잘려 보이지 않게)
            let line = NSBox(); line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 5),
                line.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                line.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            ])
        }
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: countTop, constant: 8),
            countLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: header ? 10 : 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private weak var listScroll: NSScrollView?

    @objc private func searchChanged(_ sender: NSSearchField) { onSearch?(sender) }
    @objc private func gridToggle() { onGridToggle?() }

    /// 오른쪽 사진 목록(세로 한 줄): 패널 폭에 맞춰 사진 칸 너비가 변한다. 양옆 여백 12pt, 넓으면 두 줄.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !grid, !horizontal, let scroll = listScroll else { return }
        let inset: CGFloat = 12, gap: CGFloat = 8
        let avail = scroll.contentSize.width - inset * 2
        guard avail > 40 else { return }
        let cols: CGFloat = avail >= 400 ? 2 : 1
        let w = floor((avail - gap * (cols - 1)) / cols)
        // 사진(3:2) + 이름·별점 줄
        let size = NSSize(width: w, height: floor(w * 2 / 3) + 8 + 30)
        guard layout.itemSize != size else { return }
        layout.itemSize = size
        layout.minimumInteritemSpacing = gap
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 6, left: inset, bottom: 12, right: inset)
        layout.invalidateLayout()
    }

    /// 격자 칸 크기 (라이브러리 모드 확대 슬라이더).
    func setThumbSize(_ w: CGFloat) {
        layout.itemSize = NSSize(width: w, height: w * 0.78 + 30)
    }

    func reload() {
        guard isViewLoaded else { return }
        // 격자 보기는 위 막대에 장 수가 있다 (두 번 보이지 않게)
        countLabel.stringValue = library.items.isEmpty || grid ? "" : (horizontal ? "\(library.items.count)장" : "\(library.items.count)")
        let keep = Set(selectedItems.map { ObjectIdentifier($0) })
        collection.reloadData()
        let paths = library.items.enumerated().filter { keep.contains(ObjectIdentifier($0.element)) }
            .map { IndexPath(item: $0.offset, section: 0) }
        collection.selectionIndexPaths = Set(paths)
    }

    /// 여러 장 같이 보정을 켜면 필름스트립에서도 여러 장을 고를 수 있다
    func setMultipleSelection(_ on: Bool) { if isViewLoaded { collection.allowsMultipleSelection = grid || on } }

    var selectedItems: [PhotoItem] {
        collection.selectionIndexPaths.map(\.item).sorted().compactMap { library.items.indices.contains($0) ? library.items[$0] : nil }
    }

    /// 경로 비교는 표준화해서 한다 (/private/tmp → /tmp 처럼 표준화가 경로를 바꾼다).
    func select(_ url: URL) {
        let want = url.standardizedFileURL.path
        guard let i = library.items.firstIndex(where: { $0.url.standardizedFileURL.path == want }) else { return }
        select(index: i)
    }

    func select(index i: Int, notify: Bool = true) {
        guard library.items.indices.contains(i) else { return }
        let path = IndexPath(item: i, section: 0)
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: horizontal ? .centeredHorizontally : .centeredVertically)
        if notify {
            onSelect?(library.items[i])
            onSelectionChange?([library.items[i]])
        }
    }

    /// 다른 모드에서 고른 사진을 이쪽에도 표시만 한다 (알리지 않는다).
    func mirror(_ item: PhotoItem?) {
        guard isViewLoaded, let item, let i = library.items.firstIndex(where: { $0 === item }) else { return }
        if collection.selectionIndexPaths.contains(IndexPath(item: i, section: 0)) { return }
        select(index: i, notify: false)
    }

    func refresh(_ item: PhotoItem) {
        guard isViewLoaded, let i = library.items.firstIndex(where: { $0 === item }) else { return }
        // 사진 목록이 바뀌었는데 격자가 아직 옛 목록이면 한 칸만 고칠 수 없다 (앱이 멈췄다) → 전체를 다시
        // 칸을 새로 그리면 그 칸의 선택이 풀렸다 → 별점을 준 뒤 채택(P)이 아무 사진에도 안 걸렸다. 선택을 지킨다
        let sel = collection.selectionIndexPaths
        guard collection.numberOfSections > 0, collection.numberOfItems(inSection: 0) == library.items.count else {
            reload(); return
        }
        collection.reloadItems(at: [IndexPath(item: i, section: 0)])
        if collection.selectionIndexPaths != sel { collection.selectionIndexPaths = sel }
    }

    func refreshAll() {
        guard isViewLoaded else { return }
        let sel = collection.selectionIndexPaths
        collection.reloadData()
        collection.selectionIndexPaths = sel
    }

    func focus() { view.window?.makeFirstResponder(collection) }

    // MARK: - 데이터

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { library.items.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: Self.itemID, for: indexPath) as! PhotoCell
        let item = library.items[indexPath.item]
        cell.show(item)
        cell.onDoubleClick = { [weak self] in self?.onOpen?(item) }
        if item.thumbnail == nil {
            library.loadThumbnail(item) { [weak cell] _ in
                if cell?.current === item { cell?.show(item) }
            }
        }
        return cell
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    // MARK: - 끌어 놓기 (DragDrop.swift)

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard library.items.indices.contains(indexPath.item) else { return nil }
        let item = library.items[indexPath.item]
        let p = NSPasteboardItem()
        p.setString(item.url.absoluteString, forType: .fileURL)
        p.setString(item.url.path, forType: .duochromePhotos)
        return p
    }

    /// 다른 사진 "위"에만 놓을 수 있다 (사이에는 안 됨) → 조정 복사
    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath p: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard onDropAdjustments != nil, let path = info.draggingPasteboard.string(forType: .duochromePhotos) else { return [] }
        let i = p.pointee.item
        guard library.items.indices.contains(i), library.items[i].url.path != path else { return [] }
        op.pointee = .on
        return .copy
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let path = info.draggingPasteboard.string(forType: .duochromePhotos),
              library.items.indices.contains(indexPath.item) else { return false }
        onDropAdjustments?(path, library.items[indexPath.item])
        return true
    }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    private func selectionChanged() {
        let items = selectedItems
        onSelectionChange?(items)
        if let first = items.first, items.count == 1 { onSelect?(first) }
    }
}

/// 필름스트립에서는 방향키 위아래로 한 장씩 넘긴다 (여러 열이어도 앞뒤 사진으로).
/// 숫자 키 0~5는 별점, 리턴은 열기.
final class BrowserCollectionView: NSCollectionView {
    var singleStep = true
    var onRate: ((Int) -> Void)?
    var onOpen: (() -> Void)?
    /// 채택 P(1)·거부 X(-1)·표시 없음 U(0)
    static var onFlag: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let ch = event.charactersIgnoringModifiers, let n = Int(ch), (0...5).contains(n),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onRate?(n); return
        }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let ch = event.charactersIgnoringModifiers?.lowercased(), let f = ["p": 1, "x": -1, "u": 0][ch] {
            Self.onFlag?(f); return
        }
        if event.keyCode == 36 { onOpen?(); return }   // 리턴
        guard singleStep else { return super.keyDown(with: event) }
        let delta: Int? = switch event.keyCode {
        case 123, 126: -1   // ←, ↑
        case 124, 125: 1    // →, ↓
        default: nil
        }
        guard let delta, numberOfItems(inSection: 0) > 0 else { return super.keyDown(with: event) }
        let cur = selectionIndexPaths.first?.item ?? -1
        let next = min(max(cur + delta, 0), numberOfItems(inSection: 0) - 1)
        guard next != cur else { return }
        let path = IndexPath(item: next, section: 0)
        deselectAll(nil)
        selectItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        delegate?.collectionView?(self, didSelectItemsAt: [path])
    }
}

/// 색 태그 색 (순서: 빨강·주황·노랑·초록·파랑·분홍·보라).
let colorTags: [(String, NSColor)] = [
    ("없음", .clear), ("빨강", .systemRed), ("주황", .systemOrange), ("노랑", .systemYellow),
    ("초록", .systemGreen), ("파랑", .systemBlue), ("분홍", .systemPink), ("보라", .systemPurple),
]

final class PhotoCell: NSCollectionViewItem {
    private(set) var current: PhotoItem?
    var onDoubleClick: (() -> Void)?
    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let stars = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let badge = NSImageView(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "조정됨")!)
    private let offline = NSImageView(image: NSImage(systemSymbolName: "icloud.slash", accessibilityDescription: "오프라인")!)

    override func loadView() {
        let root = ClickView()
        root.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        root.wantsLayer = true
        root.layer?.cornerRadius = 4
        thumb.imageScaling = .scaleProportionallyUpOrDown
        // 썸네일이 칸을 다 차지해 이름 줄이 0 높이로 눌렸다. 이름이 먼저 자리를 잡게 한다.
        thumb.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        thumb.setContentHuggingPriority(.defaultLow, for: .vertical)
        name.setContentCompressionResistancePriority(.required, for: .vertical)
        stars.setContentCompressionResistancePriority(.required, for: .vertical)
        name.font = .systemFont(ofSize: 11)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        stars.font = .systemFont(ofSize: 9)
        stars.alignment = .center
        stars.textColor = .systemOrange
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for b in [badge, offline] {
            b.contentTintColor = .secondaryLabelColor
            b.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        }
        for v in [thumb, name, stars, dot, badge, offline] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            thumb.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -3),
            name.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            name.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            name.bottomAnchor.constraint(equalTo: stars.topAnchor, constant: 0),
            stars.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stars.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            offline.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            offline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
        ])
        view = root
    }

    func show(_ item: PhotoItem) {
        current = item
        thumb.image = item.thumbnail
        thumb.alphaValue = item.offline ? 0.55 : 1
        name.stringValue = (item.flag == 1 ? "⚑ " : item.flag == -1 ? "✕ " : "") + item.name
        stars.stringValue = item.rating > 0 ? String(repeating: "★", count: item.rating) : " "
        thumb.alphaValue = item.offline || item.flag == -1 ? 0.45 : 1
        badge.isHidden = !item.edited
        offline.isHidden = !item.offline
        dot.layer?.backgroundColor = colorTags[min(max(item.color, 0), 7)].1.cgColor
        dot.isHidden = item.color == 0
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.14).cgColor : nil
            name.textColor = isSelected ? .labelColor : .secondaryLabelColor
        }
    }
}

/// 두 번 누르기를 받는 칸 (컬렉션 뷰는 두 번 누르기 동작이 따로 없다).
final class ClickView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
