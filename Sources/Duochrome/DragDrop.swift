import AppKit
import UniformTypeIdentifiers

// Drag and drop (checklist "drag and drop"):
// ① photo list → sidebar album: add to album
// ② photo → another photo: copy adjustments (same groups as Apply Adjustments)
// ③ within the layer list: reorder, move into a group
// ④ Finder image → layer list / canvas: image layer
// ⑤ Finder folder / photo → window: open (DropWindow)

extension NSPasteboard.PasteboardType {
    /// In-app photo drag (value: photo paths, newline-separated)
    static let duochromePhotos = NSPasteboard.PasteboardType("com.doozymalen.duochrome.photos")
    /// In-app layer drag (value: layer id)
    static let duochromeLayer = NSPasteboard.PasteboardType("com.doozymalen.duochrome.layer")
    /// Tool drag in the tool customization window (value: tool id)
    static let duochromeTool = NSPasteboard.PasteboardType("com.doozymalen.duochrome.tool")
}

enum DragFiles {
    /// Dragged file URLs
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Images that can become layers (not RAW — RAW opens as a photo)
    static func isLayerImage(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .rawImage)
    }
}

// MARK: - Dragging layer rows

/// Shared behavior of a layer list row: select on click (on mouse-up), drag the layer after moving more than 4 pt.
/// (Selecting on mouse-down redrew the list and the row vanished, so dragging couldn't start)
class DraggableLayerRow: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    /// Layer id to drag. nil for the background row (not draggable, only a drop target)
    var dragID: String?
    /// For a group row, dropping in the middle puts it inside the group
    var isGroupRow = false
    private var downAt: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, !dragging, let id = dragID else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        let item = NSPasteboardItem()
        item.setString(id, forType: .duochromeLayer)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick?() }
        downAt = nil
        dragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Where to drop the layer
enum LayerDropPlace: Equatable {
    case above, below, into
}

/// Layer list (shared by the batch-edit layers tab and the layer-edit layers panel): accepts dragged layers and Finder images.
class LayerDropList: FlippedStackView {
    /// Places a layer id above, below, or inside the target layer (nil = background row)
    var onDropLayer: ((_ id: String, _ target: String?, _ place: LayerDropPlace) -> Void)?
    /// Finder images as image layers
    var onDropFiles: (([URL]) -> Bool)?

    private let marker = NSView()
    private var pending: (target: String?, place: LayerDropPlace)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.duochromeLayer, .fileURL])
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1.5
        marker.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rows() -> [DraggableLayerRow] { arrangedSubviews.compactMap { $0 as? DraggableLayerRow } }

    /// Drag location → (target, position, indicator rect)
    private func target(at p: NSPoint, dragged: String?) -> (String?, LayerDropPlace, DraggableLayerRow)? {
        let rs = rows()
        guard !rs.isEmpty else { return nil }
        let row = rs.first { $0.frame.minY <= p.y && p.y <= $0.frame.maxY }
            ?? (p.y < rs[0].frame.minY ? rs[0] : rs[rs.count - 1])
        if let d = dragged, row.dragID == d { return nil }
        // Background row: bottom only
        guard row.dragID != nil else { return (nil, .above, row) }
        let t = (p.y - row.frame.minY) / max(row.frame.height, 1)   // Flipped coordinates: 0 = top of the row
        if row.isGroupRow, t > 0.28, t < 0.72 { return (row.dragID, .into, row) }
        return (row.dragID, t < 0.5 ? .above : .below, row)
    }

    private func show(_ place: LayerDropPlace, on row: DraggableLayerRow) {
        if marker.superview == nil { addSubview(marker) }
        marker.isHidden = false
        marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        switch place {
        case .into:
            marker.frame = row.frame.insetBy(dx: 4, dy: 1)
            marker.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            marker.layer?.cornerRadius = 6
        case .above, .below:
            let y = place == .above ? row.frame.minY : row.frame.maxY
            marker.frame = NSRect(x: 8, y: y - 1.5, width: bounds.width - 16, height: 3)
            marker.layer?.cornerRadius = 1.5
        }
    }

    private func draggedLayer(_ info: NSDraggingInfo) -> String? { info.draggingPasteboard.string(forType: .duochromeLayer) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        if let id = draggedLayer(sender) {
            guard let (t, place, row) = target(at: p, dragged: id) else { marker.isHidden = true; pending = nil; return [] }
            pending = (t, place)
            show(place, on: row)
            return .move
        }
        let files = DragFiles.urls(sender).filter(DragFiles.isLayerImage)
        guard !files.isEmpty, onDropFiles != nil else { return [] }
        marker.isHidden = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { marker.isHidden = true; pending = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        marker.isHidden = true
        if let id = draggedLayer(sender) {
            guard let p = pending else { return false }
            onDropLayer?(id, p.target, p.place)
            pending = nil
            return true
        }
        let files = DragFiles.urls(sender).filter(DragFiles.isLayerImage)
        return !files.isEmpty && (onDropFiles?(files) ?? false)
    }
}

