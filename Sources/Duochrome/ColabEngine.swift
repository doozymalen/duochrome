import AppKit

// MARK: - 바깥 처리: 코랩 L4
// 생성형 채우기·확장, 노이즈 제거, 2배 확대처럼 맥에서 무거운 일만 코랩으로 보낸다. 지우기·선택은 맥 안에서.
// 구글 공식 코랩 명령줄 도구로 켜고(가상 머신 배정), 파일을 올리고, 커널 안 함수를 부르고, 결과를 받고, 끈다.
// 브라우저 창·웹 화면·원격 접속을 쓰지 않는다 (코랩 이용 규정의 "웹 화면으로 우회"에 걸리지 않게).

enum AIRemote: Int {
    case colabL4 = 0, colabA100 = 1, local = 2
    static var current: AIRemote { AIRemote(rawValue: UserDefaults.standard.integer(forKey: "set.aiRemote")) ?? .colabL4 }
    var gpu: String? { self == .colabL4 ? "L4" : (self == .colabA100 ? "A100" : nil) }
}

final class ColabEngine {
    static let shared = ColabEngine()
    let session = "duochrome"
    /// 실제로 배정된 그래픽 카드 (L4가 없으면 T4로 물러선다)
    private(set) var gpu: String?
    private(set) var ready = false { didSet { if ready != oldValue { state = ready ? .on : .off } } }
    /// 상단 바 AI 엔진 단추가 보여 줄 상태
    enum State { case off, starting, on }
    private(set) var state: State = .off {
        didSet { if state != oldValue { DispatchQueue.main.async { NotificationCenter.default.post(name: AIEngineButton.changed, object: nil) } } }
    }
    private var lastUse = Date()
    /// 코랩 일은 한 번에 하나씩 (가상 머신을 두 번 켜지 않게)
    private let opLock = NSLock()
    /// 코랩을 못 쓴 까닭 (있으면 이 맥 엔진이 예비로 처리 중). 상단 바 단추 설명에 보인다
    private(set) var lastFailure: String?
    /// 코랩이 안 되던 때부터 잠시는 다시 시도하지 않고 바로 이 맥으로 (매번 수십 초씩 기다리지 않게). 단추로 켜면 다시 시도
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
    /// 허깅페이스 토큰: 사용자 폴더 안 본인만 읽을 수 있는 파일 (키체인은 앱을 다시 빌드하거나 이름을 바꾸면 비밀번호를 물었다)
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

    // MARK: 명령줄 도구

    /// 명령줄 도구를 실행하고 출력(표준 출력+오류)을 돌려준다. onLine: 줄마다 (진행 표시용)
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

    /// 명령줄 도구가 없으면 설치 (파이썬 도구 uv로, 사용자 폴더 안에만)
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

    /// 코랩 계정 연결 (처음 한 번). 명령줄 도구가 구글 허용 주소를 내면 브라우저로 열고,
    /// 허용 뒤 구글이 보여 주는 인증 코드를 askCode(주 스레드에서 사용자에게 묻기)로 받아 넘긴다. 뒤 스레드에서 부른다
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

    // MARK: 켜기·끄기

    /// 명령줄 도구는 세션이 없어도 성공 코드를 돌려줄 때가 있어 글로 확인한다 (코랩이 가상 머신을 회수한 경우 등)
    private func sessionAlive() -> Bool {
        guard let out = try? cli(["status", "-s", session], timeout: 60) else { return false }
        return !Self.saysGone(out)
    }

    static func saysGone(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("not found") || t.contains("no active session") || t.contains("pruned")
    }

    /// 켜기 (상단 바 단추나 AI 도구를 고를 때만). 뒤에서 준비하고, 켠 뒤로 쓰지 않으면 자동으로 끈다
    func start(fallback: (() -> Void)? = nil) {
        guard state == .off else { return }
        unavailableUntil = nil      // 직접 켜면 다시 시도
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

    /// 가상 머신을 켜고 엔진을 준비한다 (뒤 스레드에서, opLock 안에서 부른다)
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
                // L4·A100이 모자라면 T4로 (느리지만 같은 모델로 돈다)
                JobCenter.shared.detail("colab", "\(want)가 없어 T4로")
                try cli(["new", "-s", session, "--gpu", "T4"], timeout: 600)
                created = true
                gpu = "T4"
            }
        }
        // 토큰은 파일로 올린다 (명령에 넣으면 코랩 실행 기록에 남는다)
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
        // Duochrome 전용 부품(지우기·반사 제거)을 이 맥과 같은 것으로
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

    /// 작업 흐름 하나를 코랩에서 돌린다. inputs: 엔진 입력 폴더에 올릴 (이름, PNG·JPEG 자료)
    func run(_ workflow: [String: Any], inputs: [(String, Data)], title: String, jpeg: Bool = false) throws -> Data {
        opLock.lock()
        defer { opLock.unlock() }
        do { return try runLocked(workflow, inputs: inputs, title: title, jpeg: jpeg) } catch {
            // 가상 머신이 꺼졌거나 커널이 새로 시작됐으면 한 번 더 (다시 준비)
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
        // 입력 이름을 작업 번호로 바꿔 서로 섞이지 않게
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

    /// 커널 안 뒤 스레드 일이 끝날 때까지 2초마다 짧은 명령으로 묻는다. 묻는 명령이 멈추면 1분 뒤 다시 묻는다
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
            // 커널이 새로 시작되면 함수가 없다 → 다시 준비하게 (run()이 한 번 더 시도)
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

    /// 한동안 안 쓰면 끈다 (켜져 있는 시간만큼 사용량이 줄어든다)
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

    /// 가상 머신을 끄고 반납한다
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

    /// 앱을 켤 때: 지난번에 앱이 비정상으로 끝나 남은 가상 머신이 있으면 끈다 (켜져 있는 만큼 사용량이 줄어든다)
    func cleanupStale() {
        guard FileManager.default.isExecutableFile(atPath: Self.cli.path), !ready, state == .off else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let out = try? self.cli(["sessions"], timeout: 60), out.contains("[\(self.session)]") else { return }
            self.stop("지난번에 남은 가상 머신")
        }
    }

    /// 앱을 닫을 때: 켜져 있으면 끈다 (최대 몇 초만 기다림)
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
