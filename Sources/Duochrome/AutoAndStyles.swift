import AppKit

/// Auto adjustments and styles.
extension MainWindowController {
    // MARK: - Auto adjust

    /// Auto adjust: white balance (gray world) → exposure (mid brightness) → levels (black/white points).
    @objc func autoAdjust(_ sender: Any?) {
        guard photo != nil else { NSSound.beep(); return }
        pickWhiteBalance(at: nil) { [weak self] in
            guard let self, let doc = self.photo, var s = self.photo?.settings else { return }
            let tone = Self.autoTone(doc.image(scale: Develop.guideScale))
            s.exposure = min(max(s.exposure + tone.ev, -4), 4)
            if tone.white < 0.95 { s.levelInWhite = max(tone.white, 0.6) }
            if tone.black > 0.03 { s.levelInBlack = min(tone.black, 0.15) }
            self.replaceSettings(s, recordUndo: true, label: "자동 조정")
            self.inspector.show(doc)
            NSLog("auto adjust: ev %+.2f black %.3f white %.3f", tone.ev, tone.black, tone.white)
        }
    }

    /// Auto for one card only (Exposure card: exposure, Levels card: black/white points)
    func autoCard(_ id: String) {
        guard let doc = photo else { NSSound.beep(); return }
        var s = doc.settings
        let tone = Self.autoTone(doc.image(scale: Develop.guideScale))
        switch id {
        case "exposure":
            s.exposure = min(max(s.exposure + tone.ev, -4), 4)
        case "levels":
            // Black/white points measured at the current exposure
            let gain = pow(2, -tone.ev / 2.2)
            s.levelInWhite = max(min(tone.white * gain, 1), 0.6)
            s.levelInBlack = min(max(tone.black * gain, 0), 0.15)
        default: return
        }
        replaceSettings(s, recordUndo: true, label: id == "levels" ? "자동 레벨" : "자동 노출")
        inspector.show(doc)
    }

    /// From the display (gamma) luminance histogram: exposure moving the median to 0.46, then the 0.1% / 99.9% luminance after the move.
    static func autoTone(_ img: CIImage) -> (ev: Float, black: Float, white: Float) {
        let e = img.extent
        let k = 256 / max(e.width, e.height)
        let small = img.transformed(by: .init(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 4, h > 4 else { return (0, 0, 1) }
        var buf = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: Render.displaySpace)
        var lum = (0..<(w * h)).map { 0.2126 * buf[$0 * 4] + 0.7152 * buf[$0 * 4 + 1] + 0.0722 * buf[$0 * 4 + 2] }
        lum.sort()
        func q(_ p: Double) -> Float { lum[min(lum.count - 1, max(0, Int(Double(lum.count) * p)))] }
        let median = max(q(0.5), 0.01)
        let ev = min(max(2.2 * log2(0.46 / median), -2), 2)
        let gain = pow(2, ev / 2.2)
        return (ev, min(q(0.001) * gain, 1), min(q(0.999) * gain, 1))
    }

    // MARK: - Styles

    static var stylesFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let env = ProcessInfo.processInfo.environment
        let dir = env["DUOCHROME_SNAPSHOT"] != nil || env["DUOCHROME_SELFTEST"] != nil
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test-styles")
            : base.appendingPathComponent("Duochrome/Styles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func styleNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stylesFolder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Saves current adjustments as a style (geometry, retouching, and layers are per-photo, so excluded).
    @objc func saveStyle(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "스타일로 저장"
        a.informativeText = "화이트 밸런스·노출·색·디테일 등 조정을 저장합니다. 형태·리터칭·레이어는 넣지 않습니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "스타일 이름"
        a.accessoryView = field
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        saveStyle(named: field.stringValue, from: doc.settings)
    }

    func saveStyle(named name: String, from s: DevelopSettings) {
        let all = settingsDict(s)
        var out: [String: Any] = [:]
        for k in AdjustGroup.keys(Set(AdjustGroup.allCases.filter(\.defaultOn))) { out[k] = all[k] }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.stylesFolder.appendingPathComponent("\(safe).json"))
        }
    }

