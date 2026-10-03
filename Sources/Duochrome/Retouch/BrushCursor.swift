import AppKit

/// Pointer for brush tools: a circle the size of the brush (black and white outline so it shows on any photo) with a small
/// center mark, like the reference editor. Below a few points it falls back to the crosshair.
enum BrushCursor {
    private static var cache: (Int, NSCursor)?

    static func make(viewRadius r: CGFloat) -> NSCursor {
        let radius = Int(min(max(r, 0), 256).rounded())
        guard radius >= 4 else { return .crosshair }
        if let c = cache, c.0 == radius { return c.1 }
        let side = CGFloat(radius * 2 + 4)
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2
            NSColor.black.withAlphaComponent(0.55).setStroke(); ring.stroke()
            ring.lineWidth = 1
            NSColor.white.setStroke(); ring.stroke()
            let m = NSBezierPath()
            m.move(to: NSPoint(x: rect.midX - 3, y: rect.midY)); m.line(to: NSPoint(x: rect.midX + 3, y: rect.midY))
            m.move(to: NSPoint(x: rect.midX, y: rect.midY - 3)); m.line(to: NSPoint(x: rect.midX, y: rect.midY + 3))
            m.lineWidth = 1
            NSColor.white.withAlphaComponent(0.8).setStroke(); m.stroke()
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cache = (radius, c)
        return c
    }
}
