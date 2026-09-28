import CoreImage
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

/// RAW 레이어의 현상값.
struct DevelopSettings: Equatable, Codable {
    // 화이트 밸런스
    var temperature: Float = 5500
    var tint: Float = 0
    // 노출 (대비·밝기·채도는 -100~100)
    var exposure: Float = 0
    var contrast: Float = 0
    var brightness: Float = 0
    var saturation: Float = 0
    // 하이 다이내믹 레인지 (모두 -100~100)
    /// 예전 파일의 하이라이트 (0~100, 클수록 눌러 되살림). 새 값은 highlights, 화면과 계산은 highlightTone.
    var highlight: Float = 0
    /// 하이라이트 -100~100: +는 밝은 곳을 더 밝게, -는 눌러 되살린다 (docs/SLIDERS.md)
    var highlights: Float = 0
    /// 화면·계산에 쓰는 하이라이트 값. 예전 값(highlight)은 음수로 읽고, 새로 바꾸면 highlights로 옮긴다.
    var highlightTone: Float {
        get { highlights - highlight }
        set { highlights = newValue; highlight = 0 }
    }
    var shadow: Float = 0
    var white: Float = 0
    var black: Float = 0
    // RAW 엔진 단계 (0~1, 샤프닝은 0~2). 기본값은 카메라마다 다르다.
    var sharpness: Float = 0
    var detail: Float = 0
    var lumaNoise: Float = 0
    var colorNoise: Float = 0
    var moire: Float = 0
    /// 1이면 켬. 슬라이더와 같은 방식으로 다루려고 Float로 둔다.
    var lensCorrection: Float = 1
    /// 기본 모습: 0 Apple 기본, 1 카메라 맞춤 (보정표가 있는 카메라만)
    var look: Float = 1
    /// 전체 강도 (0~1): 모든 보정을 보정 전과 섞는 정도
    var intensity: Float = 1
    /// 손 렌즈 보정 (-100~100, 0~100). 원본 좌표 단계에서 건다.
    /// 왜곡 +는 술통형을 편다, −는 실패형을 편다. 색수차는 빨강·파랑 채널 크기를 바꾼다.
    var lensDistortion: Float = 0
    var lensCA: Float = 0
    var lensCABlue: Float = 0
    /// 주변부 광량 (모서리를 밝힘) 0~100, 주변부 선명도 0~100
    var lensVignette: Float = 0
    var lensSharpFalloff: Float = 0
    // 형태: 90° 회전 수(0~3), 뒤집기(1이면 켬), 미세 회전(°), 키스톤(-100~100), 크롭
    var quarterTurns: Float = 0
    var flipH: Float = 0
    var flipV: Float = 0
    var rotation: Float = 0
    var keystoneV: Float = 0
    var keystoneH: Float = 0
    var keystoneAspect: Float = 0
    var crop = CropRect()
    /// 크롭 비율 고정 (가로/세로). 0이면 자유.
    var cropAspect: Float = 0
    // 기본 특성: 카메라 톤 커브 강도 (0 선형 ~ 1 표준)
    var filmCurve: Float = 1
    /// 기본 커브에 더하는 대비 (기본 특성 "높은 대비"·"부드럽게").
    var filmContrast: Float = 0
    /// RAW 엔진의 하이라이트 복구 (날아간 채널 재구성).
    var highlightRecoveryOn = true
    // 필름 그레인 (0~100)
    var grainAmount: Float = 0
    var grainSize: Float = 30
    // 클래리티·구조 (-100~100), 디헤이즈 (0~100)
    var clarity: Float = 0
    var structure: Float = 0
    /// 클래리티 방식 0 내추럴, 1 펀치, 2 뉴트럴, 3 클래식
    var clarityMethod: Float = 0
    var dehaze: Float = 0
    /// 안개 색: 색조(°)와 양(0~1). 양 0이면 회색 안개.
    var dehazeHue: Float = 30
    var dehazeTint: Float = 0
    // 추가 샤프닝: 양 0~300, 반경 원본 px, 임계값, 헤일로 억제 0~100
    var sharpenAmount: Float = 0
    var sharpenRadius: Float = 0.8
    var sharpenThreshold: Float = 1
    var sharpenHalo: Float = 50
    /// 단일 픽셀(핫 픽셀) 제거 0~100
    var hotPixels: Float = 0
    /// 그레인 종류 0 미세, 1 은염, 2 부드럽게, 3 색 입자
    var grainType: Float = 0
    // 리터칭 점 (복구·복제). 디코딩 원본 좌표.
    var spots: [RetouchSpot] = []
    /// 패스 패널의 패스들 (펜 도구, 원본 좌표)
    var paths: [VectorPath]? = nil
    /// 문서 모드 (DocMode: 0 RGB, 1 회색조, 2 이중톤, 3 CMYK, 4 Lab), 색 공간(ExportRecipe.Space), 비트 깊이(8·16·32)
    var docMode: Int? = nil
    var docSpace: String? = nil
    var docDepth: Int? = nil
    /// 이중톤 잉크 두 개 (화면 값 RGB 여섯), 첫 잉크 무게
    var duotone: [Float]? = nil
    var duotoneBalance: Float? = nil
    /// 안내선 (사진 화면 틀 좌표), 계수 점 (x, y 반복)
    var guidesV: [Double]? = nil
    var guidesH: [Double]? = nil
    var countMarks: [Double]? = nil
    /// 배경 제거: 이 마스크(원본 좌표 흑백 그림) 밖은 투명. 알파를 지원하는 형식으로 내보내면 투명하게 남는다
    var cutout: String? = nil
    // 조정 레이어 (아래부터 위로)
    var layers: [AdjustLayer] = []
    /// 레이어 구성: 레이어 보임·불투명도·혼합·자리를 이름 붙여 저장 (LayerAdvanced.swift)
    var layerComps: [LayerComp]? = nil
    /// 저장한 선택 (알파 채널, Selection.swift)
    var channels: [SavedSelection]? = nil
    /// 감마 혼합 (화면 감마에서 섞기). PSD에서 가져온 문서는 켠다.
    var gammaBlend: Bool? = nil
    /// LCC 평면 보정 지도 (레이어 그림 폴더), 1 색 편차 + 2 빛 균일화
    var lcc: String? = nil
    var lccMode: Int? = nil
    /// 원근 자르기: 틀(90° 회전 뒤) 좌표의 네 점 (왼아래, 오른아래, 오른위, 왼위) → 반듯한 사각형으로
    var perspective: [Double]? = nil
    /// 캔버스 크기: 크롭 결과 둘레에 더하는 여백 (왼, 아래, 오른, 위 — 크롭 크기의 비율), 색 (없으면 투명)
    var canvasPad: [Double]? = nil
    var canvasColor: [Float]? = nil
    /// 이미지 크기 (내보낼 때 픽셀 크기, 0이면 그대로)와 리샘플링 (0 란초스, 1 바이큐빅, 2 세부 유지, 3 최근접)
    var outputSize: [Double]? = nil
    var resample: Int? = nil
    /// 소실점 평면 (원본 좌표 네 점)
    var vanishingPlane: [Double]? = nil
    /// 외부 카탈로그에서 가져온 화이트 밸런스 차이 (미레드, 틴트). 처음 열 때 카메라 기록값에 더하고 지운다
    var importWBShift: [Double]? = nil
    // 비네팅 (-100 어둡게 ~ 100 밝게)
    var vignette: Float = 0
    // 레벨 (0~1, 감마는 1이 그대로)
    var levelInBlack: Float = 0
    var levelInWhite: Float = 1
    var levelGamma: Float = 1
    var levelOutBlack: Float = 0
    var levelOutWhite: Float = 1
    /// 채널별 레벨 R·G·B: [입력 검정, 입력 흰색, 감마, 출력 검정, 출력 흰색]
    var levelsRGB: [[Float]] = Array(repeating: [0, 1, 1, 0, 1], count: 3)
    // 커브
    var curves = CurveSet()
    // 컬러 밸런스, 흑백 (3D LUT 하나로 굽는다)
    var color = ColorLUT.Key()

