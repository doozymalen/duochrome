import AppKit

/// Top-level code in main.swift isn't on the main actor, so creating AppKit objects
/// trips isolation checks. An @main entry point on the main actor is cleaner.
@main
struct DuochromeApp {
    @MainActor
    static func main() {
        // Launch only as an .app bundle. Running the bare executable shows a notice and quits.
        // Dev testing unlocks it with DUOCHROME_DEV=1
        if Bundle.main.bundleURL.pathExtension != "app", ProcessInfo.processInfo.environment["DUOCHROME_DEV"] == nil {
            FileHandle.standardError.write(Data("Duochrome은 Duochrome.app(응용 프로그램 폴더)으로 켜 주세요.\n".utf8))
            let a = NSAlert()
            a.messageText = "Duochrome.app으로 켜 주세요"
            a.informativeText = "응용 프로그램 폴더의 Duochrome을 여세요. 실행 파일만 따로 켤 수는 없습니다."
            a.runModal()
            exit(1)
        }
        if ProcessInfo.processInfo.environment["DUOCHROME_SELFTEST"] != nil { SelfTest.run() }
        if let pkg = ProcessInfo.processInfo.environment["DUOCHROME_CATALOG_TEST"] { SelfTest.catalogImport(pkg) }
        // Green accent color: set the system accent value (3 = green) in the app's defaults domain.
        // Standard controls (checkboxes, popups, sliders, text selection) all follow it.
        UserDefaults.standard.register(defaults: ["AppleAccentColor": 3, "AppleHighlightColor": "0.752941 0.964706 0.678431 Green"])
        let app = NSApplication.shared
        if ProcessInfo.processInfo.environment["DUOCHROME_ACCENT_CHECK"] != nil {
            let c = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            print(String(format: "강조 색 %.2f %.2f %.2f", c.redComponent, c.greenComponent, c.blueComponent))
            exit(0)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()
        // Dev only: log the actual cursor (position · hotspot · kind)
        if ProcessInfo.processInfo.environment["DUOCHROME_CURSORLOG"] != nil {
            var last = ""
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                guard let c = NSCursor.currentSystem else { return }
                let kind = [(NSCursor.arrow, "화살표"), (NSCursor.openHand, "손"), (NSCursor.closedHand, "쥔 손"), (NSCursor.crosshair, "십자"),
                            (NSCursor.iBeam, "글자"), (NSCursor.resizeLeftRight, "좌우 크기")]
                    .first { $0.0.hotSpot == c.hotSpot && $0.0.image.size == c.image.size }?.1 ?? "기타"
                let m = NSEvent.mouseLocation
                let line = String(format: "포인터 %.0f,%.0f %@", m.x, m.y, kind)
                if kind != last.split(separator: " ").last.map(String.init) { NSLog("%@", line) }
                last = line
            }
        }
        windowController = MainWindowController()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.backupOnQuit()
        AIEngine.shared.stop()
        ColabEngine.shared.stopOnQuit()
        windowController?.gphoto?.stop()
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController?.showWindow(nil)
        if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] == nil { ColabEngine.shared.cleanupStale() }
        // Dev only: log which view real mouse-downs hit (DUOCHROME_HITLOG=1)
        if ProcessInfo.processInfo.environment["DUOCHROME_HITLOG"] != nil {
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify]) { e in
                NSLog("HITLOG 사건 %d %@", e.type.rawValue, NSStringFromPoint(e.locationInWindow))
                return e
            }
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
                if let w = e.window, let frame = w.contentView?.superview {
                    var chain: [String] = []
                    var h = frame.hitTest(frame.convert(e.locationInWindow, from: nil))
                    while let x = h, chain.count < 14 {
                        let g = x.gestureRecognizers.map { "\(type(of: $0))(delay \($0.delaysPrimaryMouseButtonEvents ? 1 : 0))" }
                        chain.append("\(type(of: x))" + (g.isEmpty ? "" : "\(g)"))
                        h = x.superview
                    }
                    NSLog("HITLOG %@ key %d → %@", NSStringFromPoint(e.locationInWindow), w.isKeyWindow ? 1 : 0, chain.joined(separator: " < "))
                }
                return e
            }
        }
        // Daily/weekly/monthly backup: in the background when due
        if AppSettings.backupInterval >= 3, CatalogBackup.due, ProcessInfo.processInfo.environment["DUOCHROME_SNAPSHOT"] == nil,
           let wc = windowController {
            DispatchQueue.global(qos: .utility).async {
                _ = try? CatalogBackup.run(wc.library.catalog, to: URL(fileURLWithPath: AppSettings.backupFolder),
                                           previews: AppSettings.backupPreviews, keep: AppSettings.backupKeep)
            }
        }
        if ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil, let w = windowController?.window {
            NSLog("after show frame %@ visible %d", NSStringFromRect(w.frame), w.isVisible ? 1 : 0)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Dev only: when the screen is locked and screencapture fails, the app writes its window as PNG (DUOCHROME_WINDOW_PNG=path)
        if let out = ProcessInfo.processInfo.environment["DUOCHROME_WINDOW_PNG"], let w = windowController?.window {
            let delay = Double(ProcessInfo.processInfo.environment["DUOCHROME_WINDOW_PNG_DELAY"] ?? "") ?? 3
            // Dev only: scroll the inspector to this card (DUOCHROME_REVEAL=editor etc.)
            if let card = ProcessInfo.processInfo.environment["DUOCHROME_REVEAL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(delay - 1, 0.5)) { [weak self] in
                    self?.windowController?.inspector.reveal(card)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let frame = w.contentView?.superview else { return }
                guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                NSLog("window png %@", out)
            }
        }
        // Dev only: remote driver for a developer tool (DUOCHROME_DEV=1 + DUOCHROME_DRIVER=dir), see DevDriver.swift
        if let w = windowController?.window { DevDriver.startIfRequested(window: w) }
        // Dev only: open a photo right after launch.
        if let path = ProcessInfo.processInfo.environment["DUOCHROME_FOLDER"] {
            windowController?.openFolder(URL(fileURLWithPath: path))
        }
        if let path = ProcessInfo.processInfo.environment["DUOCHROME_OPEN"] {
            windowController?.openFileOrFolder(URL(fileURLWithPath: path))
        }
    }

    /// Files passed in via Finder "Open With".
    func application(_ sender: NSApplication, open urls: [URL]) {
        // duochrome:// URLs are commands from Shortcuts or other apps
        for url in urls where url.scheme == "duochrome" { windowController?.handleURL(url) }
        if let url = urls.first(where: { $0.isFileURL }) { windowController?.openFileOrFolder(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .image, .package]
        panel.message = "사진, Duochrome 문서(.duochrome), 외부 카탈로그(.cocatalog)를 열 수 있습니다."
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowController?.openFileOrFolder(url)
    }

    @objc func openFolder(_ sender: Any?) {
        windowController?.chooseFolder()
    }
}
