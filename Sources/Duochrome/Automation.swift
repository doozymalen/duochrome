import AppKit

// MARK: - Automation: action record/playback, batch processing, AppleScript, Shortcuts (URL)

/// One action step: changed values (settings JSON path → new value). Layers keep additions and per-position edits separately
struct ActionStep {
    var label: String
    /// ([path], value) — value is a JSON value (number, string, bool, array, dict, NSNull)
    var patches: [([String], Any)] = []
    /// Newly added layers (JSON)
    var addedLayers: [[String: Any]] = []
    /// Number of removed layers (from the top)
    var removedLayers = 0
    /// Layer edits by position
    var layerEdits: [(Int, [([String], Any)])] = []
    /// Positions count from the top (the newest layer is 0), so an action that adds a layer and then edits it
    /// works on photos with a different number of layers. Actions saved before this counted from the bottom
    var fromTop = true

    var json: [String: Any] {
        ["label": label,
         "patches": patches.map { ["path": $0.0, "value": $0.1] },
         "addedLayers": addedLayers,
         "removedLayers": removedLayers,
         "layerEdits": layerEdits.map { ["index": $0.0, "patches": $0.1.map { ["path": $0.0, "value": $0.1] }] },
         "fromTop": fromTop]
    }

    init(label: String) { self.label = label }

    init?(json j: [String: Any]) {
        guard let l = j["label"] as? String else { return nil }
        label = l
        func ps(_ a: Any?) -> [([String], Any)] {
            (a as? [[String: Any]] ?? []).compactMap { p in (p["path"] as? [String]).map { ($0, p["value"] ?? NSNull()) } }
        }
        patches = ps(j["patches"])
        addedLayers = j["addedLayers"] as? [[String: Any]] ?? []
        removedLayers = j["removedLayers"] as? Int ?? 0
        fromTop = j["fromTop"] as? Bool ?? false
        layerEdits = (j["layerEdits"] as? [[String: Any]] ?? []).compactMap { e in (e["index"] as? Int).map { ($0, ps(e["patches"])) } }
    }
}

/// A named action
struct RecordedAction {
    var name: String
    var steps: [ActionStep]

