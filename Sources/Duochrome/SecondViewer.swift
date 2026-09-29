import AppKit

/// Window showing the current photo large on a second display.
/// Creates another canvas drawing the same document. Redraws along with every adjustment.
final class SecondViewerWindow: NSWindowController, NSWindowDelegate {
    let canvas = CanvasView()
    var onClose: (() -> Void)?

    convenience init() {
        // With another display, fill it; otherwise a normal window on the current display.
        let screens = NSScreen.screens
        let target = screens.count > 1 ? screens.first { $0 != NSScreen.main } ?? screens[1] : NSScreen.main
        let frame = target?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let w = NSWindow(contentRect: screens.count > 1 ? frame : frame.insetBy(dx: frame.width * 0.15, dy: frame.height * 0.15),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Duochrome 보기"
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.delegate = self
        canvas.tool = .pan
        w.contentView = canvas
        if screens.count > 1 { w.setFrame(frame, display: true) }
    }

    func show(_ doc: RawDocument?) {
        canvas.document = doc
        window?.title = doc?.url.lastPathComponent ?? "Duochrome 보기"
    }

    func refresh() { canvas.needsDisplay = true }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

extension MainWindowController {
    /// View → Show on Second Display (toggle)
    @objc func toggleSecondViewer(_ sender: Any?) {
        if let v = secondViewer { v.close(); secondViewer = nil; return }
        let v = SecondViewerWindow()
        v.onClose = { [weak self] in self?.secondViewer = nil }
        v.show(photo)
        v.showWindow(nil)
        v.canvas.zoomToFit()
        secondViewer = v
        window?.makeKeyAndOrderFront(nil)
    }
}
