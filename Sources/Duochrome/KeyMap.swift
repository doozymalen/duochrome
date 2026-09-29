import AppKit

/// Key combo notation: @ ⌘, $ ⇧, ~ ⌥, ^ ⌃, the rest is the key ("@r" = ⌘R, "$@c" = ⇧⌘C).
struct KeyCombo: Hashable, Codable {
    var key: String
    var mods: UInt     // 1 ⌘, 2 ⇧, 4 ⌥, 8 ⌃

    init(key: String, mods: UInt) { self.key = key; self.mods = mods }

    init(_ spec: String) {
        var m: UInt = 0
        var rest = Substring(spec)
        while rest.count > 1, let c = rest.first, "@$~^".contains(c) {
            m |= ["@": 1, "$": 2, "~": 4, "^": 8][c] ?? 0
            rest = rest.dropFirst()
        }
        key = Self.normalize(String(rest))
        mods = m
    }

    /// "+" becomes "=" (⇧= on US layout), uppercase becomes lowercase
    static func normalize(_ k: String) -> String {
        if k == "+" { return "=" }
        return k.count == 1 ? k.lowercased() : k
    }

    init?(event e: NSEvent) {
        guard let ch = e.charactersIgnoringModifiers, !ch.isEmpty else { return nil }
        var m: UInt = 0
        let f = e.modifierFlags
        if f.contains(.command) { m |= 1 }
        if f.contains(.shift) { m |= 2 }
        if f.contains(.option) { m |= 4 }
        if f.contains(.control) { m |= 8 }
        var k = Self.normalize(ch)
        // With Korean input active, characters arrive as Hangul (ㅋ etc.) — look up the Latin letter by key position
        if k.unicodeScalars.contains(where: { $0.value >= 0x1100 && $0.value < 0xFFFF && !(0xF700...0xF8FF).contains($0.value) }),
           let latin = Self.latinByKeyCode[e.keyCode] { k = latin }
        // For ⇧+digits/symbols charactersIgnoringModifiers gives the symbol (⇧= → +) — match on the symbol
        if k == "+" { k = "=" }
        // ⇧] · ⇧[ arrive as } · { — match on the braces
        if k == "}" { k = "]" } else if k == "{" { k = "[" }
        key = k
        mods = m
    }

    /// US layout key position → character (for Korean input mode)
    static let latinByKeyCode: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
        15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
    ]

    /// Display order: ⌃⌥⇧⌘
    var display: String {
        var s = ""
        if mods & 8 != 0 { s += "⌃" }
        if mods & 4 != 0 { s += "⌥" }
        if mods & 2 != 0 { s += "⇧" }
        if mods & 1 != 0 { s += "⌘" }
        let names: [String: String] = ["\u{f702}": "←", "\u{f703}": "→", "\u{f700}": "↑", "\u{f701}": "↓", "\r": "↩", "\u{7f}": "⌫",
                                        " ": "스페이스", "\t": "⇥", "\u{1b}": "esc"]
        return s + (names[key] ?? key.uppercased())
    }

    /// For menu items
    var menuKey: String { key }
    var menuMods: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & 1 != 0 { f.insert(.command) }
        if mods & 2 != 0 { f.insert(.shift) }
        if mods & 4 != 0 { f.insert(.option) }
        if mods & 8 != 0 { f.insert(.control) }
        return f
    }
}

/// One shortcut action. Has separate default keys for batch edit and layer edit.
struct KeyAction {
    let id: String
    let title: String
    let group: String
    /// The menu selector if this action is in a menu (menu display follows the mode)
    let selector: Selector?
    let run: (MainWindowController) -> Void
    let bulk: [String]
    let studio: [String]
}

enum KeyMap {
    enum Scope: String { case bulk, studio }

    static func scope(_ m: AppMode) -> Scope { m == .studio ? .studio : .bulk }