    static var folder: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["DUOCHROME_UITEST"] != nil || env["DUOCHROME_SELFTEST"] != nil
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test-actions")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Duochrome/Actions")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func load(_ name: String) -> RecordedAction? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(name + ".json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let steps = j["steps"] as? [[String: Any]] else { return nil }
        return RecordedAction(name: name, steps: steps.compactMap(ActionStep.init(json:)))
    }

    func save() throws {
        let d = try JSONSerialization.data(withJSONObject: ["name": name, "steps": steps.map(\.json)], options: [.prettyPrinted, .fragmentsAllowed])
        try d.write(to: Self.folder.appendingPathComponent(name + ".json"))
    }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".json")) }

    // MARK: Diffing

    /// Difference between two settings dictionaries → step (layers handled separately)
    static func step(label: String, before a: [String: Any], after b: [String: Any]) -> ActionStep {
        var st = ActionStep(label: label)
        for key in Set(a.keys).union(b.keys) where key != "layers" {
            diff([key], a[key], b[key], into: &st.patches)
        }
        let la = a["layers"] as? [[String: Any]] ?? [], lb = b["layers"] as? [[String: Any]] ?? []
        let idsA = Set(la.compactMap { $0["id"] as? String }), idsB = Set(lb.compactMap { $0["id"] as? String })
        st.addedLayers = lb.filter { !idsA.contains($0["id"] as? String ?? "") }
        st.removedLayers = la.filter { !idsB.contains($0["id"] as? String ?? "") }.count
        // Remaining layers: only per-position changed values
        let kept = lb.filter { idsA.contains($0["id"] as? String ?? "") }
        for (i, l) in kept.enumerated() {
            guard let old = la.first(where: { ($0["id"] as? String) == (l["id"] as? String) }) else { continue }
            var p: [([String], Any)] = []
            for key in Set(old.keys).union(l.keys) where key != "id" { diff([key], old[key], l[key], into: &p) }
            if !p.isEmpty { st.layerEdits.append((kept.count - 1 - i, p)) }
        }
        return st
    }

    private static func diff(_ path: [String], _ a: Any?, _ b: Any?, into out: inout [([String], Any)]) {
        if let da = a as? [String: Any], let db = b as? [String: Any] {
            for k in Set(da.keys).union(db.keys) { diff(path + [k], da[k], db[k], into: &out) }
            return
        }
        let na = a.map { $0 as AnyObject }, nb = b.map { $0 as AnyObject }
        if let na, let nb, na.isEqual(nb) { return }
        if na == nil && nb == nil { return }
        out.append((path, b ?? NSNull()))
    }

    /// Applies a step to a settings dictionary
    static func apply(_ st: ActionStep, to dict: inout [String: Any]) {
        for (path, v) in st.patches { set(&dict, path, v) }
        var layers = dict["layers"] as? [[String: Any]] ?? []
        if st.removedLayers > 0 { layers.removeLast(min(st.removedLayers, layers.count)) }
        for (k, p) in st.layerEdits {
            let i = st.fromTop ? layers.count - 1 - k : k
            guard layers.indices.contains(i) else { continue }
            var l = layers[i]
            for (path, v) in p { set(&l, path, v) }
            layers[i] = l
        }
        // Added layers get new ids (children follow their group's new id)
        var ids: [String: String] = [:]
        for l in st.addedLayers { if let id = l["id"] as? String { ids[id] = UUID().uuidString } }
        for var l in st.addedLayers {
            if let id = l["id"] as? String { l["id"] = ids[id] }
            if let g = l["group"] as? String, let n = ids[g] { l["group"] = n }
            layers.append(l)
        }
        dict["layers"] = layers
    }

    private static func set(_ d: inout [String: Any], _ path: [String], _ v: Any) {
        guard let first = path.first else { return }
        if path.count == 1 {
            if v is NSNull { d.removeValue(forKey: first) } else { d[first] = v }
            return
        }
        var inner = d[first] as? [String: Any] ?? [:]
        set(&inner, Array(path.dropFirst()), v)
        d[first] = inner
    }
}

/// Action being recorded
final class ActionRecorder {
    static let shared = ActionRecorder()
    var recording: RecordedAction?
    var isRecording: Bool { recording != nil }
}

extension MainWindowController {
    // MARK: Recording

    /// Called from recordHistory: while recording, stores changed values as a step
    func recordActionStep(from before: DevelopSettings, to after: DevelopSettings, label: String) {
        guard ActionRecorder.shared.isRecording, before != after else { return }
        let st = RecordedAction.step(label: label, before: settingsDict(before), after: settingsDict(after))
        if st.patches.isEmpty && st.addedLayers.isEmpty && st.removedLayers == 0 && st.layerEdits.isEmpty { return }
        ActionRecorder.shared.recording?.steps.append(st)
        window?.subtitle = "● 동작 기록 중 — \(ActionRecorder.shared.recording?.steps.count ?? 0)단계"
    }

    @objc func startActionRecording(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "새 동작 기록"
        a.informativeText = "이름을 정하면 지금부터 바꾸는 조정·레이어가 단계로 기록됩니다. 사진 > 동작 > 기록 멈추기로 끝냅니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "동작 \(RecordedAction.names().count + 1)"
        a.accessoryView = field
        a.addButton(withTitle: "기록"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        beginRecording(field.stringValue)
    }

    func beginRecording(_ name: String) {
        ActionRecorder.shared.recording = RecordedAction(name: name.isEmpty ? "동작" : name, steps: [])
        window?.subtitle = "● 동작 기록 중"
    }

    @objc func stopActionRecording(_ sender: Any?) { finishRecording() }

    /// Stops recording and saves (returns the saved action)
    @discardableResult
    func finishRecording() -> RecordedAction? {
        guard let rec = ActionRecorder.shared.recording else { NSSound.beep(); return nil }
        ActionRecorder.shared.recording = nil
        window?.subtitle = ""
        guard !rec.steps.isEmpty else { return nil }
        try? rec.save()
        return rec
    }

    // MARK: Playback

    @objc func playActionFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let act = RecordedAction.load(name) else { NSSound.beep(); return }
        playAction(act)
    }