extension LayerTree {
    /// Drag and drop: moves layer `from` (with descendants if a group) above/below `target`, or inside group `target` (as top child).
    /// A nil target means right above the background (array front, outside groups). Never onto itself or its descendants.
    @discardableResult
    static func drop(_ layers: inout [AdjustLayer], from: Int, onto target: Int?, _ place: LayerDropPlace) -> Bool {
        let r = block(layers, from)
        guard let t = target else {
            layers[from].group = nil
            let items = Array(layers[r])
            layers.removeSubrange(r)
            layers.insert(contentsOf: items, at: 0)
            return true
        }
        guard !r.contains(t) else { return false }
        if place == .into, !layers[t].isGroup { return false }
        let targetID = layers[t].id
        switch place {
        case .into: layers[from].group = targetID
        case .above, .below: layers[from].group = layers[t].group
        }
        let items = Array(layers[r])
        layers.removeSubrange(r)
        // After removing, find the target position again
        guard let nt = layers.firstIndex(where: { $0.id == targetID }) else { return false }
        let at: Int
        switch place {
        case .into: at = nt                               // Right below the group item = top child
        case .above: at = nt + 1                          // the end of the array is the top
        case .below: at = block(layers, nt).lowerBound    // below the target block
        }
        layers.insert(contentsOf: items, at: at)
        return true
    }
}

// MARK: - Window wiring

extension MainWindowController {
    /// Moves a layer dropped in the layer list.
    func dropLayer(_ id: String, onto target: String?, _ place: LayerDropPlace) {
        guard var s = photo?.settings, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        let t = target.flatMap { tid in s.layers.firstIndex { $0.id == tid } }
        guard LayerTree.drop(&s.layers, from: i, onto: t, place) else { NSSound.beep(); return }
        replaceSettings(s, recordUndo: true, label: "레이어 옮기기")
        layersTab.select(id)
        if mode == .studio { retouchEditor.reload() }
    }

    /// Inserts images dragged from Finder as image layers (files copied into the catalog Assets).
    @discardableResult
    func dropImageLayers(_ urls: [URL]) -> Bool {
        guard photo != nil else { NSSound.beep(); return false }
        var added = 0
        for u in urls where DragFiles.isLayerImage(u) {
            do {
                let file = try LayerImageStore.importFile(u)
                layersTab.addImageLayer(file: file, name: u.deletingPathExtension().lastPathComponent)
                added += 1
            } catch {
                NSLog("이미지 레이어 넣기 실패: %@", "\(error)")
            }
        }
        if mode == .studio { retouchEditor.reload() }
        return added > 0
    }

    /// Adds photos dragged from the photo list to an album.
    func dropPhotos(_ paths: [String], toAlbum id: Int64) {
        let set = Set(paths)
        let ids = library.items.filter { set.contains($0.url.path) }.map(\.id).filter { $0 != 0 }
        guard !ids.isEmpty else { NSSound.beep(); return }
        try? library.catalog.addToAlbum(id, ids)
        reloadSources()
    }

    /// Dropping a photo onto another: pastes the dragged photo's adjustments onto it (same groups as Apply Adjustments).
    func dropAdjustments(from path: String, onto target: PhotoItem) {
        guard let source = library.items.first(where: { $0.url.path == path }), source !== target else { return }
        var dict: [String: Any]
        if source === photoItem, let doc = photo {
            dict = settingsDict(doc.settings)
        } else if let data = library.rawSettings(for: source.url),
                  let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = saved
        } else {
            NSSound.beep(); return   // photo without adjustments
        }
        let saved = Set((UserDefaults.standard.stringArray(forKey: "pasteGroups") ?? []).compactMap(AdjustGroup.init))
        let groups = saved.isEmpty ? Set(AdjustGroup.allCases.filter(\.defaultOn)) : saved
        let keys = AdjustGroup.keys(groups)
        let clip = dict.filter { keys.contains($0.key) }
        if target === photoItem, let doc = photo {
            var d = settingsDict(doc.settings)
            for (k, v) in clip { d[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let s = try? JSONDecoder().decode(DevelopSettings.self, from: data) {
                replaceSettings(s, recordUndo: true, label: "조정 끌어 붙이기 (\(source.name))")
            }
        } else {
            var d = (library.rawSettings(for: target.url)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            for (k, v) in clip { d[k] = v }
            library.saveRawSettings(d, for: target.url)
        }
        target.edited = true
        target.thumbnail = nil
        refreshItem(target)
        refreshThumbnails([target])
    }

    /// Drag-and-drop wiring (once, after setupModes)
    func installDragAndDrop() {
        for list in [layersTab.dropList] {
            list.onDropLayer = { [weak self] id, t, p in self?.dropLayer(id, onto: t, p) }
            list.onDropFiles = { [weak self] urls in self?.dropImageLayers(urls) ?? false }
        }
        for b in [browser, libraryMode.grid, tetherMode.strip] {
            b.onDropAdjustments = { [weak self] path, item in self?.dropAdjustments(from: path, onto: item) }
        }
        for list in [libraryMode.sources, libraryTab.sources] {
            list.onDropPhotos = { [weak self] paths, album in self?.dropPhotos(paths, toAlbum: album) }
        }
        canvas.onDropFiles = { [weak self] urls in
            guard let self else { return false }
            // Images become image layers; RAW and folders open as if dropped on the window
            let images = urls.filter(DragFiles.isLayerImage)
            if self.photo != nil, !images.isEmpty { return self.dropImageLayers(images) }
            guard let u = urls.first else { return false }
            self.openFileOrFolder(u)
            return true
        }
    }
}
