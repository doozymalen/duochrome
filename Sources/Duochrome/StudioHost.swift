import AppKit

/// Attaching layer-edit mode (Retouch/RetouchEditor.swift) to the window: entering/leaving the mode, toolbar zoom.
extension MainWindowController {
    func setupStudio() {
        LayerThumbs.backgroundProvider = { [weak self] in
            guard let self, let doc = self.photo else { return nil }
            let img = self.studioThumbnail(doc)
            LayerThumbs.backgroundThumb = img
            return img
        }
        layersTab.rowMenu = { [weak self] id in self?.layerContextMenu(id) ?? NSMenu() }
        // The toolbar zoom control follows the visible canvas (tethering has its own canvas)
        viewer.onZoom = { [weak self] z in if self?.mode != .tether { self?.studioZoomChanged(z) } }
        tetherMode.viewer.onZoom = { [weak self] z in if self?.mode == .tether { self?.studioZoomChanged(z) } }
        installKeyMap()
        installTrace()
        setupStudioSelection()
        setupRetouchEditor()
    }

    func enterStudio() {
        retouchEditor.attachCanvas(viewer.canvas)
        retouchEditor.reload()
        retouchEditor.restoreTool()
        viewer.canvas.selectionMask = studioSelection
        viewer.canvas.beforeIsBase = true
        updateHistogram()
        viewer.canvas.zoomToFit()
        window?.makeFirstResponder(viewer.canvas)
        // Once more so the search field doesn't grab focus when the window first appears.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .studio else { return }
            self.window?.makeFirstResponder(self.viewer.canvas)
        }
    }

    /// Background thumbnail in the layer list: the current develop result, small (redone when the photo or adjustments change).
    /// Background (develop result) thumbnail: cached one right away; otherwise render in the background and redraw the layer list when done.
    /// (rendering on main stalled close to a second every time the layer list redrew — i.e. every edit)
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
                // Redraw the list only if it still matches the current settings (otherwise the next redraw requests again)
                if self.photo?.settings == settings {
                    self.layersTab.sync(self.photo?.settings)
                    if self.mode == .studio { self.retouchEditor.reload() }
                }
            }
        }
        return stale
    }

    /// Leaving layer-edit mode: returns the canvas and moved panels to the batch-edit view.
    func leaveStudio() {
        viewer.canvas.selectionMask = nil
        viewer.canvas.beforeIsBase = false
        viewer.canvas.maskOverlay.prepare = nil
        viewer.canvas.maskOverlay.clickMode = .none
        viewer.canvas.maskOverlay.quickOverride = nil
        viewer.reclaimCanvas()
        layersTab.listHidden = false
        layersTab.sync(photo?.settings)   // Layers changed in layer edit go to the batch-edit list too
        tools.select(tools.selected)
        colorPickPurpose = 0
        enterTool(.pan)
        viewer.canvas.zoomToFit()
    }

    // MARK: - Toolbar zoom (shared by the modes)

    func studioZoomChanged(_ z: (fitting: Bool, percent: CGFloat)) {
        studioZoomSlider?.doubleValue = log10(max(Double(z.percent), 1))
        studioZoomLabel?.stringValue = (z.fitting ? "맞춤 " : "") + "\(Int(z.percent.rounded()))%"
    }

    @objc func studioZoomIn(_ sender: Any?) { activeCanvas.zoomBy(1.25) }
    @objc func studioZoomOut(_ sender: Any?) { activeCanvas.zoomBy(0.8) }
    @objc func studioZoomSlid(_ sender: NSSlider) { activeCanvas.setZoomPercent(CGFloat(pow(10, sender.doubleValue))) }
}

extension NSToolbarItem.Identifier {
    static let studioZoom = Self("studioZoom")
}