    /// Applies an action to the open photo (one undo)
    func playAction(_ act: RecordedAction) {
        guard let doc = photo else { NSSound.beep(); return }
        var dict = settingsDict(doc.settings)
        for st in act.steps { RecordedAction.apply(st, to: &dict) }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = try? JSONDecoder().decode(DevelopSettings.self, from: data) else { NSSound.beep(); return }
        replaceSettings(s, recordUndo: true, label: "동작: \(act.name)")
        inspector.show(doc)
        layersTab.sync(s)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    // MARK: Batch processing

    /// Applies an action to many photos (undoable for the open one, others written straight to the catalog). Returns count changed
    @discardableResult
    func batchApply(_ act: RecordedAction, to items: [PhotoItem]) -> Int {
        var n = 0
        JobCenter.shared.add("batch", title: "일괄 처리", count: items.count)
        defer { JobCenter.shared.end("batch") }
        for item in items where !item.offline {
            defer { JobCenter.shared.step("batch") }
            if item === photoItem, photo != nil { playAction(act); n += 1; continue }
            guard let doc = try? RawDocument(url: item.url) else { continue }
            let base = library.loadSettings(for: item.url, over: doc.asShot) ?? doc.asShot
            var dict = settingsDict(base)
            for st in act.steps { RecordedAction.apply(st, to: &dict) }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let s = try? JSONDecoder().decode(DevelopSettings.self, from: data) else { continue }
            library.saveSettings(s, asShot: doc.asShot, for: item.url)
            item.edited = true
            item.thumbnail = nil
            refreshItem(item)
            n += 1
        }
        refreshThumbnails(items)
        return n
    }

    /// Batch window: pick an action, apply it to selected photos, optionally export
    @objc func showBatchProcess(_ sender: Any?) {
        let items = mode == .library ? libraryMode.grid.selectedItems : (browser.selectedItems.isEmpty ? (photoItem.map { [$0] } ?? []) : browser.selectedItems)
        let names = RecordedAction.names()
        guard !items.isEmpty, !names.isEmpty else {
            let a = NSAlert(); a.messageText = names.isEmpty ? "저장한 동작이 없습니다" : "사진을 고르세요"
            a.informativeText = "사진 > 동작 > 새 동작 기록으로 먼저 동작을 만드세요."; a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "일괄 처리 — 사진 \(items.count)장"
        a.informativeText = "고른 동작을 사진마다 겁니다. 내보내기를 켜면 끝난 뒤 내보내기 창이 열립니다."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 28, width: 260, height: 26))
        popup.addItems(withTitles: names)
        let exportBox = NSButton(checkboxWithTitle: "끝나면 내보내기", target: nil, action: nil)
        exportBox.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(popup); box.addSubview(exportBox)
        a.accessoryView = box
        a.addButton(withTitle: "실행"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn, let name = popup.titleOfSelectedItem, let act = RecordedAction.load(name) else { return }
        batchApply(act, to: items)
        if exportBox.state == .on { exportPhotos(nil) }
    }

    @objc func deleteActionFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        RecordedAction.delete(name)
    }

    @objc func revealActions(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([RecordedAction.folder]) }

    // MARK: From Shortcuts / other apps (duochrome:// URLs)

