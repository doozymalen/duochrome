import AppKit

/// 심화 보정 모드를 창에 붙이는 부분: 모드 들고 나기, 도구를 캔버스 도구로 옮기기, 창 막대.
extension MainWindowController {
    func setupStudio() {
        let m = studioMode
        m.host = self
        _ = m.view
        let panel = m.layersPanel
        panel.current = { [weak self] in self?.photo?.settings }
        panel.onChange = { [weak self] s in self?.apply(s, dragging: NSApp.currentEvent?.type == .leftMouseDragged) }
        panel.selectedID = { [weak self] in self?.layersTab.selectedID }
        panel.onSelect = { [weak self] id in
            guard let self else { return }
            self.layersTab.select(id)
            // 레이어를 고르면 마스크·배치 도구가 그 레이어를 따라간다.
            if ["maskPaint", "arrange"].contains(m.currentTool) { m.restoreTool() }
            if m.currentTool == "effects" { self.syncStudioEffects() }
            if m.currentTool == "style" { self.syncStudioStyles() }
        }
        panel.background = { [weak self] in
            guard let self, let doc = self.photo else { return nil }
            return (self.studioThumbnail(doc), "배경", doc.nativeSize)
        }
        LayerThumbs.backgroundProvider = { [weak self] in
            guard let self, let doc = self.photo else { return nil }
            let img = self.studioThumbnail(doc)
            LayerThumbs.backgroundThumb = img
            return img
        }
        panel.addMenu = { [weak self] in self?.studioAddMenu() ?? NSMenu() }
        panel.moreMenu = { [weak self] in self?.studioMoreMenu() ?? NSMenu() }
        panel.onToggleMask = { [weak self] in self?.toggleMaskView(nil) }
        panel.rowMenu = { [weak self] id in self?.layerContextMenu(id) ?? NSMenu() }
        layersTab.rowMenu = { [weak self] id in self?.layerContextMenu(id) ?? NSMenu() }
        // 창 막대의 확대 조절은 지금 보이는 캔버스를 따른다 (테더링은 자기 캔버스가 따로 있다)
        viewer.onZoom = { [weak self] z in if self?.mode != .tether { self?.studioZoomChanged(z) } }
        tetherMode.viewer.onZoom = { [weak self] z in if self?.mode == .tether { self?.studioZoomChanged(z) } }
        installKeyMap()
    }

