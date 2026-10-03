import AppKit

/// A canvas layer whose pointer depends on where it is (a handle, inside a frame, outside it), like the reference editor.
/// The view sets the pointer itself on every mouse move; the dev driver asks the same function, so both agree.
protocol PointerSource: NSView {
    /// The pointer for this point (view coordinates), nil to leave it to the cursor rects
    func pointer(at p: NSPoint) -> NSCursor?
}

extension NSView {
    /// The photo area not covered by the panels and bars, in this view's coordinates. Edit pointers belong only here:
    /// over a panel (or the tool bar) the pointer goes back to the arrow.
    var editArea: NSRect {
        // Through window coordinates: converting between views of different windows (or none yet) raises
        // A hidden layer has no visible rect: an empty intersection is the null rect (infinite origin), which addCursorRect rejects
        guard let w = window, let c = CanvasView.current, c.window === w else { return visibleRect.isNull ? .zero : visibleRect }
        let r = convert(c.convert(c.uncoveredRect, to: nil), from: nil).intersection(visibleRect)
        return r.isNull ? .zero : r
    }
}

extension PointerSource {
    /// The pointer this view shows at a point, nil outside the edit area (left to the panels' own pointers)
    func effectivePointer(at p: NSPoint) -> NSCursor? {
        editArea.contains(p) ? pointer(at: p) : nil
    }

    /// Call from mouseMoved / cursorUpdate. Leaving the edit area restores the arrow once (not on every move,
    /// so a text field's I-beam in a panel still shows)
    func updatePointer(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let id = ObjectIdentifier(self)
        if editArea.contains(p) {
            Pointers.outside.remove(id)
            pointer(at: p)?.set()       // nil: the cursor rect's pointer (brush circle) stays
        } else if !Pointers.outside.contains(id) {
            Pointers.outside.insert(id)
            NSCursor.arrow.set()
        }
    }

    /// Tracking area for mouse moves and cursor updates over the whole view (call from updateTrackingAreas)
    func installPointerTracking() {
        trackingAreas.filter { $0.userInfo?["pointer"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["pointer": true]))
    }
}

/// The system's own pointers for handles (nothing drawn here): the window-resize double arrows, the system move arrows,
/// and the accessibility set's corner rotate arrows. Each falls back to a public cursor if its file is missing.
enum Pointers {
    private static var cache: [String: NSCursor] = [:]
    /// Pointer sources whose pointer last left the edit area
    static var outside = Set<ObjectIdentifier>()

    /// The cache key of a pointer from here (dev driver labels)
    static func name(of c: NSCursor) -> String? { cache.first { $0.value === c }?.key }

    private static let hiServices = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors/"
    private static let accessibility = "/System/Library/PrivateFrameworks/AccessibilitySupport.framework/Versions/A/Frameworks/AccessibilityFoundation.framework/Versions/A/Resources/Cursors/"

    private static func cached(_ key: String, _ make: () -> NSCursor?) -> NSCursor? {
        if let c = cache[key] { return c }
        guard let c = make() else { return nil }
        cache[key] = c
        return c
    }

    /// A system cursor folder (cursor.pdf + info.plist with the hot spot)
    private static func system(_ name: String) -> NSCursor? {
        cached(name) {
            guard let img = NSImage(contentsOfFile: hiServices + name + "/cursor.pdf") else { return nil }
            let info = NSDictionary(contentsOfFile: hiServices + name + "/info.plist")
            let hot = NSPoint(x: (info?["hotx"] as? Double) ?? img.size.width / 2, y: (info?["hoty"] as? Double) ?? img.size.height / 2)
            return NSCursor(image: img, hotSpot: hot)
        }
    }

    /// An accessibility-set cursor: two template layers, the outline (top) in white under the glyph (bottom) in black,
    /// which is how the system pointers look
    private static func layered(_ name: String) -> NSCursor? {
        cached(name) {
            guard let top = NSImage(contentsOfFile: accessibility + name + "-top.pdf"),
                  let bottom = NSImage(contentsOfFile: accessibility + name + "-bottom.pdf") else { return nil }
            let size = top.size
            let img = NSImage(size: size, flipped: false) { r in
                for (layer, color) in [(top, NSColor.white), (bottom, NSColor.black)] {
                    let tinted = NSImage(size: size, flipped: false) { r2 in
                        layer.draw(in: r2); color.set(); r2.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: r)
                }
                return true
            }
            return NSCursor(image: img, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    /// Resize double arrow for a direction (degrees, 0 = left–right, counterclockwise), the nearest of the four
    static func resize(degrees: CGFloat) -> NSCursor {
        var d = Int(((degrees / 45).rounded() * 45).truncatingRemainder(dividingBy: 180))
        if d < 0 { d += 180 }
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = [0: .right, 45: .topRight, 90: .top, 135: .topLeft][d] ?? .right
            return cached("resize\(d)") { NSCursor.frameResize(position: position, directions: .all) }!
        }
        return d == 90 ? .resizeUpDown : .resizeLeftRight
    }

    /// Direction from a frame's center to a handle on it, for the resize arrow
    static func resize(from center: CGPoint, to handle: CGPoint) -> NSCursor {
        resize(degrees: atan2(handle.y - center.y, handle.x - center.x) * 180 / .pi)
    }

    /// Rotate arrow for the corner region the pointer is in (direction from the frame's center, view coordinates, y up)
    static func rotate(from center: CGPoint, at p: CGPoint) -> NSCursor {
        let east = p.x >= center.x, north = p.y >= center.y
        let name = "rotate" + (north ? "North" : "South") + (east ? "East" : "West")
        return layered(name) ?? .crosshair
    }

    /// Four-way arrows: dragging here moves the whole thing
    static var move: NSCursor { system("move") ?? .openHand }

    /// A point that can be dragged (perspective corners, pins, gradient ends)
    static var point: NSCursor { .openHand }
}
