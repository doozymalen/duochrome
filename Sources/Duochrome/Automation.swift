import AppKit

// MARK: - 자동화: 동작 기록·재생, 일괄 처리, 애플스크립트, 단축어(URL)

/// 동작 한 단계: 바뀐 값들 (설정 JSON의 경로 → 새 값). 레이어는 더한 것과 자리별로 고친 것을 따로 둔다
struct ActionStep {
    var label: String
    /// ([경로], 값) — 값은 JSON 값(숫자·문자·불·배열·사전·NSNull)
    var patches: [([String], Any)] = []
    /// 새로 더한 레이어 (JSON)
    var addedLayers: [[String: Any]] = []
    /// 지운 레이어 수 (위에서부터)
    var removedLayers = 0
    /// 자리(아래에서부터 번호)별 레이어 고침
    var layerEdits: [(Int, [([String], Any)])] = []

    var json: [String: Any] {
        ["label": label,
         "patches": patches.map { ["path": $0.0, "value": $0.1] },
         "addedLayers": addedLayers,
         "removedLayers": removedLayers,
         "layerEdits": layerEdits.map { ["index": $0.0, "patches": $0.1.map { ["path": $0.0, "value": $0.1] }] }]
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
        layerEdits = (j["layerEdits"] as? [[String: Any]] ?? []).compactMap { e in (e["index"] as? Int).map { ($0, ps(e["patches"])) } }
    }
}

/// 이름 붙인 동작
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

    // MARK: 차이 계산

    /// 두 설정 사전의 차이 → 단계 (레이어는 따로)
    static func step(label: String, before a: [String: Any], after b: [String: Any]) -> ActionStep {
        var st = ActionStep(label: label)
        for key in Set(a.keys).union(b.keys) where key != "layers" {
            diff([key], a[key], b[key], into: &st.patches)
        }
        let la = a["layers"] as? [[String: Any]] ?? [], lb = b["layers"] as? [[String: Any]] ?? []
        let idsA = Set(la.compactMap { $0["id"] as? String }), idsB = Set(lb.compactMap { $0["id"] as? String })
        st.addedLayers = lb.filter { !idsA.contains($0["id"] as? String ?? "") }
        st.removedLayers = la.filter { !idsB.contains($0["id"] as? String ?? "") }.count
        // 남은 레이어는 자리별로 고친 값만
        let kept = lb.filter { idsA.contains($0["id"] as? String ?? "") }
        for (i, l) in kept.enumerated() {
            guard let old = la.first(where: { ($0["id"] as? String) == (l["id"] as? String) }) else { continue }
            var p: [([String], Any)] = []
            for key in Set(old.keys).union(l.keys) where key != "id" { diff([key], old[key], l[key], into: &p) }
            if !p.isEmpty { st.layerEdits.append((i, p)) }
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

    /// 설정 사전에 단계를 건다
    static func apply(_ st: ActionStep, to dict: inout [String: Any]) {
        for (path, v) in st.patches { set(&dict, path, v) }
        var layers = dict["layers"] as? [[String: Any]] ?? []
        if st.removedLayers > 0 { layers.removeLast(min(st.removedLayers, layers.count)) }
        for (i, p) in st.layerEdits where layers.indices.contains(i) {
            var l = layers[i]
            for (path, v) in p { set(&l, path, v) }
            layers[i] = l
        }
        // 더한 레이어는 새 id로 (그룹 안 자식은 새 그룹 id를 따라간다)
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

/// 기록 중인 동작
final class ActionRecorder {
    static let shared = ActionRecorder()
    var recording: RecordedAction?
    var isRecording: Bool { recording != nil }
}

extension MainWindowController {
    // MARK: 기록

    /// recordHistory에서 부른다: 기록 중이면 바뀐 값을 단계로 남긴다
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

    /// 기록을 멈추고 저장한다 (저장한 동작을 돌려준다)
    @discardableResult
    func finishRecording() -> RecordedAction? {
        guard let rec = ActionRecorder.shared.recording else { NSSound.beep(); return nil }
        ActionRecorder.shared.recording = nil
        window?.subtitle = ""
        guard !rec.steps.isEmpty else { return nil }
        try? rec.save()
        return rec
    }

    // MARK: 재생

    @objc func playActionFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let act = RecordedAction.load(name) else { NSSound.beep(); return }
        playAction(act)
    }

    /// 연 사진에 동작을 건다 (되돌리기 한 번)
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

    // MARK: 일괄 처리

    /// 사진 여러 장에 동작을 건다 (연 사진은 되돌리기 가능, 나머지는 카탈로그에 바로). 고친 장 수
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

    /// 일괄 처리 창: 동작을 고르고, 고른 사진에 건 뒤 내보낼지
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

    // MARK: 단축어·다른 앱에서 (duochrome:// 주소)

    /// duochrome://open?path=… · duochrome://action?name=… · duochrome://style?name=… · duochrome://export?recipe=…&folder=…
    /// 단축어 앱의 "URL 열기"나 터미널 `open`으로 부른다. 처리했으면 참.
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

    /// 동작 메뉴 (사진 메뉴 아래)
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

// MARK: - 애플스크립트 명령 (Duochrome.sdef)

private var scriptWindow: MainWindowController? { NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first }

/// open photo "경로"
@objc(OpenPhotoCommand)
final class OpenPhotoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let p = directParameter as? String, let w = scriptWindow else { scriptErrorNumber = -1; return false }
        w.openFileOrFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        return true
    }
}

/// run action "이름"
@objc(RunActionCommand)
final class RunActionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let n = directParameter as? String, let act = RecordedAction.load(n), let w = scriptWindow else { scriptErrorNumber = -1; return false }
        w.playAction(act)
        return true
    }
}

/// apply style "이름"
@objc(ApplyStyleCommand)
final class ApplyStyleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let n = directParameter as? String, let w = scriptWindow else { scriptErrorNumber = -1; return false }
        w.applyStyle(named: n, strength: 1)
        return true
    }
}

/// export photo to "폴더" — 연 사진을 기본 레시피(또는 이름)로 내보내고 파일 경로를 돌려준다
@objc(ExportPhotoCommand)
final class ExportPhotoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let w = scriptWindow, let doc = w.photo, let item = w.photoItem else { scriptErrorNumber = -1; return nil }
        var r = ExportRecipe.library.first { $0.name == (evaluatedArguments?["recipe"] as? String) } ?? ExportRecipe()
        if let f = directParameter as? String { r.folder = (f as NSString).expandingTildeInPath }
        return (try? Exporter.export(doc, recipe: r, name: item.name))?.path
    }
}

/// current photo — 연 사진 경로
@objc(CurrentPhotoCommand)
final class CurrentPhotoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { scriptWindow?.photo?.url.path ?? "" }
}
