import AppKit
import ImageIO

// MARK: - 테더링 (유선 USB 전용): 공개 라이브러리 libgphoto2로 카메라 설정 원격 변경·라이브 뷰·초점·촬영
// 캐논 EDSDK는 개인이 받기 어려워 쓰지 않는다. 도우미(tether-helper.py)가 카메라를 잡고,
// Duochrome과는 JSON 한 줄씩 주고받는다. 도우미를 못 쓰면 macOS 기본 ImageCaptureCore(TetherCamera)로 물러선다.

final class GPhotoCamera {
    struct Setting {
        let label: String
        let value: String
        let choices: [String]
        let readonly: Bool
    }

    var onStatus: ((String) -> Void)?
    var onDownloaded: ((URL) -> Void)?
    var onConfig: (([String: Setting]) -> Void)?
    var onFrame: ((CGImage) -> Void)?
    var onLive: ((Bool) -> Void)?
    var onConnected: ((Bool) -> Void)?
    /// 도우미를 쓸 수 없을 때 (설치 실패 등) — 기본 방식으로 물러서게
    var onUnavailable: ((String) -> Void)?

    var folder: URL { didSet { send(["cmd": "folder", "path": folder.path]) } }
    private(set) var connected = false
    private(set) var model = ""
    private(set) var settings: [String: Setting] = [:]
    var canShoot: Bool { connected }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let decodeQueue = DispatchQueue(label: "tether.frames", qos: .userInteractive)
    private var decoding = false

    init(folder: URL) { self.folder = folder }

    static var root: URL { AIEngine.root.deletingLastPathComponent().appendingPathComponent("Tether") }
    static var python: URL { root.appendingPathComponent(".venv/bin/python") }
    static var script: URL? {
        if let u = Bundle.main.url(forResource: "tether-helper", withExtension: "py") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tether-helper.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// 도우미 환경 (처음 한 번, 사용자 폴더 안에만: 파이썬 3.11 + python-gphoto2. 라이브러리가 함께 들어 있다)
    static func ensureInstalled() throws {
        if FileManager.default.isExecutableFile(atPath: python.path) {
            let check = Process()
            check.executableURL = python
            check.arguments = ["-c", "import gphoto2"]
            check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
            try check.run(); check.waitUntilExit()
            if check.terminationStatus == 0 { return }
        }
        let uv = ColabEngine.uv
        guard FileManager.default.isExecutableFile(atPath: uv.path) else {
            throw AIEngine.Failure(message: "파이썬 도구(uv)가 없습니다. AI 메뉴 > AI 엔진 설치를 먼저 하세요.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["venv", "-q", "-p", "3.11", root.appendingPathComponent(".venv").path],
                     ["pip", "install", "-q", "-p", python.path, "gphoto2"]] {
            let p = Process()
            p.executableURL = uv
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw AIEngine.Failure(message: "테더링 도구 설치 실패 (\(args.first ?? ""))") }
        }
    }

    func start() {
        onStatus?("테더링 도구 준비 중…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.ensureInstalled()
                guard let script = Self.script else { throw AIEngine.Failure(message: "테더링 도우미가 없습니다") }
                let p = Process()
                p.executableURL = Self.python
                p.arguments = ["-u", script.path]
                var env = ProcessInfo.processInfo.environment
                env["PYTHONWARNINGS"] = "ignore"
                p.environment = env
                let out = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardInput = inp
                p.standardError = FileHandle.nullDevice
                out.fileHandleForReading.readabilityHandler = { [weak self] h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    self?.receive(d)
                }
                p.terminationHandler = { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.process === p else { return }
                        self.process = nil
                        self.connected = false
                        self.onConnected?(false)
                        self.onStatus?("테더링 도우미가 멈췄습니다.")
                    }
                }
                try p.run()
                DispatchQueue.main.async {
                    self.process = p
                    self.input = inp.fileHandleForWriting
                    self.send(["cmd": "folder", "path": self.folder.path])
                    self.send(["cmd": "connect"])
                }
            } catch {
                DispatchQueue.main.async { self.onUnavailable?(error.localizedDescription) }
            }
        }
    }

    func stop() {
        send(["cmd": "quit"])
        let p = process
        process = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
    }

    // MARK: 명령

    func shoot() { send(["cmd": "capture"]) }
    func set(_ name: String, _ value: String) { send(["cmd": "set", "name": name, "value": value]) }
    func live(_ on: Bool) { send(["cmd": "live", "on": on]) }
    func autofocus() { send(["cmd": "af"]) }
    /// step: "Near 3" … "Far 3" (캐논 수동 초점 구동)
    func focus(_ step: String) { send(["cmd": "focus", "step": step]) }
    func zoom(_ value: String) { send(["cmd": "zoom", "value": value]) }

    private func send(_ obj: [String: Any]) {
        guard let input, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        input.write(d + Data("\n".utf8))
    }

    // MARK: 소식

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[(nl + 1)...])
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let ev = obj["ev"] as? String else { continue }
            if ev == "frame" { frame(obj["jpeg"] as? String); continue }
            DispatchQueue.main.async { self.handle(ev, obj) }
        }
    }

    /// 라이브 뷰 한 장: 앞 장을 아직 푸는 중이면 버린다 (늦게 따라가며 쌓이지 않게)
    private func frame(_ b64: String?) {
        guard let b64, !decoding, let data = Data(base64Encoded: b64) else { return }
        decoding = true
        decodeQueue.async {
            defer { self.decoding = false }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            DispatchQueue.main.async { self.onFrame?(img) }
        }
    }

    private func handle(_ ev: String, _ obj: [String: Any]) {
        switch ev {
        case "connected":
            connected = true
            model = obj["model"] as? String ?? "카메라"
            onConnected?(true)
            onStatus?("연결됨: \(model)")
        case "disconnected":
            connected = false
            onConnected?(false)
            onLive?(false)
            onStatus?("카메라 연결이 끊겼습니다. 다시 꽂으면 알아서 붙습니다.")
        case "config":
            var out: [String: Setting] = [:]
            for (k, v) in (obj["items"] as? [String: [String: Any]]) ?? [:] {
                out[k] = Setting(label: v["label"] as? String ?? k, value: v["value"] as? String ?? "",
                                 choices: v["choices"] as? [String] ?? [], readonly: v["readonly"] as? Bool ?? false)
            }
            settings = out
            onConfig?(out)
        case "file":
            guard let p = obj["path"] as? String else { return }
            let url = TetherNaming.rename(URL(fileURLWithPath: p))
            onStatus?("받음: \(url.lastPathComponent)")
            onDownloaded?(url)
        case "live":
            onLive?(obj["on"] as? Bool ?? false)
        case "status":
            if let m = obj["msg"] as? String { onStatus?(m) }
        case "error":
            if let m = obj["msg"] as? String { onStatus?(m) }
        default: break
        }
    }
}

