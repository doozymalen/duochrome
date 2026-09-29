import AppKit

/// Menu item that calls a closure when chosen.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], state: Bool? = nil,
         enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let state { self.state = state ? .on : .off }
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Layer context menu (shared by the layer-edit layers panel and the batch-edit layers tab).
extension MainWindowController {
    func layerContextMenu(_ id: String?) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        guard let doc = photo else { return m }
        layersTab.select(id)
        guard let id, let i = doc.settings.layers.firstIndex(where: { $0.id == id }) else {
            // background
            m.addItem(ClosureMenuItem("배경 복제 (복제 레이어에 리터칭)", key: "j") { [weak self] in self?.duplicateBackground(nil) })
            m.addItem(.separator())
            for (title, kind) in [("브러시 조정 레이어", LayerMask.Kind.brush), ("선형 그라디언트 조정 레이어", .linear),
                                  ("원형 그라디언트 조정 레이어", .radial), ("전체 조정 레이어", .full)] {
                m.addItem(ClosureMenuItem(title) { [weak self] in self?.layersTab.addLayer(kind, native: doc.nativeSize) })
            }
            m.addItem(ClosureMenuItem("이미지 레이어 가져오기…") { [weak self] in self?.placeImageLayer(nil) })
            return m
        }
        let layer = doc.settings.layers[i]
        func edit(_ f: @escaping (inout AdjustLayer) -> Void) {
            guard var s = photo?.settings, let k = s.layers.firstIndex(where: { $0.id == id }) else { return }
            f(&s.layers[k])
            apply(s, dragging: false)
            layersTab.sync(s)
        }
        m.addItem(ClosureMenuItem("이름 바꾸기…") { [weak self] in self?.renameLayer(id) })
        m.addItem(ClosureMenuItem("복제", key: "j") { [weak self] in self?.layersTab.duplicateLayer() })
        m.addItem(ClosureMenuItem("삭제", key: "\u{8}", modifiers: []) { [weak self] in self?.layersTab.removeLayer() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(layer.enabled ? "숨기기" : "보이기") { edit { $0.enabled.toggle() } })
        m.addItem(ClosureMenuItem("잠금", state: layer.locked) { edit { $0.locked.toggle() } })
        m.addItem(ClosureMenuItem("아래 레이어에 클리핑", key: "g", modifiers: [.command, .option], state: layer.clipped,
                                  enabled: i > 0) { edit { $0.clipped.toggle() } })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("그룹으로 묶기", key: "g") { [weak self] in self?.layersTab.groupSelected() })
        if layer.isGroup {
            m.addItem(ClosureMenuItem("그룹 풀기", key: "g", modifiers: [.command, .shift]) { [weak self] in self?.layersTab.ungroupSelected() })
        }
        if layer.isImage || layer.isCopy {
            m.addItem(ClosureMenuItem("자유 변형", key: "t", enabled: layer.isImage) { [weak self] in self?.freeTransform(nil) })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("마스크 반전", key: "i", state: layer.mask.invert) { edit { $0.mask.invert.toggle() } })
        m.addItem(ClosureMenuItem("마스크 지우기 (전체에 적용)", enabled: layer.mask.kind != .full) { edit { l in
            l.mask.kind = .full; l.mask.strokes = []; l.mask.polygon = []; l.mask.maskFile = ""
        } })
        m.addItem(ClosureMenuItem("마스크 보기", key: "m", modifiers: [], state: viewer.canvas.maskLayerID == id) { [weak self] in
            self?.toggleMaskView(nil)
        })
        m.addItem(.separator())
        let blend = NSMenuItem(title: "혼합 모드", action: nil, keyEquivalent: "")
        let bm = NSMenu()
        if layer.isGroup {
            bm.addItem(ClosureMenuItem(AdjustLayer.passThrough.1, state: layer.blend == AdjustLayer.passThrough.0) {
                edit { $0.blend = AdjustLayer.passThrough.0 }
            })
        }
        for (key, name, _) in AdjustLayer.blendModes {
            bm.addItem(ClosureMenuItem(name, state: layer.blend == key) { edit { $0.blend = key } })
        }
        blend.submenu = bm
        m.addItem(blend)
        let op = NSMenuItem(title: "불투명도", action: nil, keyEquivalent: "")
        let om = NSMenu()
        for v in [100, 75, 50, 25, 10] {
            om.addItem(ClosureMenuItem("\(v)%", state: Int((layer.opacity * 100).rounded()) == v) { edit { $0.opacity = Float(v) / 100 } })
        }
        op.submenu = om
        m.addItem(op)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("위로", key: "]") { [weak self] in self?.layersTab.layerUp() })
        m.addItem(ClosureMenuItem("아래로", key: "[") { [weak self] in self?.layersTab.layerDown() })
        return m
    }

    func renameLayer(_ id: String) {
        guard var s = photo?.settings, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        let a = NSAlert()
        a.messageText = "레이어 이름"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = s.layers[i].name
        a.accessoryView = f
        a.addButton(withTitle: "바꾸기")
        a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
        s.layers[i].name = f.stringValue
        apply(s, dragging: false)
        layersTab.sync(s)
        studioMode.layersPanel.reload()
    }
}

extension MainWindowController {
    /// Duplicate background (⌘J with no layer selected): adds a background copy layer on top and selects it. Retouching goes into this layer.
    @objc func duplicateBackground(_ sender: Any?) {
        guard var s = photo?.settings else { NSSound.beep(); return }
        var l = AdjustLayer(name: "배경 복사")
        l.kind = "copy"
        s.layers.append(l)
        apply(s, dragging: false)
        layersTab.select(l.id)
        layersTab.sync(s)
        studioMode.layersPanel.reload()
    }

    /// ⌘J: duplicate the selected layer, or the background if none is selected
    @objc func duplicateLayerOrBackground(_ sender: Any?) {
        if layersTab.selectedID == nil { duplicateBackground(sender) } else { layersTab.duplicateLayer() }
    }
}
