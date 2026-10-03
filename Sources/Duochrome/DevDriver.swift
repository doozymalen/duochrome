import AppKit

/// Dev-only remote driver (DUOCHROME_DEV=1 + DUOCHROME_DRIVER=<dir>). It lets a developer tool operate this app's own window by
/// appending JSON lines to `<dir>/cmd.jsonl`: events are posted into the real AppKit event queue (so hit testing, responder chains
/// and tracking loops behave as with a real mouse) and results are written to `<dir>/out.log`. It only ever touches this process.
///
/// Commands (coordinates are points, origin top-left of the window frame, same space as the `shot` PNG at 1×):
///   {"cmd":"shot","name":"a"}                            → <dir>/a.png, the composited window as macOS draws it (glass, Metal canvas);
///                                                           add "mode":"view" for the plain view render (works while the screen is locked)
///   {"cmd":"cursor","x":10,"y":20}                     → which pointer the app would show there (cursor rects, front to back)
///   {"cmd":"tree"}                                       → <dir>/tree.txt (controls with their frames and labels)
///   {"cmd":"click","x":10,"y":20,"count":1,"flags":"cmd,shift"}
///   {"cmd":"rclick","x":10,"y":20}
///   {"cmd":"press","x":10,"y":20,"sec":0.6}            (long press)
///   {"cmd":"clickid","id":"heal"}                        (clicks the center of the view with that identifier)
///   {"cmd":"drag","path":[[x,y],[x,y],…]}                (press at first point, release at last)
///   {"cmd":"trace","path":[[x,y],…],"stepMs":16,"frameEvery":4,"name":"t"}
///                                                        → a drag played at real-time pace: per-step main-thread busy time and the pointer
///                                                          shown there (<dir>/t.json), plus a frame (with a drawn pointer) every N steps (<dir>/t-000.png …)
///   {"cmd":"scroll","x":10,"y":20,"dy":-30,"dx":0}
///   {"cmd":"key","chars":"b","code":11,"flags":"cmd"}
///   {"cmd":"type","text":"hello"}
///   {"cmd":"wait","sec":1.5}
///   {"cmd":"activate"}                                   (brings the app to the front: an inactive window takes the first canvas click
///                                                          only to activate, like with a real mouse)
final class DevDriver {
    static var shared: DevDriver?

    static func startIfRequested(window: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        guard env["DUOCHROME_DEV"] != nil, let dir = env["DUOCHROME_DRIVER"] else { return }
        shared = DevDriver(dir: URL(fileURLWithPath: dir, isDirectory: true), window: window)
        shared?.start()
    }

    private let dir: URL
    private weak var window: NSWindow?
    private var done = 0
    private var busy = false
    private var timer: Timer?

    private init(dir: URL, window: NSWindow) { self.dir = dir; self.window = window }

