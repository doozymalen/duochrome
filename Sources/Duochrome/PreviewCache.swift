import CoreImage
import Foundation

/// 미리보기 캐시 (카탈로그 안 Previews 폴더).
///
/// 저장하는 것: RAW를 푼 결과(조정 전, 기본 모습·손 렌즈 보정 전), 긴 변 `AppSettings.previewSize`.
/// 열쇠: 사진 경로 해시 + 파일 크기·수정 시각 + RAW 단계 값(색온도·노출·노이즈·RAW 샤프닝·렌즈 프로필 등) + 크기·품질·처리 버전.
/// 화면 맞춤처럼 작은 배율은 캐시로 그리고, 캐시보다 큰 해상도(100%·내보내기)가 필요할 때만 원본을 푼다.
final class PreviewCache {
    static let shared = PreviewCache()
    /// RAW 처리 방식이 바뀌면 올린다 (예전 캐시를 버리게)
    static let version = 1

    private let queue = DispatchQueue(label: "duochrome.previews", qos: .utility, attributes: .concurrent)
    private var limiter = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var pending = Set<String>()
    private var memory: [String: CIImage] = [:]
    /// 사진마다 가장 최근에 요청한 열쇠
    private var latest: [String: String] = [:]

    var folder: URL? {
        guard let c = LayerImageStore.catalogURL else { return nil }
        let f = c.appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// 캐시 파일 이름
    func key(url: URL, settings s: DevelopSettings) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let raw = [s.temperature, s.tint, s.exposure, s.sharpness, s.detail, s.lumaNoise, s.colorNoise, s.moire,
                   s.lensCorrection, s.filmCurve, s.highlightRecoveryOn ? 1 : 0].map { String(format: "%.3f", $0) }.joined(separator: ",")
        let spec = "\(size)-\(mtime)-\(raw)-\(AppSettings.previewSize)-\(AppSettings.previewQuality)-\(Self.version)"
        var h: UInt64 = 1469598103934665603
        for b in spec.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Library.key(for: url) + "-" + String(h, radix: 36)
    }

    private func file(_ key: String) -> URL? {
        folder?.appendingPathComponent(key + (AppSettings.previewQuality == 0 ? ".tif" : ".heic"))
    }

    // MARK: 썸네일 바탕 (긴 변 약 360, 반정밀도 TIFF 약 1MB)
    // RAW를 한 번 풀어 썸네일을 만들 때 해독 결과를 함께 남긴다. 다음에 보정을 바꿔 썸네일을 다시 만들 때는
    // 이것에 노출·색온도 차이만 얹어 RAW 해독(장당 0.6~0.9초, 한 번에 하나씩)을 건너뛴다

    private func thumbFile(url: URL, settings: DevelopSettings) -> URL? {
        folder?.appendingPathComponent(key(url: url, settings: settings) + "-t.tif")
    }

    func thumbBase(url: URL, settings: DevelopSettings) -> CIImage? {
        guard let f = thumbFile(url: url, settings: settings), FileManager.default.fileExists(atPath: f.path),
              let img = CIImage(contentsOf: f) else { return nil }
        let e = img.extent
        return img.transformed(by: .init(translationX: -e.minX, y: -e.minY))
    }

    func storeThumbBase(_ img: CIImage, url: URL, settings: DevelopSettings) {
        guard let f = thumbFile(url: url, settings: settings), !img.extent.isEmpty, img.extent.width < 1200 else {
            if ProcessInfo.processInfo.environment["DUOCHROME_THUMBLOG"] != nil { print("썸네일 바탕 건너뜀: 폴더 \(folder?.path ?? "없음"), 크기 \(img.extent)") }
            return
        }
        let e = img.extent.integral
        do {
            try Render.context.writeTIFFRepresentation(of: img.cropped(to: e), to: f, format: .RGBAh, colorSpace: Render.workingSpace)
        } catch {
            if ProcessInfo.processInfo.environment["DUOCHROME_THUMBLOG"] != nil { print("썸네일 바탕 저장 실패: \(error)") }
        }
    }

