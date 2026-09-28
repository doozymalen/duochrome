import AppKit

/// main.swift 최상위 코드는 메인 액터가 아니어서 AppKit 객체를 만들면
/// 격리 검사에 걸린다. @main 진입점을 메인 액터로 두면 깔끔하다.
@main
struct DuochromeApp {
    @MainActor
    static func main() {
        // .app 묶음으로만 켠다. 실행 파일만 따로 켜면 알리고 끝낸다.
        // 개발 시험은 DUOCHROME_DEV=1로 풀어 준다
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
        // 강조 색을 초록으로: 앱 설정 영역에 시스템 강조 색 값(3 = 초록)을 둔다.
        // 기본 조작 요소(체크 상자·팝업·슬라이더·글자 선택)가 모두 이 값을 따른다.
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
        // 개발용: 실제 포인터 모양을 로그로 (위치 · 핫스폿 · 종류)
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
        // 개발용: 실제 마우스 누름이 어느 뷰에 닿는지 기록 (DUOCHROME_HITLOG=1)
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
        // 매일·매주·매달 백업: 때가 됐으면 뒤에서
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
        // 개발용: 화면이 잠겨 screencapture가 안 될 때를 위해 창 내용을 앱이 직접 PNG로 (DUOCHROME_WINDOW_PNG=경로)
        if let out = ProcessInfo.processInfo.environment["DUOCHROME_WINDOW_PNG"], let w = windowController?.window {
            let delay = Double(ProcessInfo.processInfo.environment["DUOCHROME_WINDOW_PNG_DELAY"] ?? "") ?? 3
            // 개발용: 속성 패널을 이 카드까지 굴린다 (DUOCHROME_REVEAL=editor 등)
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
        // 개발용: 실행하자마자 사진을 연다.
        if let path = ProcessInfo.processInfo.environment["DUOCHROME_FOLDER"] {
            windowController?.openFolder(URL(fileURLWithPath: path))
        }
        if let path = ProcessInfo.processInfo.environment["DUOCHROME_OPEN"] {
            windowController?.openFileOrFolder(URL(fileURLWithPath: path))
        }
    }

    /// Finder에서 "다음으로 열기"로 넘어온 파일.
    func application(_ sender: NSApplication, open urls: [URL]) {
        // duochrome:// 주소는 단축어·다른 앱에서 온 명령
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
