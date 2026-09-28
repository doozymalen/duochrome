import AppKit

/// UI 시험 (DUOCHROME_UITEST=1): 실제 마우스 사건(누르기·끌기·떼기)을 만들어 각 뷰에 보내고 결과 설정을 확인한다.
/// 사람이 마우스로 하는 조작을 대신 확인하려고 만들었다. 결과는 표준 출력에 "통과/실패"로 찍고 끝낸다.
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

        // 캔버스 위 이미지 좌표(화면 이미지 픽셀) → 뷰 좌표
        func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { canvas.viewPoint(forImage: CGPoint(x: x, y: y)) }
        let W = doc.pixelSize.width, H = doc.pixelSize.height

        // 1. 크롭: 오른위 손잡이를 안쪽으로 끈다
        tools.select(tools.index(of: "형태"))
        enterTool(.crop)
        canvas.layoutSubtreeIfNeeded()
        let fw = doc.frameSize.width, fh = doc.frameSize.height
        drag(canvas.overlay, from: v(fw, fh), to: v(fw * 0.8, fh * 0.75))
        let c = doc.settings.crop
        check("크롭 손잡이 끌기", abs(c.w - 0.8) < 0.02 && abs(c.h - 0.75) < 0.02 && c.x == 0 && c.y == 0,
              String(format: "크롭 x %.2f y %.2f w %.3f h %.3f (0.8×0.75 기대)", c.x, c.y, c.w, c.h))
        // 가운데를 끌어 옮기기
        drag(canvas.overlay, from: v(fw * 0.4, fh * 0.4), to: v(fw * 0.5, fh * 0.45))
        let c2 = doc.settings.crop
        check("크롭 영역 옮기기", abs(c2.x - 0.1) < 0.02 && abs(c2.y - 0.05) < 0.02,
              String(format: "x %.3f y %.3f (0.1, 0.05 기대)", c2.x, c2.y))
        enterTool(.pan)

        // 2. 수평: 기울어진 선(3°)을 따라 끈다 → 회전 +3°
        let before = doc.settings.rotation
        enterTool(.straighten)
        let a = v(W * 0.2, H * 0.5), b = CGPoint(x: a.x + 300, y: a.y + 300 * tan(3 * .pi / 180))
        drag(canvas.overlay, from: a, to: b)
        check("수평 맞추기 선", abs((doc.settings.rotation - before) - 3) < 0.2,
              String(format: "회전 %.2f° → %.2f°", before, doc.settings.rotation))
        enterTool(.pan)

        // 2-1. 키스톤 선 두 개: 위로 모이는 두 선(왼쪽은 오른쪽으로, 오른쪽은 왼쪽으로 기움)
        let kvBefore = doc.settings.keystoneV
        enterTool(.keystone)
        drag(canvas.overlay, from: v(W * 0.3, H * 0.2), to: v(W * 0.33, H * 0.8))
        drag(canvas.overlay, from: v(W * 0.7, H * 0.2), to: v(W * 0.67, H * 0.8))
        check("키스톤 선 긋기", doc.settings.keystoneV > kvBefore + 5,
              String(format: "세로 키스톤 %.1f → %.1f, 회전 %.2f°", kvBefore, doc.settings.keystoneV, doc.settings.rotation))
        // 2-1b. 가로 방식: 오른쪽으로 모이는 두 선 → 가로 키스톤만 바뀐다
        shape.selectKeystoneMode(.horizontal)
        let khBefore = doc.settings.keystoneH, kv2 = doc.settings.keystoneV
        drag(canvas.overlay, from: v(W * 0.2, H * 0.3), to: v(W * 0.8, H * 0.34))
        drag(canvas.overlay, from: v(W * 0.2, H * 0.7), to: v(W * 0.8, H * 0.66))
        check("키스톤 가로 방식", abs(doc.settings.keystoneH - khBefore) > 5 && doc.settings.keystoneV == kv2 && canvas.overlay.keystoneMode == .horizontal,
              String(format: "가로 키스톤 %.1f → %.1f, 세로 그대로 %.1f", khBefore, doc.settings.keystoneH, doc.settings.keystoneV))
        shape.selectKeystoneMode(.vertical)
        enterTool(.pan)

        // 2-2. 화이트 밸런스 스포이트: 누르면 그 자리로 스포이트가 불리는지, 그 자리 계산이 값을 내는지.
        // (실제 적용은 백그라운드 계산 뒤 주 큐로 돌아오는데, 이 시험 자체가 주 큐에서 돌아서 여기서는 기다릴 수 없다.)
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

        // 3. 이동 도구로 끌기 (화면 이동)
        canvas.zoomToActual()
        let p0 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        drag(canvas, from: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY),
             to: CGPoint(x: canvas.bounds.midX + 100, y: canvas.bounds.midY))
        let p1 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        check("이동 도구 끌기", abs((p0.x - p1.x) - 100 / canvas.zoom) < 2,
              String(format: "가운데가 원본 %.0fpx 옮겨짐 (%.0f 기대)", p0.x - p1.x, 100 / canvas.zoom))
        // 트랙패드 두 손가락 이동 = 스크롤 사건
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0),
           let e = NSEvent(cgEvent: cg) {
            let q0 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            canvas.scrollWheel(with: e)
            let q1 = canvas.imagePoint(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            check("스크롤로 이동", abs(q1.x - q0.x) > 0.5 || abs(q1.y - q0.y) > 0.5,
                  String(format: "(%.1f, %.1f) → (%.1f, %.1f)", q0.x, q0.y, q1.x, q1.y))
        }
        // 트랙패드 손가락 모으기(확대) = 제스처 사건. 손가락 아래 사진 지점은 제자리에 남아야 한다.
        canvas.zoomToFit()
        if let win = canvas.window, let cg = CGEvent(source: nil) {
            let viewPt = CGPoint(x: canvas.bounds.width * 0.3, y: canvas.bounds.height * 0.6)
            let screen = win.convertPoint(toScreen: canvas.convert(viewPt, to: nil))
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            cg.type = CGEventType(rawValue: 29)!                              // 제스처
            cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)   // 확대
            cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0.25)
            cg.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
            cg.location = CGPoint(x: screen.x, y: mainH - screen.y)           // CG 좌표는 위가 0
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

        // 4. 커브: 빈 곳을 눌러 점을 만들고 위로 끈다
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

        // 5. 컬러 밸런스: 섀도 휠을 파랑(240°) 방향 끝까지
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

        // 7-1. 슬라이더: 숫자 입력, 두 번 누르면 기본값, 기본값 근처에서 달라붙기
        do {
            _ = inspector.view
            func rows(_ v: NSView) -> [SliderRow] { v.subviews.flatMap { ($0 as? SliderRow).map { [$0] } ?? rows($0) } }
            if let ex = rows(inspector.view).first(where: { $0.slider.accessibilityLabel() == "노출" }),
               let field = ex.subviews.first.flatMap({ findField($0) }) {
                field.stringValue = "1.5 EV"
                ex.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
                let typed = doc.settings.exposure
                // 두 번 누르기는 슬라이더 셀의 끌기 시작에서 받는다 (mouseDown·제스처 인식기는 실제 마우스에서 안 됐다): 셀 종류 + 그 동작
                let hasDouble = ex.slider.cell is PixelSliderCell
                if hasDouble { ex.slider.doubleClicked() }
                let reset = doc.settings.exposure
                // 달라붙기는 설정 값에 따라 다르다 → 이 시험 동안만 기본값(켜기, 1.5%)으로
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

        // 7-2. 검색·스타일·격자·자동 조정 계산·칠 레이어
        do {
            let total = library.items.count
            library.query = (doc.url.deletingPathExtension().lastPathComponent)
            let found = library.items.count
            library.query = ""
            check("사진 검색", found == 1 && library.items.count == total, "\(total)장 중 이름으로 \(found)장")

            var st = doc.settings; st.exposure = 1; st.contrast = 40
            saveStyle(named: "시험 스타일", from: st)
            let e0 = doc.settings.exposure
            applyStyle(named: "시험 스타일", strength: 0.5)
            let e1 = doc.settings.exposure, c1v = doc.settings.contrast
            check("스타일 저장·적용 (강도 50%)", abs(e1 - (e0 + (1 - e0) * 0.5)) < 0.001 && abs(c1v - 20) < 0.5 && MainWindowController.styleNames().contains("시험 스타일"),
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

        // 7-3. 레이어 우클릭 메뉴, 배경 복제(리터칭이 복제 레이어로), 자유 변형
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

            // 자유 변형: 이미지 레이어 오른위 모서리를 바깥으로 끌면 커지고, 리턴으로 확정, 되돌리기로 원래대로
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

        // 7-4. 단축키: 모드별 기본값, 바꾸기
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

        // 7-5. 레이어 단축키: 지우기(⌫)·맨 위/아래(⇧⌘]·⇧⌘[)·위/아래 고르기(⌥]·⌥[), 잠긴 레이어는 안 지워진다
        do {
            let before = doc.settings.layers.count
            for _ in 0..<3 { layersTab.addLayer(.full, native: doc.nativeSize) }
            let ids = doc.settings.layers.suffix(3).map(\.id)   // 아래 → 위
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

        // 8-00. 대량 보정 왼쪽 도구 탭을 바꿔도 창 크기·패널 폭이 그대로 (작은 창에서도)
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

        // 8-01. 심화 보정 도구를 모두 돌려도 창 크기·패널 크기가 그대로 (작은 창에서도)
        do {
            let saved = window?.frame ?? .zero
            let tool0 = studioMode.currentTool
            let settings0 = photo?.settings
            setMode(.studio)
            var changed: [String] = []
            for size in [saved.size, NSSize(width: 1000, height: 600)] {
                window?.setFrame(NSRect(origin: saved.origin, size: size), display: true)
                window?.layoutIfNeeded()
                let f0 = window?.frame ?? .zero
                let o0 = studioMode.options.frame, l0 = studioMode.layersPanel.frame
                for t in StudioTool.all where !["export", "transform"].contains(t.id) {
                    studioMode.selectTool(t.id)
                    window?.layoutIfNeeded()
                    let f = window?.frame ?? .zero
                    if f != f0 || studioMode.options.frame != o0 || studioMode.layersPanel.frame != l0 {
                        changed.append("\(t.title) 창 \(Int(f.width))×\(Int(f.height)) 옵션 \(Int(studioMode.options.frame.height))")
                    }
                }
            }
            studioMode.selectTool(tool0)
            setMode(.edit)
            window?.setFrame(saved, display: true)
            // 도구를 고르기만 해서는 조정값이 바뀌면 안 된다
            if let s0 = settings0, let s1 = photo?.settings {
                let a = settingsDict(s0), b = settingsDict(s1)
                let diff = Set(a.keys).union(b.keys).filter { k in
                    guard let x = a[k], let y = b[k] else { return true }
                    return !((x as AnyObject).isEqual(y as AnyObject))
                }.sorted()
                if !diff.isEmpty { changed.append("바뀐 조정값: " + diff.joined(separator: ", ")); replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            }
            check("심화 도구 전환 창 크기 유지", changed.isEmpty, changed.isEmpty ? "\(StudioTool.all.count - 2)개 도구 × 두 창 크기" : changed.prefix(8).joined(separator: ", "))
        }

        // 8-02. 심화 보정: 레이어가 필요한 도구는 고를 때가 아니라 캔버스를 처음 누를 때 레이어를 만든다
        do {
            let s0 = photo?.settings
            setMode(.studio)
            let st = studioMode
            let n0 = photo?.settings.layers.count ?? 0
            st.selectTool("fill")
            let afterPick = photo?.settings.layers.count ?? 0
            let mo = canvas.maskOverlay
            click(mo, at: CGPoint(x: mo.bounds.midX, y: mo.bounds.midY))
            let afterFill = photo?.settings.layers.count ?? 0
            st.selectTool("lighten")
            let afterPick2 = photo?.settings.layers.count ?? 0
            drag(mo, from: CGPoint(x: mo.bounds.midX - 60, y: mo.bounds.midY), to: CGPoint(x: mo.bounds.midX + 60, y: mo.bounds.midY), steps: 8)
            let last = photo?.settings.layers.last
            check("심화 도구: 처음 누를 때 레이어 만들기",
                  afterPick == n0 && afterFill == n0 + 1 && afterPick2 == n0 + 1
                    && photo?.settings.layers.count == n0 + 2 && last?.preset == "lighten" && (last?.mask.strokes.count ?? 0) >= 1,
                  "고름 \(n0)→\(afterPick), 칠 누름 →\(afterFill), 닷지 고름 →\(afterPick2), 붓질 →\(photo?.settings.layers.count ?? 0) (\(last?.preset ?? "-"), 획 \(last?.mask.strokes.count ?? 0))")
            st.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
        }

        // 8-03. 유리 배치: 패널 가장자리를 끌면 폭이 바뀌고, 패널을 접으면 맞춤 보기 자리가 넓어진다
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

        // 8-04. 진짜 사건 경로(창 sendEvent → hitTest → 추적 고리)로 조정 슬라이더 끌기·도구 탭 누르기.
        // 뷰에 바로 보내는 시험은 "슬라이더가 꺼져 있어 안 눌림"을 못 잡았다.
        do {
            setMode(.edit)
            tools.select(tools.index(of: "조정"))
            window?.layoutIfNeeded()
            let s0 = photo?.settings
            let sliders = inspector.view.allSubviews.compactMap { $0 as? SnapSlider }.filter { !$0.isHiddenOrHasHiddenAncestor }
            let sl = sliders.first { $0.minValue == -4 && $0.maxValue == 4 }   // 노출
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
                // 슬라이더 끌기 자체는 시험 안에서 흉내 낼 수 없다 (추적 고리가 가짜 사건을 안 받음).
                // 켜져 있는지 + 진짜 hitTest가 슬라이더에 닿는지까지만 본다. 실제 끌기는 앱에서 마우스로 확인.
                if let frame = win.contentView?.superview {
                    moved = frame.hitTest(frame.convert(p, from: nil)) === sl
                }
                _ = v0
                let tab = tools.view.allSubviews.compactMap { $0 as? TabButton }[1]
                let q = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
                // 창 틀의 시스템 누르기 인식기 때문에 가짜 사건으로는 누름이 안정적으로 안 간다.
                // 진짜 hitTest가 탭 단추(또는 그 안)에 닿는지까지 본다. 실제 누름은 앱에서 마우스로 확인함.
                if let frame = win.contentView?.superview, let h = frame.hitTest(frame.convert(q, from: nil)) {
                    tabOK = h === tab || h.isDescendant(of: tab)
                }
            }
            check("진짜 사건: 슬라이더 켜짐·닿음·탭 누르기", enabled && moved && tabOK,
                  "슬라이더 켜짐 \(enabled), hitTest 닿음 \(moved), 탭 닿음 \(tabOK)")
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            tools.select(tools.index(of: "조정"))
        }

        // 8-05. 끌어 놓기 (DragDrop.swift): 레이어 순서·그룹, Finder 그림 → 레이어, 사진 → 앨범, 사진 → 사진 조정 복사, 도구 막대 넣기
        do {
            setMode(.edit)
            let s0 = photo?.settings
            // 레이어 나무 규칙
            var ls = [AdjustLayer(name: "A"), AdjustLayer(name: "B"), AdjustLayer(name: "C")]
            ls[2].kind = "group"
            let a = ls[0].id, b = ls[1].id, g = ls[2].id
            LayerTree.drop(&ls, from: 0, onto: 2, .into)          // A를 그룹 C 안으로
            let intoOK = ls.first { $0.id == a }?.group == g && ls.firstIndex { $0.id == a }! < ls.firstIndex { $0.id == g }!
            LayerTree.drop(&ls, from: ls.firstIndex { $0.id == b }!, onto: ls.firstIndex { $0.id == g }!, .above)  // B를 그룹 위로
            let aboveOK = ls.last?.id == b && ls.last?.group == nil
            let selfBlocked = !LayerTree.drop(&ls, from: ls.firstIndex { $0.id == g }!, onto: ls.firstIndex { $0.id == a }!, .above)  // 그룹을 자기 자식 위로 X
            LayerTree.drop(&ls, from: ls.firstIndex { $0.id == g }!, onto: nil, .above)   // 그룹 덩어리를 맨 아래로
            let bottomOK = ls.first?.id == a && ls[1].id == g && ls.last?.id == b
            // 창에서: 레이어 둘 + 그룹 → 끌어서 그룹 안으로
            layersTab.addLayer(.full, native: photo?.nativeSize)
            layersTab.addLayer(.full, native: photo?.nativeSize)
            let ids = photo?.settings.layers.map(\.id) ?? []
            if ids.count >= 2 { layersTab.select(ids[0]); layersTab.groupSelected() }
            let grp = photo?.settings.layers.first { $0.isGroup }?.id
            if let last = ids.last, let grp { dropLayer(last, onto: grp, .into) }
            let winOK = grp != nil && photo?.settings.layers.first { $0.id == ids.last }?.group == grp
            // Finder 그림 → 이미지 레이어 (캔버스에 놓기)
            let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-drop-test.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
            let n0 = photo?.settings.layers.count ?? 0
            let i0 = photo?.settings.layers.filter(\.isImage).count ?? 0
            let took = canvas.onDropFiles?([png]) ?? false
            let imgOK = took && photo?.settings.layers.count == n0 + 1 && photo?.settings.layers.filter(\.isImage).count == i0 + 1
            if !imgOK { NSLog("DBG 그림 놓기 받음 %d, 레이어 %d → %d", took ? 1 : 0, n0, photo?.settings.layers.count ?? -1) }
            // RAW는 레이어가 아니다
            let rawIsLayer = DragFiles.isLayerImage(URL(fileURLWithPath: "/tmp/x.CR3"))
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            // 사진 → 앨범 (시험 카탈로그)
            var albumOK = false
            if let cur = photoItem, let album = try? library.catalog.addAlbum("끌기 시험 \(Int(Date().timeIntervalSince1970))") {
                dropPhotos([cur.url.path], toAlbum: album)
                albumOK = ((try? library.catalog.count(.album(album))) ?? 0) == 1
            }
            // 사진 → 사진: 지금 사진의 노출을 옆 사진에 붙인다
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
            // 도구 막대 사용자화: 끌어 놓은 자리에 넣기·옮기기
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

        // 8-06. 카탈로그 백업: 시험 카탈로그를 임시 폴더에 백업하고, 백업본을 열어 조정 개수가 같은지
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

        // 8-07. 효과: 심화 보정 효과 도구에서 고르면 효과 레이어가 생기고 결과가 바뀐다. 편집기로 값을 바꾸고 끈다
        do {
            let s0 = photo?.settings
            layersTab.select(nil)
            setMode(.studio)
            studioMode.selectTool("effects")
            let before = photo?.settings.layers.count ?? 0
            studioEffects.browser.onPick?("mosaic")
            let added = photo?.settings.layers.last
            let made = photo?.settings.layers.count == before + 1 && added?.adjust.fx.first?.kind == "mosaic"
            // 값 바꾸기 (편집기) → 저장
            var list = added?.adjust.fx ?? []
            if !list.isEmpty { list[0].params["size"] = 80 }
            studioEffects.editor.onChange?(list, false)
            let changed = photo?.settings.layers.last?.adjust.fx.first?.value("size") == 80
            // 렌더가 달라졌는가 (모자이크 칸)
            var differs = false
            if let doc = photo {
                let a = doc.image(scale: Develop.guideScale)
                var off = doc.settings; off.layers[off.layers.count - 1].adjust.effects?[0].enabled = false
                let saved = doc.settings
                doc.settings = off
                let b = doc.image(scale: Develop.guideScale)
                doc.settings = saved
                let d = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
                    .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: a.extent)])
                var px = [Float](repeating: 0, count: 4)
                Render.context.render(d, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                differs = px[0] + px[1] + px[2] > 0.001
            }
            studioMode.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            check("효과 도구: 고르기·값·렌더", made && changed && differs, "레이어 \(made), 값 \(changed), 렌더 바뀜 \(differs)")
        }

        // 8-08. 레이어 고급: 혼합 조건, 무늬 칠, 레이어 구성, 스냅샷, 정렬·연결, 병합·도장, 연결된 이미지
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
            // 혼합 조건: 노출 +2 전체 레이어를 어두운 곳에만(아래 밝기 0~0.3) → 전체에 건 것보다 덜 밝다
            var s = doc.settings
            var l = AdjustLayer(name: "밝게"); l.mask.kind = .full; l.adjust.exposure = 2
            s.layers.append(l); apply(s, dragging: false)
            let full = avg(doc.image(scale: Develop.guideScale))
            s.layers[s.layers.count - 1].blendIf = [0, 0, 1, 1, 0, 0, 0.25, 0.35]
            apply(s, dragging: false)
            let limited = avg(doc.image(scale: Develop.guideScale))
            if !(limited < full - 0.05) { notes.append("혼합 조건 \(limited) vs \(full)") }
            // 무늬 칠
            s = doc.settings
            var f = AdjustLayer(name: "무늬"); f.kind = "fill"; f.fillColor = [1, 0, 0, 0, 0, 1]; f.fillPattern = 0; f.fillScale = 200
            s.layers = [f]; apply(s, dragging: false)
            let pat = doc.image(scale: Develop.guideScale)
            var px = [Float](repeating: 0, count: 8)
            let e = pat.extent
            Render.context.render(pat, toBitmap: &px, rowBytes: 32, bounds: CGRect(x: e.minX + 2, y: e.minY + 2, width: 2, height: 1), format: .RGBAf, colorSpace: nil)
            if !(px[0] > 0.5 || px[2] > 0.5) { notes.append("무늬 칠 색 \(px)") }
            // 레이어 구성: 보임 끔을 기억했다가 되돌린다
            layersTab.select(f.id)
            saveLayerComp(nil)
            s = doc.settings; s.layers[0].enabled = false; replaceSettings(s, recordUndo: true, label: "끄기")
            applyLayerComp(0)
            if doc.settings.layers[0].enabled != true || doc.settings.layerComps?.count != 1 { notes.append("레이어 구성") }
            // 스냅샷: 만들고, 바꾸고, 되돌리기 + 저장/불러오기
            makeSnapshot(named: "시험 스냅샷")
            s = doc.settings; s.exposure += 1; replaceSettings(s, recordUndo: true, label: "바꿈")
            restoreSnapshot(history.snapshots.count - 1)
            let snapOK = doc.settings.exposure == (s.exposure - 1) && historyTab.snapshots.last == "시험 스냅샷"
            var h2 = AdjustHistory()
            let restored = history.encoded().map { h2.restore($0, current: doc.settings) } ?? false
            if !snapOK || !restored || h2.snapshots.last?.label != "시험 스냅샷" { notes.append("스냅샷 \(snapOK) \(restored) \(h2.snapshots.count)") }
            // 이미지 레이어 둘(작은 PNG) → 연결 → 왼쪽 정렬 → 둘 다 움직임, 아래 레이어와 병합 → 하나
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
            // 도장 찍기: 레이어 하나 더 (원본 크기 이미지), 보이는 레이어 병합: 레이어 하나만
            stampVisible(nil)
            let stamped = doc.settings.layers.count == 2 && doc.settings.layers.last?.image?.width == Double(doc.nativeSize.width)
            mergeVisible(nil)
            if !stamped || doc.settings.layers.count != 1 { notes.append("도장·병합 \(stamped) \(doc.settings.layers.count)") }
            // 연결된 이미지: 파일을 바꾸면 레이어 그림도 바뀐다
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

        // 8-09. 선택: 자동 선택·행·색상·빠른 선택·초점 영역·다각형·자석·합치기·다듬기·알파 채널·퀵 마스크
        do {
            setMode(.studio)
            let s0 = photo?.settings
            var notes: [String] = []
            guard let doc = photo else { check("선택", false, "사진 없음"); return }
            let n = doc.nativeSize
            func maskAvg(_ id: String) -> Float {
                guard let m = doc.maskPreview(id, scale: Develop.guideScale) else { return -1 }
                let d = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
                var px = [Float](repeating: 0, count: 4)
                Render.context.render(d, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return px[0]
            }
            // 앞 시험의 크롭·회전을 되돌린다 (하늘·모서리가 잘려 나가면 안 된다)
            var s = doc.settings; s.layers = []; s.adoptGeometry(from: doc.asShot); replaceSettings(s, recordUndo: false)
            layersTab.select(nil)
            // 자동 선택: 왼쪽 위 하늘
            studioMode.selectTool("selWand")
            wandSelect(at: CGPoint(x: n.width * 0.06, y: n.height * 0.9), flags: [])
            guard let wid = layersTab.selectedID else { check("선택", false, "자동 선택 레이어 없음"); return }
            let sky = maskAvg(wid)
            if !(sky > 0.01 && sky < 0.6) { notes.append("자동 선택 \(sky)") }
            // 반전 → 1 − 값
            invertSelection(nil)
            if abs(maskAvg(wid) - (1 - sky)) > 0.02 { notes.append("반전") }
            invertSelection(nil)
            // 확장 → 커진다, 테두리 → 줄어든다
            expandSelection(nil)
            let grown = maskAvg(wid)
            if !(grown > sky) { notes.append("확장 \(grown) ≤ \(sky)") }
            borderSelection(nil)
            if !(maskAvg(wid) < grown) { notes.append("테두리") }
            // 새 선택 레이어: 사각형 → ⇧ 타원 더하기 → ⌥ 다각형 빼기
            layersTab.select(nil)
            var r = LayerMask(); r.kind = .rect; r.box = [0, 0, n.width * 0.3, n.height * 0.3]
            commitSelection(r, flags: [], label: "사각형")
            let rid = layersTab.selectedID ?? ""
            let a0 = maskAvg(rid)
            var e = LayerMask(); e.kind = .ellipse; e.box = [n.width * 0.5, n.height * 0.5, n.width * 0.9, n.height * 0.9]
            commitSelection(e, flags: .shift, label: "더하기")
            let a1 = maskAvg(rid)
            var p = LayerMask(); p.kind = .polygon; p.polygon = [0, 0, Double(n.width) * 0.15, 0, 0, Double(n.height) * 0.15]
            commitSelection(p, flags: .option, label: "빼기")
            let a2 = maskAvg(rid)
            if !(a1 > a0 + 0.05 && a2 < a1) || doc.settings.layers.last?.mask.combos?.count != 2 { notes.append("합치기 \(a0) \(a1) \(a2)") }
            // 알파 채널로 저장 → 해제 → 불러오기
            saveSelection(nil)
            deselectAll(nil)
            let cleared = maskAvg(rid)
            loadSelection(0, op: nil)
            if abs(cleared - 1) > 0.01 || abs(maskAvg(rid) - a2) > 0.01 { notes.append("알파 채널 \(cleared) \(maskAvg(rid))") }
            // 행 선택: 높이 1
            layersTab.select(nil)
            rowColumnSelect(at: CGPoint(x: 100, y: n.height / 2), column: false, flags: [])
            let box = doc.settings.layers.last?.mask.box ?? []
            if box.count != 4 || abs(box[3] - box[1]) != 1 || box[2] - box[0] != Double(n.width) { notes.append("행 선택 \(box)") }
            // 색상 범위
            layersTab.select(nil)
            colorRangeSelect(at: CGPoint(x: n.width * 0.06, y: n.height * 0.9), flags: [])
            if let cid = layersTab.selectedID, !(maskAvg(cid) > 0.01 && maskAvg(cid) < 0.8) { notes.append("색상 범위 \(maskAvg(cid))") }
            // 빠른 선택: 하늘을 칠하면 번진다
            layersTab.select(nil)
            layersTab.brushRadius = 60
            quickSelect([CGPoint(x: n.width * 0.05, y: n.height * 0.9), CGPoint(x: n.width * 0.08, y: n.height * 0.88)], flags: [])
            if let qid = layersTab.selectedID, !(maskAvg(qid) > 0.003) { notes.append("빠른 선택 \(maskAvg(qid))") }
            // 초점 영역
            layersTab.select(nil)
            selectFocusArea(nil)
            if let fid = layersTab.selectedID, !(maskAvg(fid) > 0.02 && maskAvg(fid) < 0.98) { notes.append("초점 영역 \(maskAvg(fid))") }
            // 자석: 가장자리 옆의 점이 옮겨진다
            if ProcessInfo.processInfo.environment["DUOCHROME_DEBUG_E"] != nil {
                print("E 레이어:", doc.settings.layers.map { "\($0.name)[\($0.kind) \($0.enabled) m\($0.mask.kind.rawValue)]" })
            }
            if let eng = selectionEngine {
                let q = CGPoint(x: n.width * 0.3, y: n.height * 0.5)
                let sn = eng.snap(q, radius: 80)
                if sn == q { notes.append("자석 붙기 없음") }
            } else { notes.append("선택 엔진 없음") }
            // 선택 및 마스크: 가장자리 다듬기로 값이 바뀐다
            if let id = layersTab.selectedID {
                let before = maskAvg(id)
                editSelected("다듬기") { $0.refine = 30; $0.contrast = 40 }
                if !maskAvg(id).isFinite || maskAvg(id) == before { notes.append("다듬기 \(before) → \(maskAvg(id))") }
                toggleQuickMask(nil)
                if canvas.maskStyle != 4 { notes.append("퀵 마스크") }
                toggleQuickMask(nil)
            }
            studioMode.selectTool("hand")
            setMode(.edit)
            if let s0 { replaceSettings(s0, recordUndo: false, label: "시험 되돌림") }
            check("선택", notes.isEmpty, notes.isEmpty ? "자동·반전·확장·테두리·합치기 3·알파 채널·행·색상·빠른·초점·자석·다듬기·퀵 마스크" : notes.joined(separator: " / "))
        }

        // 8-0. 모드를 오가도 창 크기가 그대로
        do {
            let f0 = window?.frame ?? .zero
            var changed: [String] = []
            for m in [AppMode.studio, .tether, .library, .edit, .studio, .edit] {
                setMode(m)
                if window?.frame != f0 { changed.append("\(m.title) \(NSStringFromRect(window?.frame ?? .zero))") }
            }
            // 왼쪽 패널 폭도 모드마다 같아야 한다 (대량 보정 → 테더링 → 심화 보정)
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

        // M. 동작 기록·재생·일괄 처리·duochrome:// 주소
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
            // 처음 상태로 되돌리고 재생
            replaceSettings(s0, recordUndo: false, label: "시험")
            if let a = RecordedAction.load("시험 동작") { playAction(a) }
            let played = doc.settings.exposure == 0.7 && doc.settings.contrast == 25 && doc.settings.layers.count == s0.layers.count + 1
                && doc.settings.layers.last?.adjust.exposure == -0.4 && doc.settings.layers.last?.id != st.layers.last?.id
            // 일괄 처리: 열지 않은 다른 사진 한 장
            var batchOK = false
            let source0 = library.source
            if library.items.count < 2 { library.show(.all); browser.reload() }
            if let other = library.items.first(where: { $0 !== photoItem && !$0.offline }), let a = RecordedAction.load("시험 동작") {
                let raw0 = library.rawSettings(for: other.url)
                batchApply(a, to: [other])
                if let d = try? RawDocument(url: other.url), let s = library.loadSettings(for: other.url, over: d.asShot) {
                    batchOK = s.exposure == 0.7 && s.layers.last?.name == "동작 레이어"
                }
                if let raw0, let dict = try? JSONSerialization.jsonObject(with: raw0) as? [String: Any] { library.saveRawSettings(dict, for: other.url) }
                else { library.removeSettings(for: other.url) }
            }
            // 주소로 재생
            replaceSettings(s0, recordUndo: false, label: "시험")
            let urlOK = handleURL(URL(string: "duochrome://action?name=" + "시험 동작".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!) && doc.settings.exposure == 0.7
            replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
            RecordedAction.delete("시험 동작")
            if library.source != source0 { library.show(source0); browser.reload() }
            check("M 동작 기록·재생·일괄 처리·주소", recOK && played && batchOK && urlOK,
                  "기록 \(recOK) (\(rec?.steps.count ?? 0)단계), 재생 \(played), 일괄 \(batchOK), 주소 \(urlOK)")
        }

        // 미리보기만 쓰기: 대량 보정은 미리보기, 심화 보정은 원본. 내보내기는 대량 보정에서도 원본 크기
        do {
            let bulkPO = photo?.previewOnly == true
            setMode(.studio)
            let studioFull = photo?.previewOnly == false
            setMode(.edit)
            let backPO = photo?.previewOnly == true
            var sharpOK = false, exportOK = false
            if let d = photo {
                // 100% 조각: 미리보기만이면 원본보다 부드럽다 (늘린 것), 원본 크기는 날카롭다 — 가장자리 세기로 비교
                let r = CGRect(x: 3000, y: 2000, width: 256, height: 256)
                func detail(_ img: CIImage) -> Float {
                    let e = img.cropped(to: r).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4])
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

        // 8. 심화 보정 모드: 같은 캔버스·같은 패널을 옮겨 붙이고, 돌아오면 되찾는가
        do {
            let spots0 = doc.settings.spots.count
            setMode(.studio)
            let st = studioMode
            check("심화 보정 모드: 캔버스 옮겨 붙이기", canvas.isDescendant(of: st.view) && canvas.bounds.width > 200,
                  String(format: "캔버스 %.0f×%.0f", canvas.bounds.width, canvas.bounds.height))
            st.selectTool("repair")
            let retouchIn = retouch.view.isDescendant(of: st.options)
            canvas.zoomToFit()
            click(canvas.retouchOverlay, at: canvas.viewPoint(forImage: CGPoint(x: doc.pixelSize.width * 0.5, y: doc.pixelSize.height * 0.5)))
            check("심화 보정: 복구 도구 (옵션 패널 + 점 찍기)", retouchIn && canvas.tool == .retouch && doc.settings.spots.count == spots0 + 1
                  && !retouch.brush.patch && retouch.brush.kind == .heal,
                  "옵션에 리터칭 패널 \(retouchIn), 점 \(spots0) → \(doc.settings.spots.count)")
            st.selectTool("adjust")
            let inspIn = inspector.view.isDescendant(of: st.options)
            st.selectTool("picker")
            click(canvas, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            let picked = pickerView.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("RGB") } != nil
            check("심화 보정: 색 조정·색상 피커", inspIn && picked && canvas.tool == .colorPick, "조정 패널 \(inspIn), 집은 색 표시 \(picked)")
            st.selectTool("smartErase")
            check("심화 보정: AI 스마트 지우기 도구 (붓질을 AI로 넘김)", canvas.tool == .mask && canvas.maskOverlay.quickOverride != nil && st.options.toolID == "smartErase",
                  "캔버스 도구 \(canvas.tool)")
            // J. 펜·패스 패널·모양·벡터 마스크·글자 (가로·세로·단락·뒤틀기·패스 위·스타일)
            do {
                let N = doc.nativeSize
                func nv(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { canvas.viewPoint(forImage: doc.toDisplay(CGPoint(x: N.width * fx, y: N.height * fy))) }
                let o = canvas.pathOverlay
                let paths0 = doc.settings.paths?.count ?? 0
                // 펜: 세 점 + 첫 점 → 닫힌 패스
                VectorToolState.shared.penKind = 0; VectorToolState.shared.penTarget = 0
                st.selectTool("pen")
                newPath()
                click(o, at: nv(0.3, 0.3)); drag(o, from: nv(0.6, 0.3), to: nv(0.65, 0.4)); click(o, at: nv(0.45, 0.6)); click(o, at: nv(0.3, 0.3))
                let p1 = doc.settings.paths?.last
                let penOK = canvas.tool == .path && (doc.settings.paths?.count ?? 0) == paths0 + 1 && p1?.closed == true && p1?.anchors.count == 3
                    && p1.map { !$0.anchors[1].isCorner } == true
                // 직접 선택: 첫 점을 끌어 옮긴다
                VectorToolState.shared.penKind = 3
                startVectorTool("pen")
                let a0 = doc.settings.paths?.last?.anchors.first?.point ?? .zero
                drag(o, from: nv(0.3, 0.3), to: nv(0.25, 0.25))
                let a1 = doc.settings.paths?.last?.anchors.first?.point ?? .zero
                let directOK = a1.x < a0.x - N.width * 0.03
                // 곡률 펜: 네 점을 누르고 첫 점을 누르면 닫힌 매끄러운 패스
                VectorToolState.shared.penKind = 2
                startVectorTool("pen"); newPath()
                for (x, y) in [(0.55, 0.55), (0.75, 0.6), (0.7, 0.8), (0.55, 0.75)] as [(CGFloat, CGFloat)] { click(o, at: nv(x, y)) }
                click(o, at: nv(0.55, 0.55))
                let c = doc.settings.paths?.last
                let curvOK = c?.closed == true && c?.anchors.count == 4 && c.map { $0.anchors.allSatisfy { !$0.isCorner } } == true
                // 패스 패널: 선택으로 → 올가미 마스크 레이어
                let n0 = doc.settings.layers.count
                pathToSelection()
                let selOK = doc.settings.layers.count == n0 + 1 && (doc.settings.layers.last?.mask.polygon.count ?? 0) > 20
                // 모양 도구: 끌어서 사각형 모양 레이어 → 가운데는 칠해지고 바깥은 투명
                VectorToolState.shared.preset = .ellipse; VectorToolState.shared.customPathID = nil
                VectorToolState.shared.fillOn = true; VectorToolState.shared.fill = [1, 0, 0]; VectorToolState.shared.strokeOn = true
                st.selectTool("shape")
                drag(o, from: nv(0.1, 0.1), to: nv(0.3, 0.3))
                let shapeLayer = doc.settings.layers.last
                var shapeOK = shapeLayer?.kind == "shape" && shapeLayer?.vector?.path.anchors.count == 4
                if let v = shapeLayer?.vector {
                    let k: CGFloat = 0.1
                    let img = VectorRender.shapeImage(v, scale: k, nativeRect: CGRect(x: 0, y: 0, width: N.width * k, height: N.height * k))
                    var px = [Float](repeating: 0, count: 4), qx = [Float](repeating: 0, count: 4)
                    Render.context.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: N.width * k * 0.2, y: N.height * k * 0.2, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    Render.context.render(img, toBitmap: &qx, rowBytes: 16, bounds: CGRect(x: N.width * k * 0.11, y: N.height * k * 0.29, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    shapeOK = shapeOK && px[3] > 0.99 && px[0] > 0.9 && px[1] < 0.1 && qx[3] < 0.05
                }
                // 모양 옵션을 바꾸면 고른 모양 레이어에 걸린다
                VectorToolState.shared.fill = [0, 0, 1]
                applyShapeOptionsToSelection()
                let restyled = doc.settings.layers.last?.vector?.fill == [0, 0, 1]
                // 벡터 마스크: 고른(모양) 레이어에 곡률 패스를 벡터 마스크로
                VectorToolState.shared.pathID = c?.id
                pathToVectorMask()
                var vmaskOK = false
                if let l = doc.settings.layers.last, l.mask.vector != nil {
                    let k: CGFloat = 0.05
                    let m = VectorRender.mask(l.mask.vector!, scale: k, nativeRect: CGRect(x: 0, y: 0, width: N.width * k, height: N.height * k))
                    var inside = [Float](repeating: 0, count: 4), outside = [Float](repeating: 0, count: 4)
                    Render.context.render(m, toBitmap: &inside, rowBytes: 16, bounds: CGRect(x: N.width * k * 0.65, y: N.height * k * 0.66, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    Render.context.render(m, toBitmap: &outside, rowBytes: 16, bounds: CGRect(x: N.width * k * 0.2, y: N.height * k * 0.2, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    vmaskOK = inside[0] > 0.9 && outside[0] < 0.1 && LayerThumbs.hasMask(l)
                }
                // 글자: 누르면 한 줄 글자, 끌면 단락 상자
                st.selectTool("text")
                click(o, at: nv(0.5, 0.5))
                let tl = doc.settings.layers.last
                let textOK = tl?.isText == true && tl?.text?.boxWidth == nil && textOptions.window != nil
                editSelectedText { $0.string = "가나다라마바사" }
                let hImg = doc.settings.layers.last?.text.flatMap { TextRender.image($0, scale: 0.2) }
                editSelectedText { $0.vertical = true }
                let vImg = doc.settings.layers.last?.text.flatMap { TextRender.image($0, scale: 0.2) }
                let verticalOK = (hImg?.extent.width ?? 0) > (hImg?.extent.height ?? 0) && (vImg?.extent.height ?? 0) > (vImg?.extent.width ?? 1)
                editSelectedText { $0.vertical = nil; $0.warp = TextWarp.arc.rawValue; $0.warpBend = 60 }
                let wImg = doc.settings.layers.last?.text.flatMap { TextRender.image($0, scale: 0.2) }
                let warpOK = (wImg?.extent.height ?? 0) > (hImg?.extent.height ?? 0)
                editSelectedText { $0.warp = nil; $0.warpBend = nil; $0.onPath = c; $0.pathOffset = 0 }
                let pImg = doc.settings.layers.last?.text.flatMap { TextRender.image($0, scale: 0.2) }
                let onPathOK = pImg != nil && (pImg?.extent.width ?? 0) > 10
                editSelectedText { $0.onPath = nil }
                drag(o, from: nv(0.1, 0.9), to: nv(0.3, 0.6))
                editSelectedText { $0.string = String(repeating: "상자 안에서 줄이 바뀝니다 ", count: 6) }
                let box = doc.settings.layers.last?.text
                let bImg = box.flatMap { TextRender.image($0, scale: 0.2) }
                let boxOK = box?.boxWidth != nil && (bImg?.extent.width ?? 1e9) < (CGFloat(box?.boxWidth ?? 0) + CGFloat(box?.size ?? 0) * 1.3) * 0.2 && (bImg?.extent.height ?? 0) > CGFloat(box?.size ?? 0) * 0.2 * 2
                // 문자 스타일 저장·입히기, 글꼴 대체
                var t = LayerText(string: "a"); t.font = "NoSuchFont-Bold"; t.size = 77; t.tracking = 30
                let saved = TextStyle.saved
                TextStyle.saved = saved + [TextStyle(name: "시험", from: t)]
                editSelectedText { TextStyle.saved.last!.apply(to: &$0) }
                let styleOK = doc.settings.layers.last?.text?.size == 77 && doc.settings.layers.last?.text?.tracking == 30
                    && NSFont(name: doc.settings.layers.last?.text?.font ?? "", size: 12) != nil && TextRender.isSubstituted("NoSuchFont-Bold")
                TextStyle.saved = saved
                check("J 텍스트와 벡터 (펜·직접 선택·곡률 펜·선택으로·모양·벡터 마스크·글자)",
                      penOK && directOK && curvOK && selOK && shapeOK && restyled && vmaskOK && textOK && verticalOK && warpOK && onPathOK && boxOK && styleOK,
                      "펜 \(penOK), 직접 \(directOK), 곡률 \(curvOK), 선택 \(selOK), 모양 \(shapeOK)/\(restyled), 벡터 마스크 \(vmaskOK), 글자 \(textOK), 세로 \(verticalOK), 뒤틀기 \(warpOK), 패스 위 \(onPathOK), 단락 \(boxOK), 스타일 \(styleOK)")
                enterTool(.pan)
            }
            // L. 화면 프로파일·HDR 보기·32비트 내보내기·CMYK 내보내기·채널 분리·합치기·견본
            do {
                let s0 = doc.settings
                let screenSpace = (canvas.window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace
                canvas.updateDisplaySpace()
                let displayOK = screenSpace == nil || (canvas.layer as? CAMetalLayer)?.colorspace?.name == screenSpace?.name
                canvas.hdrView = true
                let edrScreen = ((canvas.window?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
                let hdrOK = !edrScreen || (canvas.colorPixelFormat == .rgba16Float && (canvas.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent == true)
                canvas.hdrView = false
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-L-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var r = ExportRecipe(); r.folder = dir.path; r.longSide = 600; r.format = .tiff32; r.sharpen = 0; r.keepMetadata = false
                let f32 = try? Exporter.export(doc, recipe: r, name: "t32")
                let img32 = f32.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                var st = doc.settings; st.docMode = DocMode.cmyk.rawValue
                replaceSettings(st, recordUndo: false, label: "시험")
                r.format = .tiff8
                let fc = try? Exporter.export(doc, recipe: r, name: "cmyk")
                let imgC = fc.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                // 채널: RGB로 되돌려 셋으로 나누고 다시 합친다
                replaceSettings(s0, recordUndo: false, label: "시험")
                let files = (try? writeChannels(to: dir)) ?? []
                let n0 = doc.settings.layers.count
                mergeChannelFiles(files)
                let merged = doc.settings.layers.count == n0 + 1 && doc.settings.layers.last?.isImage == true
                // 견본: 칠하기 붓 색이 된다
                pickerView.swatches.onPick?([0.1, 0.2, 0.3])
                let swatchOK = PaintBrush.current.color == [0.1, 0.2, 0.3]
                replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
                try? FileManager.default.removeItem(at: dir)
                check("L 화면 프로파일·HDR·32비트·CMYK 내보내기·채널 분리/합치기·견본",
                      displayOK && hdrOK && img32?.bitsPerComponent == 32 && imgC?.colorSpace?.model == .cmyk && files.count == 3 && merged && swatchOK,
                      "화면 \(displayOK), HDR \(hdrOK) (EDR 화면 \(edrScreen)), 32비트 \(img32?.bitsPerComponent ?? 0), CMYK \(imgC?.colorSpace?.model == .cmyk), 채널 \(files.count), 합치기 \(merged), 견본 \(swatchOK)")
            }
            // O. 눈금자·안내선·스냅·측정·계수·초점 확인·작업 공간·레이어 종류 거르기
            do {
                let s0 = doc.settings
                let size = doc.pixelSize
                canvas.showRulers = true
                let rulersOK = !canvas.rulerTop.isHidden && canvas.rulerTop.frame.height == RulerView.thickness
                // 눈금자에서 끌어 세로 안내선 (사진 가운데)
                guideDragged(vertical: true, at: size.width * 0.4, dragging: true)
                let pendingOK = canvas.guidesOverlay.pending != nil
                guideDragged(vertical: true, at: size.width * 0.4, dragging: false)
                guideDragged(vertical: false, at: -50, dragging: false)   // 사진 밖에 놓으면 안 만든다
                let guidesOK = pendingOK && doc.settings.guidesV?.count == 1 && doc.settings.guidesH == nil && canvas.guidesOverlay.vertical.count == 1
                // 스냅: 안내선 근처 점이 붙는다
                UserDefaults.standard.set(true, forKey: "view.snap")
                let near = doc.toNative(CGPoint(x: size.width * 0.4 + 2 / max(canvas.zoom, 0.01), y: size.height * 0.3))
                let snapped = doc.toDisplay(snapNative(near))
                let snapOK = abs(snapped.x - size.width * 0.4) < 0.5
                // 측정
                startMeasure()
                canvas.guidesOverlay.onMeasure?(CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 500), false)
                let measureOK = canvas.guidesOverlay.tool == .measure && GuidesOverlayView.measureText(CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 500)).contains("500.0 px")
                // 계수: 둘 찍고 ⌥로 하나 지우기
                startCount()
                canvas.guidesOverlay.onCount?(CGPoint(x: 200, y: 200), false)
                canvas.guidesOverlay.onCount?(CGPoint(x: 800, y: 600), false)
                canvas.guidesOverlay.onCount?(CGPoint(x: 801, y: 601), true)
                let countOK = doc.settings.countMarks?.count == 2 && canvas.guidesOverlay.counts.count == 1
                canvas.guidesOverlay.tool = .none
                // 초점 확인: 100% 조각
                let loupe = FocusLoupe()
                let loupeOK = loupe.show(doc, at: CGPoint(x: size.width / 2, y: size.height / 2))
                // 작업 공간 저장·적용
                let right0 = split.showsRight
                saveWorkspace("시험 공간")
                split.showsRight = !right0
                applyWorkspace("시험 공간")
                let wsOK = split.showsRight == right0 && MainWindowController.workspaces["시험 공간"] != nil
                var ws = MainWindowController.workspaces; ws["시험 공간"] = nil; MainWindowController.workspaces = ws
                // 레이어 종류 거르기: 모양만
                var st = doc.settings
                var shapeL = AdjustLayer(name: "거르기 모양"); shapeL.kind = "shape"; shapeL.vector = VectorShape(path: .preset(.rect, in: CGRect(x: 10, y: 10, width: 50, height: 50)))
                st.layers.append(shapeL)
                var adj = AdjustLayer(name: "거르기 조정"); adj.kind = "adjust"
                st.layers.append(adj)
                replaceSettings(st, recordUndo: false, label: "시험")
                let panel = studioMode.layersPanel
                panel.kindFilter.selectItem(at: 4)
                panel.reload()
                let rows = panel.dropList.arrangedSubviews.count
                panel.kindFilter.selectItem(at: 0)
                panel.reload()
                let filterOK = rows == doc.settings.layers.filter { $0.kind == "shape" }.count
                canvas.showRulers = false
                replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
                syncGuides(); syncCounts()
                check("O 눈금자·안내선·스냅·측정·계수·초점 확인·작업 공간·레이어 거르기",
                      rulersOK && guidesOK && snapOK && measureOK && countOK && loupeOK && wsOK && filterOK,
                      "눈금자 \(rulersOK), 안내선 \(guidesOK), 스냅 \(snapOK), 측정 \(measureOK), 계수 \(countOK), 초점 \(loupeOK), 작업 공간 \(wsOK), 거르기 \(filterOK) (\(rows)줄)")
            }
            // Q. 배치 도구(크기·회전·가운데), 프리셋 보기, 반반 비교, 사진 탭
            do {
                let s0 = doc.settings
                var st = doc.settings
                var sh = AdjustLayer(name: "배치 모양"); sh.kind = "shape"
                sh.vector = VectorShape(path: .preset(.rect, in: CGRect(x: 1000, y: 1000, width: 400, height: 200)))
                st.layers.append(sh)
                replaceSettings(st, recordUndo: false, label: "시험")
                layersTab.select(sh.id)
                studioMode.selectTool("arrange")
                arrangeOptions.sync()
                func bounds() -> CGRect { doc.settings.layers.last?.vector?.path.bounds ?? .zero }
                let rows = arrangeOptions.arrangedSubviews.compactMap { $0 as? SliderRow }
                rows.first?.value = 200; rows.first?.onChange?(200, false)
                let b1 = bounds()
                let scaleOK = abs(b1.width - 800) < 1 && abs(b1.height - 400) < 1
                rows.last?.onChange?(90, false)
                let b2 = bounds()
                let rotOK = abs(b2.width - 400) < 1 && abs(b2.height - 800) < 1
                arrangeOptions.perform(Selector(("centerH")))
                let mid = doc.toNative(CGPoint(x: doc.pixelSize.width / 2, y: doc.pixelSize.height / 2))
                let centerOK = abs(bounds().midX - mid.x) < 1
                // 프리셋 보기 (앞 시험에서 저장한 스타일)
                studioMode.selectTool("adjust")
                let hasStyle = !MainWindowController.styleNames().isEmpty
                let preview = MainWindowController.styleNames().first.flatMap { stylePreview($0) }
                let presetOK = !hasStyle || (preview != nil && inspector.view.isDescendant(of: adjustContainer))
                // 반반 비교
                let split0 = canvas.splitCompare
                studioMode.options.onSplit?()
                let splitOK = canvas.splitCompare != split0
                studioMode.options.onSplit?()
                replaceSettings(s0, recordUndo: false, label: "시험 되돌림")
                check("Q 배치 도구·프리셋·반반 비교", scaleOK && rotOK && centerOK && presetOK && splitOK,
                      "크기 \(scaleOK), 회전 \(rotOK), 가운데 \(centerOK), 프리셋 \(presetOK), 반반 \(splitOK)")
            }
            let before = StudioTool.strip
            let sheet = ToolCustomizeSheet()
            sheet.toggle("twirl")
            var list: [String] = []
            sheet.onDone = { list = $0 }
            sheet.perform(Selector(("done")))
            check("도구 사용자화 (넣기)", list.contains("twirl") && list.count == before.count + 1, "\(before.count) → \(list.count)개")
            setMode(.edit)
            let back = canvas.isDescendant(of: viewer.view) && tools.view.window != nil
            tools.select(tools.index(of: "리터칭"))
            check("대량 보정으로 돌아오기", back && retouch.view.isDescendant(of: tools.view) && canvas.bounds.width > 200,
                  String(format: "캔버스 %.0f×%.0f", canvas.bounds.width, canvas.bounds.height))
            var s = doc.settings; s.spots.removeLast(); apply(s, dragging: false)
        }

        // 5-1. 컬러 에디터 스포이트: 하늘(왼쪽 위)을 집으면 파란 범위가 하나 더해진다
        // 앞 시험의 키스톤·회전·크롭을 되돌려 하늘 자리가 원래대로 오게 한다.
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

        // 5-2. 새 컬러 에디터: 고급 탭에 더한 범위가 고른 상태, 목록 체크를 끄면 계산에서 빠짐, 색조 분포, 범위 보기
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
            // 가운데(콘크리트 벽)는 파란 범위 밖 → 회색
            let grayOK = abs(px[0] - px[1]) < 0.02 && abs(px[1] - px[2]) < 0.02
            check("컬러 에디터 (고급 범위·체크 끄기·색조 분포·범위 보기)", selectedOK && offOK && onOK && bins.contains { $0 > 0 } && grayOK,
                  "고른 범위 \(selectedOK), 끄기 \(offOK)/\(onOK), 분포 \(bins.filter { $0 > 0 }.count)칸, 범위 밖 회색 \(grayOK)")
        }

        // 6. 리터칭: 누르면 점, 끌면 붓질, 흰 원 끌어 옮기기, Delete로 지우기
        tools.select(tools.index(of: "리터칭"))
        canvas.layoutSubtreeIfNeeded()
        let ro = canvas.retouchOverlay
        let n0 = doc.settings.spots.count
        click(ro, at: v(W * 0.3, H * 0.3))
        check("리터칭 점 찍기", doc.settings.spots.count == n0 + 1 && !(doc.settings.spots.last?.isStroke ?? true),
              "점 \(doc.settings.spots.count)개")
        let spot = doc.settings.spots.last!
        // 리터칭 점은 원본 좌표다. 크롭·회전을 거친 화면 좌표로 바꿔서 누른다.
        let from = canvas.viewPoint(forImage: doc.toDisplay(spot.target))
        drag(ro, from: from, to: CGPoint(x: from.x + 40, y: from.y))
        let moved = doc.settings.spots.last!
        // 기대값: 끈 거리(뷰 40pt)를 같은 좌표 변환으로 원본 좌표로 바꾼 것 (회전 확대·크롭 반영)
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

        // 6-1. 패치: 올가미를 두르면 닫힌 패치가 생기고, 초록 올가미(원본)를 끌면 원본만 옮겨진다
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

        // 7. 마스크: 브러시 레이어에 칠하기, 선형 레이어 끌기
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
        // 7-1. 잠금: 잠긴 레이어에는 칠해지지 않는다
        var locked = doc.settings
        locked.layers[locked.layers.count - 2].locked = true
        replaceSettings(locked, recordUndo: true, label: "시험: 잠금")
        layersTab.select(locked.layers[locked.layers.count - 2].id)
        let beforeLock = doc.settings.layers[locked.layers.count - 2].mask.strokes.count
        drag(canvas.maskOverlay, from: v(W * 0.2, H * 0.4), to: v(W * 0.4, H * 0.4), steps: 5)
        check("잠긴 레이어에 칠하기 막기", doc.settings.layers[locked.layers.count - 2].mask.strokes.count == beforeLock,
              "붓질 \(beforeLock)개 그대로")
        // 7-2. [ ] 로 붓 크기
        let r0 = layersTab.brushRadius
        brushLarger(nil); brushLarger(nil)
        check("] 두 번 붓 크게", abs(layersTab.brushRadius - r0 * 1.5625) < 0.5,
              String(format: "%.0f → %.0f", r0, layersTab.brushRadius))
        brushSmaller(nil); brushSmaller(nil)
        enterTool(.pan)

        // 8. 작업 내역: 되돌리기·다시 실행·특정 시점으로
        let count = history.labels.count
        let last = doc.settings
        undoAdjust(nil)
        check("되돌리기", doc.settings != last && history.index == count - 2, "내역 \(count)줄, 지금 \(history.index)")
        redoAdjust(nil)
        check("다시 실행", doc.settings == last, "")
        historyTab.onJump?(0)
        check("내역 첫 줄로 가기", doc.settings == doc.asShot || history.index == 0, "지금 \(history.index)번째 · \(history.labels.prefix(5).joined(separator: " / "))")
        historyTab.onJump?(count - 1)

        // 9. 골라 붙이기: 화이트 밸런스만
        var src = doc.settings
        src.temperature = 3200; src.exposure = 1.7
        let keepExposure = doc.settings.exposure
        pasteGroups(src, [.whiteBalance])
        check("골라 붙이기 (화이트 밸런스만)", doc.settings.temperature == 3200 && doc.settings.exposure == keepExposure,
              String(format: "색온도 %.0f, 노출 %.2f (그대로 %.2f)", doc.settings.temperature, doc.settings.exposure, keepExposure))

        // 8-10. 자동 정렬·혼합 레이어: 사진을 옮긴 이미지 레이어를 제자리로, 그리고 마스크
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

        // 8-11. 변형: 점 층을 거쳐 기울이기·뒤틀기·퍼펫·원근 자르기·유동화
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
                // 왜곡: 오른위 모서리를 안쪽으로
                distortLayer(nil)
                o.onChange?(2, CGPoint(x: n.width * 0.8, y: n.height * 0.85), false); o.onCommit?()
                if doc.settings.layers.last?.image?.quad?.count != 8 { notes.append("왜곡") }
                // 원근: 오른아래를 옮기면 왼아래가 거울로
                perspectiveLayer(nil)
                let q0 = doc.settings.layers.last?.image?.quad ?? []
                o.onChange?(1, CGPoint(x: q0[2] - 200, y: q0[3]), false); o.onCommit?()
                let q1 = doc.settings.layers.last?.image?.quad ?? []
                if !(q1.count == 8 && abs(q1[0] - (q0[0] + 200)) < 1) { notes.append("원근 \(q0.prefix(4)) → \(q1.prefix(4))") }
                // 뒤틀기: 가운데 점 하나
                warpLayer(nil)
                o.onChange?(5, CGPoint(x: n.width * 0.45, y: n.height * 0.4), false); o.onCommit?()
                if doc.settings.layers.last?.image?.mesh?.count != 32 { notes.append("뒤틀기") }
                // 퍼펫: 핀 둘, 하나 옮기기
                puppetWarp(nil)
                o.onAdd?(CGPoint(x: n.width * 0.3, y: n.height * 0.5)); o.onAdd?(CGPoint(x: n.width * 0.7, y: n.height * 0.5))
                o.onChange?(1, CGPoint(x: n.width * 0.7, y: n.height * 0.6), false); o.onCommit?()
                if (doc.settings.layers.last?.image?.pins?.count ?? 0) != 8 { notes.append("퍼펫 \(doc.settings.layers.last?.image?.pins ?? [])") }
                // 그림이 비지 않았나
                let e = doc.image(scale: 1.0 / 8)
                var avg = [Float](repeating: 0, count: 4)
                Render.context.render(e.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e.extent)]), toBitmap: &avg, rowBytes: 16,
                                      bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                if !(avg[0] > 0.01) { notes.append("그림 비었음") }
                // 유동화 붓질
                liquify(tool: 1)
                o.onStroke?([CGPoint(x: n.width * 0.5, y: n.height * 0.5)], []); o.onCommit?()
                if (doc.settings.layers.last?.liquify?.count ?? 0) != 1 { notes.append("유동화") }
                // 원근 자르기
                perspectiveCrop(nil)
                let f = doc.frameSize
                o.onChange?(2, CGPoint(x: f.width * 0.85, y: f.height * 0.95), false); o.onCommit?()
                if doc.settings.perspective?.count != 8 || doc.pixelSize.width >= f.width { notes.append("원근 자르기 \(doc.pixelSize)") }
                clearPerspectiveCrop(nil)
                // 소실점 복제: 평면 안에서 옮긴 조각이 레이어로
                let plane = [CGPoint(x: n.width * 0.2, y: n.height * 0.2), CGPoint(x: n.width * 0.8, y: n.height * 0.25),
                             CGPoint(x: n.width * 0.8, y: n.height * 0.75), CGPoint(x: n.width * 0.2, y: n.height * 0.8)]
                let cnt = doc.settings.layers.count
                vanishingClone(from: CGPoint(x: n.width * 0.3, y: n.height * 0.5), to: CGPoint(x: n.width * 0.6, y: n.height * 0.5), plane: plane, radius: 200)
                if doc.settings.layers.count != cnt + 1 || doc.settings.layers.last?.mask.kind != .polygon { notes.append("소실점") }
                // 캔버스 크기 → 다듬기: 투명 여백을 더했다가 잘라 낸다
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

        // 8-12. 칠하기
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
            // 칠 레이어 안에서 지우개
            startPainting(mode: 1)
            o.onStroke?([CGPoint(x: n.width * 0.5, y: n.height * 0.5)], []); o.onCommit?()
            if doc.settings.layers.last?.paint?.last?.brush.mode != 1 { notes.append("칠 레이어 지우개") }
            // 이미지 레이어에서 지우개 → 마스크
            if let img = rasterize([], withPhoto: true), let l = imageLayer(from: img, name: "지울 그림") {
                var s1 = doc.settings; s1.layers.append(l); replaceSettings(s1, recordUndo: true); layersTab.select(l.id)
                paintStroke([CGPoint(x: n.width * 0.3, y: n.height * 0.3)], pressures: [1], erase: true)
                if doc.settings.layers.last?.mask.brushWhite != true || doc.settings.layers.last?.mask.strokes.last?.erase != true { notes.append("마스크 지우개") }
                // 배경 지우개: 누른 색과 비슷한 곳
                layersTab.brushRadius = 300
                backgroundErase([CGPoint(x: n.width * 0.05, y: n.height * 0.9), CGPoint(x: n.width * 0.1, y: n.height * 0.9)])
                if doc.settings.layers.last?.mask.kind != .image { notes.append("배경 지우개") }
            }
            // 작업 내역 브러시
            let cnt = doc.settings.layers.count
            historyBrush(nil)
            if doc.settings.layers.count != cnt + 1 || doc.settings.layers.last?.mask.kind != .brush { notes.append("작업 내역 브러시") }
            // 적목: 빨간 점을 가진 칠 레이어 위에서
            var sr = doc.settings; sr.layers = []
            var red = AdjustLayer(name: "빨간 눈"); red.kind = "fill"; red.fillColor = [0.9, 0.05, 0.05]
            red.mask = LayerMask(kind: .ellipse, box: [n.width * 0.5 - 40, n.height * 0.5 - 40, n.width * 0.5 + 40, n.height * 0.5 + 40])
            sr.layers = [red]
            replaceSettings(sr, recordUndo: true)
            fixRedEye(at: CGPoint(x: n.width * 0.5, y: n.height * 0.5), radius: 120)
            if doc.settings.layers.last?.name != "적목 현상 제거" { notes.append("적목") }
            // 페인트 통
            paintBucket(at: CGPoint(x: n.width * 0.05, y: n.height * 0.9))
            if doc.settings.layers.last?.name != "페인트 통" || doc.settings.layers.last?.mask.kind != .image { notes.append("페인트 통") }
            check("칠하기 도구", notes.isEmpty, notes.isEmpty ? "칠하기·지우개(칠·마스크)·배경 지우개·작업 내역 브러시·적목·페인트 통" : notes.joined(separator: " / "))
            replaceSettings(s0, recordUndo: true)
        }

        // Q. 사진 탭 (다른 사진을 열어 문서가 바뀌므로 맨 끝에서)
        do {
            setMode(.studio)
            // 사진 탭: 다른 사진을 열면 탭이 둘, 앞 탭을 누르면 돌아온다
            var tabsOK = false
            let first = photoItem
            if library.items.count < 2 { library.show(.all); browser.reload() }
            if let other = library.items.first(where: { $0 !== first && !$0.offline }), let first {
                show(other)
                let two = studioTabs.contains { $0 === first } && studioTabs.contains { $0 === other } && !studioMode.tabs.isHidden
                if let i = studioTabs.firstIndex(where: { $0 === first }) { pickTab(i) }
                let back = photoItem === first
                if let j = studioTabs.firstIndex(where: { $0 === other }) { closeTab(j) }
                tabsOK = two && back && !studioTabs.contains { $0 === other }
            }
            check("Q 사진 탭", tabsOK, "탭 \(studioTabs.count)개, 되돌아오기 \(tabsOK)")
            setMode(.edit)
        }

        print(failures == 0 ? "UI 시험 모두 통과" : "UI 시험 \(failures)개 실패")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 사건 만들기

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