    /// 이 설정의 미리보기가 이미 있는지 (파일만 확인, 읽지 않는다)
    func hasPreview(url: URL, settings: DevelopSettings) -> Bool {
        let k = key(url: url, settings: settings)
        lock.lock(); let inMemory = memory[k] != nil; lock.unlock()
        return inMemory || (file(k).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    /// 캐시가 있으면 그 그림 (영역 원점 0, 선형 Rec.2020)
    func image(url: URL, settings: DevelopSettings) -> CIImage? {
        let k = key(url: url, settings: settings)
        lock.lock()
        if let m = memory[k] { lock.unlock(); return m }
        lock.unlock()
        guard let f = file(k), FileManager.default.fileExists(atPath: f.path),
              let img = CIImage(contentsOf: f) else { return nil }
        // 최근에 쓴 것을 남기려고 수정 시각을 지금으로 (용량이 넘치면 오래된 것부터 지운다)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        let e = img.extent
        let normalized = img.transformed(by: .init(translationX: -e.minX, y: -e.minY))
        lock.lock()
        if memory.count > 6 { memory.removeAll() }
        memory[k] = normalized
        lock.unlock()
        return normalized
    }

    /// 뒤에서 캐시를 만든다 (이미 있거나 만드는 중이면 건너뛴다)
    func ensure(url: URL, settings: DevelopSettings, done: (() -> Void)? = nil) {
        let k = key(url: url, settings: settings)
        guard let f = file(k) else { return }
        lock.lock()
        // 같은 사진은 가장 최근 요청만 만든다 (되돌리기·노출을 여러 번 바꾸면 지난 값의 미리보기가 줄줄이 쌓여 GPU를 붙잡았다)
        latest[url.path] = k
        if pending.contains(k) || FileManager.default.fileExists(atPath: f.path) { lock.unlock(); return }
        pending.insert(k)
        JobCenter.shared.add("previews", title: "미리보기 만들기")
        let workers = max(1, min(AppSettings.previewWorkers, 4))
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.limiter.wait()
            defer {
                self.limiter.signal()
                self.lock.lock(); self.pending.remove(k); self.lock.unlock()
            }
            _ = workers
            BackgroundGate.waitQuiet()
            self.lock.lock(); let stale = self.latest[url.path] != k; self.lock.unlock()
            if stale { JobCenter.shared.skip("previews"); done?(); return }
            autoreleasepool {
                if let img = Self.decode(url: url, settings: settings) { self.write(img, to: f) }
            }
            JobCenter.shared.step("previews")
            self.trim()
            done?()
        }
    }

    /// RAW를 미리보기 크기로 푼다 (문서의 RAW 단계와 같은 값)
    static func decode(url: URL, settings s: DevelopSettings) -> CIImage? {
        guard let raw = CIRAWFilter(imageURL: url), let full = raw.outputImage else { return nil }
        let long = max(full.extent.width, full.extent.height)
        guard long > 0 else { return nil }
        raw.scaleFactor = Float(min(1, CGFloat(AppSettings.previewSize) / long))
        raw.exposure = s.exposure
        raw.neutralTemperature = s.temperature
        raw.neutralTint = s.tint
        raw.sharpnessAmount = s.sharpness
        raw.detailAmount = s.detail
        raw.luminanceNoiseReductionAmount = s.lumaNoise
        raw.colorNoiseReductionAmount = s.colorNoise
        raw.moireReductionAmount = s.moire
        raw.boostAmount = s.filmCurve
        if #available(macOS 26, *), raw.isHighlightRecoverySupported { raw.isHighlightRecoveryEnabled = s.highlightRecoveryOn }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = s.lensCorrection > 0.5 }
        guard let out = raw.outputImage else { return nil }
        return out.transformed(by: .init(translationX: -out.extent.minX, y: -out.extent.minY))
    }

    private func write(_ img: CIImage, to f: URL) {
        let tmp = f.deletingLastPathComponent().appendingPathComponent(".tmp-" + f.lastPathComponent)
        do {
            if AppSettings.previewQuality == 0 {
                try Render.context.writeTIFFRepresentation(of: img, to: tmp, format: .RGBAh, colorSpace: Render.workingSpace)
            } else {
                try Render.context.writeHEIF10Representation(of: img, to: tmp, colorSpace: CGColorSpace(name: CGColorSpace.displayP3_PQ)!)
            }
            try? FileManager.default.removeItem(at: f)
            try FileManager.default.moveItem(at: tmp, to: f)
        } catch {
            NSLog("미리보기 저장 실패: %@", "\(error)")
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// 용량 한도를 넘으면 오래 안 쓴 것부터 지운다 (다시 만들 수 있다)
    func trim() {
        guard let folder else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard var files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        files = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        let limit = Int64(AppSettings.previewLimitGB) * 1_000_000_000
        var total: Int64 = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total > limit else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for f in sorted where total > limit {
            total -= Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fm.removeItem(at: f)
        }
    }

    var totalBytes: Int64 {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        lock.lock(); memory.removeAll(); lock.unlock()
        guard let folder else { return }
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