    /// RAW 디코딩을 다시 해야 하는 값만 모은 것. 나머지가 바뀌면 디코딩 결과를 재사용한다.
    /// 크기와 좌표를 바꾸는 값. 바뀌면 보정 전 이미지도 다시 만든다.
    var geometryKey: [Double] {
        [Double(quarterTurns), Double(flipH), Double(flipV), Double(rotation), Double(keystoneV),
         Double(keystoneH), Double(keystoneAspect), crop.x, crop.y, crop.w, crop.h] + (perspective ?? []) + (canvasPad ?? [])
    }

    var rawStage: [Float] {
        [temperature, tint, exposure, sharpness, detail, lumaNoise, colorNoise, moire, lensCorrection, filmCurve, look]
    }
}

/// 촬영 정보. 레이어 패널 아래에 보여 준다.
struct ShotInfo {
    var camera = "", lens = ""
    var iso = "", shutter = "", aperture = "", focal = ""
    var date = ""

    init(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        camera = Self.cameraName(make: tiff[kCGImagePropertyTIFFMake] as? String ?? "", model: tiff[kCGImagePropertyTIFFModel] as? String ?? "")
        lens = (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String ?? ""
        // 캐논 CR3는 ISOSpeedRatings 대신 ISOSpeed·RecommendedExposureIndex에 적는다.
        let isoValue = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            ?? exif[kCGImagePropertyExifISOSpeed] as? Int
            ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int
        if let v = isoValue { iso = "ISO \(v)" }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            shutter = t >= 1 ? String(format: "%.1f초", t) : "1/\(Int((1 / t).rounded()))초"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { aperture = String(format: "f/%.1f", f) }
        if let f = exif[kCGImagePropertyExifFocalLength] as? Double { focal = String(format: "%.0fmm", f) }
        date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
    }

    /// 회사 + 모델. 모델에 회사 이름이 이미 있으면(캐논 "Canon EOS R5", 니콘 "NIKON Z 8") 모델만,
    /// 회사 이름의 군더더기(CORPORATION, IMAGING CORP. 등)는 뺀다.
    static func cameraName(make: String, model: String) -> String {
        let noise: Set<String> = ["corporation", "corp", "corp.", "co.,ltd.", "co.,ltd", "co.", "ltd", "ltd.", "imaging", "inc", "inc."]
        let maker = make.split(separator: " ").filter { !noise.contains($0.lowercased()) }.joined(separator: " ")
        let m = model.trimmingCharacters(in: .whitespaces)
        if let first = maker.split(separator: " ").first, m.lowercased().hasPrefix(first.lowercased()) { return m }
        return [maker, m].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// 문서 맨 아래의 원본 레이어. 현상값은 언제든 다시 바꿀 수 있다.
///
/// RAW 디코딩은 Core Image RAW(CIRAWFilter)에 맡긴다. macOS가 지원하는 카메라의 RAW를 직접
/// 풀고, scaleFactor를 낮추면 원본 해상도를 다 풀지 않고 미리보기를 만든다.
/// JPEG·TIFF처럼 이미 현상된 파일은 같은 값을 Core Image 필터로 흉내 낸다.
final class RawDocument {
    enum OpenError: LocalizedError {
        case unsupported(URL)
        var errorDescription: String? {
            switch self {
            case .unsupported(let url): return "\(url.lastPathComponent) 파일을 열 수 없습니다."
            }
        }
    }

    private enum Source {
        /// guide: 넓은 반경 도구(클래리티·디헤이즈)의 지도를 만드는 1/8 해상도 전용 필터.
        case raw(CIRAWFilter, guide: CIRAWFilter)
        case rendered(CIImage)
    }

    let url: URL
    let info: ShotInfo
    /// 보정 전 보기용 RAW 필터 (처음 쓸 때 만든다)
    private lazy var originalFilter: CIRAWFilter? = CIRAWFilter(imageURL: URL(fileURLWithPath: url.path))

    /// 카메라 기록값만 (RAW 필터 하나로 가볍게) — 미리보기 준비·일괄 처리에서 문서를 다 만들지 않고
    static func shotSettings(url: URL) -> DevelopSettings? {
        guard let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: url.path)) else { return nil }
        return shot(from: raw)
    }

    /// RAW 필터의 카메라 기록값
    static func shot(from raw: CIRAWFilter) -> DevelopSettings {
        var shot = DevelopSettings()
        shot.temperature = raw.neutralTemperature
        shot.tint = raw.neutralTint
        shot.sharpness = raw.sharpnessAmount
        shot.detail = raw.detailAmount
        shot.lumaNoise = raw.luminanceNoiseReductionAmount
        shot.colorNoise = raw.colorNoiseReductionAmount
        shot.moire = raw.moireReductionAmount
        shot.filmCurve = raw.boostAmount
        shot.lensCorrection = raw.isLensCorrectionSupported && raw.isLensCorrectionEnabled ? 1 : 0
        shot.look = Float(AppSettings.defaultLook)
        return shot
    }

    /// 가져온 화이트 밸런스 차이를 기록값에 더한다 (문서 없이)
    static func importedWB(_ s: DevelopSettings, over asShot: DevelopSettings) -> DevelopSettings {
        guard let sh = s.importWBShift, sh.count == 2 else { return s }
        var o = s
        let mired = 1e6 / Double(asShot.temperature) + sh[0]
        o.temperature = Float(min(max(1e6 / max(mired, 20), 2000), 50000))
        o.tint = Float(min(max(Double(asShot.tint) + sh[1], -150), 150))
        o.importWBShift = nil
        return o
    }
    let isRaw: Bool
    /// PSD·PSB로 연 문서: 배경은 원본 자리, 나머지 레이어는 처음 열 때 조정 레이어로 옮긴다 (PSDImport)
    private(set) var psd: PSD.File?
    /// 카메라가 기록한 값. "초기화"가 돌아갈 곳이다.
    let asShot: DevelopSettings
    var settings: DevelopSettings {
        didSet {
            // 크롭 도구 중에는 틀 전체를 보여 주므로 크롭 사각형만 바뀐 건 다시 그릴 필요가 없다.
            var a = settings, b = oldValue
            if showFullFrame { a.crop = CropRect(); b.crop = CropRect(); a.cropAspect = 0; b.cropAspect = 0 }
            if a != b { cache.removeAll() }
            if settings.geometryKey != oldValue.geometryKey { originalCache.removeAll() }
        }
    }
    /// 설정은 그대로 두고 그린 결과만 버린다 (슬라이더 반응 맞추기용).
    func clearCache() { cache.removeAll(); originalCache.removeAll() }

    /// 크롭 도구를 쓰는 동안 켠다. 크롭하지 않은 틀 전체를 보여 준다.
    var showFullFrame = false {
        didSet { if showFullFrame != oldValue { cache.removeAll(); originalCache.removeAll() } }
    }
    /// 슬라이더를 끄는 동안 켠다. 디모자이크를 빠른 방식으로 바꾼다.
    /// 썸네일처럼 작게만 쓸 문서: RAW를 빠른 방식으로 푼다 (굳히기 없이)
    var quickDecode = false
    var draft = false { didSet { if draft != oldValue { cache.removeAll(); if !draft { draftDecodes.removeAll() } } } }

    private let source: Source
    private var cache: [CGFloat: CIImage] = [:]
    /// 끄는 중 빠른 길: 끌기를 시작할 때 RAW 해독 결과를 그림으로 굳혀 둔다 (노출·색온도만 바꾸면 해독을 다시 하지 않는다)
    private var draftDecodes: [String: (key: String, image: CIImage, exposure: Float, temperature: Float, tint: Float)] = [:]

    /// RAW 해독에 드는 값 중 노출·색온도·틴트를 뺀 것 (이게 같으면 굳힌 해독을 쓴다)
    private func rawKey(_ s: DevelopSettings) -> String {
        "\(s.sharpness)|\(s.detail)|\(s.lumaNoise)|\(s.colorNoise)|\(s.moire)|\(s.filmCurve)|\(s.lensCorrection)|\(s.highlightRecoveryOn)"
    }
    private var originalCache: [CGFloat: CIImage] = [:]
    /// 미리보기만 쓰기 (대량 보정·격자·테더링): RAW를 미리보기 크기(긴 변 AppSettings.previewSize)보다 크게 풀지 않고,
    /// 그보다 크게 볼 때는 미리보기를 늘린다. 원본 크기는 심화 보정에서만 (그리고 내보내기·병합처럼 결과를 만드는 일은 늘 원본으로)
    var previewOnly = false {
        didSet { if previewOnly != oldValue { draftDecodes.removeAll() } }
    }
    /// 캐시 열쇠: 미리보기만 쓰기와 원본 크기를 따로 기억한다 (초점 확인처럼 잠깐 원본을 봐도 화면 캐시가 지워지지 않게)
    private func cacheKey(_ scale: CGFloat) -> CGFloat { previewOnly && scale > previewScale ? -scale : scale }

    /// 결과를 만드는 일(내보내기·병합·인쇄·채널 분리·초점 확인)은 미리보기만 쓰기를 잠시 끄고 원본 크기로
    func withFullResolution<T>(_ f: () throws -> T) rethrows -> T {
        let was = previewOnly
        if was { previewOnly = false }
        defer { if was { previewOnly = true } }
        return try f()
    }

    /// 미리보기 크기의 배율 (긴 변 기준)
    var previewScale: CGFloat { min(1, CGFloat(AppSettings.previewSize) / max(nativeSize.width, nativeSize.height, 1)) }

    /// 카메라 방향을 반영한 디코딩 결과 크기.
    let nativeSize: CGSize
    /// 형태 보정 틀 (90° 회전 반영, 크롭 전).
    var frameSize: CGSize { Geometry.frameSize(settings, native: nativeSize) }
    /// 화면과 내보내기에 쓰는 크기. 크롭 도구 중에는 틀 전체.
    var pixelSize: CGSize { showFullFrame ? frameSize : Geometry.croppedSize(settings, native: nativeSize) }

    init(url: URL) throws {
        self.url = url
        // 변형본 조각(#v2)은 파일을 읽을 때 뺀다
        let url = URL(fileURLWithPath: url.path)
        info = ShotInfo(url: url)
        // 보정 전 보기용 필터를 따로 둔다. 같은 필터를 설정만 바꿔 쓰면 이미 만든 출력이 흔들릴 수 있다.
        // CIRAWFilter는 JPEG도 받아 준다. RAW인지는 파일 종류로 가린다.
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let looksRaw = type?.conforms(to: .rawImage) ?? false
        if PSDImport.extensions.contains(url.pathExtension.lowercased()) {
            let f = try PSD.read(url)
            guard let img = PSDImport.base(f), !img.extent.isEmpty else { throw OpenError.unsupported(url) }
            psd = f
            source = .rendered(img)
            isRaw = false
            nativeSize = img.extent.size
            var shot = DevelopSettings()
            shot.temperature = 6500
            shot.lensCorrection = 0
            asShot = shot
        } else if looksRaw, let raw = CIRAWFilter(imageURL: url),
           let guide = CIRAWFilter(imageURL: url), let full = raw.outputImage, !full.extent.isEmpty {
            // 보정 전 보기 필터는 처음 비교할 때 만든다 (필터 하나에 60ms쯤, 사진을 넘길 때마다 들었다)
            source = .raw(raw, guide: guide)
            isRaw = true
            nativeSize = full.extent.size
            asShot = Self.shot(from: raw)
        } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                  !img.extent.isEmpty {
            source = .rendered(img)
            isRaw = false
            nativeSize = img.extent.size
            // 이미 현상된 사진은 6500K를 "그대로"로 본다.
            var shot = DevelopSettings()
            shot.temperature = 6500
            shot.lensCorrection = 0
            asShot = shot
        } else {
            throw OpenError.unsupported(url)
        }
        settings = asShot
    }

    /// 가져온 화이트 밸런스 차이를 절대값으로 (true면 바뀜)
    @discardableResult
    func applyImportedWB() -> Bool {
        guard let sh = settings.importWBShift, sh.count == 2 else { return false }
        var s = settings
        let mired = 1e6 / Double(asShot.temperature) + sh[0]
        s.temperature = Float(min(max(1e6 / max(mired, 20), 2000), 50000))
        s.tint = Float(min(max(Double(asShot.tint) + sh[1], -150), 150))
        s.importWBShift = nil
        settings = s
        return true
    }

    /// PSD 레이어를 다 옮긴 뒤 파일 자료를 놓는다 (메모리)
    func releasePSD() { psd = nil }

    /// 히스토그램·색조 분포 같은 분석용 작은 그림: 이미 그려 둔 배율(1/2·1/4)이 있으면 그것을 줄여 쓴다
    /// (따로 1/8로 그리면 RAW를 한 번 더 풀어, 사진을 열 때 해독이 서너 번 겹쳤다)
    func analysisImage() -> CIImage {
        if let (sc, img) = cache.filter({ $0.key <= 0.5 && $0.key >= 1.0 / 8 }).min(by: { $0.key < $1.key }) {
            let k = min(1, (1.0 / 8) / sc)
            return k >= 0.999 ? img : img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        return image(scale: 1.0 / 8)
    }

    /// `scale`은 1, 1/2, 1/4, 1/8 중 하나. 결과 크기는 pixelSize × scale이다.
    func image(scale: CGFloat) -> CIImage {
        let settings = SliderResponse.effective(self.settings)
        if let hit = cache[cacheKey(scale)] { return hit }
        // 넓은 반경 도구의 지도는 1/8 해상도에서 만든다. 원본 해상도에서 만들면 화면 밖까지
        // 45MP 전체를 디코딩해야 해서 100% 첫 표시가 3~5초 걸렸다.
        let guideScale = Develop.guideScale
        // PSD처럼 레이어만 다른 합성이 이어질 때: 굳힌 기본 보정이 있으면 해독부터 건너뛴다
        var frozenKey = ""
        if freezeDecodes {
            var bare = settings; bare.layers = []
            frozenKey = "\(scale)|\(showFullFrame)|" + ((try? JSONEncoder().encode(bare)).map { String(decoding: $0, as: UTF8.self) } ?? "")
            if let f = frozenBase, f.key == frozenKey {
                return finishImage(settings, base: f.base, g: f.guide, layerGuideScale: f.guideScale, scale: scale)
            }
        }
        let mainShaped = shaped(decoded(scale: scale, guide: false), scale)
        let guide: CIImage?
        if scale > guideScale && scale <= 0.5 {
            // 맞춤 보기처럼 작은 배율: 이미 푼 그림을 줄여 길잡이로 (RAW를 한 번 더 풀면 사진을 열 때 0.5초가 더 들었다)
            let g0 = mainShaped.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: guideScale / scale, kCIInputAspectRatioKey: 1])
            let target = CGRect(x: 0, y: 0, width: (mainShaped.extent.width * guideScale / scale).rounded(),
                                height: (mainShaped.extent.height * guideScale / scale).rounded())
            guide = g0.clampedToExtent().cropped(to: target)
        } else {
            guide = scale > guideScale ? shaped(decoded(scale: guideScale, guide: true), guideScale) : nil
        }
        // 안개 빛은 디헤이즈를 쓸 때만, 뒤에서 잰다. 썸네일은 이미 푼 작은 그림으로 잰다 (RAW를 1/8로 다시 풀어 장당 0.7초가 더 들었다)
        let haze: Float = settings.dehaze <= 0 ? 0
            : (approximateFromPreview ? (hazeLight ?? Develop.estimateHazeLight(mainShaped)) : hazeLightOrStart())
        var (base, g) = Develop.base(settings, to: mainShaped, guide: guide, scale: scale, haze: haze)
        // 결과를 여러 번 그리는 일(PSD): 레이어만 다른 합성이 이어지므로 기본 보정 결과를 한 번 굳혀 다시 쓴다
        if freezeDecodes, let fb = freeze(base) {
            let fg = freeze(g) ?? g
            frozenBase = (frozenKey, fb, fg, guide == nil ? scale : guideScale)
            base = fb; g = fg
            // 기본 보정을 굳혔으니 해독 그림은 더 쓰지 않는다 (45MP 반정밀도 360MB)
            frozenDecodes.removeAll()
        }
        return finishImage(settings, base: base, g: g, layerGuideScale: guide == nil ? scale : guideScale, scale: scale)
    }

