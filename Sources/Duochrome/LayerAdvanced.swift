import AppKit
import CoreImage

/// Advanced layers: layer comps, snapshots, align/distribute/link, merge/stamp, linked images (smart objects).

/// Layer comp: remembers visibility, opacity, blend, and (image) position per layer.
struct LayerComp: Equatable, Codable {
    struct State: Equatable, Codable {
        var enabled: Bool
        var opacity: Float
        var blend: String
        var image: LayerImage?
        var styles: LayerStyles?
    }
    var name: String
    var states: [String: State] = [:]
}

extension MainWindowController {
    // MARK: - Layer comps

    @objc func saveLayerComp(_ sender: Any?) {
        guard var s = photo?.settings, !s.layers.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "레이어 구성 저장"
        a.informativeText = "지금 레이어의 보임·불투명도·혼합 모드·이미지 자리·스타일을 기억합니다."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = "구성 \((s.layerComps?.count ?? 0) + 1)"
        a.accessoryView = f
        a.addButton(withTitle: "저장"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] != nil || a.runModal() == .alertFirstButtonReturn else { return }
        s.layerComps = (s.layerComps ?? []) + [Self.makeComp(f.stringValue, s.layers)]
        replaceSettings(s, recordUndo: true, label: "레이어 구성 저장")
    }

    static func makeComp(_ name: String, _ layers: [AdjustLayer]) -> LayerComp {
        var c = LayerComp(name: name)
        for l in layers { c.states[l.id] = .init(enabled: l.enabled, opacity: l.opacity, blend: l.blend, image: l.image, styles: l.styles) }
        return c
    }

    func applyLayerComp(_ i: Int) {
        guard var s = photo?.settings, let comps = s.layerComps, comps.indices.contains(i) else { return }
        let c = comps[i]
        for k in s.layers.indices {
            guard let st = c.states[s.layers[k].id] else { continue }
            s.layers[k].enabled = st.enabled
            s.layers[k].opacity = st.opacity
            s.layers[k].blend = st.blend
            if s.layers[k].isImage, let im = st.image { s.layers[k].image = im }
            s.layers[k].styles = st.styles
        }
        replaceSettings(s, recordUndo: true, label: "레이어 구성: \(c.name)")
    }

    func deleteLayerComp(_ i: Int) {
        guard var s = photo?.settings, var comps = s.layerComps, comps.indices.contains(i) else { return }
        comps.remove(at: i)
        s.layerComps = comps.isEmpty ? nil : comps
        replaceSettings(s, recordUndo: true, label: "레이어 구성 지우기")
    }

