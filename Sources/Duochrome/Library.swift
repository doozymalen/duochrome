import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 브라우저에 보이는 사진 한 장.
final class PhotoItem {
    /// 원본 파일. 변형본은 조각(#v2)이 붙는다 — 파일 경로(`url.path`)는 같고, 조정값 열쇠만 다르다.
    let url: URL
    var name: String { variant > 0 ? "\(url.lastPathComponent) (변형 \(variant))" : url.lastPathComponent }
    /// 변형본 번호 (0이면 원본)
    var variant: Int { url.fragment.flatMap { $0.hasPrefix("v") ? Int($0.dropFirst()) : nil } ?? 0 }
    /// 채택 1, 거부 -1
    var flag = 0
    /// 카탈로그 번호 (0이면 카탈로그 밖).
    var id: Int64 = 0
    /// 별점 0~5, 색 태그 0(없음)~7 (빨강·주황·노랑·초록·파랑·분홍·보라).
    var rating = 0
    var color = 0
    /// 원본 파일이 지금 경로에 없다 (외부 카탈로그에서 가져왔는데 파일이 옮겨진 경우 등).
    var offline = false
    /// 가져온 썸네일 캐시 (보정이 반영된 JPEG).
    var importThumb: String?
    /// 조정값이 저장돼 있는지. 브라우저에 표시한다.
    var edited = false
    var thumbnail: NSImage?

    init(url: URL) { self.url = url }
}

/// 지금 보고 있는 사진 묶음과 조정값 저장. 사진 목록은 카탈로그(`Catalog`)에서 온다.
///
/// 조정값은 사진 폴더를 건드리지 않도록 `~/Library/Application Support/Duochrome/Adjustments`에
/// 사진 경로의 해시 이름으로 둔다.
final class Library {
    let catalog: Catalog
    private(set) var folder: URL?
    private(set) var source: Catalog.Source = .all
    private(set) var items: [PhotoItem] = []
    /// 검색 전 전체 목록
    private var allItems: [PhotoItem] = []
    /// 검색어: 파일 이름·폴더 이름에 들어 있는 사진만. "★3"처럼 쓰면 별점 3개 이상.
    var query = "" { didSet { applyQuery() } }

