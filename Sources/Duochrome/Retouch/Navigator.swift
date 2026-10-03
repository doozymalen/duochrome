import AppKit

/// Navigator for the hand/zoom tools: the whole photo small, with the visible part outlined.
/// Click or drag in it to move the view; buttons below fit, show actual pixels, or zoom in steps.
final class NavigatorView: NSView {
    private weak var canvas: CanvasView?
    private var thumb: NSImage?
    private var thumbKey: DevelopSettings?
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 170) }

    func attach(_ canvas: CanvasView) {
        self.canvas = canvas
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: CanvasView.viewChanged, object: canvas, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        refreshThumb()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Renders the small photo in the background (again when the adjustments change)
    func refreshThumb() {
        guard let doc = canvas?.document, thumbKey != doc.settings else { needsDisplay = true; return }
        thumbKey = doc.settings
        let img = doc.image(scale: Develop.guideScale)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let k = 560 / max(img.extent.width, img.extent.height, 1)
            let small = img.transformed(by: .init(scaleX: k, y: k))
            guard let cg = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: Render.displaySpace) else { return }
            DispatchQueue.main.async {
                self?.thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self?.needsDisplay = true
            }
        }
    }

    /// Where the photo is drawn inside this view (aspect kept, centered)
    private var photoRect: CGRect {
        guard let size = canvas?.document?.pixelSize, size.width > 0, size.height > 0 else { return .zero }
        let k = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = photoRect
        guard !r.isEmpty, let canvas, let size = canvas.document?.pixelSize else { return }
        if let thumb { thumb.draw(in: r) } else { NSColor.black.withAlphaComponent(0.3).setFill(); r.fill() }
        let v = canvas.visibleImageRect
        let k = r.width / size.width
        let box = CGRect(x: r.minX + v.minX * k, y: r.minY + v.minY * k, width: v.width * k, height: v.height * k)
        // Dim what is outside the view only when zoomed in (the whole photo visible needs no box)
        if v.width < size.width - 1 || v.height < size.height - 1 {
            let outside = NSBezierPath(rect: r)
            outside.append(NSBezierPath(rect: box).reversed)
            NSColor.black.withAlphaComponent(0.45).setFill()
            outside.fill()
            let p = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1.5
            NSColor.white.setStroke()
            p.stroke()
        }
    }

    private func move(to event: NSEvent) {
        guard let canvas, let size = canvas.document?.pixelSize else { return }
        let r = photoRect
        guard r.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let k = size.width / r.width
        canvas.centerOn(CGPoint(x: (p.x - r.minX) * k, y: (p.y - r.minY) * k))
    }

    override func mouseDown(with event: NSEvent) { move(to: event) }
    override func mouseDragged(with event: NSEvent) { move(to: event) }
    override func resetCursorRects() { addCursorRect(photoRect, cursor: .openHand) }
}
