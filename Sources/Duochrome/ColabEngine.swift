import AppKit

// MARK: - Offloading: Colab L4
// Only work that's heavy on the Mac goes to Colab: generative fill/expand, denoise, 2× upscale. Erase and selection stay local.
// Uses Google's official Colab CLI to start (assign a VM), upload files, call functions in the kernel, fetch results, and stop.
// No browser window, web UI, or remote shell (to stay clear of the Colab terms on "bypassing the web UI").

enum AIRemote: Int {
    case colabL4 = 0, colabA100 = 1, local = 2
    static var current: AIRemote { AIRemote(rawValue: UserDefaults.standard.integer(forKey: "set.aiRemote")) ?? .colabL4 }
    var gpu: String? { self == .colabL4 ? "L4" : (self == .colabA100 ? "A100" : nil) }
}

final class ColabEngine {
    static let shared = ColabEngine()
    let session = "duochrome"
    /// GPU actually assigned (falls back to T4 without L4)
    private(set) var gpu: String?
    private(set) var ready = false { didSet { if ready != oldValue { state = ready ? .on : .off } } }
    /// State shown by the AI engine button in the top bar
    enum State { case off, starting, on }
    private(set) var state: State = .off {
        didSet { if state != oldValue { DispatchQueue.main.async { NotificationCenter.default.post(name: AIEngineButton.changed, object: nil) } } }
    }
    private var lastUse = Date()
    /// One Colab job at a time (never start the VM twice)
    private let opLock = NSLock()
    /// Why Colab couldn't be used (if set, the local engine is handling it as fallback). Shown in the top bar button tooltip
    private(set) var lastFailure: String?
    /// For a while after Colab failed, skip retrying and go straight to this Mac (instead of waiting tens of seconds each time). Starting from the button retries
    private var unavailableUntil: Date?
    var usable: Bool { unavailableUntil.map { Date() > $0 } ?? true }

    func markUnavailable(_ reason: String) {
        lastFailure = reason
        unavailableUntil = Date().addingTimeInterval(300)
        DispatchQueue.main.async { NotificationCenter.default.post(name: AIEngineButton.changed, object: nil) }
    }
    private var idleTimer: Timer?

    typealias Failure = AIEngine.Failure