    /// duochrome://open?path=… · duochrome://action?name=… · duochrome://style?name=… · duochrome://export?recipe=…&folder=…
    /// Called via Shortcuts "Open URL" or `open` in Terminal. True if handled.
    @discardableResult
    func handleURL(_ url: URL) -> Bool {
        guard url.scheme == "duochrome", let host = url.host else { return false }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        switch host {
        case "open":
            guard let p = q["path"] else { return false }
            openFileOrFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        case "action":
            guard let n = q["name"], let act = RecordedAction.load(n) else { NSSound.beep(); return false }
            playAction(act)
        case "style":
            guard let n = q["name"] else { return false }
            applyStyle(named: n, strength: Double(q["strength"] ?? "") ?? 1)
        case "export":
            guard let doc = photo, let item = photoItem else { return false }
            var r = ExportRecipe.library.first { $0.name == q["recipe"] } ?? ExportRecipe()
            if let f = q["folder"] { r.folder = (f as NSString).expandingTildeInPath }
            _ = try? Exporter.export(doc, recipe: r, name: item.name)
        case "mode":
            setMode(AppMode.allCases.first { $0.key == q["key"] } ?? .edit)
        default: return false
        }
        return true
    }

    /// Actions menu (under the Photo menu)
    func actionMenuItems(_ menu: NSMenu) {
        menu.removeAllItems()
        let rec = ActionRecorder.shared.isRecording
        menu.addItem(withTitle: rec ? "기록 멈추고 저장" : "새 동작 기록…", action: rec ? #selector(stopActionRecording(_:)) : #selector(startActionRecording(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "일괄 처리…", action: #selector(showBatchProcess(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let names = RecordedAction.names()
        if names.isEmpty { menu.addItem(withTitle: "저장한 동작 없음", action: nil, keyEquivalent: "").isEnabled = false }
        for n in names {
            let it = menu.addItem(withTitle: "재생: \(n)", action: #selector(playActionFromMenu(_:)), keyEquivalent: "")
            it.representedObject = n; it.target = self
        }
        if !names.isEmpty {
            let del = menu.addItem(withTitle: "동작 지우기", action: nil, keyEquivalent: "")
            let dm = NSMenu()
            for n in names { let it = dm.addItem(withTitle: n, action: #selector(deleteActionFromMenu(_:)), keyEquivalent: ""); it.representedObject = n; it.target = self }
            del.submenu = dm
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "동작 폴더 보기", action: #selector(revealActions(_:)), keyEquivalent: "").target = self
    }
}

final class ActionMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ActionMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let w = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        w.actionMenuItems(menu)
    }
}

// MARK: - AppleScript commands (Duochrome.sdef)

private var scriptWindow: MainWindowController? { NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first }

/// open photo "path"
@objc(OpenPhotoCommand)
final class OpenPhotoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let p = directParameter as? String, let w = scriptWindow else { scriptErrorNumber = -1; return false }
        w.openFileOrFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        return true
    }
}

/// run action "name"
@objc(RunActionCommand)
final class RunActionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let n = directParameter as? String, let act = RecordedAction.load(n), let w = scriptWindow else { scriptErrorNumber = -1; return false }
        w.playAction(act)
        return true
    }
}

/// apply style "name"
@objc(ApplyStyleCommand)
final class ApplyStyleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let n = directParameter as? String, let w = scriptWindow else { scriptErrorNumber = -1; return false }
        w.applyStyle(named: n, strength: 1)
        return true
    }
}

/// export photo to "folder" — exports the open photo with the default recipe (or named) and returns the file path
@objc(ExportPhotoCommand)
final class ExportPhotoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let w = scriptWindow, let doc = w.photo, let item = w.photoItem else { scriptErrorNumber = -1; return nil }
        var r = ExportRecipe.library.first { $0.name == (evaluatedArguments?["recipe"] as? String) } ?? ExportRecipe()
        if let f = directParameter as? String { r.folder = (f as NSString).expandingTildeInPath }
        return (try? Exporter.export(doc, recipe: r, name: item.name))?.path
    }
}

/// current photo — path of the open photo
@objc(CurrentPhotoCommand)
final class CurrentPhotoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { scriptWindow?.photo?.url.path ?? "" }
}