    /// 기본 보정 뒤: 레이어·마무리·색 모드·배경 제거
    private func finishImage(_ settings: DevelopSettings, base: CIImage, g: CIImage, layerGuideScale: CGFloat, scale: CGFloat) -> CIImage {
        var img = base
        if !settings.layers.isEmpty {
            img = Layers.apply(settings.layers, to: base, guide: g, scale: scale,
                               guideScale: layerGuideScale, native: nativeSize,
                               shape: { [settings, showFullFrame] m, sc in
                                   let t = Geometry.transform(settings, m, scale: sc)
                                   return showFullFrame ? t : Geometry.crop(settings, t)
                               },
                               toDisplay: { [settings, nativeSize, showFullFrame] p in
                                   Geometry.toDisplay(p, settings, native: nativeSize, fullFrame: showFullFrame)
                               }, gamma: settings.gammaBlend ?? false)
        }
        img = Develop.finish(settings, img, scale: scale)
        if settings.intensity < 0.999 {
            let before = originalImage(scale: scale)
            img = before.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: img, kCIInputTimeKey: max(settings.intensity, 0),
            ]).cropped(to: img.extent)
        }
        if settings.docMode != nil || settings.docSpace != nil || settings.docDepth == 8 { img = ColorModes.apply(settings, img) }
        if let cut = settings.cutout {
            // 배경 제거: 마스크 밖을 투명하게
            var lm = LayerMask(); lm.kind = .image; lm.maskFile = cut
            let s = settings, full = showFullFrame
            let m = Layers.maskImage(lm, scale: scale, native: nativeSize, shape: { mm, sc in
                let t = Geometry.transform(s, mm, scale: sc)
                return full ? t : Geometry.crop(s, t)
            }, base: img)
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m]).cropped(to: img.extent)
        }
        if ProcessInfo.processInfo.environment["DUOCHROME_EXTENT_DEBUG"] != nil {
            NSLog("extent scale %.3f: decoded %@ shaped %@ base %@ final %@ (pixelSize×scale %@)", scale,
                  "\(decoded(scale: scale, guide: false).extent)", "\(shaped(decoded(scale: scale, guide: false), scale).extent)",
                  "\(base.extent)", "\(img.extent)", "\(CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale))")
        }
        cache[cacheKey(scale)] = img
        return img
    }

    /// RAW 디코딩 단계까지 (노출·화이트 밸런스·노이즈·샤프닝·렌즈 보정).
    /// 결과를 여러 번 그리는 일(PSD 레이어마다 합성)에서: RAW 해독을 한 번만 하고 굳혀 다시 쓴다.
    /// 내보내기용 그리기 도구는 중간 결과를 보관하지 않아, 합성마다 45MP를 새로 풀었다 (PSD 레이어 여섯 개에 1분 넘게)
    var freezeDecodes = false { didSet { if !freezeDecodes { frozenDecodes.removeAll(); frozenBase = nil } } }
    private var frozenBase: (key: String, base: CIImage, guide: CIImage, guideScale: CGFloat)?
    private var frozenDecodes: [String: (key: String, image: CIImage)] = [:]

    /// 썸네일용: 이 설정 그대로의 미리보기가 없으면 같은 사진의 다른 미리보기(촬영 값 등)에 노출·색온도 차이만 얹어 쓴다.
    /// RAW 해독(45MP CR3는 줄여 풀어도 장당 2초, 한 번에 하나씩)을 건너뛴다. 320px에서는 차이가 보이지 않는다
    var approximateFromPreview = false

    /// 미리보기 캐시를 쓸지 (내보내기·맞춤 도구는 끈다)
    var usePreviewCache = ProcessInfo.processInfo.environment["DUOCHROME_NO_PREVIEWS"] == nil

    /// 형태 보정 전 원본 좌표 그림 (AI 선택 마스크 계산용)
    func nativePreview(scale: CGFloat) -> CIImage { decoded(scale: scale, guide: true) }

    /// 그림을 한 번 그려 반정밀도 비트맵 그림으로 굳힌다 (다시 그려도 RAW를 풀지 않게)
    private func freeze(_ img: CIImage) -> CIImage? {
        let e = img.extent.integral
        guard e.width > 0, e.height > 0 else { return nil }
        var data = Data(count: Int(e.width) * Int(e.height) * 8)
        data.withUnsafeMutableBytes { p in
            guard let base = p.baseAddress else { return }
            // 결과를 만드는 일(PSD)에서는 중간 결과를 보관하지 않는 내보내기용으로 (화면용은 45MP 중간 결과를 수 GB 들고 있었다)
            let ctx = freezeDecodes ? Render.exportContext : Render.context
            ctx.render(img, toBitmap: base, rowBytes: Int(e.width) * 8, bounds: e, format: .RGBAh, colorSpace: Render.workingSpace)
        }
        return CIImage(bitmapData: data, bytesPerRow: Int(e.width) * 8, size: e.size, format: .RGBAh, colorSpace: Render.workingSpace)
            .transformed(by: .init(translationX: e.minX, y: e.minY))
    }

    private func decoded(scale: CGFloat, guide: Bool) -> CIImage {
        let settings = SliderResponse.effective(self.settings)
        switch source {
        case .raw(let main, let guideFilter):
            // 미리보기 캐시: 캐시 해상도 안의 배율이면 RAW를 풀지 않는다 (사진을 넘길 때 빠르게)
            if usePreviewCache, let p = PreviewCache.shared.image(url: url, settings: settings),
               previewOnly || nativeSize.width * scale <= p.extent.width * 1.001 {
                let target = CGRect(x: 0, y: 0, width: (nativeSize.width * scale).rounded(), height: (nativeSize.height * scale).rounded())
                let sx = target.width / p.extent.width, sy = target.height / p.extent.height
                let img = sx < 0.75
                    ? p.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
                    : p.transformed(by: .init(scaleX: sx, y: sy))
                let e = img.extent
                let fitted = img.transformed(by: .init(translationX: -e.minX, y: -e.minY)).clampedToExtent().cropped(to: target)
                return Lens.apply(settings, Look.apply(fitted, look: settings.look, camera: info.camera))
            }
            if approximateFromPreview, usePreviewCache, !guide {
                var same = settings
                same.exposure = asShot.exposure; same.temperature = asShot.temperature; same.tint = asShot.tint
                for c in [same, asShot] {
                    guard let p = PreviewCache.shared.image(url: url, settings: c) ?? PreviewCache.shared.thumbBase(url: url, settings: c) else { continue }
                    let target = CGRect(x: 0, y: 0, width: max(1, (nativeSize.width * scale).rounded()), height: max(1, (nativeSize.height * scale).rounded()))
                    let sx = target.width / p.extent.width, sy = target.height / p.extent.height
                    var img = p.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
                    let e = img.extent
                    img = img.transformed(by: .init(translationX: -e.minX, y: -e.minY)).clampedToExtent().cropped(to: target)
                    let dEV = settings.exposure - c.exposure
                    if abs(dEV) > 1e-4 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: dEV]) }
                    if settings.temperature != c.temperature || settings.tint != c.tint {
                        img = img.applyingFilter("CITemperatureAndTint", parameters: [
                            "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                            "inputTargetNeutral": CIVector(x: CGFloat(c.temperature), y: CGFloat(c.tint)),
                        ]).cropped(to: target)
                    }
                    return Lens.apply(settings, Look.apply(img, look: settings.look, camera: info.camera))
                }
            }
            let fullKey = rawKey(settings) + "|\(settings.exposure)|\(settings.temperature)|\(settings.tint)"
            let frozenSlot = "\(guide ? "g" : "m")\(scale)|\(previewOnly)"
            if freezeDecodes, let f = frozenDecodes[frozenSlot], f.key == fullKey {
                return Lens.apply(settings, Look.apply(f.image, look: settings.look, camera: info.camera))
            }
            let raw = guide ? guideFilter : main
            // 끄는 중이면 굳혀 둔 해독에 노출·색온도 차이만 얹는다 (손을 떼면 정확한 해독으로 돌아간다)
            let slot = "\(guide ? "g" : "m")\(scale)"
            if draft, let d = draftDecodes[slot], d.key == rawKey(settings) {
                var img = d.image
                let dEV = settings.exposure - d.exposure
                if abs(dEV) > 1e-4 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: dEV]) }
                if settings.temperature != d.temperature || settings.tint != d.tint {
                    img = img.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                        "inputTargetNeutral": CIVector(x: CGFloat(d.temperature), y: CGFloat(d.tint)),
                    ])
                }
                return Lens.apply(settings, Look.apply(img.cropped(to: d.image.extent), look: settings.look, camera: info.camera))
            }
            // 미리보기만 쓰기면 미리보기 크기보다 크게 풀지 않는다 (길잡이 1/8은 그대로)
            let decodeScale = previewOnly && !guide ? min(scale, previewScale) : scale
            raw.scaleFactor = Float(decodeScale)
            raw.isDraftModeEnabled = guide || draft || quickDecode
            // 썸네일: 촬영 노출·색온도로 풀어 바탕으로 남기고, 차이는 뒤에서 얹는다 (다음 썸네일은 해독 없이)
            let thumbBaseMode = approximateFromPreview && !guide && usePreviewCache
            var ds = settings
            if thumbBaseMode { ds.exposure = asShot.exposure; ds.temperature = asShot.temperature; ds.tint = asShot.tint }
            raw.exposure = ds.exposure
            raw.neutralTemperature = ds.temperature
            raw.neutralTint = ds.tint
            raw.sharpnessAmount = settings.sharpness
            raw.detailAmount = settings.detail
            raw.luminanceNoiseReductionAmount = settings.lumaNoise
            raw.colorNoiseReductionAmount = settings.colorNoise
            raw.moireReductionAmount = settings.moire
            raw.boostAmount = settings.filmCurve
            if #available(macOS 26, *), raw.isHighlightRecoverySupported {
                raw.isHighlightRecoveryEnabled = settings.highlightRecoveryOn
            }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = settings.lensCorrection > 0.5 }
            var decodedImage = normalized(raw.outputImage)
            if decodeScale < scale - 1e-6, !decodedImage.extent.isEmpty {
                // 미리보기 크기로 푼 것을 보려는 배율까지 늘린다
                let k = scale / decodeScale
                let target = CGRect(x: 0, y: 0, width: (nativeSize.width * scale).rounded(), height: (nativeSize.height * scale).rounded())
                decodedImage = decodedImage.transformed(by: .init(scaleX: k, y: k)).clampedToExtent().cropped(to: target)
            }
            if thumbBaseMode, !decodedImage.extent.isEmpty, let frozen = freeze(decodedImage) {
                PreviewCache.shared.storeThumbBase(frozen, url: url, settings: ds)
                var img = frozen
                let dEV = settings.exposure - ds.exposure
                if abs(dEV) > 1e-4 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: dEV]) }
                if settings.temperature != ds.temperature || settings.tint != ds.tint {
                    img = img.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                        "inputTargetNeutral": CIVector(x: CGFloat(ds.temperature), y: CGFloat(ds.tint)),
                    ]).cropped(to: frozen.extent)
                }
                return Lens.apply(settings, Look.apply(img, look: settings.look, camera: info.camera))
            }
            if freezeDecodes, !draft, !decodedImage.extent.isEmpty, let frozen = freeze(decodedImage) {
                frozenDecodes[frozenSlot] = (fullKey, frozen)
                decodedImage = frozen
            }
            // 미리보기만 쓰기인데 미리보기가 없으면 만들어 둔다 (다음부터는 RAW를 풀지 않게, 끄는 중에는 말고)
            if previewOnly, !guide, !draft, usePreviewCache { PreviewCache.shared.ensure(url: url, settings: settings) }
            if draft, decodeScale <= 0.5, !decodedImage.extent.isEmpty {
                // 끌기 첫 장면: 해독을 반정밀도 그림으로 굳혀 다음 장면부터 다시 풀지 않는다
                let e = decodedImage.extent.integral
                var data = Data(count: Int(e.width) * Int(e.height) * 8)
                let ok = data.withUnsafeMutableBytes { p -> Bool in
                    guard let base = p.baseAddress else { return false }
                    Render.context.render(decodedImage, toBitmap: base, rowBytes: Int(e.width) * 8, bounds: e, format: .RGBAh, colorSpace: Render.workingSpace)
                    return true
                }
                if ok {
                    let frozen = CIImage(bitmapData: data, bytesPerRow: Int(e.width) * 8, size: e.size, format: .RGBAh, colorSpace: Render.workingSpace)
                        .transformed(by: .init(translationX: e.minX, y: e.minY))
                    draftDecodes[slot] = (rawKey(settings), frozen, settings.exposure, settings.temperature, settings.tint)
                    decodedImage = frozen
                }
            }
            return Lens.apply(settings, Look.apply(decodedImage, look: settings.look, camera: info.camera))
        case .rendered(let base):
            var out = scaled(base, scale)
            if settings.exposure != 0 {
                out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
            }
            if settings.temperature != asShot.temperature || settings.tint != asShot.tint {
                out = out.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                    "inputTargetNeutral": CIVector(x: CGFloat(asShot.temperature), y: 0),
                ])
            }
            return Lens.apply(settings, out)
        }
    }

    func originalImage(scale: CGFloat) -> CIImage {
        if let hit = originalCache[cacheKey(scale)] { return hit }
        let img: CIImage
        switch source {
        case .raw:
            guard let original = originalFilter else { return image(scale: scale) }
            let os = previewOnly ? min(scale, previewScale) : scale
            original.scaleFactor = Float(os)
            var o = normalized(original.outputImage)
            if os < scale - 1e-6 {
                let target = CGRect(x: 0, y: 0, width: (nativeSize.width * scale).rounded(), height: (nativeSize.height * scale).rounded())
                o = o.transformed(by: .init(scaleX: scale / os, y: scale / os)).clampedToExtent().cropped(to: target)
            }
            img = shaped(Look.apply(o, look: settings.look, camera: info.camera), scale, retouch: false)
        case .rendered(let base):
            img = shaped(scaled(base, scale), scale, retouch: false)
        }
        originalCache[cacheKey(scale)] = img
        return img
    }

    /// 리터칭 원본 자리를 자동으로 고른다 (리터칭 전 1/8 이미지로 비교).
    func autoSource(target: CGPoint, radius: Double) -> CGPoint {
        let scale = Develop.guideScale
        return Retouch.pickSource(target: target, radius: radius, in: decoded(scale: scale, guide: true), scale: scale)
    }

    /// 마스크 보기용: 레이어 마스크를 화면 틀 좌표로 (루마 레인지는 지금 결과 밝기로 근사).
    func maskPreview(_ id: String, scale: CGFloat) -> CIImage? {
        guard let layer = settings.layers.first(where: { $0.id == id }) else { return nil }
        let base = image(scale: scale)
        let s = settings, full = showFullFrame
        return Layers.maskImage(layer.mask, scale: scale, native: nativeSize, shape: { m, sc in
            let t = Geometry.transform(s, m, scale: sc)
            return full ? t : Geometry.crop(s, t)
        }, base: base)
    }

    /// 붓질의 원본 자리 (획에서 옮길 거리).
    func autoStrokeOffset(path: [CGPoint], radius: Double) -> CGPoint {
        let scale = Develop.guideScale
        return Retouch.pickStrokeOffset(path, radius: radius, in: decoded(scale: scale, guide: true), scale: scale)
    }

    /// 자동 키스톤용: 1/8 이미지(90° 회전·뒤집기만)에서 곧은 선을 찾아 틀 좌표(원본 픽셀)로.
    func detectFramedLines() -> (vertical: [(CGPoint, CGPoint)], horizontal: [(CGPoint, CGPoint)]) {
        let scale = Develop.guideScale
        let img = decoded(scale: scale, guide: true)
        let (turn, _) = Geometry.turnTransform(settings, w: img.extent.width, h: img.extent.height)
        let found = LineDetector.detect(img.transformed(by: turn))
        func up(_ l: LineDetector.Line) -> (CGPoint, CGPoint) {
            (CGPoint(x: l.a.x / scale, y: l.a.y / scale), CGPoint(x: l.b.x / scale, y: l.b.y / scale))
        }
        return (found.vertical.map(up), found.horizontal.map(up))
    }

    /// 화면 좌표(보이는 이미지) ↔ 디코딩 원본 좌표.
    func toNative(_ p: CGPoint) -> CGPoint { Geometry.fromDisplay(p, settings, native: nativeSize, fullFrame: showFullFrame) }
    func toDisplay(_ p: CGPoint) -> CGPoint { Geometry.toDisplay(p, settings, native: nativeSize, fullFrame: showFullFrame) }

    /// 화이트 밸런스 스포이트: 화면의 그 점이 무채색이 되는 색온도·틴트를 찾는다.
    ///
    /// RAW 엔진에 값을 넣어 보고 그 점의 선형 RGB를 재는 일을 되풀이한다 (뉴턴법, 미레드·틴트 공간).
    /// 1/8 해상도 전용 필터로 재므로 한 번에 수십 ms다. 점 둘레 5×5 평균을 쓴다.
    ///
    /// RAW 엔진의 `neutralLocation`도 시험했지만 색온도만 옮기고 틴트는 거의 두어서, 누른 곳이 무채색이 되지 않았다
    /// (하늘에서 11,936K vs 이 방법 7,732K, 결과 RGB 230·230·229). 그래서 직접 맞춘다.
    ///
    /// 전용 필터와 값 복사본만 쓰므로 백그라운드 스레드에서 불러도 된다 (한 번에 1초 가까이 걸린다).
    /// `display`가 nil이면 자동 화이트 밸런스: 사진 전체 평균이 무채색이 되게 (회색 세계 가정).
    func neutralWhiteBalance(at display: CGPoint?) -> (temperature: Float, tint: Float)? {
        guard case .raw = source, let g = CIRAWFilter(imageURL: URL(fileURLWithPath: url.path)) else { return nil }
        let settings = self.settings, fullFrame = self.showFullFrame
        let scale = Develop.guideScale
        let p = display.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        var measures = 0
        let started = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil {
                NSLog("wb: %d measures, %.0f ms", measures, (CACurrentMediaTime() - started) * 1000)
            }
        }
        func measure(_ temp: Float, _ tint: Float) -> SIMD3<Float>? {
            measures += 1
            g.scaleFactor = Float(scale)
            g.isDraftModeEnabled = true
            g.exposure = settings.exposure
            g.neutralTemperature = temp
            g.neutralTint = tint
            g.boostAmount = settings.filmCurve
            if g.isLensCorrectionSupported { g.isLensCorrectionEnabled = settings.lensCorrection > 0.5 }
            let t = Geometry.transform(settings, Look.apply(normalized(g.outputImage), look: settings.look, camera: info.camera), scale: scale)
            let img = fullFrame ? t : Geometry.crop(settings, t)
            guard let p else {
                // 전체 평균 (날아간 곳은 섞이지 않게 0.95에서 자른다)
                var px = [Float](repeating: 0, count: 4)
                let avg = img.applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 0.95, y: 0.95, z: 0.95, w: 1)])
                    .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
                Render.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      format: .RGBAf, colorSpace: Render.workingSpace)
                return SIMD3(px[0], px[1], px[2])
            }
            let r = CGRect(x: (p.x - 2).rounded(.down), y: (p.y - 2).rounded(.down), width: 5, height: 5)
            guard img.extent.contains(r) else { return nil }
            var px = [Float](repeating: 0, count: 25 * 4)
            Render.context.render(img, toBitmap: &px, rowBytes: 5 * 16, bounds: r, format: .RGBAf,
                                  colorSpace: Render.workingSpace)
            var sum = SIMD3<Float>(0, 0, 0)
            for i in 0..<25 { sum += SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) }
            return sum / 25
        }
        func error(_ c: SIMD3<Float>) -> SIMD2<Float> { SIMD2(log(c.x / c.y), log(c.z / c.y)) }

        // 첫 번에만 기울기(야코비안)를 차분으로 재고, 그 뒤로는 브로이든 갱신으로 고쳐 쓴다.
        // 매번 새로 재면 반복마다 세 번 디코딩해서 1초 가까이 걸렸다.
        var x = SIMD2<Float>(1e6 / settings.temperature, settings.tint)
        guard let c0 = measure(1e6 / x.x, x.y), min(c0.x, c0.y, c0.z) > 1e-4,
              let cm = measure(1e6 / (x.x + 5), x.y), let ct = measure(1e6 / x.x, x.y + 3) else { return nil }
        var e = error(c0)
        var j = (error(cm) - e) / 5, k = (error(ct) - e) / 3   // 열: ∂e/∂미레드, ∂e/∂틴트
        for _ in 0..<8 {
            if abs(e.x) < 0.003 && abs(e.y) < 0.003 { break }
            let det = j.x * k.y - k.x * j.y
            guard abs(det) > 1e-9 else { return nil }
            // [j k] · Δ = −e
            var d = SIMD2<Float>((-e.x * k.y + k.x * e.y) / det, (-j.x * e.y + e.x * j.y) / det)
            let next = SIMD2<Float>(min(max(x.x + d.x, 1e6 / 50000), 1e6 / 2000), min(max(x.y + d.y, -150), 150))
            d = next - x
            guard let c = measure(1e6 / next.x, next.y), min(c.x, c.y, c.z) > 1e-4 else { return nil }
            let e2 = error(c)
            // 브로이든: J += ((Δe − JΔ) Δᵀ) / (ΔᵀΔ)
            let dd = d.x * d.x + d.y * d.y
            if dd > 1e-9 {
                let r = (e2 - e) - (j * d.x + k * d.y)
                j += r * (d.x / dd); k += r * (d.y / dd)
            }
            x = next; e = e2
        }
        let mired = x.x, tint = x.y
        return (1e6 / mired, tint)
    }

    /// 형태 보정과 크롭. 현상 단계보다 먼저 건다 (비네팅·히스토그램이 크롭 기준이 되도록).
    private func shaped(_ img0: CIImage, _ scale: CGFloat, retouch: Bool = true) -> CIImage {
        let img = settings.lcc.map { LCC.apply(img0, file: $0, mode: settings.lccMode ?? 3, scale: scale) } ?? img0
        let r = retouch && !settings.spots.isEmpty ? Retouch.apply(settings.spots, to: img, scale: scale) : img
        let t = Geometry.transform(settings, r, scale: scale)
        return showFullFrame ? t : Geometry.crop(settings, t)
    }

    /// 디헤이즈의 대기광. 보정 전 사진의 다크 채널에서 가장 밝은 값 (처음 쓸 때 한 번 잰다).
    /// 안개 빛 (디헤이즈 기준). 처음 쓸 때 뒤 스레드에서 따로 RAW를 1/8로 풀어 잰다.
    /// 재는 동안은 흔한 값(0.95)으로 그리고, 끝나면 그림 캐시를 비우고 다시 그리라고 알린다 (주 스레드에서 재면 사진을 열 때 멈췄다)
    private var hazeLight: Float?
    private var hazeStarted = false
    static let needsRedraw = Notification.Name("DuochromeDocumentNeedsRedraw")

    /// 안개 빛을 바로 잰다 (내보내기처럼 정확해야 할 때, 뒤 스레드의 문서)
    private func measureHazeNow() -> Float {
        let h = Develop.estimateHazeLight(originalImage(scale: 1.0 / 8))
        hazeLight = h
        return h
    }

    /// 내보내기 전에: 디헤이즈를 쓰면 안개 빛을 정확히 잰다
    func settleForExport() {
        if settings.dehaze > 0, hazeLight == nil { _ = measureHazeNow(); cache.removeAll() }
    }

    private func hazeLightOrStart() -> Float {
        if let h = hazeLight { return h }
        // 주 스레드가 아니면(내보내기·썸네일) 바로 잰다
        if !Thread.isMainThread { return measureHazeNow() }
        if !hazeStarted {
            hazeStarted = true
            let fileURL = URL(fileURLWithPath: url.path), look = settings.look, camera = info.camera, isRaw = isRaw
            let fallback: CIImage? = isRaw ? nil : originalImage(scale: 1.0 / 8)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) { [weak self] in
                // 사진을 빨리 넘겨 이 문서가 이미 풀렸으면 재지 않는다
                BackgroundGate.waitQuiet()
                guard self != nil else { return }
                var small = fallback
                if isRaw, let raw = CIRAWFilter(imageURL: fileURL) {
                    raw.scaleFactor = 1.0 / 8
                    raw.isDraftModeEnabled = true
                    if let o = raw.outputImage {
                        let e = o.extent
                        small = Look.apply(o.transformed(by: .init(translationX: -e.minX, y: -e.minY)), look: look, camera: camera)
                    }
                }
                let h = small.map { Develop.estimateHazeLight($0) } ?? 0.95
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hazeLight = h
                    self.cache.removeAll()
                    NotificationCenter.default.post(name: Self.needsRedraw, object: self)
                }
            }
        }
        return 0.95
    }

    private func scaled(_ image: CIImage, _ scale: CGFloat) -> CIImage {
        let n = normalized(image)
        return scale == 1 ? n : n.transformed(by: .init(scaleX: scale, y: scale))
    }

    /// 출력의 원점이 0이 아닐 때가 있어 맞춰 둔다. 캔버스는 원점 (0,0)을 가정한다.
    private func normalized(_ image: CIImage?) -> CIImage {
        guard let image else { return .empty() }
        let o = image.extent.origin
        return o == .zero ? image : image.transformed(by: .init(translationX: -o.x, y: -o.y))
    }
}
