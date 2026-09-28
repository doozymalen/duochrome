import AppKit
import CoreImage

/// AI 엔진: ComfyUI를 창 없이 Duochrome 안의 보이지 않는 엔진으로 쓴다.
/// - 설치: ~/Library/Application Support/Duochrome/AI 에 ai-setup.sh로 (처음 한 번, 작업 진행 창에 단계 표시)
/// - 실행: AI 기능을 처음 쓸 때 뒤에서 켜고(브라우저·창 없음), Duochrome을 닫으면 함께 끈다
/// - 일: 그림·마스크를 올리고 작업 흐름(노드 묶음)을 보내, 결과 그림을 받아 온다
final class AIEngine {
    static let shared = AIEngine()

    static var root: URL {
        if let r = ProcessInfo.processInfo.environment["DUOCHROME_AI_ROOT"] { return URL(fileURLWithPath: r) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Duochrome/AI")
    }
    static var comfy: URL { root.appendingPathComponent("ComfyUI") }
    static var python: URL { comfy.appendingPathComponent(".venv/bin/python") }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("ready").path) }

    let port = 8190
    private var server: Process?
    private let lock = NSLock()
    private var starting = false
    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: 설치

    /// 설치 스크립트 (앱 안 → 없으면 개발 폴더)
    static var setupScript: URL? {
        if let u = Bundle.main.url(forResource: "ai-setup", withExtension: "sh") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ai-setup.sh")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// 설치 (뒤 스레드에서 부른다). 진행은 작업 진행 창에
    func install() throws {
        guard let script = Self.setupScript else { throw Failure(message: "설치 스크립트를 찾지 못함") }
        JobCenter.shared.begin("ai-install", title: "AI 엔진 설치", detail: "준비")
        defer { JobCenter.shared.end("ai-install") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["DUOCHROME_AI_ROOT"] = Self.root.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var failure: String?
        pipe.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where line.hasPrefix("@@") {
                let t = line.dropFirst(2)
                if t.hasPrefix("단계 ") { JobCenter.shared.detail("ai-install", String(t.dropFirst(3))) }
                if t.hasPrefix("실패 ") { failure = String(t.dropFirst(3)) }
            }
        }
        try p.run()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus != 0 || !isInstalled { throw Failure(message: failure ?? "설치가 끝나지 않음") }
    }

    // MARK: 켜기·끄기

    /// 엔진이 살아 있으면 참
    func isAlive() -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("system_stats"))
        req.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: req) { _, r, _ in ok = (r as? HTTPURLResponse)?.statusCode == 200; sem.signal() }.resume()
        sem.wait()
        return ok
    }

    /// Duochrome 전용 엔진 부품. 공개 지우기 부품은 LaMa를 256픽셀 정사각형으로 줄였다 늘려 결과가 뭉개졌다 →
    /// 보낸 크기 그대로(8의 배수로 가장자리만 비춰 채움) 돌린다. 켤 때마다 최신으로 써 둔다
    static let nodeSource = """
    import torch
    import torch.nn.functional as F
    import comfy.model_management as mm

    class DuochromeLaMa:
        @classmethod
        def INPUT_TYPES(cls):
            return {"required": {"inpaint_model": ("INPAINT_MODEL",), "image": ("IMAGE",), "mask": ("MASK",)}}
        RETURN_TYPES = ("IMAGE",)
        FUNCTION = "run"
        CATEGORY = "duochrome"

        def run(self, inpaint_model, image, mask):
            dev = mm.get_torch_device()
            img = image.permute(0, 3, 1, 2)[:, :3]
            m = mask.reshape(-1, 1, mask.shape[-2], mask.shape[-1])[:1]
            m = (m > 0.5).float()
            h, w = img.shape[-2:]
            ph, pw = (8 - h % 8) % 8, (8 - w % 8) % 8
            x = F.pad(img, (0, pw, 0, ph), mode="reflect")
            mp = F.pad(m, (0, pw, 0, ph), mode="reflect")
            inpaint_model.to(dev)
            with torch.no_grad():
                out = inpaint_model(x.to(dev), mp.to(dev)).float().cpu()
            inpaint_model.cpu()
            out = out[:, :, :h, :w]
            out = img + (out - img) * m
            return (out.clamp(0, 1).permute(0, 2, 3, 1),)

    # 반사 제거 (DSIT, NTIRE 2025 반사 제거 대회 1위 팀 도구 모음, 아파치 2.0). 구조 파일만 불러온다 (학습용 의존성 없이)
    _DSIT = {}

    def _load_dsit(root):
        if "net" in _DSIT:
            return _DSIT["net"]
        import sys, os, types, importlib.util
        pkg = os.path.join(root, "xreflection", "xreflection")
        for name, sub in [("xreflection", ""), ("xreflection.archs", "archs"), ("xreflection.models", "models"), ("xreflection.utils", "utils")]:
            if name not in sys.modules:
                m = types.ModuleType(name); m.__path__ = [os.path.join(pkg, sub) if sub else pkg]; sys.modules[name] = m
        spec = importlib.util.spec_from_file_location("xreflection.archs.dsit_arch", os.path.join(pkg, "archs", "dsit_arch.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sw = sys.modules["xreflection.archs.swin_det"]
        mod.swin_large_384_det = lambda *a, **k: sw.SwinTransformer(pretrain_img_size=384, embed_dim=192, depths=[2, 2, 18, 2],
                                                                      num_heads=[6, 12, 24, 48], window_size=12, out_indices=[1, 2, 3], pretrained=None)
        net = mod.DSIT(pretrained_models={}, window_size=12, enc_blk_nums=[12, 8, 4, 2, 2], dec_blk_nums=[2, 2, 2, 2, 2])
        ck = torch.load(os.path.join(root, "reflection", "dsit-26.6959.ckpt"), map_location="cpu", weights_only=False)["state_dict"]
        net.load_state_dict({k[6:]: v for k, v in ck.items() if k.startswith("net_g.")})
        net.eval()   # 이 구조의 eval()은 자신을 돌려주지 않는다
        _DSIT["net"] = net
        return net

    class DuochromeReflection:
        @classmethod
        def INPUT_TYPES(cls):
            return {"required": {"image": ("IMAGE",)}}
        RETURN_TYPES = ("IMAGE",)
        FUNCTION = "run"
        CATEGORY = "duochrome"

        def run(self, image):
            import os, folder_paths
            root = os.path.dirname(folder_paths.base_path)
            # 채우기 모델 등이 그래픽 메모리를 잡고 있으면 모자라다 → 먼저 내린다
            mm.unload_all_models()
            mm.soft_empty_cache()
            net = _load_dsit(root)
            dev = mm.get_torch_device()
            net.to(dev)
            x = image.permute(0, 3, 1, 2)[:, :3]
            # 이 맥(MPS)은 긴 변 1024까지, 코랩 L4는 1536까지 (2048은 메모리가 모자랐다. 넘으면 줄였다 늘린다)
            H0, W0 = x.shape[-2:]
            cap = 1536 if dev.type == "cuda" else 1024
            k = min(1.0, cap / max(H0, W0))
            full = x
            if k < 1.0:
                x = F.interpolate(x, size=(int(H0 * k) // 8 * 8, int(W0 * k) // 8 * 8), mode="bicubic", align_corners=False).clamp(0, 1)
            h, w = x.shape[-2:]
            ph, pw = (32 - h % 32) % 32, (32 - w % 32) % 32
            xp = F.pad(x, (0, pw, 0, ph), mode="reflect").to(dev)
            with torch.no_grad():
                out = net(xp)[0].float().cpu()
            net.cpu()
            out = out[:, :, :h, :w]
            if k < 1.0:
                # 반사 차이만 늘려 원래 크기에 더한다 (결은 원래 그림 그대로)
                out = full + F.interpolate(out - x, size=(H0, W0), mode="bicubic", align_corners=False)
            return (out.clamp(0, 1).permute(0, 2, 3, 1),)

    NODE_CLASS_MAPPINGS = {"DuochromeLaMa": DuochromeLaMa, "DuochromeReflection": DuochromeReflection}
    """

    private func writeNodes() {
        let dir = Self.comfy.appendingPathComponent("custom_nodes/duochrome_nodes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("__init__.py")
        if (try? String(contentsOf: f, encoding: .utf8)) != Self.nodeSource {
            try? Self.nodeSource.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    /// 필요하면 설치하고 켠다 (뒤 스레드에서 부른다). 이미 켜져 있으면 바로 돌아온다
    func ensureRunning() throws {
        if isAlive() { return }
        if !isInstalled { try install() }
        lock.lock()
        if starting { lock.unlock(); return try waitAlive(120) }
        starting = true
        lock.unlock()
        defer { lock.lock(); starting = false; lock.unlock() }
        writeNodes()
        JobCenter.shared.begin("ai-start", title: "AI 엔진 켜는 중")
        defer { JobCenter.shared.end("ai-start") }
        let p = Process()
        p.executableURL = Self.python
        p.currentDirectoryURL = Self.comfy
        // 창·브라우저 없이, 이 맥 안에서만 (127.0.0.1), 미리보기 그림 없이
        p.arguments = ["main.py", "--listen", "127.0.0.1", "--port", "\(port)", "--disable-auto-launch", "--preview-method", "none",
                       "--output-directory", Self.root.appendingPathComponent("output").path,
                       "--input-directory", Self.root.appendingPathComponent("input").path]
        var env = ProcessInfo.processInfo.environment
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        p.environment = env
        let log = Self.root.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = try FileHandle(forWritingTo: log)
        p.standardOutput = h
        p.standardError = h
        try p.run()
        server = p
        try waitAlive(180)
        DispatchQueue.main.async { NotificationCenter.default.post(name: AIEngineButton.changed, object: nil) }
    }

    private func waitAlive(_ seconds: Double) throws {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            if isAlive() { return }
            if let s = server, !s.isRunning { throw Failure(message: "AI 엔진이 켜지다 멈춤 (engine.log 확인)") }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw Failure(message: "AI 엔진이 \(Int(seconds))초 안에 켜지지 않음")
    }

    /// 이 맥 엔진이 Duochrome이 켠 채로 돌고 있으면 참
    var isRunningHere: Bool { server?.isRunning == true }

    /// 미리 켜 두기: AI 도구를 고르거나 AI 창을 열 때 뒤에서 켜서, 실제로 누를 때 기다리지 않게 (설치 전이면 아무것도 안 함)
    func warmUp() {
        guard isInstalled else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, !self.isAlive() else { return }
            try? self.ensureRunning()
        }
    }

    /// 큰 생성 모델을 메모리에서 내린다 (16GB 맥에서 생성 뒤 7GB 가까이 붙잡고 있지 않게). 지우기 모델도 함께 내려가지만 다시 싣는 데 1초 안팎
    func freeMemory() {
        var req = URLRequest(url: base.appendingPathComponent("free"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["unload_models": true, "free_memory": true])
        _ = try? data(req)
    }

    /// Duochrome을 닫을 때: 엔진도 끈다 (메모리를 돌려받는다)
    func stop() {
        guard let p = server, p.isRunning else { return }
        p.terminate()
        let t0 = Date()
        while p.isRunning && Date().timeIntervalSince(t0) < 3 { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        server = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: AIEngineButton.changed, object: nil) }
    }

    // MARK: 일 보내기

    /// PNG를 엔진 입력 폴더에 올리고 이름을 돌려준다
    func upload(_ png: Data, name: String) throws -> String {
        let boundary = "duochrome-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(png)
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n")
        var req = URLRequest(url: base.appendingPathComponent("upload/image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let j = try json(req)
        guard let n = j["name"] as? String else { throw Failure(message: "그림을 엔진에 올리지 못함") }
        return n
    }

    /// 작업 흐름을 보내고 결과 그림(PNG 자료)들을 받는다. progress: 0~1 (엔진이 알려 주는 단계로)
    func run(_ workflow: [String: Any], title: String, progress: ((Double) -> Void)? = nil) throws -> [Data] {
        var req = URLRequest(url: base.appendingPathComponent("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": workflow, "client_id": "duochrome"])
        let j = try json(req)
        guard let id = j["prompt_id"] as? String else {
            let err = (j["error"] as? [String: Any])?["message"] as? String ?? "\(j["node_errors"] ?? "")"
            throw Failure(message: "AI 작업을 받지 않음: \(err)")
        }
        // 끝날 때까지 결과 기록을 본다
        let t0 = Date()
        while true {
            Thread.sleep(forTimeInterval: 0.4)
            let h = try json(URLRequest(url: base.appendingPathComponent("history/\(id)")))
            if let entry = h[id] as? [String: Any] {
                if let st = entry["status"] as? [String: Any], (st["status_str"] as? String) == "error" {
                    let msgs = (st["messages"] as? [[Any]])?.compactMap { ($0.last as? [String: Any])?["exception_message"] as? String } ?? []
                    throw Failure(message: "AI 작업 실패: " + (msgs.first ?? "알 수 없는 오류"))
                }
                var images: [Data] = []
                for (_, out) in (entry["outputs"] as? [String: Any]) ?? [:] {
                    for im in ((out as? [String: Any])?["images"] as? [[String: Any]]) ?? [] {
                        guard let fn = im["filename"] as? String else { continue }
                        var c = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
                        c.queryItems = [URLQueryItem(name: "filename", value: fn), URLQueryItem(name: "subfolder", value: im["subfolder"] as? String ?? ""),
                                        URLQueryItem(name: "type", value: im["type"] as? String ?? "output")]
                        images.append(try data(URLRequest(url: c.url!)))
                        // 엔진 출력 폴더에 쌓이지 않게 지운다
                        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("output").appendingPathComponent(im["subfolder"] as? String ?? "").appendingPathComponent(fn))
                    }
                }
                if !images.isEmpty { return images }
                if entry["outputs"] != nil, (entry["status"] as? [String: Any])?["completed"] as? Bool == true { throw Failure(message: "AI 작업이 그림을 내지 않음") }
            }
            if Date().timeIntervalSince(t0) > 3600 { throw Failure(message: "AI 작업이 한 시간 안에 끝나지 않음") }
        }
    }

    private func data(_ req: URLRequest) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?, err: Error?
        session.dataTask(with: req) { d, r, e in
            if let e { err = e } else if let code = (r as? HTTPURLResponse)?.statusCode, code >= 400 { err = Failure(message: "엔진 응답 \(code): \(String(data: d ?? Data(), encoding: .utf8)?.prefix(200) ?? "")") } else { out = d }
            sem.signal()
        }.resume()
        sem.wait()
        if let err { throw err }
        return out ?? Data()
    }

    private func json(_ req: URLRequest) throws -> [String: Any] {
        let d = try data(req)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}