    static var cli: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/colab") }
    static var uv: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv") }
    static var idleMinutes: Int {
        get { UserDefaults.standard.object(forKey: "set.colabIdle") as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "set.colabIdle") }
    }
    /// Hugging Face token: a user-only file in the user folder (the keychain asked for a password after rebuilds or renames)
    static var tokenFile: URL { AIEngine.root.deletingLastPathComponent().appendingPathComponent("secrets/huggingface") }
    static var hfToken: String? {
        get {
            if let s = try? String(contentsOf: tokenFile, encoding: .utf8), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
        set {
            if let v = newValue, !v.isEmpty { writeToken(v) } else { try? FileManager.default.removeItem(at: tokenFile) }
        }
    }

    private static func writeToken(_ v: String) {
        let dir = tokenFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(v.utf8), attributes: [.posixPermissions: 0o600])
    }

    static var remoteScript: URL? {
        if let u = Bundle.main.url(forResource: "colab-remote", withExtension: "py") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/colab-remote.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: CLI

    /// Runs the CLI and returns its output (stdout + stderr). onLine: per line (for progress)
    @discardableResult
    func cli(_ args: [String], stdin: String? = nil, timeout: Double = 900, onLine: ((String) -> Void)? = nil) throws -> String {
        try ensureCLI()
        let p = Process()
        p.executableURL = Self.cli
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        var text = ""
        var partial = ""
        let textLock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            textLock.lock()
            text += s
            partial += s
            var lines: [String] = []
            while let r = partial.range(of: "\n") {
                lines.append(String(partial[..<r.lowerBound]))
                partial = String(partial[r.upperBound...])
            }
            textLock.unlock()
            lines.forEach { onLine?($0) }
        }
        try p.run()
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let t0 = Date()
        while p.isRunning {
            if Date().timeIntervalSince(t0) > timeout { p.terminate(); throw Failure(message: "코랩 응답이 \(Int(timeout))초 안에 없음") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        out.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.readDataToEndOfFile()
        textLock.lock()
        if let s = String(data: rest, encoding: .utf8) { text += s }
        let all = text
        textLock.unlock()
        if ProcessInfo.processInfo.environment["DUOCHROME_COLABLOG"] != nil { print("코랩 \(args.first ?? "") → \(p.terminationStatus)\n\(all.suffix(1500))") }
        if all.contains("To authorize colab-cli") {
            throw Failure(message: "코랩 계정이 연결되지 않았습니다 (설정 > AI > 연결 확인·로그인)")
        }
        if p.terminationStatus != 0 || (args.first != "status" && all.contains("Session '") && Self.saysGone(all)) {
            if Self.saysGone(all) { ready = false }
            throw Failure(message: "코랩 \(args.first ?? "") 실패: " + Self.tail(all))
        }
        return all
    }

    static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(6).joined(separator: "\n")
    }

    /// Installs the CLI if missing (via the Python tool uv, inside the user folder only)
    func ensureCLI() throws {
        if FileManager.default.isExecutableFile(atPath: Self.cli.path) { return }
        guard FileManager.default.isExecutableFile(atPath: Self.uv.path) else { throw Failure(message: "파이썬 도구(uv)가 없습니다. AI 메뉴 > AI 엔진 설치를 먼저 하세요.") }
        let p = Process()
        p.executableURL = Self.uv
        p.arguments = ["tool", "install", "google-colab-cli"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard FileManager.default.isExecutableFile(atPath: Self.cli.path) else { throw Failure(message: "코랩 명령줄 도구를 설치하지 못함") }
    }

    /// Connects the Colab account (first time). When the CLI prints a Google consent URL, opens it in the browser,
    /// then passes along the auth code Google shows via askCode (asks the user on the main thread). Call from a background thread
    func login(askCode: @escaping () -> String?) throws {
        try ensureCLI()
        let p = Process()
        p.executableURL = Self.cli
        p.arguments = ["sessions"]
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inPipe
        var text = ""
        let lock = NSLock()
        var asked = false
        out.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            lock.lock(); text += s; let all = text; lock.unlock()
            guard !asked, all.contains("authorization code"),
                  let r = all.range(of: "https://accounts.google.com[^\\s]+", options: .regularExpression),
                  let url = URL(string: String(all[r])) else { return }
            asked = true
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
                let code = askCode()
                inPipe.fileHandleForWriting.write(Data(((code ?? "") + "\n").utf8))
            }
        }
        try p.run()
        let t0 = Date()
        while p.isRunning {
            if Date().timeIntervalSince(t0) > 600 { p.terminate(); throw Failure(message: "로그인이 10분 안에 끝나지 않음") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let all = text; lock.unlock()
        if p.terminationStatus != 0 || all.contains("Aborted") || all.lowercased().contains("error") {
            throw Failure(message: "로그인 실패: " + Self.tail(all))
        }
    }

    // MARK: Start / stop

    /// The CLI sometimes returns success even without a session, so check the text (e.g. when Colab reclaimed the VM)
    private func sessionAlive() -> Bool {
        guard let out = try? cli(["status", "-s", session], timeout: 60) else { return false }
        return !Self.saysGone(out)
    }

    static func saysGone(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("not found") || t.contains("no active session") || t.contains("pruned")
    }

    /// Start (only from the top bar button or when picking an AI tool). Prepares in the background; stops automatically when idle
    func start(fallback: (() -> Void)? = nil) {
        guard state == .off else { return }
        unavailableUntil = nil      // Starting manually retries
        lastFailure = nil
        state = .starting
        DispatchQueue.global(qos: .userInitiated).async {
            self.opLock.lock()
            defer { self.opLock.unlock() }
            do {
                try self.ensureReadyLocked()
                self.lastUse = Date()
                DispatchQueue.main.async { self.scheduleIdleStop() }
            } catch {
                self.state = self.ready ? .on : .off
                self.markUnavailable(error.localizedDescription)
                AIRegion.notice("코랩 연결 안 됨 → 이 맥 엔진으로", error.localizedDescription)
                fallback?()
            }
        }
    }

    /// Starts the VM and prepares the engine (call on a background thread, inside opLock)
    private func ensureReadyLocked() throws {
        if ready, sessionAlive() { return }
        ready = false
        state = .starting
        var ok = false
        var created = false
        defer {
            if !ok {
                state = .off
                if created { _ = try? cli(["stop", "-s", session], timeout: 60) }
            }
        }
        guard let token = Self.hfToken, !token.isEmpty else {
            throw Failure(message: "허깅페이스 읽기 토큰이 없습니다. 설정 > AI에서 넣어 주세요 (사진 생성 모델을 받는 데 필요).")
        }
        guard let script = Self.remoteScript else { throw Failure(message: "원격 스크립트를 찾지 못함") }
        let want = AIRemote.current.gpu ?? "L4"
        JobCenter.shared.begin("colab", title: "코랩 \(want) 켜는 중", detail: "가상 머신 배정")
        defer { JobCenter.shared.end("colab") }
        if !sessionAlive() {
            do {
                try cli(["new", "-s", session, "--gpu", want], timeout: 600)
                created = true
                gpu = want
            } catch {
                // If L4/A100 is unavailable, use T4 (slower but runs the same models)
                JobCenter.shared.detail("colab", "\(want)가 없어 T4로")
                try cli(["new", "-s", session, "--gpu", "T4"], timeout: 600)
                created = true
                gpu = "T4"
            }
        }
        // Upload the token as a file (in a command it would stay in Colab's execution history)
        JobCenter.shared.detail("colab", "엔진 준비")
        try cli(["exec", "-s", session, "-f", script.path], timeout: 120)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-hf-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: tmp) }
        try cli(["upload", "-s", session, tmp.path, "/root/.cache/huggingface/token"], timeout: 120)
        let gpuLine = (try? cli(["exec", "-s", session], stdin: "duochrome_gpu()\n", timeout: 60)) ?? ""
        if let r = gpuLine.range(of: "DUOCHROME_GPU ") {
            let name = gpuLine[r.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
            for g in ["L4", "A100", "T4", "H100"] where name.contains(g) { gpu = g }
        }
        // Make Duochrome custom nodes (erase, reflection removal) match this Mac's
        let nodes = FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-nodes-\(UUID().uuidString).py")
        try AIEngine.nodeSource.write(to: nodes, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: nodes) }
        try cli(["upload", "-s", session, nodes.path, "/content/duochrome_nodes.py"], timeout: 120)
        JobCenter.shared.begin("colab", title: "코랩 \(gpu ?? want) 준비 중", detail: "엔진 설치")
        try cli(["exec", "-s", session, "--timeout", "60"], stdin: "duochrome_setup_start()\n", timeout: 90)
        try waitRemote("setup", limit: 2400) { step in
            if step.hasPrefix("@@단계 ") { JobCenter.shared.detail("colab", String(step.dropFirst(5))) }
        }
        ok = true
        ready = true
        lastFailure = nil
        unavailableUntil = nil
    }

    /// Runs one workflow on Colab. inputs: (name, PNG/JPEG data) to upload into the engine input folder
    func run(_ workflow: [String: Any], inputs: [(String, Data)], title: String, jpeg: Bool = false) throws -> Data {
        opLock.lock()
        defer { opLock.unlock() }
        do { return try runLocked(workflow, inputs: inputs, title: title, jpeg: jpeg) } catch {
            // If the VM stopped or the kernel restarted, try once more (re-prepare)
            let msg = error.localizedDescription
            guard msg.contains("NameError") || msg.contains("not found") || msg.contains("No active") || msg.contains("session") else { throw error }
            ready = false
            return try runLocked(workflow, inputs: inputs, title: title, jpeg: jpeg)
        }
    }

    private func runLocked(_ workflow: [String: Any], inputs: [(String, Data)], title: String, jpeg: Bool) throws -> Data {
        try ensureReadyLocked()
        let job = "j\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duochrome-colab-\(job)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        JobCenter.shared.detail("ai-\(title)", "코랩으로 보내는 중")
        // Rename inputs by job id so jobs don't mix
        var wfText = String(data: try JSONSerialization.data(withJSONObject: workflow), encoding: .utf8) ?? "{}"
        for (name, data) in inputs {
            let remoteName = "\(job)-\(name)"
            wfText = wfText.replacingOccurrences(of: "\"\(name)\"", with: "\"\(remoteName)\"")
            let f = dir.appendingPathComponent(remoteName)
            try data.write(to: f)
            try cli(["upload", "-s", session, f.path, "/content/ComfyUI/input/\(remoteName)"], timeout: 900)
        }
        let wf = dir.appendingPathComponent("\(job).json")
        try wfText.write(to: wf, atomically: true, encoding: .utf8)
        try cli(["upload", "-s", session, wf.path, "/content/duochrome_jobs/\(job).json"], timeout: 120)
        JobCenter.shared.detail("ai-\(title)", "코랩 \(gpu ?? "")에서 처리 중")
        try cli(["exec", "-s", session, "--timeout", "60"], stdin: "duochrome_job_start(\"\(job)\", jpeg=\(jpeg ? "True" : "False"))\n", timeout: 90)
        try waitRemote(job, limit: 1800) { _ in }
        JobCenter.shared.detail("ai-\(title)", "결과 받는 중")
        let local = dir.appendingPathComponent("out.png")
        try cli(["download", "-s", session, "/content/duochrome_jobs/\(job)-out.png", local.path], timeout: 900)
        _ = try? cli(["exec", "-s", session], stdin: "import os; os.remove('/content/duochrome_jobs/\(job)-out.png'); os.remove('/content/duochrome_jobs/\(job).json')\n", timeout: 60)
        lastUse = Date()
        DispatchQueue.main.async { self.scheduleIdleStop() }
        return try Data(contentsOf: local)
    }

    /// Polls every 2 s with short commands until the kernel background job finishes. If a poll hangs, poll again after a minute
    private func waitRemote(_ name: String, limit: Double, step: (String) -> Void) throws {
        let t0 = Date()
        var misses = 0
        while Date().timeIntervalSince(t0) < limit {
            Thread.sleep(forTimeInterval: 2)
            guard let out = try? cli(["exec", "-s", session, "--timeout", "30"], stdin: "duochrome_status(\"\(name)\")\n", timeout: 60) else {
                misses += 1
                if misses >= 5 || !sessionAlive() { throw Failure(message: "코랩과 연락이 끊겼습니다") }
                continue
            }
            misses = 0
            // A restarted kernel lacks the functions → re-prepare (run() retries once)
            if out.contains("NameError") { ready = false; throw Failure(message: "코랩 커널이 다시 시작됨 (NameError)") }
            if let r = out.range(of: "DUOCHROME_STEP ") { step(String(out[r.upperBound...].split(separator: "\n").first ?? "")) }
            guard let r = out.range(of: "DUOCHROME_STATE ") else { continue }
            let state = String(out[r.upperBound...].split(separator: "\n").first ?? "")
            if state == "done" { return }
            if state.hasPrefix("error") { throw Failure(message: "코랩 작업 실패: " + state.dropFirst(7)) }
            if state == "unknown" { ready = false; throw Failure(message: "코랩 커널이 다시 시작되어 작업을 잃음 (NameError)") }
        }
        throw Failure(message: "코랩 작업이 \(Int(limit / 60))분 안에 끝나지 않음")
    }

    /// Stops after a period of disuse (usage is consumed while it's on)
    private func scheduleIdleStop() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard self.ready else { t.invalidate(); return }
            if Date().timeIntervalSince(self.lastUse) > Double(Self.idleMinutes * 60) {
                t.invalidate()
                DispatchQueue.global(qos: .utility).async { self.stop("\(Self.idleMinutes)분 동안 쓰지 않음") }
            }
        }
    }

    /// Stops and releases the VM
    func stop(_ reason: String = "") {
        if ProcessInfo.processInfo.environment["DUOCHROME_COLABLOG"] != nil { print("코랩 끄기 까닭: \(reason)") }
        opLock.lock()
        defer { opLock.unlock() }
        guard ready || sessionAlive() else { state = .off; return }
        _ = try? cli(["stop", "-s", session], timeout: 60)
        ready = false
        state = .off
        gpu = nil
    }

    /// On launch: if a VM was left over from an abnormal exit last time, stop it (usage is consumed while it's on)
    func cleanupStale() {
        guard FileManager.default.isExecutableFile(atPath: Self.cli.path), !ready, state == .off else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let out = try? self.cli(["sessions"], timeout: 60), out.contains("[\(self.session)]") else { return }
            self.stop("지난번에 남은 가상 머신")
        }
    }

    /// On quit: stop if running (waits at most a few seconds)
    func stopOnQuit() {
        guard ready, FileManager.default.isExecutableFile(atPath: Self.cli.path) else { return }
        let p = Process()
        p.executableURL = Self.cli
        p.arguments = ["stop", "-s", session]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let t0 = Date()
        while p.isRunning && Date().timeIntervalSince(t0) < 8 { Thread.sleep(forTimeInterval: 0.1) }
    }
}
