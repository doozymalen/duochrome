import AppKit
import UniformTypeIdentifiers

// 끌어 놓기 (체크리스트 "드레그 드롭"):
// ① 사진 목록 → 사이드바 앨범: 앨범에 넣기
// ② 사진 → 다른 사진: 조정 복사 (조정 적용과 같은 갈래)
// ③ 레이어 목록 안: 순서 바꾸기, 그룹 안으로 넣기
// ④ Finder 그림 → 레이어 목록·캔버스: 이미지 레이어
// ⑤ Finder 폴더·사진 → 창: 열기 (DropWindow)
// ⑥ 도구 사용자화: 도구를 끌어 막대에 넣기·순서 바꾸기 (Studio.swift ToolCustomizeSheet)

extension NSPasteboard.PasteboardType {
    /// 앱 안 사진 끌기 (값: 사진 경로들, 줄바꿈으로)
    static let duochromePhotos = NSPasteboard.PasteboardType("com.doozymalen.duochrome.photos")
    /// 앱 안 레이어 끌기 (값: 레이어 id)
    static let duochromeLayer = NSPasteboard.PasteboardType("com.doozymalen.duochrome.layer")
    /// 도구 사용자화 창의 도구 끌기 (값: 도구 id)
    static let duochromeTool = NSPasteboard.PasteboardType("com.doozymalen.duochrome.tool")
}

enum DragFiles {
    /// 끌어 온 파일 URL들
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 레이어로 넣을 수 있는 그림 (RAW는 아니다 — RAW는 사진으로 연다)
    static func isLayerImage(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .rawImage)
    }
}

// MARK: - 레이어 줄 끌기

/// 레이어 목록 한 줄의 공통 동작: 누르면 고르고(떼었을 때), 4pt 넘게 끌면 레이어를 끈다.
/// (누를 때 바로 고르면 목록을 다시 그려 줄이 사라져 끌기를 시작할 수 없었다)
class DraggableLayerRow: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    /// 끌 레이어 id. nil이면 배경 줄 (끌 수 없고, 놓을 곳으로만 쓴다)
    var dragID: String?
    /// 그룹 줄이면 가운데에 놓을 때 그룹 안으로 넣는다
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

/// 레이어를 놓을 자리
enum LayerDropPlace: Equatable {
    case above, below, into
}

/// 레이어 목록 (대량 보정 레이어 탭·심화 보정 레이어 패널 공통): 끌어 온 레이어와 Finder 그림을 받는다.
class LayerDropList: FlippedStackView {
    /// 레이어 id를 대상 레이어(nil = 배경 줄) 위·아래·안에 놓는다
    var onDropLayer: ((_ id: String, _ target: String?, _ place: LayerDropPlace) -> Void)?
    /// Finder 그림들을 이미지 레이어로
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

    /// 끌기 위치 → (대상, 자리, 표시할 곳)
    private func target(at p: NSPoint, dragged: String?) -> (String?, LayerDropPlace, DraggableLayerRow)? {
        let rs = rows()
        guard !rs.isEmpty else { return nil }
        let row = rs.first { $0.frame.minY <= p.y && p.y <= $0.frame.maxY }
            ?? (p.y < rs[0].frame.minY ? rs[0] : rs[rs.count - 1])
        if let d = dragged, row.dragID == d { return nil }
        // 배경 줄: 맨 아래로만
        guard row.dragID != nil else { return (nil, .above, row) }
        let t = (p.y - row.frame.minY) / max(row.frame.height, 1)   // 뒤집힌 좌표: 0 = 줄의 위
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
    /// 끌어 놓기: from번 레이어(그룹이면 자손까지)를 target 레이어 위·아래 또는 그룹 target 안(맨 위 자식)으로.
    /// target nil은 배경 바로 위(배열 맨 앞, 그룹 밖). 자기 자신·자기 자손 위에는 놓지 않는다.
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
        // 지운 뒤 대상 위치를 다시 찾는다
        guard let nt = layers.firstIndex(where: { $0.id == targetID }) else { return false }
        let at: Int
        switch place {
        case .into: at = nt                               // 그룹 항목 바로 아래 = 맨 위 자식
        case .above: at = nt + 1                          // 배열 뒤가 위
        case .below: at = block(layers, nt).lowerBound    // 대상 덩어리 아래
        }
        layers.insert(contentsOf: items, at: at)
        return true
    }
}

// MARK: - 창에 연결

extension MainWindowController {
    /// 레이어 목록에서 끌어 놓은 레이어를 옮긴다.
    func dropLayer(_ id: String, onto target: String?, _ place: LayerDropPlace) {
        guard var s = photo?.settings, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        let t = target.flatMap { tid in s.layers.firstIndex { $0.id == tid } }
        guard LayerTree.drop(&s.layers, from: i, onto: t, place) else { NSSound.beep(); return }
        replaceSettings(s, recordUndo: true, label: "레이어 옮기기")
        layersTab.select(id)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// Finder에서 끌어 온 그림들을 이미지 레이어로 넣는다 (파일은 카탈로그 Assets에 복사).
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
        if mode == .studio { studioMode.layersPanel.reload() }
        return added > 0
    }

    /// 사진 목록에서 끌어 온 사진들을 앨범에 넣는다.
    func dropPhotos(_ paths: [String], toAlbum id: Int64) {
        let set = Set(paths)
        let ids = library.items.filter { set.contains($0.url.path) }.map(\.id).filter { $0 != 0 }
        guard !ids.isEmpty else { NSSound.beep(); return }
        try? library.catalog.addToAlbum(id, ids)
        reloadSources()
    }

    /// 사진을 다른 사진 위에 놓으면: 끌어 온 사진의 조정을 그 사진에 붙인다 (조정 적용과 같은 갈래).
    func dropAdjustments(from path: String, onto target: PhotoItem) {
        guard let source = library.items.first(where: { $0.url.path == path }), source !== target else { return }
        var dict: [String: Any]
        if source === photoItem, let doc = photo {
            dict = settingsDict(doc.settings)
        } else if let data = library.rawSettings(for: source.url),
                  let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = saved
        } else {
            NSSound.beep(); return   // 조정 없는 사진
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

    /// 끌어 놓기 연결 (setupModes 뒤에 한 번)
    func installDragAndDrop() {
        for list in [layersTab.dropList, studioMode.layersPanel.dropList] {
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
            // 그림은 이미지 레이어로, RAW·폴더는 창에 놓은 것처럼 연다
            let images = urls.filter(DragFiles.isLayerImage)
            if self.photo != nil, !images.isEmpty { return self.dropImageLayers(images) }
            guard let u = urls.first else { return false }
            self.openFileOrFolder(u)
            return true
        }
    }
}
