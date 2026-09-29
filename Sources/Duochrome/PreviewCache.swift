import CoreImage
import Foundation

/// Preview cache (Previews folder inside the catalog).
///
/// Stores: the decoded RAW (before adjustments, before base look and manual lens correction), long side `AppSettings.previewSize`.
/// Key: photo path hash + file size and mtime + RAW-stage values (temperature, exposure, noise, RAW sharpening, lens profile, etc.) + size, quality, pipeline version.
/// Small zooms like fit view draw from the cache; the source is decoded only when a larger resolution is needed (100%, export).
final class PreviewCache {
    static let shared = PreviewCache()
    /// Bump when RAW processing changes (discards old caches)
    static let version = 1

    private let queue = DispatchQueue(label: "duochrome.previews", qos: .utility, attributes: .concurrent)
    private var limiter = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var pending = Set<String>()
    private var memory: [String: CIImage] = [:]
    /// Most recently requested key per photo
    private var latest: [String: String] = [:]

    var folder: URL? {
        guard let c = LayerImageStore.catalogURL else { return nil }
        let f = c.appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// Cache file name
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

    // MARK: Thumbnail base (long side ~360, half-float TIFF ~1 MB)
    // When a RAW is decoded once to build a thumbnail, keep the decoded result. When adjustments change and the thumbnail is rebuilt,
    // only exposure/temperature deltas are applied on top, skipping the RAW decode (0.6–0.9 s per photo, one at a time)

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

    /// Whether a preview for these settings exists (checks the file only, doesn't read it)
    func hasPreview(url: URL, settings: DevelopSettings) -> Bool {
        let k = key(url: url, settings: settings)
        lock.lock(); let inMemory = memory[k] != nil; lock.unlock()
        return inMemory || (file(k).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    /// Cached image if present (extent origin 0, linear Rec.2020)
    func image(url: URL, settings: DevelopSettings) -> CIImage? {
        let k = key(url: url, settings: settings)
        lock.lock()
        if let m = memory[k] { lock.unlock(); return m }
        lock.unlock()
        guard let f = file(k), FileManager.default.fileExists(atPath: f.path),
              let img = CIImage(contentsOf: f) else { return nil }
        // Touch mtime to now to keep recently used ones (when over capacity, oldest are deleted first)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        let e = img.extent
        let normalized = img.transformed(by: .init(translationX: -e.minX, y: -e.minY))
        lock.lock()
        if memory.count > 6 { memory.removeAll() }
        memory[k] = normalized
        lock.unlock()
        return normalized
    }

    /// Builds the cache in the background (skipped if it exists or is in progress)
    func ensure(url: URL, settings: DevelopSettings, done: (() -> Void)? = nil) {
        let k = key(url: url, settings: settings)
        guard let f = file(k) else { return }
        lock.lock()
        // Only the latest request per photo is built (repeated undo/exposure changes queued stale previews and hogged the GPU)
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

    /// Decodes the RAW at preview size (same values as the document's RAW stage)
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

    /// Over the capacity limit, deletes least recently used first (they can be rebuilt)
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
