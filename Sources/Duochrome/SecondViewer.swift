import AppKit

/// 두 번째 화면에 지금 사진을 크게 띄우는 창.
/// 캔버스를 하나 더 만들어 같은 문서를 그린다. 조정할 때마다 같이 다시 그린다.
final class SecondViewerWindow: NSWindowController, NSWindowDelegate {
    let canvas = CanvasView()
    var onClose: (() -> Void)?

    convenience init() {
        // 다른 화면이 있으면 그 화면을 꽉 채우고, 없으면 지금 화면에 보통 창으로.
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
    /// 보기 → 두 번째 화면에 보기 (켜고 끄기)
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