    private func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "".write(to: dir.appendingPathComponent("out.log"), atomically: true, encoding: .utf8)
        try? "".write(to: dir.appendingPathComponent("cmd.jsonl"), atomically: true, encoding: .utf8)
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        // Common modes: keeps reading commands while a menu or a drag tracking loop runs (so esc can close a menu)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("driver ready \(dir.path)")
    }

    private func log(_ s: String) {
        guard let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("out.log")) else { return }
        h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
    }

    private func poll() {
        guard !busy, let text = try? String(contentsOf: dir.appendingPathComponent("cmd.jsonl"), encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        guard done < lines.count else { return }
        let line = lines[done]; done += 1
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let cmd = obj["cmd"] as? String else {
            log("\(done) bad json"); return
        }
        busy = true
        run(cmd, obj) { [weak self] msg in
            self?.log("\(self?.done ?? 0) \(cmd) \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.busy = false }
        }
    }

    // MARK: Geometry

    /// The view whose bounds the PNG and all coordinates use (the window frame view, so the toolbar is included).
    private var base: NSView? { window?.contentView?.superview ?? window?.contentView }

    private func windowPoint(_ x: Double, _ y: Double) -> CGPoint? {
        guard let v = base else { return nil }
        let p = v.isFlipped ? CGPoint(x: x, y: y) : CGPoint(x: x, y: v.bounds.height - y)
        return v.convert(p, to: nil)
    }

    private func flags(_ s: String?) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for part in (s ?? "").split(separator: ",") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd": f.insert(.command)
            case "shift": f.insert(.shift)
            case "opt", "alt": f.insert(.option)
            case "ctrl": f.insert(.control)
            default: break
            }
        }
        return f
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard let w = window else { return nil }
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    private func post(_ e: NSEvent?) { if let e { NSApp.postEvent(e, atStart: false) } }

    // MARK: Commands

    private func run(_ cmd: String, _ o: [String: Any], _ finish: @escaping (String) -> Void) {
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        let fl = flags(o["flags"] as? String)
        switch cmd {
        case "shot":
            let name = (o["name"] as? String) ?? "shot"
            let url = dir.appendingPathComponent(name + ".png")
            if (o["mode"] as? String) != "view", let w = window {
                // The composited window, like a user sees it. Runs off the main thread so the app keeps drawing meanwhile.
                DispatchQueue.global().async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", String(w.windowNumber), url.path]
                    try? p.run(); p.waitUntilExit()
                    let ok = FileManager.default.fileExists(atPath: url.path) && p.terminationStatus == 0
                    DispatchQueue.main.async { finish(ok ? "ok real \(name).png" : "fail real capture (status \(p.terminationStatus)); retry with mode=view") }
                }
                return
            }
            guard let v = base, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return finish("fail") }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            finish("ok view \(name).png \(Int(v.bounds.width))x\(Int(v.bounds.height))pt")
        case "cursor":
            finish(cursorAt(num("x") ?? 0, num("y") ?? 0))
        case "tree":
            finish(dumpTree())
        case "clickid":
            guard let v = base, let id = o["id"] as? String,
                  let target = v.allSubviews.first(where: { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor }) else {
                return finish("fail no view")
            }
            let c = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            post(mouse(.leftMouseDown, c)); post(mouse(.leftMouseUp, c))
            finish("ok")
        case "press":
            // Mouse down, held for "sec", then up (long press)
            guard let p = windowPoint(num("x") ?? 0, num("y") ?? 0) else { return finish("fail") }
            post(mouse(.leftMouseDown, p, flags: fl))
            DispatchQueue.main.asyncAfter(deadline: .now() + (num("sec") ?? 0.6)) { [weak self] in
                self?.post(self?.mouse(.leftMouseUp, p, flags: fl)); finish("ok")
            }
        case "click", "rclick":
            guard let p = windowPoint(num("x") ?? 0, num("y") ?? 0) else { return finish("fail") }
            let n = Int(num("count") ?? 1)
            let right = cmd == "rclick"
            for i in 1...max(n, 1) {
                post(mouse(right ? .rightMouseDown : .leftMouseDown, p, clicks: i, flags: fl))
                post(mouse(right ? .rightMouseUp : .leftMouseUp, p, clicks: i, flags: fl))
            }
            finish("ok")
        case "drag":
            guard let pts = (o["path"] as? [[Double]])?.compactMap({ $0.count == 2 ? windowPoint($0[0], $0[1]) : nil }), pts.count >= 2 else {
                return finish("fail path")
            }
            post(mouse(.leftMouseDown, pts[0], flags: fl))
            var i = 1
            func step() {
                if i < pts.count {
                    post(mouse(.leftMouseDragged, pts[i], flags: fl)); i += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step() }
                } else {
                    post(mouse(.leftMouseUp, pts[pts.count - 1], flags: fl)); finish("ok")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { step() }
        case "trace":
            guard let pts = (o["path"] as? [[Double]])?.compactMap({ $0.count == 2 ? ($0, windowPoint($0[0], $0[1])) : nil }), pts.count >= 2 else {
                return finish("fail path")
            }
            trace(pts.map { ($0.0, $0.1!) }, stepMs: num("stepMs") ?? 16, frameEvery: Int(num("frameEvery") ?? 0),
                  name: (o["name"] as? String) ?? "trace", flags: fl, finish: finish)
        case "scroll":
            guard let p = windowPoint(num("x") ?? 0, num("y") ?? 0), let w = window, let v = base else { return finish("fail") }
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(num("dy") ?? 0), wheel2: Int32(num("dx") ?? 0), wheel3: 0) else { return finish("fail") }
            cg.location = w.convertPoint(toScreen: p)
            // Scroll events aren't hit-tested by the queue the way clicks are, so deliver to the view under the point directly.
            let target = v.hitTest(v.convert(p, from: nil)) ?? v
            if let e = NSEvent(cgEvent: cg) { target.scrollWheel(with: e) }
            finish("ok \(type(of: target))")
        case "key":
            guard let w = window else { return finish("fail") }
            let chars = (o["chars"] as? String) ?? ""
            let code = UInt16(num("code") ?? 0)
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                post(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: fl, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: chars,
                                      charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code))
            }
            finish("ok")
        case "type":
            guard let w = window else { return finish("fail") }
            for ch in (o["text"] as? String) ?? "" {
                let s = String(ch)
                for t in [NSEvent.EventType.keyDown, .keyUp] {
                    post(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                          isARepeat: false, keyCode: 0))
                }
            }
            finish("ok")
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish(NSApp.isActive ? "ok" : "ok (not active yet)") }
        case "wait":
            DispatchQueue.main.asyncAfter(deadline: .now() + (num("sec") ?? 1)) { finish("ok") }
        default:
            finish("unknown command")
        }
    }



    // MARK: Drag trace

    /// Plays a drag at a steady pace and records how long the main thread was busy handling each event (a step over ~16 ms drops a frame),
    /// the pointer shown at that point, and periodic frames with the pointer drawn in, so the drag can be watched afterwards.
    private func trace(_ pts: [([Double], CGPoint)], stepMs: Double, frameEvery: Int, name: String, flags: NSEvent.ModifierFlags,
                       finish: @escaping (String) -> Void) {
        var rows = [[String: Any]]()
        var frames = 0
        post(mouse(.leftMouseDown, pts[0].1, flags: flags))
        var i = 1

        func frame(_ at: [Double], _ cursor: NSCursor?) {
            guard let v = base, let w = window else { return }
            // Real composited capture (includes the Metal canvas), taken synchronously while the drag waits at this step.
            let f = String(format: "%@-%03d.png", name, frames); frames += 1
            let url = dir.appendingPathComponent(f)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), url.path]
            try? p.run(); p.waitUntilExit()
            guard let c = cursor, let img = NSImage(contentsOf: url), let rep = img.representations.first else { return }
            let k = CGFloat(rep.pixelsWide) / v.bounds.width
            let out = NSImage(size: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            out.lockFocus()
            img.draw(in: CGRect(origin: .zero, size: out.size))
            let size = c.image.size
            let origin = CGPoint(x: (at[0] - c.hotSpot.x) * k, y: (v.bounds.height - at[1] - (size.height - c.hotSpot.y)) * k)
            c.image.draw(in: CGRect(origin: origin, size: CGSize(width: size.width * k, height: size.height * k)))
            out.unlockFocus()
            if let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                try? r.representation(using: .png, properties: [:])?.write(to: url)
            }
        }

        func step() {
            if i >= pts.count {
                post(mouse(.leftMouseUp, pts[pts.count - 1].1, flags: flags))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.contactSheet(name: name, count: frames)
                    let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
                    try? data?.write(to: self.dir.appendingPathComponent(name + ".json"))
                    let busy = rows.compactMap { $0["busyMs"] as? Double }.sorted()
                    let p95 = busy.isEmpty ? 0 : busy[Int(Double(busy.count - 1) * 0.95)]
                    finish(String(format: "ok %d steps, busy median %.1f ms, p95 %.1f ms, max %.1f ms, over16ms %d, frames %d", busy.count,
                                  busy.isEmpty ? 0 : busy[busy.count / 2], p95, busy.last ?? 0, busy.filter { $0 > 16.7 }.count, frames))
                }
                return
            }
            // The monitor runs right before the app handles the event; the run-loop observer fires once the main thread is idle again.
            var t0: CFTimeInterval?
            var monitor: Any?
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { e in
                if t0 == nil { t0 = CACurrentMediaTime() }
                return e
            }
            post(mouse(.leftMouseDragged, pts[i].1, flags: flags))
            var obs: CFRunLoopObserver?
            obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { o, _ in
                guard let start = t0 else { return }   // idle before the event arrived
                let busyMs = (CACurrentMediaTime() - start) * 1000
                var row: [String: Any] = ["i": i, "x": pts[i].0[0], "y": pts[i].0[1], "busyMs": (busyMs * 10).rounded() / 10]
                var shown: NSCursor?
                if frameEvery > 0 && i % frameEvery == 0 {
                    // Pointer as the app declares it at this point (the real pointer isn't moved by synthetic events).
                    let r = self.resolveCursor(pts[i].0[0], pts[i].0[1]); row["pointer"] = r.1; shown = r.0
                    frame(pts[i].0, shown)
                }
                rows.append(row)
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
                if let m = monitor { NSEvent.removeMonitor(m) }
                i += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + stepMs / 1000) { step() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { step() }
    }

    /// Tiles the trace frames into one image (<dir>/<name>-sheet.png, 3 columns) so a whole drag can be read at a glance.
    private func contactSheet(name: String, count: Int) {
        let imgs = (0..<count).compactMap { NSImage(contentsOf: dir.appendingPathComponent(String(format: "%@-%03d.png", name, $0))) }
        guard let first = imgs.first, !imgs.isEmpty else { return }
        let cols = 3, tileW: CGFloat = 640
        let tileH = tileW * first.size.height / first.size.width
        let rows = (imgs.count + cols - 1) / cols
        let sheet = NSImage(size: CGSize(width: tileW * CGFloat(cols), height: tileH * CGFloat(rows)))
        sheet.lockFocus()
        for (k, im) in imgs.enumerated() {
            let r = CGRect(x: CGFloat(k % cols) * tileW, y: CGFloat(rows - 1 - k / cols) * tileH, width: tileW, height: tileH)
            im.draw(in: r)
        }
        sheet.unlockFocus()
        if let t = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + "-sheet.png"))
        }
    }

    // MARK: Pointer

    private static var recorded: [(rect: NSRect, cursor: NSCursor)]?
    private static var swizzled = false

    /// Records `addCursorRect` calls while a view's `resetCursorRects` runs (dev driver only), so the pointer a view would show can be read.
    private static func installRecorder() {
        guard !swizzled else { return }
        swizzled = true
        guard let a = class_getInstanceMethod(NSView.self, #selector(NSView.addCursorRect(_:cursor:))),
              let b = class_getInstanceMethod(NSView.self, #selector(NSView.devAddCursorRect(_:cursor:))) else { return }
        method_exchangeImplementations(a, b)
    }

    fileprivate static func record(_ r: NSRect, _ c: NSCursor) { recorded?.append((r, c)) }

    private static func name(of c: NSCursor) -> String {
        let known: [(NSCursor, String)] = [(.arrow, "arrow"), (.openHand, "openHand"), (.closedHand, "closedHand"), (.crosshair, "crosshair"),
                                           (.iBeam, "iBeam"), (.resizeLeftRight, "resizeLeftRight"), (.resizeUpDown, "resizeUpDown"),
                                           (.pointingHand, "pointingHand"), (.operationNotAllowed, "notAllowed")]
        return known.first { $0.0 === c || ($0.0.hotSpot == c.hotSpot && $0.0.image.size == c.image.size) }?.1 ?? "custom \(c.image.size)"
    }

    /// Front-to-back views under the point whose cursor rects contain it; the first one wins, like AppKit's cursor rect resolution.
    private func cursorAt(_ x: Double, _ y: Double) -> String { resolveCursor(x, y).1 }

    private func resolveCursor(_ x: Double, _ y: Double) -> (NSCursor, String) {
        guard let v = base, let p0 = windowPoint(x, y) else { return (.arrow, "fail") }
        DevDriver.installRecorder()
        var front = [NSView]()
        func walk(_ view: NSView) {
            if view.isHidden { return }
            let local = view.convert(p0, from: nil)
            guard view.bounds.contains(local) || view === v else { return }
            front.append(view)
            for sub in view.subviews { walk(sub) }   // later subviews are drawn on top
        }
        walk(v)
        for view in front.reversed() {
            DevDriver.recorded = []
            view.resetCursorRects()
            let hits = DevDriver.recorded ?? []
            DevDriver.recorded = nil
            let local = view.convert(p0, from: nil)
            if let h = hits.last(where: { $0.rect.contains(local) }) {
                return (h.cursor, "ok \(DevDriver.name(of: h.cursor)) from \(type(of: view))")
            }
        }
        return (.arrow, "ok arrow (no cursor rect; default)")
    }

    private func dumpTree() -> String {
        guard let v = base else { return "fail" }
        var out = [String]()
        func walk(_ view: NSView, _ depth: Int) {
            if view.isHidden { return }
            let r = view.convert(view.bounds, to: v)
            let y = v.isFlipped ? r.minY : v.bounds.height - r.maxY
            var label = ""
            if let b = view as? NSButton {
                let t = (b.title.isEmpty || b.title == "Button") ? "" : b.title
                label = [t, b.toolTip.map { "tip:\($0)" } ?? "", b.accessibilityLabel().map { "ax:\($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            }
            else if let t = view as? NSTextField { label = t.stringValue }
            else if let s = view as? NSSlider { label = "value \(s.doubleValue)" }
            else { label = view.toolTip ?? "" }
            if view is NSControl || !label.isEmpty || view.acceptsFirstResponder {
                let ident = view.identifier.map { " #\($0.rawValue)" } ?? ""
                out.append(String(repeating: " ", count: min(depth, 12)) + "\(type(of: view))\(ident) [\(Int(r.minX)),\(Int(y)) \(Int(r.width))x\(Int(r.height))] \(label)")
            }
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(v, 0)
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
        return "ok tree.txt \(out.count) views"
    }
}

extension NSView {
    /// Swapped in for `addCursorRect` by DevDriver; after the swap this name calls the original.
    @objc func devAddCursorRect(_ rect: NSRect, cursor: NSCursor) {
        DevDriver.record(rect, cursor)
        devAddCursorRect(rect, cursor: cursor)
    }
}
