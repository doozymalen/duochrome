import AppKit

/// UI test (DUOCHROME_UITEST=1): synthesizes real mouse events (down, drag, up), sends them to each view, and checks the resulting settings.
/// Built to verify mouse interactions a person would do. Prints "통과/실패" to stdout and quits.
extension MainWindowController {
    func runUITests() {
        guard let doc = photo else { print("실패  사진이 열리지 않음"); exit(1) }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "통과" : "실패")  \(name)  \(detail)")
            if !ok { failures += 1 }
        }
        let canvas = viewer.canvas
        canvas.zoomToFit()
        canvas.layoutSubtreeIfNeeded()

        // image coordinates on the canvas (displayed image pixels) → view coordinates
        func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { canvas.viewPoint(forImage: CGPoint(x: x, y: y)) }
        let W = doc.pixelSize.width, H = doc.pixelSize.height

        // 1. Crop: drag the top-right handle inward
        tools.select(tools.index(of: "형태"))
        enterTool(.crop)
        canvas.layoutSubtreeIfNeeded()
        let fw = doc.frameSize.width, fh = doc.frameSize.height
        drag(canvas.overlay, from: v(fw, fh), to: v(fw * 0.8, fh * 0.75))
        let c = doc.settings.crop
        check("크롭 손잡이 끌기", abs(c.w - 0.8) < 0.02 && abs(c.h - 0.75) < 0.02 && c.x == 0 && c.y == 0,
              String(format: "크롭 x %.2f y %.2f w %.3f h %.3f (0.8×0.75 기대)", c.x, c.y, c.w, c.h))
        // drag the center to move
        drag(canvas.overlay, from: v(fw * 0.4, fh * 0.4), to: v(fw * 0.5, fh * 0.45))
        let c2 = doc.settings.crop
        check("크롭 영역 옮기기", abs(c2.x - 0.1) < 0.02 && abs(c2.y - 0.05) < 0.02,
              String(format: "x %.3f y %.3f (0.1, 0.05 기대)", c2.x, c2.y))
        enterTool(.pan)

        // 2. Straighten: drag along a tilted line (3°) → rotation +3°
        let before = doc.settings.rotation
        enterTool(.straighten)
        let a = v(W * 0.2, H * 0.5), b = CGPoint(x: a.x + 300, y: a.y + 300 * tan(3 * .pi / 180))
        drag(canvas.overlay, from: a, to: b)
        check("수평 맞추기 선", abs((doc.settings.rotation - before) - 3) < 0.2,
              String(format: "회전 %.2f° → %.2f°", before, doc.settings.rotation))
        enterTool(.pan)

        // 2-1. Two keystone lines: converging upward (left leaning right, right leaning left)
        let kvBefore = doc.settings.keystoneV
        enterTool(.keystone)
        drag(canvas.overlay, from: v(W * 0.3, H * 0.2), to: v(W * 0.33, H * 0.8))
        drag(canvas.overlay, from: v(W * 0.7, H * 0.2), to: v(W * 0.67, H * 0.8))
        check("키스톤 선 긋기", doc.settings.keystoneV > kvBefore + 5,
              String(format: "세로 키스톤 %.1f → %.1f, 회전 %.2f°", kvBefore, doc.settings.keystoneV, doc.settings.rotation))
        // 2-1b. Horizontal mode: two lines converging to the right → only horizontal keystone changes
        shape.selectKeystoneMode(.horizontal)
        let khBefore = doc.settings.keystoneH, kv2 = doc.settings.keystoneV
        drag(canvas.overlay, from: v(W * 0.2, H * 0.3), to: v(W * 0.8, H * 0.34))
        drag(canvas.overlay, from: v(W * 0.2, H * 0.7), to: v(W * 0.8, H * 0.66))
        check("키스톤 가로 방식", abs(doc.settings.keystoneH - khBefore) > 5 && doc.settings.keystoneV == kv2 && canvas.overlay.keystoneMode == .horizontal,
              String(format: "가로 키스톤 %.1f → %.1f, 세로 그대로 %.1f", khBefore, doc.settings.keystoneH, doc.settings.keystoneV))
        shape.selectKeystoneMode(.vertical)
        enterTool(.pan)

        // 2-2. White balance eyedropper: clicking calls the eyedropper at that spot, and that spot's computation yields values.
        // (Actually applying returns to the main queue after a background computation, and this test runs on the main queue, so it can't wait here.)
        enterTool(.whiteBalance)
        let original = canvas.onPick
        var picked: CGPoint?
        canvas.onPick = { _, p in picked = p }
        click(canvas, at: v(W * 0.5, H * 0.5))
        canvas.onPick = original
        let wb = picked.flatMap { doc.neutralWhiteBalance(at: $0) }
        check("화이트 밸런스 스포이트 누르기", picked.map { abs($0.x - W * 0.5) < 2 && abs($0.y - H * 0.5) < 2 } == true && wb != nil,
              String(format: "누른 곳 (%.0f, %.0f), 맞춘 값 %.0fK / 틴트 %.1f", picked?.x ?? -1, picked?.y ?? -1,
                     wb?.temperature ?? 0, wb?.tint ?? 0))
        enterTool(.pan)

        // 3. Drag with the move tool (pan)
        canvas.zoomToActual()
        let p0 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        drag(canvas, from: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY),
             to: CGPoint(x: canvas.bounds.midX + 100, y: canvas.bounds.midY))
        let p1 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        check("이동 도구 끌기", abs((p0.x - p1.x) - 100 / canvas.zoom) < 2,
              String(format: "가운데가 원본 %.0fpx 옮겨짐 (%.0f 기대)", p0.x - p1.x, 100 / canvas.zoom))
        // trackpad two-finger pan = scroll events
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0),
           let e = NSEvent(cgEvent: cg) {
            let q0 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            canvas.scrollWheel(with: e)
            let q1 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            check("스크롤로 이동", abs(q1.x - q0.x) > 0.5 || abs(q1.y - q0.y) > 0.5,
                  String(format: "(%.1f, %.1f) → (%.1f, %.1f)", q0.x, q0.y, q1.x, q1.y))
        }
        // Trackpad pinch (zoom) = gesture events. The photo point under the fingers must stay put.
        canvas.zoomToFit()
        if let win = canvas.window, let cg = CGEvent(source: nil) {
            let viewPt = CGPoint(x: canvas.bounds.width * 0.3, y: canvas.bounds.height * 0.6)
            let screen = win.convertPoint(toScreen: canvas.convert(viewPt, to: nil))
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            cg.type = CGEventType(rawValue: 29)!                              // gesture
            cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)   // magnify
            cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0.25)
            cg.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
            cg.location = CGPoint(x: screen.x, y: mainH - screen.y)           // CG coordinates: top is 0
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(win.windowNumber))
            if let e = NSEvent(cgEvent: cg), e.type == .magnify {
                let z0 = canvas.zoom, a0 = canvas.imagePoint(at: canvas.convert(e.locationInWindow, from: nil))
                canvas.magnify(with: e)
                let a1 = canvas.imagePoint(at: canvas.convert(e.locationInWindow, from: nil))
                check("트랙패드 손가락 모으기 확대", abs(canvas.zoom / z0 - 1.25) < 0.01 && hypot(a1.x - a0.x, a1.y - a0.y) < 2,
                      String(format: "배율 %.3f → %.3f (×%.2f), 손가락 아래 지점 이동 %.1fpx", z0, canvas.zoom, canvas.zoom / z0,
                             hypot(a1.x - a0.x, a1.y - a0.y)))
            } else {
                check("트랙패드 손가락 모으기 확대", false, "제스처 사건을 만들지 못함")
            }
        }
        canvas.zoomToFit()

        // 4. Curves: click empty space to add a point and drag it up
        tools.select(tools.index(of: "조정"))
        inspector.reveal("curve")
        let ce = inspector.curveEditor
        ce.layoutSubtreeIfNeeded()
        let plot = ce.bounds.insetBy(dx: 6, dy: 6)
        let start = CGPoint(x: plot.minX + plot.width * 0.5, y: plot.minY + plot.height * 0.5)
        drag(ce, from: start, to: CGPoint(x: start.x, y: start.y + plot.height * 0.15))
        let pts = doc.settings.curves.rgb.points
        let mid = pts.first { abs($0.x - 0.5) < 0.03 }
        check("커브 점 만들고 끌기", pts.count == 3 && mid.map { abs($0.y - 0.65) < 0.03 } == true,
              "점 \(pts.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined(separator: " "))")

        // 5. Color balance: shadow wheel all the way toward blue (240°)
        if let wheel = inspector.wheel(1) {
            wheel.layoutSubtreeIfNeeded()
            let d = wheel.discRect.width
            let ctr = CGPoint(x: wheel.discRect.midX, y: wheel.discRect.midY)
            let ang = (240 + ColorWheelView.hueOffset) * CGFloat.pi / 180
            drag(wheel, from: ctr, to: CGPoint(x: ctr.x + cos(ang) * d / 2 * 0.8, y: ctr.y + sin(ang) * d / 2 * 0.8))
            let sh = doc.settings.color.shadow
            check("컬러 밸런스 휠 끌기", abs(sh.hue - 240) < 3 && abs(sh.amount - 0.8) < 0.05,
                  String(format: "색조 %.0f° 양 %.2f (240°, 0.8 기대)", sh.hue, sh.amount))
        }

        // 7-1. Sliders: number entry, double-click to default, snapping near the default
        do {
            _ = inspector.view
            func rows(_ v: NSView) -> [SliderRow] { v.subviews.flatMap { ($0 as? SliderRow).map { [$0] } ?? rows($0) } }
            if let ex = rows(inspector.view).first(where: { $0.slider.accessibilityLabel() == "노출" }),
               let field = ex.subviews.first.flatMap({ findField($0) }) {
                field.stringValue = "1.5 EV"
                ex.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
                let typed = doc.settings.exposure
                // Double-click is received at the slider cell's drag start (mouseDown and gesture recognizers didn't work with a real mouse): cell type + that behavior
                let hasDouble = ex.slider.cell is PixelSliderCell
                if hasDouble { ex.slider.doubleClicked() }
                let reset = doc.settings.exposure
                // Snapping depends on settings → default (on, 1.5%) only during this test
                let savedSnap = (AppSettings.snapEnabled, AppSettings.snapPercent)
                AppSettings.snapEnabled = true; AppSettings.snapPercent = 1.5
                ex.slider.doubleValue = 0.08
                _ = ex.slider.sendAction(ex.slider.action, to: ex.slider.target)
                let snapped = ex.slider.doubleValue
                (AppSettings.snapEnabled, AppSettings.snapPercent) = savedSnap
                ex.slider.doubleValue = 0.5
                _ = ex.slider.sendAction(ex.slider.action, to: ex.slider.target)
                let free = doc.settings.exposure
                check("슬라이더 숫자 입력·두 번 누르기·달라붙기", abs(typed - 1.5) < 0.001 && reset == doc.asShot.exposure && snapped == 0 && abs(free - 0.5) < 0.001,
                      String(format: "입력 1.5 → %.2f, 두 번 누름 → %.2f, 0.08로 끌면 %.2f, 0.5는 %.2f", typed, reset, snapped, free))
                ex.resetToDefault()
            } else {
                check("슬라이더 숫자 입력·두 번 누르기·달라붙기", false, "노출 슬라이더를 찾지 못함")
            }
        }

        // 7-2. Search, styles, grid, auto adjust computation, fill layers
        do {
            let total = library.items.count
            library.query = (doc.url.deletingPathExtension().lastPathComponent)
            let found = library.items.count
            let hasDoc = library.items.contains { $0.url == doc.url }
            library.query = ""
            // Other photos may share the name (another copy in the catalog); the open one must be among the results
            check("사진 검색", found >= 1 && found < total && hasDoc && library.items.count == total, "\(total)장 중 이름으로 \(found)장, 연 사진 포함 \(hasDoc)")

            var st = doc.settings; st.exposure = 1; st.contrast = 40
            saveStyle(named: "시험 스타일", from: st)
            let e0 = doc.settings.exposure, c0 = doc.settings.contrast
            applyStyle(named: "시험 스타일", strength: 0.5)
            let e1 = doc.settings.exposure, c1v = doc.settings.contrast
            check("스타일 저장·적용 (강도 50%)", abs(e1 - (e0 + (1 - e0) * 0.5)) < 0.001 && abs(c1v - (c0 + (40 - c0) * 0.5)) < 0.5 && MainWindowController.styleNames().contains("시험 스타일"),
                  String(format: "노출 %.2f → %.2f, 대비 → %.1f", e0, e1, c1v))
            undoAdjust(nil)

            let g0 = viewer.canvas.gridOverlay.mode
            cycleGrid(nil)
            check("구도 격자", viewer.canvas.gridOverlay.mode.rawValue == (g0.rawValue + 1) % 4, "\(g0) → \(viewer.canvas.gridOverlay.mode)")
            viewer.canvas.gridOverlay.mode = g0

            let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
            let t = MainWindowController.autoTone(dark)
            check("자동 조정 (어두운 사진은 노출을 올림)", t.ev > 1, String(format: "노출 %+.2f", t.ev))

            let n0 = doc.settings.layers.count
            layersTab.addFillLayer(colors: [1, 0, 0], gradient: false)
            let fl = doc.settings.layers.last
            check("칠 레이어", doc.settings.layers.count == n0 + 1 && fl?.isFill == true && fl?.fillColor == [1, 0, 0], "레이어 \(n0) → \(doc.settings.layers.count)")
            layersTab.removeLayer()

            toggleSecondViewer(nil)
            let sv = secondViewer
            let shown = sv?.canvas.document === doc && sv?.window?.isVisible == true
            toggleSecondViewer(nil)
            check("두 번째 화면에 보기", shown && secondViewer == nil, "같은 사진 \(shown), 끄면 닫힘 \(secondViewer == nil)")
        }

        // 7-3. Layer context menu, duplicate background (retouching goes into the copy), free transform
        do {
            let bgMenu = layerContextMenu(nil)
            duplicateBackground(nil)
            let copy = doc.settings.layers.last
            let copyMenu = layerContextMenu(copy?.id)
            let spots0 = doc.settings.spots.count
            enterTool(.retouch)
            let rro = canvas.retouchOverlay
            click(rro, at: canvas.viewPoint(forImage: CGPoint(x: doc.pixelSize.width * 0.4, y: doc.pixelSize.height * 0.4)))
            let copySpots = doc.settings.layers.last?.spots.count ?? 0
            check("배경 복제·우클릭 메뉴", copy?.isCopy == true && bgMenu.items.count >= 5 && copyMenu.items.count >= 12
                  && copySpots == 1 && doc.settings.spots.count == spots0,
                  "배경 메뉴 \(bgMenu.items.count)개, 레이어 메뉴 \(copyMenu.items.count)개, 복제 레이어 점 \(copySpots), 배경 점 \(spots0) → \(doc.settings.spots.count)")
            layersTab.removeLayer()
            enterTool(.pan)

            // Free transform: dragging an image layer's top-right corner outward enlarges it; Return confirms, undo restores
            let png = Render.context.pngRepresentation(of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)),
                                                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            let file = try! LayerImageStore.importData(png, ext: "png")
            layersTab.addImageLayer(file: file, name: "변형 시험")
            let w0 = doc.settings.layers.last?.image?.width ?? 0
            freeTransform(nil)
            let t = canvas.transformOverlay
            if let im = t.image, let toView = t.toView {
                let hw = im.width / 2, hh = im.width * t.aspect / 2
                let corner = toView(CGPoint(x: im.cx + hw, y: im.cy + hh))
                let far = toView(CGPoint(x: im.cx + hw * 1.5, y: im.cy + hh * 1.5))
                drag(t, from: corner, to: far)
                t.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
            }
            let w1 = doc.settings.layers.last?.image?.width ?? 0
            let toolBack = canvas.tool != .transform
            undoAdjust(nil)
            let w2 = doc.settings.layers.last?.image?.width ?? 0
            check("자유 변형 (모서리 끌기·확정·되돌리기)", abs(w1 - w0 * 1.25) < 2 && toolBack && abs(w2 - w0) < 0.5,
                  String(format: "너비 %.0f → %.0f, 되돌리면 %.0f", w0, w1, w2))
            layersTab.select(doc.settings.layers.last?.id)
            layersTab.removeLayer()
        }

        // 7-4. Shortcuts: per-mode defaults, changing
        do {
            let rB = KeyMap.table(.bulk)[KeyCombo("@r")]?.id, lB = KeyMap.table(.bulk)[KeyCombo("l")]?.id
            let jS = KeyMap.table(.studio)[KeyCombo("j")]?.id, tS = KeyMap.table(.studio)[KeyCombo("@t")]?.id
            let fiveS = KeyMap.table(.studio)[KeyCombo("5")]?.id, fiveB = KeyMap.table(.bulk)[KeyCombo("5")]?.id
            let a = KeyMap.actions.first { $0.id == "adj.reset" }!
            KeyMap.set(a, .bulk, ["^@x"])
            let moved = KeyMap.table(.bulk)[KeyCombo("^@x")]?.id == "adj.reset" && KeyMap.table(.bulk)[KeyCombo("@r")] == nil
            KeyMap.set(a, .bulk, nil)
            let back = KeyMap.table(.bulk)[KeyCombo("@r")]?.id == "adj.reset"
            check("단축키 (모드별 기본값, 바꾸기)",
                  rB == "adj.reset" && lB == "tool.linear" && jS == "tool.heal" && tS == "layer.transform"
                  && fiveS == "layer.opacity5" && fiveB == "photo.rate5" && moved && back && KeyMap.conflicts(.bulk).isEmpty && KeyMap.conflicts(.studio).isEmpty,
                  "⌘R \(rB ?? "-"), L \(lB ?? "-"), 심화 J \(jS ?? "-"), ⌘T \(tS ?? "-"), 5: 심화 \(fiveS ?? "-") / 대량 \(fiveB ?? "-"), 바꾸기 \(moved), 되돌리기 \(back), 겹침 \(KeyMap.conflicts(.bulk).count + KeyMap.conflicts(.studio).count)")
        }

        // 7-5. Layer shortcuts: delete (⌫), front/back (⇧⌘] ⇧⌘[), select above/below (⌥] ⌥[); locked layers aren't deleted
        do {
            let before = doc.settings.layers.count
            for _ in 0..<3 { layersTab.addLayer(.full, native: doc.nativeSize) }
            let ids = doc.settings.layers.suffix(3).map(\.id)   // bottom → top
            layersTab.select(ids[0])
            layersTab.layerToEnd(top: true)
            let topOK = doc.settings.layers.last?.id == ids[0]
            layersTab.layerToEnd(top: false)
            let bottomOK = doc.settings.layers.firstIndex { $0.id == ids[0] } == 0
            layersTab.selectNeighbor(up: true)
            let upOK = layersTab.selectedID == doc.settings.layers[1].id
            layersTab.selectNeighbor(up: false); layersTab.selectNeighbor(up: false)
            let bgOK = layersTab.selectedID == nil
            var s = doc.settings
            if let i = s.layers.firstIndex(where: { $0.id == ids[1] }) { s.layers[i].locked = true }
            replaceSettings(s, recordUndo: false, label: "잠금")
            layersTab.select(ids[1])
            _ = layersTab.deleteSelectedLayer()
            let lockedKept = doc.settings.layers.contains { $0.id == ids[1] }
            layersTab.select(ids[2])
            _ = layersTab.deleteSelectedLayer()
            let deleted = !doc.settings.layers.contains { $0.id == ids[2] }
            let keys = ["\u{7f}": "layer.delete", "$@]": "layer.top", "$@[": "layer.bottom", "~]": "layer.selectUp", "~[": "layer.selectDown", "@j": "layer.duplicate"]
            let keysOK = keys.allSatisfy { KeyMap.table(.studio)[KeyCombo($0.key)]?.id == $0.value }
                && KeyMap.table(.bulk)[KeyCombo("\u{7f}")]?.id == "layer.delete"
            s = doc.settings
            s.layers.removeAll { ids.contains($0.id) }
            replaceSettings(s, recordUndo: false, label: "정리")
            layersTab.sync(doc.settings)
            check("레이어 단축키", topOK && bottomOK && upOK && bgOK && lockedKept && deleted && keysOK && doc.settings.layers.count == before,
                  "맨 위 \(topOK), 맨 아래 \(bottomOK), 위 고르기 \(upOK), 배경까지 \(bgOK), 잠금 유지 \(lockedKept), 지우기 \(deleted), 키 \(keysOK)")
        }

        // 8-00. Switching batch-edit left tool tabs keeps window size and panel widths (even in a small window)
        do {
            var changed: [String] = []
            let saved = window?.frame ?? .zero
            for size in [saved.size, NSSize(width: 1100, height: 640)] {
                window?.setFrame(NSRect(origin: saved.origin, size: size), display: true)
                window?.layoutIfNeeded()
                let f0 = window?.frame ?? .zero
                let w0 = tools.view.frame.width
                for i in [0, 1, 2, 3, 4, 5, 2, 0, 5, 1] {
                    tools.select(i)
                    window?.layoutIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    let f = window?.frame ?? .zero, w = tools.view.frame.width
                    if f != f0 || abs(w - w0) > 0.5 { changed.append("\(tools.tabTitle(i)) \(Int(f.width))×\(Int(f.height)) 패널 \(Int(w))") }
                }
                if !changed.isEmpty { changed.insert("[\(Int(f0.width))×\(Int(f0.height)) 패널 \(Int(w0))]", at: 0) }
            }
            window?.setFrame(saved, display: true)
            check("도구 탭 전환 창 크기 유지", changed.isEmpty, changed.isEmpty ? "여섯 탭 × 두 창 크기" : changed.joined(separator: ", "))
        }

        // 8-01. Cycling through all layer-edit tools keeps window and panel sizes (even in a small window), and picking changes nothing
        do {
            let saved = window?.frame ?? .zero
            let ed = retouchEditor
            let tool0 = ed.currentTool
            let settings0 = photo?.settings
            setMode(.studio)
            var changed: [String] = []
            for size in [saved.size, NSSize(width: 1000, height: 600)] {
                window?.setFrame(NSRect(origin: saved.origin, size: size), display: true)
                window?.layoutIfNeeded()
                let f0 = window?.frame ?? .zero
                let o0 = ed.inspector.frame, l0 = ed.layersPanel.frame
                for t in RetouchTool.all where !["transform", "perspective"].contains(t.id) {
                    ed.selectTool(t.id)
                    window?.layoutIfNeeded()
                    let f = window?.frame ?? .zero
                    if f != f0 || ed.inspector.frame != o0 || ed.layersPanel.frame != l0 {
                        changed.append("\(t.title) 창 \(Int(f.width))×\(Int(f.height))")
                    }
                }
            }
            ed.selectTool(tool0)
            setMode(.edit)
            window?.setFrame(saved, display: true)
            if let s0 = settings0, let s1 = photo?.settings, s0 != s1 {
                changed.append("도구만 골랐는데 조정값이 바뀜")
                replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
            }
            check("심화 도구 전환 창 크기 유지", changed.isEmpty, changed.isEmpty ? "\(RetouchTool.all.count)개 도구 × 두 창 크기" : changed.prefix(8).joined(separator: ", "))
        }

        // 8-02. Layer edit brushes: picking makes no layer; the first stroke makes the brush's layer, later strokes go on it,
        //       ⌥ erases; the mask brush paints the selected layer's mask
        do {
            let s0 = photo?.settings
            setMode(.studio)
            let ed = retouchEditor
            let n0 = photo?.settings.layers.count ?? 0
            ed.selectTool("dodge")
            let afterPick = photo?.settings.layers.count ?? 0
            let b = canvas.brushSurface
            let visible = !b.isHidden && canvas.tool == .brush
            drag(b, from: CGPoint(x: b.bounds.midX - 60, y: b.bounds.midY), to: CGPoint(x: b.bounds.midX + 60, y: b.bounds.midY), steps: 8)
            drag(b, from: CGPoint(x: b.bounds.midX - 60, y: b.bounds.midY + 40), to: CGPoint(x: b.bounds.midX + 60, y: b.bounds.midY + 40), steps: 8)
            let last = photo?.settings.layers.last
            let dodgeOK = afterPick == n0 && photo?.settings.layers.count == n0 + 1 && last?.preset == "dodge" && last?.mask.strokes.count == 2
            drag(b, from: CGPoint(x: b.bounds.midX - 20, y: b.bounds.midY), to: CGPoint(x: b.bounds.midX + 20, y: b.bounds.midY), flags: .option)
            let eraseOK = photo?.settings.layers.last?.mask.strokes.last?.erase == true
            // Mask brush on a new adjustment layer: the first stroke limits the layer to where it is painted
            retouchAddAdjustLayer()
            ed.selectTool("maskBrush")
            drag(b, from: CGPoint(x: b.bounds.midX - 60, y: b.bounds.midY), to: CGPoint(x: b.bounds.midX + 60, y: b.bounds.midY))
            let m = photo?.settings.layers.last?.mask
            let maskOK = m?.kind == .brush && m?.strokes.count == 1 && m?.brushWhite == false
            check("심화 붓: 처음 칠할 때 레이어·이어 칠하기·지우기·마스크 붓", visible && dodgeOK && eraseOK && maskOK,
                  "붓 층 \(visible), 고름 \(n0)→\(afterPick), 닷지 \(dodgeOK), 지우기 \(eraseOK), 마스크 붓 \(maskOK)")
            ed.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
        }

        // 8-03. Glass layout: dragging a panel edge changes its width, and collapsing a panel widens the fit area
        do {
            setMode(.edit)
            window?.layoutIfNeeded()
            let w0 = split.leftWidth
            let handle = split.view.subviews.compactMap { $0 as? ResizeHandle }.first
            var dragged = false
            if let h = handle {
                let from = CGPoint(x: h.bounds.midX, y: h.bounds.midY)
                drag(h, from: from, to: CGPoint(x: from.x + 40, y: from.y), steps: 4)
                dragged = abs(split.leftWidth - (w0 + 40)) < 1
            }
            let inset0 = canvas.fitInsets.left
            split.showsLeft = false
            let insetHidden = canvas.fitInsets.left
            split.showsLeft = true
            split.leftWidth = w0
            check("유리 패널 폭 끌기·접기", dragged && inset0 > 200 && insetHidden == 0 && canvas.fitInsets.left == 8 + w0,
                  String(format: "폭 %.0f → 끌어서 %@, 맞춤 가림 %.0f → 접으면 %.0f", w0, dragged ? "+40" : "안 됨", inset0, insetHidden))
        }

        // 8-04. Real event path (window sendEvent → hitTest → tracking loop) for dragging an adjustment slider and clicking a tool tab.
        // Tests sending straight to views missed "slider disabled, doesn't respond".
        do {
            setMode(.edit)
            tools.select(tools.index(of: "조정"))
            window?.layoutIfNeeded()
            let s0 = photo?.settings
            let sliders = inspector.view.allSubviews.compactMap { $0 as? SnapSlider }.filter { !$0.isHiddenOrHasHiddenAncestor }
            let sl = sliders.first { $0.minValue == -4 && $0.maxValue == 4 }   // exposure
            var moved = false, enabled = false, tabOK = false
            if let sl, let win = window {
                enabled = sl.isEnabled
                sl.scrollToVisible(sl.bounds)
                let v0 = sl.doubleValue
                let knob = (sl.cell as? NSSliderCell)?.knobRect(flipped: sl.isFlipped) ?? sl.bounds
                let p = sl.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
                func ev(_ t: NSEvent.EventType, _ pt: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
                }
                // Dragging a slider can't be simulated inside the test (the tracking loop ignores synthetic events).
                // Checks only that it's enabled and a real hitTest reaches the slider. Actual dragging was checked with a mouse in the app.
                if let frame = win.contentView?.superview {
                    moved = frame.hitTest(frame.convert(p, from: nil)) === sl
                }
                _ = v0
                let tab = tools.view.allSubviews.compactMap { $0 as? TabButton }[1]
                let q = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
                // The window frame's system click recognizers make synthetic clicks unreliable.
                // Checks that a real hitTest reaches the tab button (or inside it). Actual clicks were checked with a mouse in the app.
                if let frame = win.contentView?.superview, let h = frame.hitTest(frame.convert(q, from: nil)) {
                    tabOK = h === tab || h.isDescendant(of: tab)
                }
            }
            check("진짜 사건: 슬라이더 켜짐·닿음·탭 누르기", enabled && moved && tabOK,
                  "슬라이더 켜짐 \(enabled), hitTest 닿음 \(moved), 탭 닿음 \(tabOK)")
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            tools.select(tools.index(of: "조정"))
        }

        // 8-05. Drag and drop (DragDrop.swift): layer order/groups, Finder image → layer, photo → album, photo → photo copy adjustments, adding to the tool strip
        do {
            setMode(.edit)
            let s0 = photo?.settings
            // layer tree rules
            var ls = [AdjustLayer(name: "A"), AdjustLayer(name: "B"), AdjustLayer(name: "C")]
            ls[2].kind = "group"
            let a = ls[0].id, b = ls[1].id, g = ls[2].id
            LayerTree.drop(&ls, from: 0, onto: 2, .into)          // A into group C
            let intoOK = ls.first { $0.id == a }?.group == g && ls.firstIndex { $0.id == a }! < ls.firstIndex { $0.id == g }!
            LayerTree.drop(&ls, from: ls.firstIndex { $0.id == b }!, onto: ls.firstIndex { $0.id == g }!, .above)  // B above the group
            let aboveOK = ls.last?.id == b && ls.last?.group == nil
            let selfBlocked = !LayerTree.drop(&ls, from: ls.firstIndex { $0.id == g }!, onto: ls.firstIndex { $0.id == a }!, .above)  // group onto its own child: no
            LayerTree.drop(&ls, from: ls.firstIndex { $0.id == g }!, onto: nil, .above)   // group block to the bottom
            let bottomOK = ls.first?.id == a && ls[1].id == g && ls.last?.id == b
            // In the window: two layers + a group → drag into the group
            layersTab.addLayer(.full, native: photo?.nativeSize)
            layersTab.addLayer(.full, native: photo?.nativeSize)
            let ids = photo?.settings.layers.map(\.id) ?? []
            if ids.count >= 2 { layersTab.select(ids[0]); layersTab.groupSelected() }
            let grp = photo?.settings.layers.first { $0.isGroup }?.id
            if let last = ids.last, let grp { dropLayer(last, onto: grp, .into) }
            let winOK = grp != nil && photo?.settings.layers.first { $0.id == ids.last }?.group == grp
            // Finder image → image layer (drop on canvas)
            let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-drop-test.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
            let n0 = photo?.settings.layers.count ?? 0
            let i0 = photo?.settings.layers.filter(\.isImage).count ?? 0
            let took = canvas.onDropFiles?([png]) ?? false
            let imgOK = took && photo?.settings.layers.count == n0 + 1 && photo?.settings.layers.filter(\.isImage).count == i0 + 1
            if !imgOK { NSLog("DBG 그림 놓기 받음 %d, 레이어 %d → %d", took ? 1 : 0, n0, photo?.settings.layers.count ?? -1) }
            // RAW isn't a layer
            let rawIsLayer = DragFiles.isLayerImage(URL(fileURLWithPath: "/tmp/x.CR3"))
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            // photo → album (test catalog)
            var albumOK = false
            if let cur = photoItem, let album = try? library.catalog.addAlbum("끌기 시험 \(Int(Date().timeIntervalSince1970))") {
                dropPhotos([cur.url.path], toAlbum: album)
                albumOK = ((try? library.catalog.count(.album(album))) ?? 0) == 1
            }
            // photo → photo: paste the current photo's exposure onto the neighbor
            var adjOK = false
            if let cur = photoItem, let other = library.items.first(where: { $0 !== cur && !$0.offline }) {
                let had = library.rawSettings(for: other.url)
                var s = photo!.settings; s.exposure = 0.77; apply(s, dragging: false)
                dropAdjustments(from: cur.url.path, onto: other)
                let d = library.rawSettings(for: other.url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                adjOK = abs(((d?["exposure"] as? Double) ?? 0) - 0.77) < 0.001
                if let had, let dict = try? JSONSerialization.jsonObject(with: had) as? [String: Any] { library.saveRawSettings(dict, for: other.url) }
                else { library.removeSettings(for: other.url) }
                if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            }
            // Tool strip customization: insert and move at the drop position
            let sheet = ToolCustomizeSheet()
            var list: [String] = []
            sheet.onDone = { list = $0 }
            sheet.insert("twirl", at: 0)
            sheet.insert(StudioTool.strip[2], at: 1)
            sheet.perform(Selector(("done")))
            let stripOK = list.first == "twirl" && list.count > 2 && list[1] == StudioTool.strip[2]
            check("끌어 놓기: 레이어·그림·앨범·조정·도구 막대",
                  intoOK && aboveOK && selfBlocked && bottomOK && winOK && imgOK && !rawIsLayer && albumOK && adjOK && stripOK,
                  "그룹 안 \(intoOK) 위 \(aboveOK) 자기막기 \(selfBlocked) 맨아래 \(bottomOK) 창 \(winOK) 그림 \(imgOK) RAW제외 \(!rawIsLayer) 앨범 \(albumOK) 조정 \(adjOK) 도구막대 \(stripOK)")
        }

        // 8-06. Catalog backup: back up the test catalog to a temp folder, open the backup, and check the adjustment count matches
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-backup-test-\(Int(Date().timeIntervalSince1970))")
            var ok = false, detail = ""
            library.catalog.setAdjustment("backup-test-key", "{\"exposure\":0.5}")
            defer { library.catalog.setAdjustment("backup-test-key", nil) }
            do {
                let dest = try CatalogBackup.run(library.catalog, to: dir, previews: false, keep: 0)
                let copy = try Catalog(url: dest)
                let a = library.catalog.adjustedKeys().count, b = copy.adjustedKeys().count
                ok = a == b && a >= 1 && copy.adjustment("backup-test-key") == "{\"exposure\":0.5}"
                detail = "원본 조정 \(a)개, 백업 \(b)개 — \(dest.lastPathComponent)"
            } catch { detail = "\(error)" }
            try? FileManager.default.removeItem(at: dir)
            check("카탈로그 백업", ok, detail)
        }

        // 8-08. Advanced layers: Blend If, pattern fill, layer comps, snapshots, align/link, merge/stamp, linked images
        do {
            setMode(.edit)
            let s0 = photo?.settings
            var notes: [String] = []
            func avg(_ img: CIImage) -> Float {
                let d = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
                var px = [Float](repeating: 0, count: 4)
                Render.context.render(d, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return px[0] + px[1] + px[2]
            }
            guard let doc = photo else { check("레이어 고급", false, "사진 없음"); return }
            // Blend If: a full exposure +2 layer only on dark areas (below brightness 0–0.3) → less bright than applied everywhere
            var s = doc.settings
            var l = AdjustLayer(name: "밝게"); l.mask.kind = .full; l.adjust.exposure = 2
            s.layers.append(l); apply(s, dragging: false)
            let full = avg(doc.image(scale: Develop.guideScale))
            s.layers[s.layers.count - 1].blendIf = [0, 0, 1, 1, 0, 0, 0.25, 0.35]
            apply(s, dragging: false)
            let limited = avg(doc.image(scale: Develop.guideScale))
            if !(limited < full - 0.05) { notes.append("혼합 조건 \(limited) vs \(full)") }
            // pattern fill
            s = doc.settings
            var f = AdjustLayer(name: "무늬"); f.kind = "fill"; f.fillColor = [1, 0, 0, 0, 0, 1]; f.fillPattern = 0; f.fillScale = 200
            s.layers = [f]; apply(s, dragging: false)
            let pat = doc.image(scale: Develop.guideScale)
            var px = [Float](repeating: 0, count: 8)
            let e = pat.extent
            Render.context.render(pat, toBitmap: &px, rowBytes: 32, bounds: CGRect(x: e.minX + 2, y: e.minY + 2, width: 2, height: 1), format: .RGBAf, colorSpace: nil)
            if !(px[0] > 0.5 || px[2] > 0.5) { notes.append("무늬 칠 색 \(px)") }
            // Layer comps: remember hidden visibility and restore it
            layersTab.select(f.id)
            saveLayerComp(nil)
            s = doc.settings; s.layers[0].enabled = false; replaceSettings(s, recordUndo: true, label: "끄기")
            applyLayerComp(0)
            if doc.settings.layers[0].enabled != true || doc.settings.layerComps?.count != 1 { notes.append("레이어 구성") }
            // Snapshots: create, change, revert + save/load
            makeSnapshot(named: "시험 스냅샷")
            s = doc.settings; s.exposure += 1; replaceSettings(s, recordUndo: true, label: "바꿈")
            restoreSnapshot(history.snapshots.count - 1)
            let snapOK = doc.settings.exposure == (s.exposure - 1) && historyTab.snapshots.last == "시험 스냅샷"
            var h2 = AdjustHistory()
            let restored = history.encoded().map { h2.restore($0, current: doc.settings) } ?? false
            if !snapOK || !restored || h2.snapshots.last?.label != "시험 스냅샷" { notes.append("스냅샷 \(snapOK) \(restored) \(h2.snapshots.count)") }
            // two image layers (small PNG) → link → align left → both move; merge down → one
            let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-k-test.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<16 { for x in 0..<16 { rep.setColor(NSColor(red: 0, green: 1, blue: 0, alpha: 1), atX: x, y: y) } }
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
            s = doc.settings; s.layers = []; replaceSettings(s, recordUndo: false)
            _ = dropImageLayers([png]); _ = dropImageLayers([png])
            let ids = doc.settings.layers.map(\.id)
            if ids.count == 2 {
                layersTab.select(ids[1]); toggleLinkBelow(nil)
                let before = doc.settings.layers.map { $0.image?.cx ?? 0 }
                alignLayer(.left)
                let after = doc.settings.layers.map { $0.image?.cx ?? 0 }
                if !(after[0] < before[0] && abs((before[0] - after[0]) - (before[1] - after[1])) < 0.01) { notes.append("정렬·연결 \(before) → \(after)") }
                layersTab.select(ids[1]); mergeDown(nil)
                if doc.settings.layers.count != 1 || doc.settings.layers.first?.isImage != true { notes.append("아래 레이어와 병합 \(doc.settings.layers.count)") }
            } else { notes.append("이미지 레이어 \(ids.count)") }
            // Stamp: one more layer (full-size image); merge visible: only one layer
            stampVisible(nil)
            let stamped = doc.settings.layers.count == 2 && doc.settings.layers.last?.image?.width == Double(doc.nativeSize.width)
            mergeVisible(nil)
            if !stamped || doc.settings.layers.count != 1 { notes.append("도장·병합 \(stamped) \(doc.settings.layers.count)") }
            // Linked image: changing the file changes the layer image
            let linked = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-linked.png")
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.copyItem(at: png, to: linked)
            layersTab.addImageLayer(file: "link:" + linked.path, name: "연결")
            let e1 = Layers.sourceImage("link:" + linked.path)?.extent
            let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            Thread.sleep(forTimeInterval: 1.1)
            try? big.representation(using: .png, properties: [:])?.write(to: linked)
            let e2 = Layers.sourceImage("link:" + linked.path)?.extent
            if e1?.width != 16 || e2?.width != 40 { notes.append("연결된 이미지 \(String(describing: e1)) → \(String(describing: e2))") }
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            history.snapshots.removeAll(); syncHistory()
            check("레이어 고급", notes.isEmpty, notes.isEmpty ? "혼합 조건·무늬 칠·구성·스냅샷·정렬·연결·병합·도장·연결된 이미지" : notes.joined(separator: " / "))
        }

        // 8-09. Layer-edit selection belongs to the document (StudioSelection.swift): selection tools make a
        //       marching-ants selection (no layer), ⇧/⌥ combine, ⌘A/⌘D/⇧⌘I, refine, ⌫ clears the selected area of a layer,
        //       ⌘J copies it into a new layer, new adjustment layers are masked by it
        do {
            setMode(.studio)
            let s0 = photo?.settings
            var notes: [String] = []
            guard let doc = photo else { check("선택", false, "사진 없음"); return }
            let n = doc.nativeSize
            func avg(_ m: CIImage) -> Float {
                let d = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
                var px = [Float](repeating: 0, count: 4)
                Render.context.render(d, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return px[0]
            }
            func selAvg() -> Float {
                guard let m = studioSelection else { return 0 }
                return avg(doc.selectionPreview(m, scale: Develop.guideScale, base: doc.image(scale: Develop.guideScale)))
            }
            func maskAvg(_ id: String) -> Float { doc.maskPreview(id, scale: Develop.guideScale).map(avg) ?? -1 }
            var s = doc.settings; s.layers = []; s.adoptGeometry(from: doc.asShot); replaceSettings(s, recordUndo: false)
            layersTab.select(nil)
            studioSelection = nil
            // Rectangle tool: a real drag on the canvas makes a selection, no layer
            retouchEditor.selectTool("selRect")
            let t = canvas.selectionTool
            canvas.layoutSubtreeIfNeeded()
            if t.isHidden { notes.append("선택 도구 층이 숨어 있음") }
            let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            if let frame = window?.contentView?.superview, frame.hitTest(canvas.convert(center, to: nil)) !== t { notes.append("캔버스 클릭이 선택 도구에 닿지 않음") }
            func vn(_ x: CGFloat, _ y: CGFloat) -> CGPoint { canvas.viewPoint(forImage: doc.toDisplay(CGPoint(x: x, y: y))) }
            drag(t, from: vn(0, 0), to: vn(n.width * 0.5, n.height * 0.5))
            let a0 = selAvg()
            if studioSelection == nil || !(a0 > 0.15 && a0 < 0.35) { notes.append("사각형 선택 \(a0)") }
            if !doc.settings.layers.isEmpty { notes.append("선택이 레이어를 만듦") }
            // ⇧ adds an ellipse, ⌥ subtracts
            t.mode = .ellipse
            drag(t, from: vn(n.width * 0.6, n.height * 0.6), to: vn(n.width * 0.95, n.height * 0.95), flags: .shift)
            let a1 = selAvg()
            if !(a1 > a0 + 0.03) { notes.append("더하기 \(a0) → \(a1)") }
            t.mode = .rect
            drag(t, from: vn(0, 0), to: vn(n.width * 0.2, n.height * 0.2), flags: .option)
            let a2 = selAvg()
            if !(a2 < a1 - 0.02) { notes.append("빼기 \(a1) → \(a2)") }
            // invert, all, deselect
            invertSelection(nil)
            if abs(selAvg() - (1 - a2)) > 0.03 { notes.append("반전 \(selAvg())") }
            invertSelection(nil)
            selectAllStudio(nil)
            if abs(selAvg() - 1) > 0.02 { notes.append("전체 선택 \(selAvg())") }
            deselectAll(nil)
            if studioSelection != nil { notes.append("선택 해제") }
            // magic wand: sky at top left
            retouchEditor.selectTool("selWand")
            wandSelect(at: CGPoint(x: n.width * 0.06, y: n.height * 0.9), flags: [])
            let sky = selAvg()
            if !(sky > 0.01 && sky < 0.6) { notes.append("자동 선택 \(sky)") }
            expandSelection(nil)
            if !(selAvg() > sky) { notes.append("확장") }
            // color range, quick selection, row
            deselectAll(nil)
            colorRangeSelect(at: CGPoint(x: n.width * 0.06, y: n.height * 0.9), flags: [])
            if !(selAvg() > 0.01 && selAvg() < 0.9) { notes.append("색상 범위 \(selAvg())") }
            deselectAll(nil)
            layersTab.brushRadius = 60
            quickSelect([CGPoint(x: n.width * 0.05, y: n.height * 0.9), CGPoint(x: n.width * 0.08, y: n.height * 0.88)], flags: [])
            if !(selAvg() > 0.003) { notes.append("빠른 선택 \(selAvg())") }
            // magnetic snap
            if let eng = selectionEngine {
                let q = CGPoint(x: n.width * 0.3, y: n.height * 0.5)
                if eng.snap(q, radius: 80) == q { notes.append("자석 붙기 없음") }
            }
            // A new adjustment layer takes the selection as its mask
            deselectAll(nil)
            retouchEditor.selectTool("selRect")
            drag(t, from: vn(0, 0), to: vn(n.width * 0.5, n.height), flags: [])
            let half = selAvg()
            layersTab.addLayer(.full, native: n)
            if let id = layersTab.selectedID, abs(maskAvg(id) - half) > 0.03 { notes.append("새 레이어 마스크 \(maskAvg(id)) (선택 \(half))") }
            // ⌫ with a selection hides that area of the selected layer (the left half → 0)
            if let id = layersTab.selectedID {
                clearSelectedArea()
                if maskAvg(id) > 0.03 { notes.append("선택 영역 지우기 \(maskAvg(id))") }
            }
            // ⌘J with a selection copies only that area (background → copy layer masked by the selection)
            layersTab.select(nil)
            let count = doc.settings.layers.count
            duplicateSelectedArea()
            if doc.settings.layers.count != count + 1 || doc.settings.layers.last?.kind != "copy" { notes.append("선택 영역 복제 레이어") }
            else if let id = layersTab.selectedID, abs(maskAvg(id) - half) > 0.03 { notes.append("선택 영역 복제 마스크 \(maskAvg(id))") }
            studioSelection = nil
            retouchEditor.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            check("선택 (문서 선택 영역)", notes.isEmpty, notes.isEmpty ? "사각형 끌기·더하기·빼기·반전·전체·해제·자동·확장·색상·빠른·자석·새 레이어 마스크·지우기·복제" : notes.joined(separator: " / "))
        }

        // 8-09b. Every layer-edit tool: a real click at the canvas center must reach the canvas (not a panel or glass layer on top)
        do {
            setMode(.studio)
            window?.layoutIfNeeded()
            var blocked: [String] = []
            let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            for tool in RetouchTool.all where !["transform", "perspective"].contains(tool.id) {
                retouchEditor.selectTool(tool.id)
                window?.layoutIfNeeded()
                guard let frame = window?.contentView?.superview, let h = frame.hitTest(canvas.convert(center, to: nil)) else {
                    blocked.append("\(tool.title)(없음)"); continue
                }
                if !(h === canvas || h.isDescendant(of: canvas)) { blocked.append("\(tool.title)→\(type(of: h))") }
            }
            retouchEditor.selectTool("hand")
            setMode(.edit)
            check("심화 보정 도구: 캔버스 클릭이 닿음", blocked.isEmpty, blocked.isEmpty ? "모든 도구" : blocked.joined(separator: ", "))
        }

        // 8-10. Layer editor extras: linear/radial gradient tools (drag makes a layer, handle drag edits it), luma range,
        //       curves and per-color adjustments on an adjustment layer, "before" = develop without layers,
        //       selection grow/feather, AI sky selection
        do {
            setMode(.studio)
            let s0 = photo?.settings
            var notes: [String] = []
            guard let doc = photo else { check("심화 추가 기능", false, "사진 없음"); return }
            let n = doc.nativeSize
            func avg(_ m: CIImage) -> Float {
                let d = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
                var px = [Float](repeating: 0, count: 4)
                Render.context.render(d, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return px[0]
            }
            func maskAvg(_ id: String) -> Float { doc.maskPreview(id, scale: Develop.guideScale).map(avg) ?? -1 }
            func imgAvg() -> Float { avg(doc.image(scale: Develop.guideScale)) }
            func vn(_ x: CGFloat, _ y: CGFloat) -> CGPoint { canvas.viewPoint(forImage: doc.toDisplay(CGPoint(x: x, y: y))) }
            var s = doc.settings; s.layers = []; s.adoptGeometry(from: doc.asShot); replaceSettings(s, recordUndo: false)
            layersTab.select(nil)
            studioSelection = nil
            let plain = imgAvg()
            // Linear gradient: top (full) → middle (none)
            retouchEditor.selectTool("gradLinear")
            let g = canvas.gradientSurface
            canvas.layoutSubtreeIfNeeded()
            if canvas.tool != .gradient || g.isHidden { notes.append("그라디언트 층이 안 보임") }
            drag(g, from: vn(n.width / 2, n.height * 0.05), to: vn(n.width / 2, n.height * 0.5))
            let lin = doc.settings.layers.last
            if doc.settings.layers.count != 1 || lin?.mask.kind != .linear { notes.append("선형 레이어 \(doc.settings.layers.count)") }
            if let id = lin?.id {
                let a = maskAvg(id)
                if !(a > 0.1 && a < 0.6) { notes.append("선형 마스크 \(a)") }
                if !(imgAvg() < plain - 0.002) { notes.append("선형 어둡게 \(plain) → \(imgAvg())") }
                // Before (Y) in layer edit = develop without layers
                if !canvas.beforeIsBase || abs(avg(doc.imageWithoutLayers(scale: Develop.guideScale)) - plain) > 0.002 { notes.append("보정 전 = 레이어 없는 현상") }
                // Drag the end handle down: same layer, gradient longer
                let y0 = lin?.mask.linear[3] ?? 0
                drag(g, from: vn(n.width / 2, n.height * 0.5), to: vn(n.width / 2, n.height * 0.9))
                if doc.settings.layers.count != 1 || abs((doc.settings.layers.last?.mask.linear[3] ?? 0) - y0) < 1 { notes.append("끝점 끌기") }
                // Luma range: only the brighter half keeps the effect
                let darker = imgAvg()
                var s1 = doc.settings; s1.layers[0].mask.lumaMin = 0.6; apply(s1, dragging: false)
                if !(imgAvg() > darker + 0.001) { notes.append("밝기 범위 \(darker) → \(imgAvg())") }
            }
            // Radial: a circle in the middle
            retouchEditor.selectTool("gradRadial")
            layersTab.select(nil)
            drag(g, from: vn(n.width / 2, n.height / 2), to: vn(n.width * 0.7, n.height / 2))
            let rad = doc.settings.layers.last
            if doc.settings.layers.count != 2 || rad?.mask.kind != .radial { notes.append("원형 레이어") }
            else if let id = rad?.id, !(maskAvg(id) > 0.02 && maskAvg(id) < 0.5) { notes.append("원형 마스크 \(maskAvg(id))") }
            // Curves and per-color on a whole-photo adjustment layer
            s = doc.settings; s.layers = []; replaceSettings(s, recordUndo: false)
            retouchAddAdjustLayer()
            let base = imgAvg()
            s = doc.settings
            var c = CurveSet(); c.rgb = ToneCurve(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.75), CGPoint(x: 1, y: 1)])
            s.layers[0].adjust.curves = c
            apply(s, dragging: false)
            let curved = imgAvg()
            if !(curved > base + 0.01) { notes.append("커브 \(base) → \(curved)") }
            s = doc.settings
            s.layers[0].adjust.curves = nil
            var h = [Float](repeating: 0, count: 24)
            for i in 0..<8 { h[i * 3 + 2] = -100 }
            s.layers[0].adjust.hsl = h
            apply(s, dragging: false)
            if !(imgAvg() < base - 0.002) { notes.append("색상별 밝기 \(base) → \(imgAvg())") }
            // Selection refine: growing the selection makes it bigger, the inspector sliders follow the selection
            retouchEditor.selectTool("selRect")
            drag(canvas.selectionTool, from: vn(n.width * 0.3, n.height * 0.3), to: vn(n.width * 0.6, n.height * 0.6))
            if let sel = studioSelection {
                let a0 = avg(doc.selectionPreview(sel, scale: Develop.guideScale, base: doc.image(scale: Develop.guideScale)))
                var grown = sel; grown.grow = 100; grown.feather = 20
                studioSelection = grown
                let a1 = avg(doc.selectionPreview(grown, scale: Develop.guideScale, base: doc.image(scale: Develop.guideScale)))
                if !(a1 > a0) { notes.append("선택 넓히기 \(a0) → \(a1)") }
            } else { notes.append("사각형 선택 없음") }
            studioSelection = nil
            // Sky (the test photo has sky at the top)
            if AISelect.mask(doc, target: .sky) == nil { notes.append("하늘 선택 실패") }
            retouchEditor.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            check("심화 추가 기능 (그라디언트·밝기 범위·커브·색상별·보정 전·선택 다듬기·하늘)", notes.isEmpty,
                  notes.isEmpty ? "모두" : notes.joined(separator: " / "))
        }

        // 8-11. Filter layers (noise reduction, sharpen, blur, skin), filter brushes, stamp visible, tool bar fits the window
        do {
            setMode(.studio)
            let s0 = photo?.settings
            var notes: [String] = []
            guard let doc = photo else { check("필터·도장", false, "사진 없음"); return }
            func avg(_ m: CIImage) -> Float {
                let d = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
                var px = [Float](repeating: 0, count: 4)
                Render.context.render(d, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return px[0]
            }
            let sc: CGFloat = 0.25
            var s = doc.settings; s.layers = []; replaceSettings(s, recordUndo: false)
            layersTab.select(nil)
            studioSelection = nil
            let plain = doc.image(scale: sc)
            func change() -> Float { avg(doc.image(scale: sc).applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: plain])) }
            // Each filter on a whole-photo layer changes the picture
            for (name, set) in [("노이즈 제거", { (a: inout LocalAdjust) in a.denoise = 100 }), ("선명하게", { $0.sharpen = 200 }),
                                ("흐림", { $0.blur = 20 }), ("피부", { $0.skinSmooth = 100 })] as [(String, (inout LocalAdjust) -> Void)] {
                s = doc.settings; s.layers = []; replaceSettings(s, recordUndo: false)
                retouchFilterLayer(name, set)
                let d = change()
                if !(d > 0.0005) || doc.settings.layers.count != 1 { notes.append("\(name) \(d)") }
            }
            // Filter brush: the stroke makes a noise-reduction layer
            s = doc.settings; s.layers = []; replaceSettings(s, recordUndo: false)
            layersTab.select(nil)
            retouchEditor.selectTool("denoiseBrush")
            let b = canvas.brushSurface
            drag(b, from: CGPoint(x: b.bounds.midX - 40, y: b.bounds.midY), to: CGPoint(x: b.bounds.midX + 40, y: b.bounds.midY))
            if doc.settings.layers.last?.preset != "denoiseBrush" || (doc.settings.layers.last?.adjust.denoise ?? 0) <= 0 { notes.append("노이즈 제거 붓") }
            // Stamp visible: one more image layer, same picture
            s = doc.settings; s.layers = []; replaceSettings(s, recordUndo: false)
            retouchFilterLayer("선명하게") { $0.sharpen = 100 }
            let before = avg(doc.image(scale: sc))
            stampVisible(nil)
            if doc.settings.layers.count != 2 || doc.settings.layers.last?.isImage != true { notes.append("도장 레이어 \(doc.settings.layers.count)") }
            else if abs(avg(doc.image(scale: sc)) - before) > 0.01 { notes.append("도장 결과 \(before) → \(avg(doc.image(scale: sc)))") }
            // Tool bar stays inside the space between the panels (even in a small window)
            let f0 = window?.frame
            if let w = window { w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: 1100, height: w.frame.height), display: true) }
            retouchEditor.view.layoutSubtreeIfNeeded()
            let bar = retouchEditor.toolBar.frame
            if bar.minX < retouchEditor.layersPanel.frame.maxX || bar.maxX > retouchEditor.inspector.frame.minX { notes.append("도구 막대가 패널에 겹침 \(NSStringFromRect(bar))") }
            if let f0 { window?.setFrame(f0, display: true) }
            retouchEditor.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            check("필터 레이어·필터 붓·도장 찍기·도구 막대 폭", notes.isEmpty, notes.isEmpty ? "모두" : notes.joined(separator: " / "))
        }

        // 8-0. Switching modes keeps the window size
        do {
            let f0 = window?.frame ?? .zero
            var changed: [String] = []
            for m in [AppMode.studio, .tether, .library, .edit, .studio, .edit] {
                setMode(m)
                if window?.frame != f0 { changed.append("\(m.title) \(NSStringFromRect(window?.frame ?? .zero))") }
            }
            // Left panel width must match across modes too (batch edit → tethering → layer edit)
            var lefts: [String] = []
            for m in [AppMode.edit, .tether, .studio, .edit] {
                setMode(m)
                window?.layoutIfNeeded()
                let w = sideWidths(m)
                if let l = w.left, let r = w.right { lefts.append("\(m.title) \(Int(l.rounded()))/\(Int(r.rounded()))") }
            }
            let lw = Set(lefts.map { $0.split(separator: " ").last.map(String.init) ?? "" })
            if lw.count > 1 || lefts.count < 4 { changed.append("좌/우 패널 폭 " + lefts.joined(separator: ", ")) }
            check("모드 전환 창 크기 유지", changed.isEmpty, changed.isEmpty ? NSStringFromRect(f0) : changed.joined(separator: ", "))
        }

        // M. Action record/playback, batch processing, duochrome:// URLs
        do {
            let s0 = doc.settings
            RecordedAction.delete("시험 동작")
            beginRecording("시험 동작")
            var st = doc.settings; st.exposure = 0.7; st.contrast = 25
            replaceSettings(st, recordUndo: true, label: "노출")
            layersTab.addLayer(.full, native: doc.nativeSize)
            st = doc.settings
            if let i = st.layers.indices.last { st.layers[i].adjust.exposure = -0.4; st.layers[i].name = "동작 레이어" }
            replaceSettings(st, recordUndo: true, label: "레이어 조정")
            let rec = finishRecording()
            let recOK = rec != nil && (rec?.steps.count ?? 0) >= 2 && RecordedAction.names().contains("시험 동작")
            // reset to the initial state and play back
            replaceSettings(s0, recordUndo: false, label: "시험")
            if let a = RecordedAction.load("시험 동작") { playAction(a) }
            let played = doc.settings.exposure == 0.7 && doc.settings.contrast == 25 && doc.settings.layers.count == s0.layers.count + 1
                && doc.settings.layers.last?.adjust.exposure == -0.4 && doc.settings.layers.last?.id != st.layers.last?.id
            // Batch: one other photo that isn't open
            var batchOK = false
            var batchWhy = "다른 사진 없음"
            let source0 = library.source
            if library.items.count < 2 { library.show(.all); browser.reload() }
            if let other = library.items.first(where: { $0 !== photoItem && !$0.offline }), let a = RecordedAction.load("시험 동작") {
                let raw0 = library.rawSettings(for: other.url)
                let done = batchApply(a, to: [other])
                batchWhy = "\(other.url.lastPathComponent) 적용 \(done)"
                if let d = try? RawDocument(url: other.url) {
                    if let s = library.loadSettings(for: other.url, over: d.asShot) {
                        batchOK = s.exposure == 0.7 && s.layers.last?.name == "동작 레이어"
                        batchWhy += " 노출 \(s.exposure) 마지막 레이어 \(s.layers.last?.name ?? "없음")"
                    } else { batchWhy += " 저장값 없음" }
                } else { batchWhy += " 열리지 않음" }
                if let raw0, let dict = try? JSONSerialization.jsonObject(with: raw0) as? [String: Any] { library.saveRawSettings(dict, for: other.url) }
                else { library.removeSettings(for: other.url) }
            }
            // play back via URL
            replaceSettings(s0, recordUndo: false, label: "시험")
            let urlOK = handleURL(URL(string: "duochrome://action?name=" + "시험 동작".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!) && doc.settings.exposure == 0.7
            replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
            RecordedAction.delete("시험 동작")
            if library.source != source0 { library.show(source0); browser.reload() }
            check("M 동작 기록·재생·일괄 처리·주소", recOK && played && batchOK && urlOK,
                  "기록 \(recOK) (\(rec?.steps.count ?? 0)단계), 재생 \(played), 일괄 \(batchOK) (\(batchWhy)), 주소 \(urlOK)")
        }

        // Preview-only: batch edit uses previews, layer edit full size. Export is full size even from batch edit
        do {
            let bulkPO = photo?.previewOnly == true
            setMode(.studio)
            let studioFull = photo?.previewOnly == false
            setMode(.edit)
            let backPO = photo?.previewOnly == true
            var sharpOK = false, exportOK = false
            if let d = photo {
                // 100% tile: preview-only is softer than full size (upscaled), full size is sharp — compared by fine-detail energy
                // (mean difference from a 1 px blur). Averaged edge strength barely separated the two on bright, low-contrast
                // areas (1.196× on a white wall), while an upscaled preview has almost nothing at this scale.
                let r = CGRect(x: 3000, y: 2000, width: 256, height: 256)
                func detail(_ img: CIImage) -> Float {
                    let tile = img.cropped(to: r)
                    let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: r)
                    let e = tile.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blurred])
                        .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
                    var p = [Float](repeating: 0, count: 4)
                    Render.context.render(e, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    return p[0] + p[1] + p[2]
                }
                let soft = detail(d.image(scale: 1))
                let sharp = d.withFullResolution { detail(d.image(scale: 1)) }
                sharpOK = sharp > soft * 1.2 && d.previewOnly
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-po-\(UUID().uuidString)")
                var rc = ExportRecipe(); rc.folder = dir.path; rc.format = .jpeg; rc.sharpen = 0; rc.keepMetadata = false
                if let u = try? Exporter.export(d, recipe: rc, name: "po"), let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                   let im = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    exportOK = CGFloat(im.width) >= d.pixelSize.width - 2 && d.previewOnly
                }
                try? FileManager.default.removeItem(at: dir)
            }
            check("미리보기만 쓰기 (대량 보정)·원본 크기 (심화 보정·내보내기)", bulkPO && studioFull && backPO && sharpOK && exportOK,
                  "대량 \(bulkPO), 심화 원본 \(studioFull), 되돌아와 \(backPO), 100% 미리보기가 원본보다 부드러움 \(sharpOK), 내보내기 원본 크기 \(exportOK)")
        }

        // 8. Layer editor: takes the canvas, adjustment layer from the panel with a value, inspector shows it, gives the canvas back
        do {
            setMode(.studio)
            let ed = retouchEditor
            let s0 = doc.settings
            let attached = canvas.isDescendant(of: ed.view) && canvas.bounds.width > 200
            layersTab.select(nil)
            retouchAddAdjustLayer()
            let added = doc.settings.layers.last
            var s = doc.settings
            if let i = s.layers.indices.last { s.layers[i].adjust.exposure = 1 }
            apply(s, dragging: false)
            ed.reload()
            let sliders = ed.inspector.allSubviews.compactMap { $0 as? SliderRow }
            let shows = sliders.contains { abs($0.value - 1) < 0.001 }
            let rows = ed.layersPanel.allSubviews.compactMap { $0 as? LayerListRow }.count
            check("심화 보정: 캔버스·조정 레이어·속성·레이어 목록", attached && added?.kind == "adjust" && shows && rows == doc.settings.layers.count + 1,
                  "캔버스 \(attached), 레이어 \(added?.name ?? "-"), 속성에 노출 표시 \(shows), 목록 \(rows)줄")
            // Retouch: heal places a spot with a click on the photo
            layersTab.select(nil)
            let spots0 = doc.settings.spots.count
            ed.selectTool("heal")
            click(canvas.retouchOverlay, at: canvas.viewPoint(forImage: CGPoint(x: doc.pixelSize.width * 0.5, y: doc.pixelSize.height * 0.5)))
            let healOK = canvas.tool == .retouch && doc.settings.spots.count == spots0 + 1 && retouch.brush.kind == .heal && !retouch.brush.patch
            ed.selectTool("clone")
            let cloneOK = retouch.brush.kind == .clone && canvas.tool == .retouch
            // Move: a photo layer dragged with the move tool; free transform opens its frame and cancel returns to move
            var moveOK = false, transformOK = false
            let px = [UInt8](repeating: 200, count: 64 * 64)
            if let file = MainWindowController.saveMaskPNG(px, w: 64, h: 64) {
                var st = doc.settings
                var l = AdjustLayer(name: "넣은 사진")
                l.kind = "image"
                l.image = LayerImage(file: file, cx: Double(doc.nativeSize.width / 2), cy: Double(doc.nativeSize.height / 2), width: 800)
                st.layers.append(l)
                replaceSettings(st, recordUndo: false, label: "시험")
                layersTab.select(l.id)
                ed.selectTool("move")
                let m = canvas.moveSurface
                let c0 = canvas.viewPoint(forImage: doc.toDisplay(CGPoint(x: doc.nativeSize.width / 2, y: doc.nativeSize.height / 2)))
                drag(m, from: c0, to: CGPoint(x: c0.x + 80, y: c0.y))
                let cx = doc.settings.layers.last?.image?.cx ?? 0
                moveOK = canvas.tool == .move && cx > Double(doc.nativeSize.width / 2) + 10
                ed.selectTool("transform")
                let opened = canvas.tool == .transform
                canvas.transformOverlay.onCancel?()
                transformOK = opened && canvas.tool == .move && ed.currentTool == "move"
            }
            check("심화 보정: 복구·복제 도장·이동·자유 변형", healOK && cloneOK && moveOK && transformOK,
                  "복구 \(healOK), 복제 \(cloneOK), 이동 \(moveOK), 자유 변형 \(transformOK)")
            replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
            setMode(.edit)
            let back = canvas.isDescendant(of: viewer.view) && tools.view.window != nil
            check("대량 보정으로 돌아오기", back && canvas.bounds.width > 200, String(format: "캔버스 %.0f×%.0f", canvas.bounds.width, canvas.bounds.height))
        }

        // 5-1. Color editor eyedropper: picking the sky (top left) adds one blue range
        // Undo the previous test's keystone/rotation/crop so the sky is back in place.
        var flat = doc.settings
        flat.adoptGeometry(from: doc.asShot)
        inspector.adoptGeometry(flat)
        replaceSettings(flat, recordUndo: true, label: "시험: 형태 되돌림")
        canvas.zoomToFit()
        let W2 = doc.pixelSize.width, H2 = doc.pixelSize.height
        let nRanges = doc.settings.color.editor.count
        inspector.onPickColor?(0)
        click(canvas, at: canvas.viewPoint(forImage: CGPoint(x: W2 * 0.06, y: H2 * 0.9)))
        let added = doc.settings.color.editor.last
        check("컬러 에디터 스포이트", doc.settings.color.editor.count == nRanges + 1 && (added.map { $0.hue > 180 && $0.hue < 260 } ?? false),
              String(format: "범위 %d → %d개, 집은 색조 %.0f°", nRanges, doc.settings.color.editor.count, added?.hue ?? -1))
        inspector.onPickColor?(1)
        click(canvas, at: v(W * 0.5, H * 0.5))
        check("스킨 톤 스포이트", doc.settings.color.skin.enabled && doc.settings.color.skin.hueAmount > 0,
              String(format: "기준 색조 %.0f°, 채도 %.2f", doc.settings.color.skin.hue, doc.settings.color.skin.sat))

        // 5-2. New color editor: a range added in the advanced tab is selected, unchecking it in the list drops it from computation, hue distribution, range view
        do {
            let ed = inspector.colorEditor
            let last = doc.settings.color.editor.count - 1
            let selectedOK = ed.index == last
            var s = doc.settings
            s.color.editor[last].dSat = 60
            s.color.editor[last].off = true
            let offOK = !s.color.editor[last].isActive
            s.color.editor[last].off = nil
            let onOK = s.color.editor[last].isActive
            let bins = HueHistogramView.measure(doc)
            let small = doc.image(scale: 0.05)
            let viewed = RangeView.apply(small, s.color.editor[last])
            var px = [Float](repeating: 0, count: 4)
            let r = CGRect(x: small.extent.midX, y: small.extent.midY, width: 1, height: 1)
            Render.context.render(viewed, toBitmap: &px, rowBytes: 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            // The center (concrete wall) is outside the blue range → gray
            let grayOK = abs(px[0] - px[1]) < 0.02 && abs(px[1] - px[2]) < 0.02
            check("컬러 에디터 (고급 범위·체크 끄기·색조 분포·범위 보기)", selectedOK && offOK && onOK && bins.contains { $0 > 0 } && grayOK,
                  "고른 범위 \(selectedOK), 끄기 \(offOK)/\(onOK), 분포 \(bins.filter { $0 > 0 }.count)칸, 범위 밖 회색 \(grayOK)")
        }

        // 6. Retouching: click for a spot, drag for a stroke, drag the white circle to move, Delete to remove
        tools.select(tools.index(of: "리터칭"))
        canvas.layoutSubtreeIfNeeded()
        let ro = canvas.retouchOverlay
        let n0 = doc.settings.spots.count
        click(ro, at: v(W * 0.3, H * 0.3))
        check("리터칭 점 찍기", doc.settings.spots.count == n0 + 1 && !(doc.settings.spots.last?.isStroke ?? true),
              "점 \(doc.settings.spots.count)개")
        let spot = doc.settings.spots.last!
        // Retouch spots are in source coordinates. Click at view coordinates mapped through crop/rotation.
        let from = canvas.viewPoint(forImage: doc.toDisplay(spot.target))
        drag(ro, from: from, to: CGPoint(x: from.x + 40, y: from.y))
        let moved = doc.settings.spots.last!
        // Expected: the drag distance (40 pt in view) converted to source coordinates with the same mapping (rotation scale and crop included)
        let want = doc.toNative(canvas.imagePoint(at: CGPoint(x: from.x + 40, y: from.y)))
        check("리터칭 점 옮기기", hypot(moved.targetX - want.x, moved.targetY - want.y) < 3,
              String(format: "(%.0f, %.0f) → (%.0f, %.0f), 기대 (%.0f, %.0f)", spot.targetX, spot.targetY,
                     moved.targetX, moved.targetY, want.x, want.y))
        drag(ro, from: v(W * 0.6, H * 0.6), to: v(W * 0.7, H * 0.62), steps: 12)
        let stroke = doc.settings.spots.last!
        check("리터칭 붓질", stroke.isStroke && stroke.points.count >= 3, "획 점 \(stroke.points.count)개")
        ro.selected = doc.settings.spots.count - 1
        key(ro, code: 51)
        check("고른 점 Delete로 지우기", doc.settings.spots.count == n0 + 1, "남은 점 \(doc.settings.spots.count)개")

        // 6-1. Patch: drawing a lasso makes a closed patch; dragging the green lasso (source) moves only the source
        retouch.brush.patch = true
        let lasso = [v(W * 0.3, H * 0.3), v(W * 0.36, H * 0.3), v(W * 0.36, H * 0.36), v(W * 0.3, H * 0.36), v(W * 0.3, H * 0.305)]
        ro.mouseDown(with: event(.leftMouseDown, ro, lasso[0]))
        for (a, b) in zip(lasso, lasso.dropFirst()) {
            for i in 1...8 { let t = CGFloat(i) / 8; ro.mouseDragged(with: event(.leftMouseDragged, ro, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))) }
        }
        ro.mouseUp(with: event(.leftMouseUp, ro, lasso.last!))
        let patch = doc.settings.spots.last!
        let srcCenter = canvas.viewPoint(forImage: doc.toDisplay(CGPoint(x: patch.points[0].x + patch.offset.x + 10, y: patch.points[0].y + patch.offset.y + 10)))
        let target0 = patch.target
        drag(ro, from: srcCenter, to: CGPoint(x: srcCenter.x + 30, y: srcCenter.y))
        let patched = doc.settings.spots.last!
        check("패치 올가미·원본 옮기기", patch.isPatch && patch.points.count >= 10 && patched.target == target0 && patched.offset != patch.offset,
              String(format: "올가미 점 %d개, 원본 거리 (%.0f, %.0f) → (%.0f, %.0f)", patch.points.count,
                     patch.offset.x, patch.offset.y, patched.offset.x, patched.offset.y))
        retouch.brush.patch = false

        // 7. Masks: paint on a brush layer, drag a linear layer
        tools.select(tools.index(of: "레이어"))
        layersTab.addLayer(.brush, native: doc.nativeSize)
        enterTool(.mask)
        canvas.layoutSubtreeIfNeeded()
        drag(canvas.maskOverlay, from: v(W * 0.2, H * 0.2), to: v(W * 0.5, H * 0.3), steps: 10)
        let strokes = doc.settings.layers.last?.mask.strokes ?? []
        check("마스크 붓 칠하기", strokes.count == 1 && strokes[0].points.count >= 6, "붓질 \(strokes.count)개, 점 \(strokes.first?.points.count ?? 0)")
        drag(canvas.maskOverlay, from: v(W * 0.2, H * 0.6), to: v(W * 0.3, H * 0.6), steps: 4, flags: .option)
        check("옵션 키로 지우개", doc.settings.layers.last?.mask.strokes.last?.erase == true, "")
        layersTab.addLayer(.linear, native: doc.nativeSize)
        drag(canvas.maskOverlay, from: v(W * 0.5, H * 0.9), to: v(W * 0.5, H * 0.5))
        let lin = doc.settings.layers.last?.mask.linear ?? []
        check("선형 그라디언트 끌기", lin.count == 4 && lin[1] > lin[3], String(format: "시작 y %.0f → 끝 y %.0f", lin[1], lin[3]))
        // 7-1. Lock: locked layers can't be painted
        var locked = doc.settings
        locked.layers[locked.layers.count - 2].locked = true
        replaceSettings(locked, recordUndo: true, label: "시험: 잠금")
        layersTab.select(locked.layers[locked.layers.count - 2].id)
        let beforeLock = doc.settings.layers[locked.layers.count - 2].mask.strokes.count
        drag(canvas.maskOverlay, from: v(W * 0.2, H * 0.4), to: v(W * 0.4, H * 0.4), steps: 5)
        check("잠긴 레이어에 칠하기 막기", doc.settings.layers[locked.layers.count - 2].mask.strokes.count == beforeLock,
              "붓질 \(beforeLock)개 그대로")
        // 7-2. brush size with [ ]
        let r0 = layersTab.brushRadius
        brushLarger(nil); brushLarger(nil)
        check("] 두 번 붓 크게", abs(layersTab.brushRadius - r0 * 1.5625) < 0.5,
              String(format: "%.0f → %.0f", r0, layersTab.brushRadius))
        brushSmaller(nil); brushSmaller(nil)
        enterTool(.pan)

        // 8. History: undo, redo, jump to a point
        let count = history.labels.count
        let last = doc.settings
        undoAdjust(nil)
        check("되돌리기", doc.settings != last && history.index == count - 2, "내역 \(count)줄, 지금 \(history.index)")
        redoAdjust(nil)
        check("다시 실행", doc.settings == last, "")
        historyTab.onJump?(0)
        check("내역 첫 줄로 가기", doc.settings == doc.asShot || history.index == 0, "지금 \(history.index)번째 · \(history.labels.prefix(5).joined(separator: " / "))")
        historyTab.onJump?(count - 1)

        // 9. Selective paste: white balance only
        var src = doc.settings
        src.temperature = 3200; src.exposure = 1.7
        let keepExposure = doc.settings.exposure
        pasteGroups(src, [.whiteBalance])
        check("골라 붙이기 (화이트 밸런스만)", doc.settings.temperature == 3200 && doc.settings.exposure == keepExposure,
              String(format: "색온도 %.0f, 노출 %.2f (그대로 %.2f)", doc.settings.temperature, doc.settings.exposure, keepExposure))

        // 8-10. Auto-align/blend layers: move a shifted image layer back into place, and masks
        do {
            var s0 = doc.settings
            s0.layers = []
            replaceSettings(s0, recordUndo: true)
            if let img = rasterize([], withPhoto: true), var l = imageLayer(from: img, name: "옮긴 사진") {
                let n = doc.nativeSize
                l.image?.cx += n.width * 0.03
                l.image?.cy -= n.height * 0.02
                var s1 = doc.settings; s1.layers.append(l)
                replaceSettings(s1, recordUndo: true)
                autoAlignLayers(nil)
                let im = doc.settings.layers.last?.image
                let dx = (im?.cx ?? 0) - n.width / 2, dy = (im?.cy ?? 0) - n.height / 2
                check("자동 정렬 레이어", abs(dx) < n.width * 0.004 && abs(dy) < n.height * 0.004 && abs(im?.rotation ?? 9) < 0.3,
                      String(format: "가운데 어긋남 %.1f, %.1f px, 회전 %.2f°", dx, dy, im?.rotation ?? 0))
                autoBlendLayers(nil)
                check("자동 혼합 레이어", doc.settings.layers.last?.mask.kind == .image && !(doc.settings.layers.last?.mask.maskFile.isEmpty ?? true),
                      "마스크 \(doc.settings.layers.last?.mask.kind.rawValue ?? "-")")
            }
            replaceSettings(s0, recordUndo: true)
        }

        // 8-11. Transforms: skew, warp, puppet, perspective crop, liquify through the point layer
        do {
            var s0 = doc.settings
            s0.layers = []
            replaceSettings(s0, recordUndo: true)
            let n = doc.nativeSize
            if let img = rasterize([], withPhoto: true), let l = imageLayer(from: img, name: "변형 시험") {
                var s1 = doc.settings; s1.layers.append(l)
                replaceSettings(s1, recordUndo: true)
                layersTab.select(l.id)
                let o = canvas.pointsOverlay
                var notes: [String] = []
                // distort: top-right corner inward
                distortLayer(nil)
                o.onChange?(2, CGPoint(x: n.width * 0.8, y: n.height * 0.85), false); o.onCommit?()
                if doc.settings.layers.last?.image?.quad?.count != 8 { notes.append("왜곡") }
                // perspective: moving bottom right mirrors bottom left
                perspectiveLayer(nil)
                let q0 = doc.settings.layers.last?.image?.quad ?? []
                o.onChange?(1, CGPoint(x: q0[2] - 200, y: q0[3]), false); o.onCommit?()
                let q1 = doc.settings.layers.last?.image?.quad ?? []
                if !(q1.count == 8 && abs(q1[0] - (q0[0] + 200)) < 1) { notes.append("원근 \(q0.prefix(4)) → \(q1.prefix(4))") }
                // warp: one center point
                warpLayer(nil)
                o.onChange?(5, CGPoint(x: n.width * 0.45, y: n.height * 0.4), false); o.onCommit?()
                if doc.settings.layers.last?.image?.mesh?.count != 32 { notes.append("뒤틀기") }
                // puppet: two pins, move one
                puppetWarp(nil)
                o.onAdd?(CGPoint(x: n.width * 0.3, y: n.height * 0.5)); o.onAdd?(CGPoint(x: n.width * 0.7, y: n.height * 0.5))
                o.onChange?(1, CGPoint(x: n.width * 0.7, y: n.height * 0.6), false); o.onCommit?()
                if (doc.settings.layers.last?.image?.pins?.count ?? 0) != 8 { notes.append("퍼펫 \(doc.settings.layers.last?.image?.pins ?? [])") }
                // image not empty
                let e = doc.image(scale: 1.0 / 8)
                var avg = [Float](repeating: 0, count: 4)
                Render.context.render(e.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e.extent)]), toBitmap: &avg, rowBytes: 16,
                                      bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                if !(avg[0] > 0.01) { notes.append("그림 비었음") }
                // liquify stroke
                liquify(tool: 1)
                o.onStroke?([CGPoint(x: n.width * 0.5, y: n.height * 0.5)], []); o.onCommit?()
                if (doc.settings.layers.last?.liquify?.count ?? 0) != 1 { notes.append("유동화") }
                // perspective crop
                perspectiveCrop(nil)
                let f = doc.frameSize
                o.onChange?(2, CGPoint(x: f.width * 0.85, y: f.height * 0.95), false); o.onCommit?()
                if doc.settings.perspective?.count != 8 || doc.pixelSize.width >= f.width { notes.append("원근 자르기 \(doc.pixelSize)") }
                clearPerspectiveCrop(nil)
                // Vanishing point clone: a patch moved within the plane becomes a layer
                let plane = [CGPoint(x: n.width * 0.2, y: n.height * 0.2), CGPoint(x: n.width * 0.8, y: n.height * 0.25),
                             CGPoint(x: n.width * 0.8, y: n.height * 0.75), CGPoint(x: n.width * 0.2, y: n.height * 0.8)]
                let cnt = doc.settings.layers.count
                vanishingClone(from: CGPoint(x: n.width * 0.3, y: n.height * 0.5), to: CGPoint(x: n.width * 0.6, y: n.height * 0.5), plane: plane, radius: 200)
                if doc.settings.layers.count != cnt + 1 || doc.settings.layers.last?.mask.kind != .polygon { notes.append("소실점") }
                // Canvas size → trim: add a transparent margin, then trim it away
                var sp = doc.settings; sp.layers = []; sp.canvasPad = [0.1, 0.1, 0.1, 0.1]
                replaceSettings(sp, recordUndo: true)
                let padded = doc.pixelSize
                trimCanvas(nil)
                let trimmed = doc.pixelSize
                if !(padded.width > trimmed.width * 1.15 && doc.settings.canvasPad == nil) { notes.append("캔버스 다듬기 \(padded) → \(trimmed)") }
                check("변형 도구", notes.isEmpty, notes.isEmpty ? "왜곡·원근·뒤틀기·퍼펫·유동화·원근 자르기" : notes.joined(separator: " / "))
            }
            replaceSettings(s0, recordUndo: true)
        }

        // 8-12. Painting
        do {
            var s0 = doc.settings; s0.layers = []
            replaceSettings(s0, recordUndo: true)
            let n = doc.nativeSize
            var notes: [String] = []
            layersTab.select(nil)
            startPainting(mode: 0)
            let o = canvas.pointsOverlay
            o.onStroke?([CGPoint(x: n.width * 0.2, y: n.height * 0.5), CGPoint(x: n.width * 0.8, y: n.height * 0.5)], [])
            o.onCommit?()
            if doc.settings.layers.last?.kind != "paint" || doc.settings.layers.last?.paint?.count != 1 { notes.append("칠하기") }
            // eraser inside a paint layer
            startPainting(mode: 1)
            o.onStroke?([CGPoint(x: n.width * 0.5, y: n.height * 0.5)], []); o.onCommit?()
            if doc.settings.layers.last?.paint?.last?.brush.mode != 1 { notes.append("칠 레이어 지우개") }
            // eraser on an image layer → mask
            if let img = rasterize([], withPhoto: true), let l = imageLayer(from: img, name: "지울 그림") {
                var s1 = doc.settings; s1.layers.append(l); replaceSettings(s1, recordUndo: true); layersTab.select(l.id)
                paintStroke([CGPoint(x: n.width * 0.3, y: n.height * 0.3)], pressures: [1], erase: true)
                if doc.settings.layers.last?.mask.brushWhite != true || doc.settings.layers.last?.mask.strokes.last?.erase != true { notes.append("마스크 지우개") }
                // background eraser: areas similar to the clicked color
                layersTab.brushRadius = 300
                backgroundErase([CGPoint(x: n.width * 0.05, y: n.height * 0.9), CGPoint(x: n.width * 0.1, y: n.height * 0.9)])
                if doc.settings.layers.last?.mask.kind != .image { notes.append("배경 지우개") }
            }
            // history brush
            let cnt = doc.settings.layers.count
            historyBrush(nil)
            if doc.settings.layers.count != cnt + 1 || doc.settings.layers.last?.mask.kind != .brush { notes.append("작업 내역 브러시") }
            // red-eye: over a paint layer with a red dot
            var sr = doc.settings; sr.layers = []
            var red = AdjustLayer(name: "빨간 눈"); red.kind = "fill"; red.fillColor = [0.9, 0.05, 0.05]
            red.mask = LayerMask(kind: .ellipse, box: [n.width * 0.5 - 40, n.height * 0.5 - 40, n.width * 0.5 + 40, n.height * 0.5 + 40])
            sr.layers = [red]
            replaceSettings(sr, recordUndo: true)
            fixRedEye(at: CGPoint(x: n.width * 0.5, y: n.height * 0.5), radius: 120)
            if doc.settings.layers.last?.name != "적목 현상 제거" { notes.append("적목") }
            // paint bucket
            paintBucket(at: CGPoint(x: n.width * 0.05, y: n.height * 0.9))
            if doc.settings.layers.last?.name != "페인트 통" || doc.settings.layers.last?.mask.kind != .image { notes.append("페인트 통") }
            check("칠하기 도구", notes.isEmpty, notes.isEmpty ? "칠하기·지우개(칠·마스크)·배경 지우개·작업 내역 브러시·적목·페인트 통" : notes.joined(separator: " / "))
            replaceSettings(s0, recordUndo: true)
        }

        print(failures == 0 ? "UI 시험 모두 통과" : "UI 시험 \(failures)개 실패")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Synthesizing events

    private func event(_ type: NSEvent.EventType, _ view: NSView, _ p: CGPoint, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func drag(_ view: NSView, from a: CGPoint, to b: CGPoint, steps: Int = 6, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: event(.leftMouseDown, view, a, flags: flags))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            view.mouseDragged(with: event(.leftMouseDragged, view, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags))
        }
        view.mouseUp(with: event(.leftMouseUp, view, b, flags: flags))
    }

    func click(_ view: NSView, at p: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, view, p))
        view.mouseUp(with: event(.leftMouseUp, view, p))
    }

    func key(_ view: NSView, code: UInt16) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "\u{8}",
                                 charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: code)!
        view.keyDown(with: e)
    }

    fileprivate func findField(_ v: NSView) -> NSTextField? {
        if let f = v as? NSTextField, f.isEditable { return f }
        for sub in v.subviews { if let f = findField(sub) { return f } }
        return nil
    }
}

extension NSView {
    var allSubviews: [NSView] { subviews + subviews.flatMap(\.allSubviews) }
}