    static let actions: [KeyAction] = {
        typealias W = MainWindowController
        func sel(_ id: String, _ title: String, _ group: String, _ s: Selector, bulk: [String], studio: [String]) -> KeyAction {
            KeyAction(id: id, title: title, group: group, selector: s, run: { NSApp.sendAction(s, to: $0, from: nil) }, bulk: bulk, studio: studio)
        }
        func act(_ id: String, _ title: String, _ group: String, bulk: [String], studio: [String], _ run: @escaping (W) -> Void) -> KeyAction {
            KeyAction(id: id, title: title, group: group, selector: nil, run: run, bulk: bulk, studio: studio)
        }
        var a: [KeyAction] = [
            // Tools (batch edit cursor tools)
            act("tool.pan", "이동 / 손", "도구", bulk: ["h", "v"], studio: ["h"]) { $0.keyTool(.pan, studio: "hand") },
            act("tool.zoom", "확대", "도구", bulk: ["z"], studio: ["z"]) { $0.keyTool(.zoom, studio: "zoom") },
            act("tool.crop", "크롭 / 자르기", "도구", bulk: ["c"], studio: ["c"]) { $0.keyTool(.crop, studio: "crop") },
            act("tool.straighten", "수평", "도구", bulk: ["r"], studio: []) { $0.keyTool(.straighten, studio: "straighten") },
            act("tool.keystone", "키스톤", "도구", bulk: ["k"], studio: ["k"]) { $0.keyTool(.keystone, studio: "keystone") },
            act("tool.wb", "화이트 밸런스 스포이트", "도구", bulk: ["w"], studio: []) { $0.keyTool(.whiteBalance, studio: "whiteBalance") },
            act("tool.heal", "복구", "도구", bulk: ["q", "o"], studio: ["j"]) { $0.keyRetouch("repair") },
            act("tool.clone", "복제 도장", "도구", bulk: ["s"], studio: ["s"]) { $0.keyRetouch("clone") },
            act("tool.mask", "마스크 칠하기 (브러시)", "도구", bulk: ["b"], studio: ["b"]) { $0.keyTool(.mask, studio: "maskPaint") },
            act("tool.maskErase", "마스크 지우개", "도구", bulk: ["e"], studio: []) { w in w.layersTab.erase = true; w.keyTool(.mask, studio: "maskPaint") },
            act("tool.linear", "선형 그라디언트", "도구", bulk: ["l"], studio: []) { $0.keyGradient(.linear) },
            act("tool.radial", "원형 그라디언트", "도구", bulk: ["t"], studio: []) { $0.keyGradient(.radial) },
            act("tool.picker", "색상 피커", "도구", bulk: ["d"], studio: ["i"]) { $0.keyTool(.colorPick, studio: "picker") },
            // Layer-edit-only tools
            act("tool.arrange", "배치 (이동)", "도구", bulk: [], studio: ["v"]) { $0.studioMode.selectTool("arrange") },
            act("tool.marquee", "선택 윤곽", "도구", bulk: [], studio: ["m"]) { $0.studioMode.selectTool("selRect") },
            act("tool.lasso", "올가미", "도구", bulk: [], studio: ["l"]) { $0.studioMode.selectTool("selFree") },
            act("tool.quickSel", "빠른 선택", "도구", bulk: [], studio: ["w"]) { $0.studioMode.selectTool("selQuick") },
            act("tool.wand", "자동 선택 (마술봉)", "도구", bulk: [], studio: ["$w"]) { $0.studioMode.selectTool("selWand") },
            act("sel.quickMask", "퀵 마스크", "선택", bulk: [], studio: ["q"]) { $0.toggleQuickMask(nil) },
            sel("sel.deselect", "선택 해제", "선택", #selector(W.deselectAll(_:)), bulk: [], studio: ["@d"]),
            sel("sel.invert", "선택 반전", "선택", #selector(W.invertSelection(_:)), bulk: [], studio: ["$@i"]),
            sel("sel.selectMask", "선택 및 마스크", "선택", #selector(W.showSelectAndMask(_:)), bulk: [], studio: ["~@r"]),
            act("tool.dodge", "닷지 (밝게)", "도구", bulk: [], studio: ["o"]) { $0.studioMode.selectTool("lighten") },
            act("tool.gradient", "그라디언트", "도구", bulk: [], studio: ["g"]) { $0.studioMode.selectTool("gradient") },
            act("tool.eraser", "지우개", "도구", bulk: [], studio: ["e"]) { $0.studioMode.selectTool("erase") },
            act("tool.type", "문자", "도구", bulk: [], studio: ["t"]) { $0.studioMode.selectTool("text") },
            act("tool.pen", "펜", "도구", bulk: [], studio: ["p"]) { $0.studioMode.selectTool("pen") },
            act("tool.shape", "도형", "도구", bulk: [], studio: ["u"]) { $0.studioMode.selectTool("shape") },
            act("tool.brushSmaller", "브러시 작게", "도구", bulk: ["["], studio: ["["]) { $0.brushSmaller(nil) },
            act("tool.brushLarger", "브러시 크게", "도구", bulk: ["]"], studio: ["]"]) { $0.brushLarger(nil) },
            // View
            sel("view.fit", "화면에 맞추기", "보기", #selector(W.zoomToFit(_:)), bulk: [",", "@0"], studio: ["@0"]),
            sel("view.actual", "100%", "보기", #selector(W.zoomToActual(_:)), bulk: [".", "@1"], studio: ["@1", "~@0"]),
            sel("view.zoomIn", "확대", "보기", #selector(W.zoomIn(_:)), bulk: ["@="], studio: ["@="]),
            sel("view.zoomOut", "축소", "보기", #selector(W.zoomOut(_:)), bulk: ["@-"], studio: ["@-"]),
            sel("view.before", "보정 전", "보기", #selector(W.toggleOriginal(_:)), bulk: ["y"], studio: ["y"]),
            sel("view.split", "전후 나란히", "보기", #selector(W.toggleSplitCompare(_:)), bulk: ["$y"], studio: ["$y"]),
            sel("view.clipping", "노출 경고", "보기", #selector(W.toggleClipping(_:)), bulk: ["@e"], studio: []),
            sel("view.grid", "구도 격자", "보기", #selector(W.cycleGrid(_:)), bulk: ["@g"], studio: ["@'"]),
            sel("view.proof", "교정쇄 보기", "보기", #selector(W.toggleSoftProof(_:)), bulk: ["$@\\"], studio: ["@y"]),
            sel("view.gamut", "색역 경고", "보기", #selector(W.toggleGamutWarning(_:)), bulk: [], studio: ["$@y"]),
            sel("view.mask", "마스크 보기", "보기", #selector(W.toggleMaskView(_:)), bulk: ["m"], studio: ["\\"]),
            sel("view.second", "두 번째 화면에 보기", "보기", #selector(W.toggleSecondViewer(_:)), bulk: ["~@v"], studio: []),
            act("view.fullscreen", "전체 화면", "보기", bulk: ["f"], studio: ["f"]) { $0.window?.toggleFullScreen(nil) },
            act("view.leftPanel", "왼쪽 패널 보이기·가리기", "보기", bulk: ["@t"], studio: ["\t"]) { $0.keyTogglePanels(left: true) },
            act("view.rightPanel", "오른쪽 패널 보이기·가리기", "보기", bulk: ["@b"], studio: []) { $0.keyTogglePanels(left: false) },
            // Adjust
            sel("adj.copy", "조정 복사", "조정", #selector(W.copyAdjustments(_:)), bulk: ["$@c"], studio: []),
            sel("adj.paste", "조정 적용", "조정", #selector(W.pasteAdjustments(_:)), bulk: ["$@v"], studio: []),
            sel("adj.reset", "조정 초기화", "조정", #selector(W.resetAdjustments(_:)), bulk: ["@r"], studio: []),
            sel("adj.auto", "자동 조정", "조정", #selector(W.autoAdjust(_:)), bulk: ["@l"], studio: ["$@l"]),
            act("adj.exposureUp", "노출 올리기", "조정", bulk: ["^@="], studio: []) { $0.keyNudge(\.exposure, 0.1) },
            act("adj.exposureDown", "노출 내리기", "조정", bulk: ["^@-"], studio: []) { $0.keyNudge(\.exposure, -0.1) },
            act("adj.contrastUp", "대비 올리기", "조정", bulk: ["^$@="], studio: []) { $0.keyNudge(\.contrast, 5) },
            act("adj.contrastDown", "대비 내리기", "조정", bulk: ["^$@-"], studio: []) { $0.keyNudge(\.contrast, -5) },
            act("adj.satUp", "채도 올리기", "조정", bulk: ["^~@="], studio: []) { $0.keyNudge(\.saturation, 5) },
            act("adj.satDown", "채도 내리기", "조정", bulk: ["^~@-"], studio: []) { $0.keyNudge(\.saturation, -5) },
            act("adj.kelvinUp", "색온도 올리기", "조정", bulk: ["$="], studio: []) { $0.keyNudge(\.temperature, 100) },
            act("adj.kelvinDown", "색온도 내리기", "조정", bulk: ["$-"], studio: []) { $0.keyNudge(\.temperature, -100) },
            act("adj.levels", "레벨", "조정", bulk: [], studio: ["@l"]) { $0.keyRevealCard("levels") },
            act("adj.curves", "커브", "조정", bulk: [], studio: ["@m"]) { $0.keyRevealCard("curve") },
            act("adj.balance", "컬러 밸런스", "조정", bulk: [], studio: ["@b"]) { $0.keyRevealCard("balance") },
            act("adj.hueSat", "색조/채도 (컬러 에디터)", "조정", bulk: [], studio: ["@u"]) { $0.keyRevealCard("editor") },
            act("adj.invert", "반전 레이어", "조정", bulk: [], studio: ["@i"]) { $0.keyAdjustLayer("반전") { $0.invert = 1 } },
            act("adj.desaturate", "채도 빼기 레이어", "조정", bulk: [], studio: ["$@u"]) { $0.keyAdjustLayer("채도 빼기") { $0.saturation = -100 } },
            // Layers
            sel("layer.duplicate", "복제 (레이어 / 배경)", "레이어", #selector(W.duplicateLayerOrBackground(_:)), bulk: [], studio: ["@j"]),
            sel("layer.transform", "자유 변형", "레이어", #selector(W.freeTransform(_:)), bulk: [], studio: ["@t"]),
            sel("layer.group", "그룹으로 묶기", "레이어", #selector(W.groupLayer(_:)), bulk: [], studio: ["@g"]),
            sel("layer.ungroup", "그룹 풀기", "레이어", #selector(W.ungroupLayer(_:)), bulk: [], studio: ["$@g"]),
            sel("layer.mergeDown", "아래 레이어와 병합", "레이어", #selector(W.mergeDown(_:)), bulk: [], studio: ["@e"]),
            sel("layer.mergeVisible", "보이는 레이어 병합", "레이어", #selector(W.mergeVisible(_:)), bulk: [], studio: ["$@e"]),
            sel("layer.stamp", "보이는 레이어 도장 찍기", "레이어", #selector(W.stampVisible(_:)), bulk: [], studio: ["~$@e"]),
            act("layer.clip", "클리핑 마스크", "레이어", bulk: [], studio: ["~@g"]) { $0.keyToggleClip() },
            act("layer.new", "새 조정 레이어", "레이어", bulk: [], studio: ["$@n"]) { $0.layersTab.addLayer(.full, native: $0.photo?.nativeSize) },
            act("layer.up", "레이어 위로", "레이어", bulk: ["@]"], studio: ["@]"]) { $0.keyLayerEdit { $0.layersTab.layerUp() } },
            act("layer.down", "레이어 아래로", "레이어", bulk: ["@["], studio: ["@["]) { $0.keyLayerEdit { $0.layersTab.layerDown() } },
            act("layer.top", "레이어 맨 위로", "레이어", bulk: ["$@]"], studio: ["$@]"]) { $0.keyLayerEdit { $0.layersTab.layerToEnd(top: true) } },
            act("layer.bottom", "레이어 맨 아래로", "레이어", bulk: ["$@["], studio: ["$@["]) { $0.keyLayerEdit { $0.layersTab.layerToEnd(top: false) } },
            act("layer.selectUp", "위 레이어 고르기", "레이어", bulk: ["~]"], studio: ["~]"]) { $0.keyLayerEdit { $0.layersTab.selectNeighbor(up: true) } },
            act("layer.selectDown", "아래 레이어 고르기", "레이어", bulk: ["~["], studio: ["~["]) { $0.keyLayerEdit { $0.layersTab.selectNeighbor(up: false) } },
            act("layer.delete", "레이어 지우기", "레이어", bulk: ["\u{7f}", "\u{f728}"], studio: ["\u{7f}", "\u{f728}"]) { w in
                w.keyLayerEdit { if !$0.layersTab.deleteSelectedLayer() { NSSound.beep() } }
            },
            sel("view.rulers", "눈금자", "보기", #selector(W.toggleRulers(_:)), bulk: [], studio: ["@r"]),
            sel("view.guides", "안내선 보기", "보기", #selector(W.toggleGuides(_:)), bulk: ["@;"], studio: ["@;"]),
            sel("view.snap", "스냅", "보기", #selector(W.toggleSnap(_:)), bulk: ["$@;"], studio: ["$@;"]),
            // Photo · File
            sel("file.export", "내보내기", "파일", #selector(W.exportPhotos(_:)), bulk: ["$@d"], studio: ["~$@w"]),
            act("photo.rotateLeft", "왼쪽으로 90°", "사진", bulk: ["~@l"], studio: []) { $0.keyRotate(-1) },
            act("photo.rotateRight", "오른쪽으로 90°", "사진", bulk: ["~@r"], studio: []) { $0.keyRotate(1) },
            act("photo.tagRed", "색 태그 빨강", "사진", bulk: ["-"], studio: []) { $0.tagColor(1) },
            act("photo.tagYellow", "색 태그 노랑", "사진", bulk: ["*"], studio: []) { $0.tagColor(3) },
            act("photo.tagGreen", "색 태그 초록", "사진", bulk: ["="], studio: []) { $0.tagColor(4) },
        ]
        // Rating (batch edit) · opacity (layer edit, 5 = 50%, 0 = 100%)
        for n in 0...5 {
            a.append(act("photo.rate\(n)", "별점 \(n)", "사진", bulk: ["\(n)"], studio: []) { $0.rate(n) })
        }
        for n in 0...9 {
            a.append(act("layer.opacity\(n)", "레이어 불투명도 \(n == 0 ? 100 : n * 10)%", "레이어", bulk: [], studio: ["\(n)"]) {
                $0.keyOpacity(n == 0 ? 1 : Float(n) / 10)
            })
        }
        return a
    }()

    /// The user's value if changed, else the default
    static func combos(_ a: KeyAction, _ s: Scope) -> [KeyCombo] {
        if let saved = UserDefaults.standard.stringArray(forKey: "keys.\(s.rawValue).\(a.id)") { return saved.map(KeyCombo.init) }
        return (s == .bulk ? a.bulk : a.studio).map(KeyCombo.init)
    }

    static func set(_ a: KeyAction, _ s: Scope, _ specs: [String]?) {
        let k = "keys.\(s.rawValue).\(a.id)"
        if let specs { UserDefaults.standard.set(specs, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        cache = [:]
    }

    static func spec(_ c: KeyCombo) -> String {
        var s = ""
        if c.mods & 8 != 0 { s += "^" }
        if c.mods & 4 != 0 { s += "~" }
        if c.mods & 2 != 0 { s += "$" }
        if c.mods & 1 != 0 { s += "@" }
        return s + c.key
    }

    private static var cache: [Scope: [KeyCombo: KeyAction]] = [:]

    static func table(_ s: Scope) -> [KeyCombo: KeyAction] {
        if let t = cache[s] { return t }
        var t: [KeyCombo: KeyAction] = [:]
        for a in actions { for c in combos(a, s) where t[c] == nil { t[c] = a } }
        cache[s] = t
        return t
    }

    /// Reports when two actions use the same key
    static func conflicts(_ s: Scope) -> [(KeyCombo, [String])] {
        var byCombo: [KeyCombo: [String]] = [:]
        for a in actions { for c in combos(a, s) { byCombo[c, default: []].append(a.title) } }
        return byCombo.filter { $0.value.count > 1 }.map { ($0.key, $0.value) }
    }
}

// MARK: - Actions invoked by shortcut

extension MainWindowController {
    /// Receives shortcuts for all modes. Leaves typing in text fields alone. Intercepts before menus.
    func installKeyMap() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if ProcessInfo.processInfo.environment["DUOCHROME_KEYLOG"] != nil {
                NSLog("키 코드 %d 글자 %@ 수정 %lu", e.keyCode, e.charactersIgnoringModifiers ?? "-", e.modifierFlags.rawValue)
            }
            guard let self, e.window === self.window, !(self.window?.firstResponder is NSTextView),
                  self.window?.attachedSheet == nil, let combo = KeyCombo(event: e) else { return e }
            guard let action = KeyMap.table(KeyMap.scope(self.mode))[combo] else {
                // ⌘ combos with Korean input: convert to Latin letters and pass to the menu (⌘Z etc.)
                if e.modifierFlags.contains(.command), combo.key != KeyCombo.normalize(e.charactersIgnoringModifiers ?? ""),
                   let latin = NSEvent.keyEvent(with: .keyDown, location: e.locationInWindow, modifierFlags: e.modifierFlags,
                                                timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                                characters: combo.key, charactersIgnoringModifiers: combo.key,
                                                isARepeat: e.isARepeat, keyCode: e.keyCode),
                   NSApp.mainMenu?.performKeyEquivalent(with: latin) == true { return nil }
                return e
            }
            // Layer shortcuts only when the layer list is visible; if the photo list has focus, it gets them
            if action.id.hasPrefix("layer."), !self.layerKeysActive { return e }
            action.run(self)
            return nil
        }
        syncMenuKeys()
    }

    /// Shows the current mode's shortcuts in menus (only for actions with selectors)
    func syncMenuKeys() {
        guard let main = NSApp.mainMenu else { return }
        let scope = KeyMap.scope(mode)
        var bySelector: [Selector: KeyCombo?] = [:]
        for a in KeyMap.actions { if let s = a.selector { bySelector[s] = KeyMap.combos(a, scope).first } }
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let sub = item.submenu { walk(sub) }
                guard let s = item.action, let combo = bySelector[s] else { continue }
                if let c = combo {
                    item.keyEquivalent = c.menuKey
                    item.keyEquivalentModifierMask = c.menuMods
                } else {
                    item.keyEquivalent = ""
                }
            }
        }
        walk(main)
    }

    func keyTool(_ t: CanvasView.Tool, studio id: String) {
        if mode == .studio { studioMode.selectTool(id) } else { enterTool(t) }
    }

    func keyRetouch(_ id: String) {
        if mode == .studio { studioMode.selectTool(id); return }
        var b = retouch.brush
        b.patch = false
        b.kind = id == "clone" ? .clone : .heal
        retouch.brush = b
        tools.select(tools.index(of: "리터칭"))
        enterTool(.retouch)
    }

    /// L·T: if the selected layer is that kind, switch to its mask tool; otherwise add a layer of that kind
    func keyGradient(_ kind: LayerMask.Kind) {
        guard let doc = photo else { return }
        if let id = layersTab.selectedID, doc.settings.layers.first(where: { $0.id == id })?.mask.kind == kind {} else {
            layersTab.addLayer(kind, native: doc.nativeSize)
        }
        tools.select(tools.index(of: "레이어"))
        enterTool(.mask)
    }

    func keyNudge(_ key: WritableKeyPath<DevelopSettings, Float>, _ d: Float) {
        guard var s = photo?.settings, let doc = photo else { return }
        s[keyPath: key] += d
        apply(s, dragging: false)
        inspector.show(doc)
    }

    func keyRevealCard(_ id: String) {
        if mode == .studio { studioMode.selectTool("adjust") } else { tools.select(tools.index(of: "조정")) }
        inspector.reveal(id)
    }

    func keyAdjustLayer(_ name: String, _ f: (inout LocalAdjust) -> Void) {
        guard let doc = photo else { return }
        layersTab.addLayer(.full, native: doc.nativeSize)
        guard var s = photo?.settings, let i = s.layers.indices.last else { return }
        f(&s.layers[i].adjust)
        s.layers[i].name = "\(name) \(s.layers.count)"
        apply(s, dragging: false)
        layersTab.sync(s)
    }

    func keyToggleClip() {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), i > 0 else { return }
        s.layers[i].clipped.toggle()
        apply(s, dragging: false)
        layersTab.sync(s)
    }

    /// Whether layer shortcuts apply: in layer edit or with the batch-edit layers tab visible, and the photo list unfocused
    var layerKeysActive: Bool {
        if window?.firstResponder is NSCollectionView { return false }
        if mode == .studio { return true }
        return mode == .edit && layersTab.isViewLoaded && layersTab.view.window != nil && !layersTab.view.isHiddenOrHasHiddenAncestor
    }

    /// Shortcuts that change layers: redraw both layer lists afterwards
    func keyLayerEdit(_ f: (MainWindowController) -> Void) {
        f(self)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    func keyOpacity(_ v: Float) {
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        s.layers[i].opacity = v
        apply(s, dragging: false)
        layersTab.sync(s)
    }

    func keyRotate(_ dir: Int) {
        guard var s = photo?.settings else { return }
        s.quarterTurns = Float((Int(s.quarterTurns) + (dir > 0 ? 1 : 3)) % 4)
        s.crop = CropRect()
        inspector.adoptGeometry(s)
        apply(s, dragging: false)
    }

    func keyTogglePanels(left: Bool) {
        switch mode {
        case .studio:
            studioMode.showsLayers.toggle(); studioMode.showsOptions = studioMode.showsLayers
        default:
            togglePanel(left: left)
        }
    }
}