    /// Apply style. Moves numeric values from current toward the style by the amount (0–1). Non-numeric values (curves etc.) switch at 50% or more.
    func applyStyle(named name: String, strength: Double) {
        guard let doc = photo,
              let data = try? Data(contentsOf: Self.stylesFolder.appendingPathComponent("\(name).json")),
              let style = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("스타일 읽기 실패: %@", name); NSSound.beep(); return
        }
        var dict = settingsDict(doc.settings)
        func blend(_ cur: Any?, _ target: Any) -> Any {
            // Booleans (NSNumber bool) are not blended as numbers
            func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
            if !isBool(cur), !isBool(target), let a = cur as? Double, let b = target as? Double { return a + (b - a) * strength }
            if let a = cur as? [String: Any], let b = target as? [String: Any] {
                var o = a
                for (k, v) in b { o[k] = blend(a[k], v) }
                return o
            }
            return strength >= 0.5 ? target : (cur ?? target)
        }
        for (k, v) in style { dict[k] = blend(dict[k], v) }
        let s: DevelopSettings
        do {
            let out = try JSONSerialization.data(withJSONObject: dict)
            s = try JSONDecoder().decode(DevelopSettings.self, from: out)
        } catch {
            NSLog("스타일 적용 실패: %@", "\(error)"); return
        }
        replaceSettings(s, recordUndo: true, label: "스타일 \(name) \(Int((strength * 100).rounded()))%")
        inspector.show(doc)
    }

    @objc func applyStyleFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let strength = UserDefaults.standard.object(forKey: "styleStrength") as? Double ?? 1
        applyStyle(named: name, strength: strength)
    }

    @objc func setStyleStrength(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag) / 100, forKey: "styleStrength")
    }

    @objc func revealStyles(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([Self.stylesFolder]) }
}

/// "Styles" menu: re-reads the saved style list each time it opens.
final class StyleMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = StyleMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "지금 조정을 스타일로 저장…", action: #selector(MainWindowController.saveStyle(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let names = MainWindowController.styleNames()
        if names.isEmpty {
            menu.addItem(withTitle: "저장한 스타일 없음", action: nil, keyEquivalent: "").isEnabled = false
        }
        for n in names {
            let item = menu.addItem(withTitle: n, action: #selector(MainWindowController.applyStyleFromMenu(_:)), keyEquivalent: "")
            item.representedObject = n
        }
        menu.addItem(.separator())
        let strength = menu.addItem(withTitle: "적용 강도", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cur = Int(((UserDefaults.standard.object(forKey: "styleStrength") as? Double ?? 1) * 100).rounded())
        for p in [25, 50, 75, 100] {
            let i = sub.addItem(withTitle: "\(p)%", action: #selector(MainWindowController.setStyleStrength(_:)), keyEquivalent: "")
            i.tag = p
            i.state = p == cur ? .on : .off
        }
        strength.submenu = sub
        menu.addItem(withTitle: "스타일 폴더 열기", action: #selector(MainWindowController.revealStyles(_:)), keyEquivalent: "")
    }
}

extension MainWindowController {
    /// Cycle composition grids (⌘')
    @objc func cycleGrid(_ sender: Any?) {
        let g = viewer.canvas.gridOverlay
        g.mode = GridOverlayView.Mode(rawValue: (g.mode.rawValue + 1) % GridOverlayView.Mode.allCases.count) ?? .none
    }
}

extension MainWindowController {
    /// Photo search (window toolbar search field): filters within the current collection.
    @objc func searchPhotos(_ sender: NSSearchField) {
        library.query = sender.stringValue
        // The batch-edit photo panel and the grid view search fields show the same query
        for f in [browser.searchField, libraryMode.searchField] where f !== sender { f?.stringValue = sender.stringValue }
        browser.reload()
        libraryMode.grid.reload()
    }
}

extension MainWindowController {
    /// ⌘V: outside text fields, pastes the clipboard image as an image layer.
    @objc func paste(_ sender: Any?) { pasteImageLayer(sender) }

}

extension MainWindowController {
    /// Soft proof (⌘Y) · gamut warning (⇧⌘Y)
    @objc func toggleSoftProof(_ sender: Any?) { viewer.canvas.softProof.toggle() }
    @objc func toggleGamutWarning(_ sender: Any?) { viewer.canvas.gamutWarning.toggle() }
}