// MARK: - 다음 촬영 이름 규칙 (설정 > 테더링 > 파일 이름): {날짜} {시각} {순번} {원래이름}

enum TetherNaming {
    /// RAW+JPEG처럼 같은 원래 이름으로 잇달아 오는 파일은 같은 새 이름을 쓴다
    private static var recent: [String: (String, Date)] = [:]

    static func rename(_ url: URL, rule: String = AppSettings.tetherNaming, now: Date = Date()) -> URL {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty, rule != "{원래이름}" else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        let newStem: String
        if let (s, t) = recent[stem], now.timeIntervalSince(t) < 10 {
            newStem = s
        } else {
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
            let tf = DateFormatter(); tf.dateFormat = "HHmmss"
            let existing = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            // 방금 받은 파일 자신과 RAW+JPEG 짝은 세지 않는다 (경로 표기가 /private/var 와 /var 처럼 달라도 이름으로)
            let stems = Set(existing.filter { Library.supported.contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent != stem }
                .map { $0.deletingPathExtension().lastPathComponent })
            let seq = String(format: "%04d", stems.count + 1)
            newStem = rule.replacingOccurrences(of: "{날짜}", with: df.string(from: now))
                .replacingOccurrences(of: "{시각}", with: tf.string(from: now))
                .replacingOccurrences(of: "{순번}", with: seq)
                .replacingOccurrences(of: "{원래이름}", with: stem)
                .replacingOccurrences(of: "/", with: "-")
            recent[stem] = (newStem, now)
        }
        var dst = folder.appendingPathComponent(newStem).appendingPathExtension(ext)
        var n = 1
        while FileManager.default.fileExists(atPath: dst.path) && dst != url {
            dst = folder.appendingPathComponent("\(newStem)-\(n)").appendingPathExtension(ext); n += 1
        }
        guard dst != url, (try? FileManager.default.moveItem(at: url, to: dst)) != nil else { return url }
        return dst
    }
}

// MARK: - 라이브 뷰와 구도 오버레이 (뷰어 캔버스 위에 뜬다)

final class LiveOverlayView: NSView {
    let live = NSImageView()
    let reference = NSImageView()
    let grid = GridLines()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [live, reference] {
            v.imageScaling = .scaleProportionallyUpOrDown
            v.imageAlignment = .alignCenter
            addSubview(v)
        }
        reference.alphaValue = CGFloat(UserDefaults.standard.object(forKey: "tether.overlayAlpha") as? Double ?? 0.4)
        addSubview(grid)
        live.isHidden = true
        reference.isHidden = true
        grid.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 누르기는 아래 캔버스로
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        var r = bounds
        if let c = superview as? CanvasView {
            let i = c.fitInsets
            r = NSRect(x: i.left, y: i.bottom, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        }
        live.frame = r
        // 오버레이·격자는 라이브 뷰 그림(또는 캔버스)의 실제 그림 영역에 맞춘다
        let size = live.image?.size ?? reference.image?.size ?? r.size
        let fit = Self.aspectFit(size, in: r)
        reference.frame = fit
        grid.frame = fit
    }

    static func aspectFit(_ s: NSSize, in r: NSRect) -> NSRect {
        guard s.width > 0, s.height > 0 else { return r }
        let k = min(r.width / s.width, r.height / s.height)
        let w = s.width * k, h = s.height * k
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    final class GridLines: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.45).setStroke()
            let p = NSBezierPath()
            for i in 1...2 {
                let x = bounds.width * CGFloat(i) / 3, y = bounds.height * CGFloat(i) / 3
                p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: bounds.height))
                p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: bounds.width, y: y))
            }
            p.lineWidth = 1
            p.stroke()
        }
    }
}
