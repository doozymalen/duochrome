import AppKit

/// Photo browser. Used two ways.
/// - Edit mode, right filmstrip: pick one at a time.
/// - Library mode, center grid: pick many; double-click opens in edit mode.
/// Thumbnails show file name, rating, color tag, and adjusted/offline badges.
final class BrowserViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var library: Library!
    /// The primary pick (the photo opened in edit mode).
    var onSelect: ((PhotoItem) -> Void)?
    /// When the whole selection changed.
    var onSelectionChange: (([PhotoItem]) -> Void)?
    /// On double-click (library → edit).
    var onOpen: ((PhotoItem) -> Void)?
    /// When a photo is dropped onto another photo (dragged photo path, target photo)
    var onDropAdjustments: ((String, PhotoItem) -> Void)?
    /// Number keys set rating (0–5).
    var onRate: ((Int) -> Void)?

    let grid: Bool
    /// Horizontal filmstrip under the viewer
    let horizontal: Bool
    private let collection = BrowserCollectionView()
    private let countLabel = NSTextField(labelWithString: "")
    private static let itemID = NSUserInterfaceItemIdentifier("PhotoCell")
    private let layout = NSCollectionViewFlowLayout()

    /// Header above the right photo list (search field + grid button). Only used in batch-edit mode.
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
        // Dragging: both in-app (onto albums or photos) and to Finder (file copy)
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
            // Filmstrip: count small at the top left
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
            // Header: [photo search ········] [grid view]
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
            // Hairline under the count: shows the list scrolling beneath it (so thumbnails don't look clipped by the count)
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

    /// Right photo list (single column): cell width follows the panel width. 12 pt side margins; two columns when wide.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !grid, !horizontal, let scroll = listScroll else { return }
        let inset: CGFloat = 12, gap: CGFloat = 8
        let avail = scroll.contentSize.width - inset * 2
        guard avail > 40 else { return }
        let cols: CGFloat = avail >= 400 ? 2 : 1
        let w = floor((avail - gap * (cols - 1)) / cols)
        // photo (3:2) + name/rating row
        let size = NSSize(width: w, height: floor(w * 2 / 3) + 8 + 30)
        guard layout.itemSize != size else { return }
        layout.itemSize = size
        layout.minimumInteritemSpacing = gap
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 6, left: inset, bottom: 12, right: inset)
        layout.invalidateLayout()
    }

    /// Grid cell size (library mode zoom slider).
    func setThumbSize(_ w: CGFloat) {
        layout.itemSize = NSSize(width: w, height: w * 0.78 + 30)
    }

    func reload() {
        guard isViewLoaded else { return }
        // Grid view shows the count in the top bar (not twice)
        countLabel.stringValue = library.items.isEmpty || grid ? "" : (horizontal ? "\(library.items.count)장" : "\(library.items.count)")
        let keep = Set(selectedItems.map { ObjectIdentifier($0) })
        collection.reloadData()
        let paths = library.items.enumerated().filter { keep.contains(ObjectIdentifier($0.element)) }
            .map { IndexPath(item: $0.offset, section: 0) }
        collection.selectionIndexPaths = Set(paths)
    }

    /// With multi-photo editing on, the filmstrip allows multiple selection too
    func setMultipleSelection(_ on: Bool) { if isViewLoaded { collection.allowsMultipleSelection = grid || on } }

    var selectedItems: [PhotoItem] {
        collection.selectionIndexPaths.map(\.item).sorted().compactMap { library.items.indices.contains($0) ? library.items[$0] : nil }
    }

    /// Compare standardized paths (standardizing changes paths like /private/tmp → /tmp).
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

    /// Mirrors a selection made in another mode without notifying.
    func mirror(_ item: PhotoItem?) {
        guard isViewLoaded, let item, let i = library.items.firstIndex(where: { $0 === item }) else { return }
        if collection.selectionIndexPaths.contains(IndexPath(item: i, section: 0)) { return }
        select(index: i, notify: false)
    }

    func refresh(_ item: PhotoItem) {
        guard isViewLoaded, let i = library.items.firstIndex(where: { $0 === item }) else { return }
        // If the photo list changed but the grid still has the old one, a single item can't be reloaded (the app hung) → reload all
        // Redrawing a cell dropped its selection → after rating, pick (P) hit no photo. Preserve the selection
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

    // MARK: - Data

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

    // MARK: - Drag and drop (DragDrop.swift)

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

    /// Drops only "onto" another photo (not between) → copy adjustments
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

/// In the filmstrip, up/down arrows step one photo (previous/next even with several columns).
/// Number keys 0–5 set rating, Return opens.
final class BrowserCollectionView: NSCollectionView {
    var singleStep = true
    var onRate: ((Int) -> Void)?
    var onOpen: (() -> Void)?
    /// Pick P(1) · reject X(-1) · unflagged U(0)
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
        if event.keyCode == 36 { onOpen?(); return }   // Return
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

/// Color tag colors (order: red, orange, yellow, green, blue, pink, purple).
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
        // The thumbnail took the whole cell and squeezed the name row to zero height. Let the name claim space first.
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

/// Cell that receives double-clicks (collection views have no double-click action).
final class ClickView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