    func layerCompMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("지금 상태를 레이어 구성으로 저장…", modifiers: []) { [weak self] in self?.saveLayerComp(nil) })
        let comps = photo?.settings.layerComps ?? []
        if !comps.isEmpty { m.addItem(.separator()) }
        for (i, c) in comps.enumerated() {
            let item = NSMenuItem(title: c.name, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem("적용", modifiers: []) { [weak self] in self?.applyLayerComp(i) })
            sub.addItem(ClosureMenuItem("지금 상태로 다시 저장", modifiers: []) { [weak self] in
                guard let self, var s = self.photo?.settings, var cs = s.layerComps, cs.indices.contains(i) else { return }
                cs[i] = Self.makeComp(cs[i].name, s.layers); s.layerComps = cs
                self.replaceSettings(s, recordUndo: true, label: "레이어 구성 다시 저장")
            })
            sub.addItem(ClosureMenuItem("지우기", modifiers: []) { [weak self] in self?.deleteLayerComp(i) })
            item.submenu = sub
            m.addItem(item)
        }
        return m
    }

    // MARK: - Snapshots (History tab)

    func makeSnapshot(named name: String? = nil) {
        guard let doc = photo else { NSSound.beep(); return }
        history.snapshots.append((name ?? "스냅샷 \(history.snapshots.count + 1)", doc.settings))
        syncHistory()
        saveHistoryNow()
    }

    func restoreSnapshot(_ i: Int) {
        guard history.snapshots.indices.contains(i) else { return }
        let snap = history.snapshots[i]
        inspector.adoptGeometry(snap.settings)
        replaceSettings(snap.settings, recordUndo: true, label: "스냅샷: \(snap.label)")
    }

    func deleteSnapshot(_ i: Int) {
        guard history.snapshots.indices.contains(i) else { return }
        history.snapshots.remove(at: i)
        syncHistory()
        saveHistoryNow()
    }

    func saveHistoryNow() {
        guard let doc = photo, let h = history.encoded() else { return }
        library.catalog.setHistory(Library.key(for: doc.url), h)
    }

    // MARK: - Align · distribute · link (image layer positions)

    enum AlignEdge: Int { case left, centerX, right, top, centerY, bottom }

    /// Aligns the selected image layer (and linked layers) to the photo frame (source coordinates).
    func alignLayer(_ edge: AlignEdge) {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }),
              let im = s.layers[i].image, let doc = photo else { NSSound.beep(); return }
        let n = doc.nativeSize
        let (w, h) = layerSize(im)
        var dx = 0.0, dy = 0.0
        switch edge {
        case .left: dx = w / 2 - im.cx
        case .centerX: dx = n.width / 2 - im.cx
        case .right: dx = n.width - w / 2 - im.cx
        case .bottom: dy = h / 2 - im.cy
        case .centerY: dy = n.height / 2 - im.cy
        case .top: dy = n.height - h / 2 - im.cy
        }
        moveLinked(&s, from: i, dx: dx, dy: dy)
        replaceSettings(s, recordUndo: true, label: "레이어 정렬")
    }

    /// Bounding box size of a rotated image layer (source pixels)
    func layerSize(_ im: LayerImage) -> (Double, Double) {
        let src = Layers.sourceImage(im.file)?.extent.size ?? CGSize(width: 1, height: 1)
        let w = im.width, h = im.height ?? im.width * Double(src.height / max(src.width, 1))
        let r = im.rotation * .pi / 180
        return (abs(w * cos(r)) + abs(h * sin(r)), abs(w * sin(r)) + abs(h * cos(r)))
    }

    /// Moves all image layers linked with layer i
    func moveLinked(_ s: inout DevelopSettings, from i: Int, dx: Double, dy: Double) {
        let link = s.layers[i].link
        for k in s.layers.indices where k == i || (link != nil && s.layers[k].link == link) {
            s.layers[k].image?.cx += dx
            s.layers[k].image?.cy += dy
        }
    }

    /// Spreads linked image layers evenly horizontally (vertically) (by center, three or more)
    func distributeLinked(horizontal: Bool) {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }),
              let link = s.layers[i].link else { NSSound.beep(); return }
        var idx = s.layers.indices.filter { s.layers[$0].link == link && s.layers[$0].image != nil }
        guard idx.count >= 3 else { NSSound.beep(); return }
        idx.sort { horizontal ? s.layers[$0].image!.cx < s.layers[$1].image!.cx : s.layers[$0].image!.cy < s.layers[$1].image!.cy }
        let first = horizontal ? s.layers[idx.first!].image!.cx : s.layers[idx.first!].image!.cy
        let last = horizontal ? s.layers[idx.last!].image!.cx : s.layers[idx.last!].image!.cy
        for (n, k) in idx.enumerated() {
            let v = first + (last - first) * Double(n) / Double(idx.count - 1)
            if horizontal { s.layers[k].image!.cx = v } else { s.layers[k].image!.cy = v }
        }
        replaceSettings(s, recordUndo: true, label: "레이어 분배")
    }

    /// Links the selected layer with the one right below (unlinks if already linked)
    @objc func toggleLinkBelow(_ sender: Any?) {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        if s.layers[i].link != nil { s.layers[i].link = nil; replaceSettings(s, recordUndo: true, label: "연결 풀기"); return }
        guard i > 0 else { NSSound.beep(); return }
        let l = s.layers[i - 1].link ?? UUID().uuidString
        s.layers[i - 1].link = l
        s.layers[i].link = l
        replaceSettings(s, recordUndo: true, label: "레이어 연결")
    }

    // MARK: - Merge · stamp

    /// Renders layers over a transparent background (or the photo) at source coordinates and size (without geometry — the new image layer gets geometry again)
    func rasterize(_ layers: [AdjustLayer], withPhoto: Bool) -> CIImage? {
        guard let doc = photo else { return nil }
        let n = doc.nativeSize
        let rect = CGRect(x: 0, y: 0, width: n.width, height: n.height)
        if withPhoto {
            var flat = doc.settings
            flat.layers = layers
            flat.adoptGeometry(from: DevelopSettings())   // strip geometry corrections
            let saved = doc.settings, full = doc.showFullFrame
            doc.settings = flat
            doc.showFullFrame = true
            defer { doc.settings = saved; doc.showFullFrame = full }
            return doc.withFullResolution { doc.image(scale: 1) }.cropped(to: rect)
        }
        let clear = CIImage(color: .clear).cropped(to: rect)
        return Layers.apply(layers, to: clear, guide: clear, scale: 1, guideScale: 1, native: n, shape: { img, _ in img },
                            gamma: doc.settings.gammaBlend ?? false)
    }

    /// Saves an image as PNG in the layer image folder and makes an image layer covering the whole source
    func imageLayer(from img: CIImage, name: String) -> AdjustLayer? {
        guard let doc = photo else { return nil }
        let n = doc.nativeSize
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-merge-\(UUID().uuidString).png")
        do {
            try Render.context.writePNGRepresentation(of: img.cropped(to: CGRect(origin: .zero, size: n)), to: tmp,
                                                      format: .RGBA8, colorSpace: Render.displaySpace)
            let file = try LayerImageStore.importFile(tmp)
            try? FileManager.default.removeItem(at: tmp)
            var l = AdjustLayer(name: name)
            l.kind = "image"
            l.image = LayerImage(file: file, cx: n.width / 2, cy: n.height / 2, width: n.width)
            return l
        } catch {
            NSLog("병합 실패: %@", "\(error)")
            return nil
        }
    }

    /// Stamp visible (⌥⇧⌘E): the current visible result as a new image layer (other layers untouched)
    @objc func stampVisible(_ sender: Any?) {
        guard var s = photo?.settings, let img = rasterize(s.layers, withPhoto: true),
              let l = imageLayer(from: img, name: "도장 \(s.layers.count + 1)") else { NSSound.beep(); return }
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "보이는 레이어 도장 찍기")
        layersTab.select(l.id)
    }

    /// Merge visible (⇧⌘E): replace with the single visible result and remove all layers
    @objc func mergeVisible(_ sender: Any?) {
        guard var s = photo?.settings, !s.layers.isEmpty, let img = rasterize(s.layers, withPhoto: true),
              let l = imageLayer(from: img, name: "병합") else { NSSound.beep(); return }
        s.layers = [l]
        replaceSettings(s, recordUndo: true, label: "보이는 레이어 병합")
        layersTab.select(l.id)
    }

    /// Merge down (⌘E): merges the selected layer with the one right below (same level) on transparency into one image layer.
    /// An adjustment layer bakes into the content layer below. Not possible if neither has content (two adjustments).
    @objc func mergeDown(_ sender: Any?) {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), i > 0 else { NSSound.beep(); return }
        let below = i - 1
        let top = s.layers[i], bottom = s.layers[below]
        let content: (AdjustLayer) -> Bool = { $0.isImage || $0.isFill || $0.kind == "text" || $0.kind == "shape" }
        guard !top.isGroup, !bottom.isGroup, content(bottom) || content(top) else { NSSound.beep(); return }
        var b = bottom; b.group = nil
        var t = top; t.group = nil; t.clipped = false
        guard let img = rasterize([b, t], withPhoto: false), var l = imageLayer(from: img, name: bottom.name) else { NSSound.beep(); return }
        l.group = bottom.group
        s.layers[below] = l
        s.layers.remove(at: i)
        replaceSettings(s, recordUndo: true, label: "아래 레이어와 병합")
        layersTab.select(l.id)
    }

    // MARK: - Linked images (smart objects)

    /// Inserts a file as an image layer by link, without copying (the layer follows edits to the source file)
    @objc func placeLinkedImage(_ sender: Any?) {
        guard photo != nil, let window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "연결할 그림을 고르세요. 복사하지 않고 원본 파일을 가리킵니다 (파일을 고치면 레이어도 바뀝니다)."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = panel.url, let self else { return }
            self.layersTab.addImageLayer(file: "link:" + u.path, name: u.deletingPathExtension().lastPathComponent + " (연결)")
        }
    }

    /// Copies a linked image into the catalog, making it embedded
    @objc func embedLinkedImage(_ sender: Any?) {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }),
              let file = s.layers[i].image?.file, file.hasPrefix("link:") else { NSSound.beep(); return }
        do {
            let copied = try LayerImageStore.importFile(URL(fileURLWithPath: String(file.dropFirst(5))))
            s.layers[i].image?.file = copied
            replaceSettings(s, recordUndo: true, label: "내장 이미지로")
        } catch { NSAlert(error: error).runModal() }
    }
}

extension MainWindowController {
    @objc func alignFromMenu(_ sender: NSMenuItem) { alignLayer(AlignEdge(rawValue: sender.tag) ?? .left) }
    @objc func distributeH(_ sender: Any?) { distributeLinked(horizontal: true) }
    @objc func distributeV(_ sender: Any?) { distributeLinked(horizontal: false) }
}

/// Fills the "Layer Comps" menu with saved comps each time it opens
final class LayerCompMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = LayerCompMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let w = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        for item in w.layerCompMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }
}
