import AppKit

/// Diagnostic trace (DUOCHROME_TRACE=1): logs every click and key in the window with the view that received it,
/// the current mode and tool, the selected layer, and what changed in the layer list afterwards.
/// Run the app from Terminal, reproduce a problem, and the log shows where the input went and what it did.
extension MainWindowController {
    func installTrace() {
        guard ProcessInfo.processInfo.environment["DUOCHROME_TRACE"] != nil else { return }
        tlog("on")
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let before = self.traceLayers()
            let what: String
            switch e.type {
            case .keyDown: what = "key \(e.charactersIgnoringModifiers ?? "?") mods \(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
            case .leftMouseDown: what = "down\(e.clickCount > 1 ? " ×\(e.clickCount)" : "")"
            case .leftMouseUp: what = "up"
            default: what = "right-down"
            }
            var chain: [String] = []
            if e.type != .keyDown, let frame = self.window?.contentView?.superview {
                var v = frame.hitTest(e.locationInWindow)
                while let view = v, chain.count < 4 { chain.append(String(describing: type(of: view))); v = view.superview }
            } else if let r = self.window?.firstResponder {
                chain.append("responder " + String(describing: type(of: r)))
            }
            tlog("\(what) → \(chain.joined(separator: " < ")) | \(self.traceState())")
            // What the event did to the layers (after it is handled)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let after = self.traceLayers()
                if after != before { tlog("  layers: \(before) → \(after)") }
            }
            return e
        }
    }

    func traceState() -> String {
        let layer = layersTab.selectedID.flatMap { id in photo?.settings.layers.first { $0.id == id } }
        let sel = layer.map { "\($0.kind)/\($0.mask.kind)\($0.isGroup ? "/group" : "")" } ?? "none"
        return "mode \(mode) studioTool \(retouchEditor.currentTool) canvasTool \(viewer.canvas.tool) selected \(sel) photo \(photo == nil ? "none" : "open")"
    }

    private func traceLayers() -> String {
        guard let s = photo?.settings else { return "-" }
        return "\(s.layers.count) [" + s.layers.map { "\($0.kind)/\($0.mask.kind)" }.joined(separator: ", ") + "]"
    }

    /// Called when a layer-edit tool is picked
    func traceTool(_ id: String) {
        guard ProcessInfo.processInfo.environment["DUOCHROME_TRACE"] != nil else { return }
        tlog("tool picked \(id) | \(traceState())")
    }
}

/// Unbuffered (stderr), so lines show up immediately even when piped
func tlog(_ s: String) { FileHandle.standardError.write(Data(("[trace] " + s + "\n").utf8)) }