    func enterStudio() {
        studioMode.attachCanvas(viewer.canvas)
        layersTab.listHidden = true
        studioMode.layersPanel.reload()
        studioMode.restoreTool()
        viewer.canvas.zoomToFit()
        window?.makeFirstResponder(viewer.canvas)
        // 창이 처음 뜰 때 검색칸이 초점을 가져가지 않게 한 번 더.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .studio else { return }
            self.window?.makeFirstResponder(self.viewer.canvas)
        }
    }

    /// 레이어 목록의 배경 썸네일: 지금 현상 결과를 작게 (사진이 바뀌거나 조정이 바뀌면 다시).
    /// 배경(현상 결과) 썸네일: 기억해 둔 것이 있으면 바로, 없으면 뒤에서 그리고 끝나면 레이어 목록을 다시 그린다.
    /// (주 스레드에서 그리면 레이어 목록을 새로 그릴 때마다 — 편집할 때마다 — 1초 가까이 멈췄다)
    func studioThumbnail(_ doc: RawDocument) -> NSImage? {
        if let c = studioThumbCache, c.url == doc.url, c.settings == doc.settings { return c.image }
        let settings = doc.settings, url = doc.url
        let stale = studioThumbCache?.url == doc.url ? studioThumbCache?.image : nil
        guard studioThumbPending != settings else { return stale }
        studioThumbPending = settings
        let img = doc.image(scale: Develop.guideScale)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let k = 120 / max(img.extent.width, img.extent.height, 1)
            let small = img.transformed(by: .init(scaleX: k, y: k))
            guard let cg = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: Render.displaySpace) else { return }
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                guard let self, self.photo?.url == url else { return }
                self.studioThumbPending = nil
                self.studioThumbCache = (url, settings, ns)
                LayerThumbs.backgroundThumb = ns
                // 지금 설정과 같을 때만 목록을 다시 (다르면 다음 새로 그리기에서 또 요청된다)
                if self.photo?.settings == settings {
                    self.layersTab.sync(self.photo?.settings)
                    if self.mode == .studio { self.studioMode.layersPanel.reload() }
                }
            }
        }
        return stale
    }

    /// 심화 보정 모드를 떠날 때: 캔버스와 옮겨 간 패널을 대량 보정 화면으로 되돌린다.
    func leaveStudio() {
        viewer.canvas.maskOverlay.prepare = nil
        viewer.canvas.maskOverlay.clickMode = .none
        viewer.canvas.maskOverlay.quickOverride = nil
        viewer.reclaimCanvas()
        layersTab.listHidden = false
        layersTab.sync(photo?.settings)   // 심화 보정에서 바뀐 레이어를 대량 보정 목록에도
        tools.select(tools.selected)
        colorPickPurpose = 0
        enterTool(.pan)
        viewer.canvas.zoomToFit()
    }

    // MARK: - 도구

    /// 심화 보정 도구를 캔버스 도구로 옮긴다.
    func applyStudioTool(_ tool: StudioTool) {
        colorPickPurpose = 0
        canvas.guidesOverlay.tool = .none
        // 도구를 고르기만 해서는 사진이 바뀌지 않는다. 레이어가 필요한 도구는 캔버스를 처음 누를 때 만든다.
        viewer.canvas.maskOverlay.prepare = nil
        viewer.canvas.maskOverlay.clickMode = .none
        viewer.canvas.maskOverlay.quickOverride = nil
        var b = retouch.brush
        switch tool.id {
        case "hand", "adjust": enterTool(.pan)
        case "zoom": enterTool(.zoom)
        case "picker":
            colorPickPurpose = 9
            enterTool(.colorPick)
        case "crop": enterTool(.crop)
        case "straighten": enterTool(.straighten)
        case "keystone": enterTool(.keystone)
        case "whiteBalance": enterTool(.whiteBalance)
        case "repair", "clone", "patch":
            b.patch = tool.id == "patch"
            if !b.patch { b.kind = tool.id == "repair" ? .heal : .clone }
            retouch.brush = b
            enterTool(.retouch)
        case "maskPaint", "arrange":
            enterTool(layersTab.selectedID == nil ? .pan : .mask)
        case "selRect", "selOval", "selFree":
            let kind: LayerMask.Kind = tool.id == "selRect" ? .rect : (tool.id == "selOval" ? .ellipse : .polygon)
            viewer.canvas.maskOverlay.prepare = { [weak self] in
                guard let self else { return false }
                // 더하기·빼기·교차면 고른 레이어에 합친다 (새 레이어를 만들지 않는다)
                if self.selectionOp(self.viewer.canvas.maskOverlay.startFlags) != nil,
                   let id = self.layersTab.selectedID, self.photo?.settings.layers.first(where: { $0.id == id })?.isGroup == false { return false }
                self.ensureStudioLayer(kind: kind, preset: nil)
                return false
            }
            enterTool(photo == nil ? .pan : .mask)
        case "selRow", "selColumn", "selWand", "selColor":
            viewer.canvas.maskOverlay.clickMode = .point
            enterTool(photo == nil ? .pan : .mask)
        case "selPolygon":
            viewer.canvas.maskOverlay.clickMode = .polygonClicks
            enterTool(photo == nil ? .pan : .mask)
        case "selMagnetic":
            viewer.canvas.maskOverlay.clickMode = .magnetic
            enterTool(photo == nil ? .pan : .mask)
        case "selQuick":
            viewer.canvas.maskOverlay.clickMode = .quick
            enterTool(photo == nil ? .pan : .mask)
        case "lighten", "darken", "saturate", "desaturate", "sharpen", "soften":
            let preset = tool.id
            viewer.canvas.maskOverlay.prepare = { [weak self] in self?.ensureStudioLayer(kind: .brush, preset: preset); return false }
            enterTool(photo == nil ? .pan : .mask)
        case "selSubject":
            // 이미 AI 선택 레이어를 골랐으면 그대로, 아니면 피사체 선택 레이어를 만든다
            if let id = layersTab.selectedID, photo?.settings.layers.first(where: { $0.id == id })?.mask.kind == .image {
                enterTool(.pan)
            } else {
                // 캔버스를 누르면 피사체 선택 레이어를 만든다
                viewer.canvas.maskOverlay.prepare = { [weak self] in
                    self?.addAISelection(.subject)
                    self?.enterTool(.pan)
                    return true
                }
                enterTool(photo == nil ? .pan : .mask)
            }
        case "aiRemove", "smartErase", "selObject":
            // 붓질을 받아 AI에 넘긴다 (레이어는 결과가 오면 생긴다)
            let id = tool.id
            if id != "selObject" { AIEngine.shared.warmUp() }
            viewer.canvas.maskOverlay.clickMode = .quick
            viewer.canvas.maskOverlay.quickOverride = { [weak self] pts, _ in
                guard let self else { return }
                let r = self.layersTab.brushRadius
                if id == "selObject" {
                    let xs = pts.map(\.x), ys = pts.map(\.y)
                    let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -r, dy: -r)
                    self.selectObject(in: box)
                } else {
                    let s = MaskStroke(points: pts.flatMap { [Double($0.x), Double($0.y)] }, radius: r, hardness: 0.8)
                    self.aiRemove(strokes: [s], smart: id == "smartErase")
                }
            }
            enterTool(photo == nil ? .pan : .mask)
        case "transform":
            freeTransform(nil)
            return
        case "pen", "shape", "text":
            startVectorTool(tool.id)
            return
        case "measure": startMeasure(); return
        case "count": startCount(); return
        case "paint", "pixelPaint", "erase":
            startPainting(mode: ["paint": 0, "pixelPaint": 4, "erase": 1][tool.id] ?? 0)
            return
        case "smudge":
            liquify(tool: 0)
            return
        case "exportWeb":
            if ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] == nil { exportForWeb(nil) }
            return
        case "distort", "bump", "pinch", "twirl":
            liquify(tool: ["distort": 0, "bump": 1, "pinch": 2, "twirl": 3][tool.id] ?? 0)
            return
        case "fill", "gradient":
            let grad = tool.id == "gradient"
            if let id = layersTab.selectedID, let l = photo?.settings.layers.first(where: { $0.id == id }),
               l.isFill, (l.fillColor.count == 6) == grad {
                // 고른 칠 레이어를 그대로 쓴다
            } else if photo != nil {
                // 캔버스를 처음 누를 때 칠 레이어를 만든다 (그라디언트는 그 누름부터 바로 끌 수 있게 넘긴다)
                viewer.canvas.maskOverlay.prepare = { [weak self] in
                    self?.layersTab.addFillLayer(colors: grad ? [0, 0, 0, 1, 1, 1] : [0.5, 0.5, 0.5], gradient: grad)
                    return !grad
                }
            }
            enterTool(photo == nil ? .pan : .mask)
        default:
            enterTool(.pan)   // 준비 중인 도구
        }
    }

    /// 도구 옵션 패널에 넣을 내용. nil이면 준비 중 안내.
    func studioOptionsView(for tool: StudioTool) -> NSView? {
        // 대량 보정 모드에서 한 번도 열지 않은 패널은 여기서 처음 만들어진다. 그때 지금 사진 값을 넣는다.
        if let doc = photo {
            if !inspector.isViewLoaded { _ = inspector.view; inspector.show(doc) }
            if !shape.isViewLoaded { _ = shape.view; shape.sync(doc.settings) }
            if !retouch.isViewLoaded { _ = retouch.view; retouch.showCount(doc.settings.spots.count) }
            if !layersTab.isViewLoaded { _ = layersTab.view; layersTab.sync(doc.settings) }
        }
        switch tool.id {
        case "adjust":
            adjustContainer.attach(inspector.view)
            return adjustContainer
        case "whiteBalance": return inspector.view
        case "crop", "straighten", "keystone": return shape.view
        case "repair", "clone", "patch": return retouch.view
        case "selRect", "selOval", "selFree", "selRow", "selColumn", "selWand", "selColor", "selPolygon", "selMagnetic", "selQuick":
            selectionOptions.show(tool: tool.id)
            return selectionOptions
        case "selSubject", "fill", "gradient", "lighten", "darken", "saturate", "desaturate", "sharpen", "soften":
            // 고른 레이어가 없으면 레이어 탭 카드가 모두 숨어 빈칸이었다 → 무엇이 일어나는지 안내
            if layersTab.selectedID == nil {
                let what: [String: String] = [
                    "selSubject": "캔버스를 누르면 AI가 피사체를 골라 선택 레이어를 만듭니다.",
                    "fill": "캔버스를 누르면 단색 칠 레이어가 생깁니다. 색은 레이어를 고른 뒤 여기서 바꿉니다.",
                    "gradient": "캔버스에서 끌면 그 방향으로 그라디언트 칠 레이어가 생깁니다.",
                    "lighten": "캔버스를 칠하면 '밝게' 레이어가 생기고 칠한 곳이 밝아집니다.",
                    "darken": "캔버스를 칠하면 '어둡게' 레이어가 생기고 칠한 곳이 어두워집니다.",
                    "saturate": "캔버스를 칠하면 칠한 곳의 채도가 높아집니다.",
                    "desaturate": "캔버스를 칠하면 칠한 곳의 채도가 낮아집니다.",
                    "sharpen": "캔버스를 칠하면 칠한 곳이 선명해집니다.",
                    "soften": "캔버스를 칠하면 칠한 곳이 부드러워집니다.",
                ]
                return StudioOptionsPanel.note((what[tool.id] ?? "") + "\n\n레이어가 생기면 여기에 붓 크기·세기와 조정 값이 나옵니다.")
            }
            return layersTab.view
        case "arrange":
            arrangeOptions.sync()
            return arrangeOptions
        case "maskPaint":
            if layersTab.selectedID == nil {
                return StudioOptionsPanel.note(tool.id == "arrange"
                    ? "옮길 레이어를 왼쪽 목록에서 고르세요.\n지금은 이미지 레이어를 끌어 옮길 수 있습니다 (마스크가 전체일 때)."
                    : "마스크를 칠할 레이어를 왼쪽 목록에서 고르거나, 위 + 단추로 조정 레이어를 더하세요.")
            }
            return layersTab.view
        case "picker": return pickerView
        case "pen": penOptions.sync(); return penOptions
        case "measure", "count": syncCounts(); return measureOptions
        case "shape": shapeOptions.sync(); return shapeOptions
        case "text": textOptions.sync(); return textOptions
        case "paint", "pixelPaint", "erase":
            paintOptions.reload()
            return paintOptions
        case "style":
            syncStudioStyles()
            return studioStyles
        case "effects":
            studioEffects.browser.setSource(photo.map { $0.image(scale: Develop.guideScale) })
            syncStudioEffects()
            return studioEffects
        case "zoom", "hand": return StudioZoomOptions(canvas: viewer.canvas)
        case "aiRemove", "smartErase", "selObject":
            selectionOptions.show(tool: tool.id)
            return selectionOptions
        default: return nil
        }
    }

    /// 선택·붓 도구가 칠할 레이어: 고른 레이어가 맞으면 그대로, 아니면 새로 만든다.
    func ensureStudioLayer(kind: LayerMask.Kind, preset: String?) {
        guard let doc = photo else { return }
        if let id = layersTab.selectedID, let l = doc.settings.layers.first(where: { $0.id == id }),
           l.kind == "adjust", l.mask.kind == kind, l.preset == preset { return }
        layersTab.addLayer(kind, native: doc.nativeSize)
        guard let preset, var s = photo?.settings, let i = s.layers.indices.last else { return }
        let names = ["lighten": "밝게 (닷지)", "darken": "어둡게 (번)", "saturate": "채도 높이기", "desaturate": "채도 낮추기",
                     "sharpen": "선명하게", "soften": "부드럽게"]
        s.layers[i].preset = preset
        s.layers[i].name = "\(names[preset] ?? preset) \(s.layers.count)"
        switch preset {
        case "lighten": s.layers[i].adjust.exposure = 0.6
        case "darken": s.layers[i].adjust.exposure = -0.6
        case "saturate": s.layers[i].adjust.saturation = 40
        case "desaturate": s.layers[i].adjust.saturation = -60
        case "sharpen": s.layers[i].adjust.sharpen = 150
        case "soften": s.layers[i].adjust.blur = 4
        default: break
        }
        apply(s, dragging: false)
    }

    // MARK: - 레이어 메뉴

    private func studioAddMenu() -> NSMenu {
        let m = NSMenu()
        for (title, kind) in [("브러시 조정 레이어", LayerMask.Kind.brush), ("선형 그라디언트 조정 레이어", .linear),
                              ("원형 그라디언트 조정 레이어", .radial), ("전체 조정 레이어", .full)] {
            let item = m.addItem(withTitle: title, action: #selector(studioAddLayer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
        }
        m.addItem(.separator())
        m.addItem(withTitle: "피사체 선택 (AI)", action: #selector(selectSubjectAI(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "배경 선택 (AI)", action: #selector(selectBackgroundAI(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "사람 선택 (AI)", action: #selector(selectPersonAI(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "이미지 레이어 가져오기…", action: #selector(placeImageLayer(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "클립보드 그림 붙여넣기", action: #selector(pasteImageLayer(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "그룹으로 묶기", action: #selector(groupLayer(_:)), keyEquivalent: "").target = self
        return m
    }

    private func studioMoreMenu() -> NSMenu {
        let m = NSMenu()
        let t = layersTab
        for (title, sel) in [("복제", #selector(LayersTabController.duplicateLayer)), ("삭제", #selector(LayersTabController.removeLayer)),
                             ("위로", #selector(LayersTabController.layerUp)), ("아래로", #selector(LayersTabController.layerDown)),
                             ("그룹 풀기", #selector(LayersTabController.ungroupSelected))] {
            m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = t
        }
        return m
    }

    @objc func studioAddLayer(_ sender: NSMenuItem) {
        guard photo != nil, let raw = sender.representedObject as? String, let kind = LayerMask.Kind(rawValue: raw) else { return }
        layersTab.addLayer(kind, native: photo?.nativeSize)
        studioMode.selectTool("maskPaint")
    }

    // MARK: - 창 막대

    func studioToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case .studioSidebar: return button("레이어 보기", "sidebar.left", #selector(toggleStudioLayers(_:)))
        case .studioOptions: return button("도구 옵션 보기", "sidebar.right", #selector(toggleStudioOptions(_:)))
        case .studioCompare: return button("비교", "square.split.2x1", #selector(toggleOriginal(_:)))
        case .studioAdjust: return button("색 조정", "camera.filters", #selector(studioAdjustTool(_:)))
        case .studioCrop: return button("자르기", "crop", #selector(studioCropTool(_:)))
        case .studioExport: return button("내보내기", "square.and.arrow.up", #selector(exportPhotos(_:)))
        case .undoAdjust: return button("실행 취소", "arrow.uturn.backward", #selector(undoAdjust(_:)))
        case .redoAdjust: return button("다시 실행", "arrow.uturn.forward", #selector(redoAdjust(_:)))
        case .studioMore:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "더 보기"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "더 보기")
            item.showsIndicator = false
            let menu = NSMenu()
            menu.addItem(withTitle: "도구 사용자화…", action: #selector(studioCustomize(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "대량 보정 모드로", action: #selector(switchToEdit(_:)), keyEquivalent: "").target = self
            item.menu = menu
            return item
        case .studioZoom:
            // − 슬라이더 +
            let minus = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "축소")!, target: self, action: #selector(studioZoomOut(_:)))
            let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "확대")!, target: self, action: #selector(studioZoomIn(_:)))
            for b in [minus, plus] { b.isBordered = false; b.contentTintColor = .secondaryLabelColor }
            // 슬라이더는 배율의 로그 (1% ~ 1600%)
            let slider = NSSlider(value: 2, minValue: 0, maxValue: log10(1600), target: self, action: #selector(studioZoomSlid(_:)))
            slider.controlSize = .small
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let label = NSTextField(labelWithString: "맞춤")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let stack = NSStackView(views: [minus, slider, plus, label])
            stack.spacing = 4
            studioZoomSlider = slider
            studioZoomLabel = label
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "확대/축소"
            item.view = stack
            return item
        default: return nil
        }
    }

    func studioZoomChanged(_ z: (fitting: Bool, percent: CGFloat)) {
        studioZoomSlider?.doubleValue = log10(max(Double(z.percent), 1))
        studioZoomLabel?.stringValue = (z.fitting ? "맞춤 " : "") + "\(Int(z.percent.rounded()))%"
    }

    @objc func toggleStudioLayers(_ sender: Any?) { studioMode.showsLayers.toggle() }
    @objc func toggleStudioOptions(_ sender: Any?) { studioMode.showsOptions.toggle() }
    @objc func studioAdjustTool(_ sender: Any?) { studioMode.selectTool("adjust") }
    @objc func studioCropTool(_ sender: Any?) { studioMode.selectTool("crop") }
    @objc func studioCustomize(_ sender: Any?) { studioMode.customize() }
    @objc func studioZoomIn(_ sender: Any?) { activeCanvas.zoomBy(1.25) }
    @objc func studioZoomOut(_ sender: Any?) { activeCanvas.zoomBy(0.8) }
    @objc func studioZoomSlid(_ sender: NSSlider) { activeCanvas.setZoomPercent(CGFloat(pow(10, sender.doubleValue))) }
}

extension NSToolbarItem.Identifier {
    static let studioSidebar = Self("studioSidebar")
    static let studioZoom = Self("studioZoom")
    static let studioOptions = Self("studioOptions")
    static let studioCompare = Self("studioCompare")
    static let studioAdjust = Self("studioAdjust")
    static let studioCrop = Self("studioCrop")
    static let studioExport = Self("studioExport")
    static let studioMore = Self("studioMore")
}

extension StudioOptionsPanel {
    static func note(_ text: String) -> NSView {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 250
        stack.addArrangedSubview(t)
        return stack
    }
}

/// 확대/축소·손 도구 옵션: 맞춤, 100%, 배율 단추.
final class StudioZoomOptions: FlippedStackView {
    private weak var canvas: CanvasView?

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let row1 = NSStackView(views: [button("크기에 맞게", #selector(fit)), button("100%", #selector(actual))])
        let row2 = NSStackView(views: [50, 200, 400].map { p in
            let b = button("\(p)%", #selector(percent(_:)))
            b.tag = p
            return b
        })
        let hint = NSTextField(wrappingLabelWithString: "두 번 누르면 맞춤과 100%를 오갑니다. 트랙패드는 두 손가락으로 옮기고 모아서 확대합니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 250
        for v in [row1, row2, hint] { addArrangedSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ t: String, _ a: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: a)
        b.bezelStyle = .appPush
        return b
    }

    @objc private func fit() { canvas?.zoomToFit() }
    @objc private func actual() { canvas?.zoomToActual() }
    @objc private func percent(_ b: NSButton) { canvas?.setZoomPercent(CGFloat(b.tag)) }
}

/// 색상 피커 도구 옵션: 집은 색과 값 (Display P3).
final class StudioPickerView: FlippedStackView {
    private let swatch = NSView()
    /// 색상 견본: 누르면 붓·글자·모양 색으로, +는 마지막으로 집은 색을 더한다, ⌥누르기 지우기
    let swatches = SwatchesView()
    /// 마지막으로 집은 색 (sRGB 0~1)
    private(set) var lastColor: [Float]?
    private let values = NSTextField(wrappingLabelWithString: "사진을 누르면 그 자리(5×5 평균)의 색을 집습니다.")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 8
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        swatch.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        swatch.widthAnchor.constraint(equalToConstant: 260).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 64).isActive = true
        values.preferredMaxLayoutWidth = 260
        values.textColor = .secondaryLabelColor
        values.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        addArrangedSubview(swatch)
        addArrangedSubview(values)
        let title = NSTextField(labelWithString: "색상 견본")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        addArrangedSubview(title)
        addArrangedSubview(swatches)
        swatches.widthAnchor.constraint(equalToConstant: 260).isActive = true
        swatches.current = { [weak self] in self?.lastColor }
        let hint = NSTextField(wrappingLabelWithString: "견본을 누르면 칠하기 붓·고른 글자·고른 모양의 색이 됩니다. +는 지금 집은 색을 더하고, ⌥를 누르고 누르면 지웁니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 260
        addArrangedSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `c`: 화면 색 공간(Display P3) 0~1.
    func show(_ c: SIMD3<Float>) {
        let cl = SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
        let ns = NSColor(displayP3Red: CGFloat(cl.x), green: CGFloat(cl.y), blue: CGFloat(cl.z), alpha: 1)
        swatch.layer?.backgroundColor = ns.cgColor
        if let s = ns.usingColorSpace(.sRGB) {
            lastColor = [Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)].map { min(max($0, 0), 1) }
        }
        let (h, s, v) = ColorLUT.hsv(cl)
        let rgb = [cl.x, cl.y, cl.z].map { Int(($0 * 255).rounded()) }
        let hex = rgb.map { String(format: "%02X", $0) }.joined()
        values.stringValue = "RGB  \(rgb[0])  \(rgb[1])  \(rgb[2])\nHSB  \(Int(h.rounded()))°  \(Int((s * 100).rounded()))%  \(Int((v * 100).rounded()))%\n#\(hex)  (Display P3)"
    }
}

// MARK: - 효과 도구 (필터를 레이어에)

final class StudioEffectsPanel: NSStackView {
    let browser = EffectsBrowser()
    let editor = EffectsEditor()
    private let target = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        target.font = .systemFont(ofSize: 11)
        target.textColor = .secondaryLabelColor
        let line = NSBox(); line.boxType = .separator
        for v in [browser, line, target, editor] as [NSView] {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func showTarget(_ name: String?) {
        target.stringValue = name.map { "\($0)의 효과" } ?? "레이어를 고르지 않았습니다 — 효과를 누르면 새 효과 레이어를 만듭니다"
    }
}

extension MainWindowController {
    /// 효과를 걸 레이어: 고른 레이어(그룹 제외), 없으면 새 전체 조정 레이어 "효과"
    func effectsTargetIndex(create: Bool) -> Int? {
        guard var s = photo?.settings else { return nil }
        if let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), !s.layers[i].isGroup { return i }
        guard create else { return nil }
        var l = AdjustLayer(name: "효과 \(s.layers.count + 1)")
        l.mask.kind = .full
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "효과 레이어")
        layersTab.select(l.id)
        return photo?.settings.layers.firstIndex { $0.id == l.id }
    }

    func syncStudioEffects() {
        let p = studioEffects
        p.browser.onPick = { [weak self] kind in
            guard let self, let i = self.effectsTargetIndex(create: true), var s = self.photo?.settings else { return }
            var list = s.layers[i].adjust.fx
            list.append(LayerEffect(kind: kind))
            s.layers[i].adjust.effects = list
            self.replaceSettings(s, recordUndo: true, label: "효과 \(Effects.spec(kind)?.title ?? kind)")
            self.syncStudioEffects()
            self.studioMode.layersPanel.reload()
        }
        p.editor.onChange = { [weak self] list, dragging in
            guard let self, let i = self.effectsTargetIndex(create: false), var s = self.photo?.settings else { return }
            s.layers[i].adjust.effects = list.isEmpty ? nil : list
            if dragging { self.apply(s, dragging: true) } else { self.replaceSettings(s, recordUndo: true, label: "효과 바꾸기") }
        }
        let i = effectsTargetIndex(create: false)
        let layer = i.flatMap { photo?.settings.layers[$0] }
        p.showTarget(layer?.name)
        p.editor.show(layer?.adjust.fx ?? [])
    }
}

// MARK: - 스타일 도구 (레이어 스타일)

extension MainWindowController {
    func syncStudioStyles() {
        let id = layersTab.selectedID
        let layer = photo?.settings.layers.first { $0.id == id }
        studioStyles.show(layer?.styles, applicable: layer?.takesStyles ?? false)
        studioStyles.onChange = { [weak self] st, dragging in
            guard let self, let id = self.layersTab.selectedID, var s = self.photo?.settings,
                  let i = s.layers.firstIndex(where: { $0.id == id }), s.layers[i].takesStyles else { NSSound.beep(); return }
            s.layers[i].styles = st.isActive ? st : nil
            if dragging { self.apply(s, dragging: true) } else { self.replaceSettings(s, recordUndo: true, label: "레이어 스타일") }
        }
    }
}