    private func applyQuery() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { items = allItems; return }
        var minRating = 0
        var words: [String] = []
        let tokens = q.split(separator: " ").map(String.init)
        let ids = catalog.searchIDs(tokens.filter(Catalog.isSearchToken))
        for w in tokens where !Catalog.isSearchToken(w) {
            if w.hasPrefix("★"), let n = Int(w.dropFirst()) { minRating = n }
            else if w.hasPrefix("*"), let n = Int(w.dropFirst()) { minRating = n }
            else { words.append(w) }
        }
        items = allItems.filter { item in
            (ids?.contains(item.id) ?? true) && item.rating >= minRating && words.allSatisfy { item.url.path.localizedCaseInsensitiveContains($0) }
        }
    }

    init(catalog: Catalog) { self.catalog = catalog }

    static let supported: Set<String> = ["cr3", "cr2", "nef", "arw", "raf", "dng", "orf", "rw2",
                                         "jpg", "jpeg", "tif", "tiff", "png", "heic", "psd", "psb"]

    /// 예전 조정값 폴더 (JSON 파일). 이제는 카탈로그 DB에 저장하고, 이 폴더는 옮겨 올 때만 읽는다.
    static var legacyStore: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["DUOCHROME_ADJUSTMENTS"] { return URL(fileURLWithPath: custom) }
        if env["DUOCHROME_SNAPSHOT"] != nil || env["DUOCHROME_CATALOG_TEST"] != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test-adjustments")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duochrome/Adjustments", isDirectory: true)
    }

    private let thumbQueue = DispatchQueue(label: "duochrome.thumbs", qos: .userInitiated, attributes: .concurrent)
    private let thumbLimit = DispatchSemaphore(value: 4)

    /// 폴더를 카탈로그에 등록하고 그 폴더를 보여 준다.
    func open(folder: URL) {
        do {
            let fid = try catalog.addFolder(folder)
            self.folder = folder
            show(.folder(fid))
            UserDefaults.standard.set(folder.path, forKey: "lastFolder")
        } catch {
            NSLog("폴더 등록 실패: \(error)")
        }
    }

    /// 카탈로그의 한 묶음을 보여 준다.
    func show(_ source: Catalog.Source) {
        self.source = source
        if case .folder = source {} else { folder = nil }
        allItems = (try? catalog.items(source)) ?? []
        applyQuery()
        let adjusted = catalog.adjustedKeys()
        for item in allItems {
            item.edited = adjusted.contains(Self.key(for: item.url))
        }
    }

    func setRating(_ items: [PhotoItem], _ r: Int) {
        try? catalog.setRating(items.map(\.id), r)
        items.forEach { $0.rating = r }
    }

    func setColor(_ items: [PhotoItem], _ c: Int) {
        try? catalog.setColor(items.map(\.id), c)
        items.forEach { $0.color = c }
    }

    // MARK: - 조정값 (카탈로그 DB에 저장. 예전에는 Application Support의 JSON 파일)

    /// 사진 경로 해시 (예전 JSON 파일 이름과 같다 — 옮길 때 1:1로 맞는다)
    static func key(for photo: URL) -> String {
        // 변형본(#v2)은 같은 파일이지만 조정값을 따로 둔다
        let base = photo.standardizedFileURL.path + (photo.fragment.map { "#" + $0 } ?? "")
        return SHA256.hash(data: Data(base.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 저장된 조정값 JSON 그대로
    func rawSettings(for photo: URL) -> Data? { catalog.adjustment(Self.key(for: photo)).map { Data($0.utf8) } }

    /// 저장된 값을 카메라 기록값 위에 덮는다. 나중에 도구가 늘어도 예전 파일이 그대로 읽힌다.
    func loadSettings(for photo: URL, over base: DevelopSettings) -> DevelopSettings? {
        guard let saved = rawSettings(for: photo),
              let savedDict = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let baseData = try? JSONEncoder().encode(base),
              var dict = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else { return nil }
        var patch = savedDict
        // 레이어는 배열이라 통째로 바뀐다. 예전 파일에 없는 레이어 항목은 기본 레이어 값으로 채운다.
        if let layers = patch["layers"] as? [[String: Any]],
           let defData = try? JSONEncoder().encode(AdjustLayer(name: "")),
           let def = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] {
            patch["layers"] = layers.map { l -> [String: Any] in
                var d = def
                Self.overlay(&d, l)
                return d
            }
        }
        // 기본값에 없는 선택 항목(gammaBlend·layerComps·channels 등)도 살린다
        Self.overlay(&dict, patch)
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(DevelopSettings.self, from: merged)
    }

    /// merge와 같되, 기본값에 없는 키(비어 있는 선택 항목)도 넣는다.
    private static func overlay(_ into: inout [String: Any], _ from: [String: Any]) {
        for (k, v) in from {
            if var sub = into[k] as? [String: Any], let vs = v as? [String: Any] {
                overlay(&sub, vs)
                into[k] = sub
            } else {
                into[k] = v
            }
        }
    }

    private static func merge(_ into: inout [String: Any], _ from: [String: Any]) {
        for (k, v) in from {
            if var sub = into[k] as? [String: Any], let vs = v as? [String: Any] {
                merge(&sub, vs)
                into[k] = sub
            } else if into[k] != nil {
                into[k] = v
            }
        }
    }


    func removeSettings(for photo: URL) { catalog.setAdjustment(Self.key(for: photo), nil) }

    func hasSettings(for photo: URL) -> Bool {
        catalog.adjustment(Self.key(for: photo)) != nil
    }

    /// 다른 프로그램에서 옮겨 온 설정 조각을 그대로 적는다. 읽을 때 카메라 기록값 위에 덮인다.
    func saveRawSettings(_ dict: [String: Any], for photo: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        catalog.setAdjustment(Self.key(for: photo), String(decoding: data, as: UTF8.self))
        catalog.markEdited(photo, true)
    }

    /// 카메라 기록값과 같으면 파일을 지운다 ("조정 안 됨"으로 돌아간다).
    func saveSettings(_ s: DevelopSettings, asShot: DevelopSettings, for photo: URL) {
        let key = Self.key(for: photo)
        let item = items.first { $0.url == photo }
        if s == asShot {
            catalog.setAdjustment(key, nil)
            item?.edited = false
            catalog.markEdited(photo, false)
            return
        }
        if let data = try? JSONEncoder().encode(s) {
            catalog.setAdjustment(key, String(decoding: data, as: UTF8.self))
            if item?.edited != true { catalog.markEdited(photo, true) }
            item?.edited = true
        }
    }

    // MARK: - 썸네일

    /// RAW 안에 든 미리보기를 쓴다. CR3는 JPEG 미리보기가 들어 있어 디코딩 없이 빠르다.
    /// 외부 카탈로그에서 가져온 사진은 가져온 썸네일(보정 반영)을 먼저 쓴다. 오프라인 사진은 원본을 읽지 않는다
    /// (구글 드라이브 같은 스트리밍 위치면 읽는 순간 파일 전체를 내려받는다).
    func loadThumbnail(_ item: PhotoItem, size: Int = 320, done: @escaping (NSImage?) -> Void) {
        thumbQueue.async { [thumbLimit] in
            thumbLimit.wait()
            defer { thumbLimit.signal() }
            if !item.edited || item.offline, let t = item.importThumb, FileManager.default.fileExists(atPath: t),
               let img = NSImage(contentsOfFile: t) {
                DispatchQueue.main.async { item.thumbnail = img; done(img) }
                return
            }
            if item.offline { DispatchQueue.main.async { done(nil) }; return }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
            ]
            var image: NSImage?
            if let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                item.thumbnail = image
                done(image)
            }
        }
    }

    /// 조정한 결과로 썸네일을 새로 만든다 (다른 사진으로 넘어갈 때).
    func refreshThumbnail(_ item: PhotoItem, from doc: RawDocument) {
        if let t = Self.thumbnail(from: doc.image(scale: 1.0 / 8)) { item.thumbnail = t }
    }

    /// 조정 결과 그림 → 긴 변 320px 썸네일 (어느 스레드에서나)
    static func thumbnail(from image: CIImage) -> NSImage? {
        let longSide = max(image.extent.width, image.extent.height)
        guard longSide > 0 else { return nil }
        let k = min(1, 320 / longSide)
        let small = image.transformed(by: .init(scaleX: k, y: k))
        guard let cg = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                                    colorSpace: Render.displaySpace) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
