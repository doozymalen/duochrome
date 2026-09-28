import AppKit

// MARK: - 도구와 속성 (오른쪽)

/// 슬라이더 하나의 정의. 화면 값 = 저장 값 × `display`.
struct SliderSpec {
    let label: String
    let key: WritableKeyPath<DevelopSettings, Float>
    let min: Double, max: Double
    var format = "%+.0f"
    var display: Double = 1
    /// 트랙 색 그라디언트 (왼쪽 → 오른쪽). 색온도·틴트·흑백 채널처럼 값이 색인 슬라이더
    var colors: [NSColor]? = nil
}

/// 고르기 칸 (값은 고른 번호를 Float로 저장).
struct PopupSpec {
    let label: String
    let items: [String]
    let key: WritableKeyPath<DevelopSettings, Float>
}

/// 카드 하나의 정의. 꺼지면 `bypass`가 값을 중립으로 돌린다.
struct CardSpec {
    let id: String
    let title: String
    var rows: [SliderSpec] = []
    var popups: [PopupSpec] = []
    /// 기본은 카드 안 값들을 카메라 기록값으로 되돌리기.
    var bypass: ((inout DevelopSettings, DevelopSettings) -> Void)? = nil
    /// RAW 필터가 지원할 때만 보인다.
    var rawOnly = false
    /// 있으면 카드 스위치가 "끄기"가 아니라 이 기능을 켜고 끈다 (흑백처럼 기본이 꺼진 도구).
    var enableKey: WritableKeyPath<DevelopSettings, Bool>? = nil
    /// 제목 줄에 "자동" 단추 (이 카드만 자동으로)
    var auto = false
    /// 제목 옆에 다 못 쓰는 설명 (풍선 도움말)
    var help: String? = nil
}

/// 도구 순서.
let developCards: [CardSpec] = [
    CardSpec(id: "wb", title: "화이트 밸런스", rows: [
        SliderSpec(label: "색온도", key: \.temperature, min: 2000, max: 12000, format: "%.0f K", colors: TrackColors.temperature),
        SliderSpec(label: "틴트", key: \.tint, min: -150, max: 150, colors: TrackColors.tint),
    ], auto: true),
    CardSpec(id: "base", title: "기본 특성", rows: [
        SliderSpec(label: "톤 커브 (0 선형 · 100 표준)", key: \.filmCurve, min: 0, max: 1, format: "%.0f", display: 100),
    ], popups: [PopupSpec(label: "기본 모습", items: Look.titles, key: \.look)], rawOnly: true),
    CardSpec(id: "exposure", title: "노출", rows: [
        SliderSpec(label: "노출", key: \.exposure, min: -4, max: 4, format: "%+.2f"),
        SliderSpec(label: "대비", key: \.contrast, min: -100, max: 100),
        SliderSpec(label: "밝기", key: \.brightness, min: -100, max: 100),
        SliderSpec(label: "채도", key: \.saturation, min: -100, max: 100, colors: TrackColors.saturation),
    ], auto: true),
    CardSpec(id: "hlrec", title: "하이라이트 복구", rawOnly: true, enableKey: \.highlightRecoveryOn, help: "날아간 채널을 남은 채널로 되살립니다"),
    CardSpec(id: "hdr", title: "하이 다이내믹 레인지", rows: [
        SliderSpec(label: "하이라이트", key: \.highlight, min: 0, max: 100, format: "%.0f"),
        SliderSpec(label: "섀도", key: \.shadow, min: 0, max: 100, format: "%.0f"),
        SliderSpec(label: "화이트", key: \.white, min: -100, max: 100),
        SliderSpec(label: "블랙", key: \.black, min: -100, max: 100),
    ]),
    CardSpec(id: "clarity", title: "클래리티", rows: [
        SliderSpec(label: "클래리티", key: \.clarity, min: -100, max: 100),
        SliderSpec(label: "구조", key: \.structure, min: -100, max: 100),
    ], popups: [PopupSpec(label: "방식", items: ["내추럴", "펀치", "뉴트럴", "클래식"], key: \.clarityMethod)]),
    CardSpec(id: "dehaze", title: "디헤이즈", rows: [
        SliderSpec(label: "양", key: \.dehaze, min: 0, max: 100, format: "%.0f"),
        SliderSpec(label: "안개 색조", key: \.dehazeHue, min: 0, max: 360, format: "%.0f°", colors: TrackColors.hue),
        SliderSpec(label: "안개 색 양", key: \.dehazeTint, min: 0, max: 1, format: "%.0f", display: 100),
    ]),
    CardSpec(id: "levels", title: "레벨", rows: [
        SliderSpec(label: "입력 검정", key: \.levelInBlack, min: 0, max: 0.9, format: "%.0f", display: 255),
        SliderSpec(label: "입력 흰색", key: \.levelInWhite, min: 0.1, max: 1, format: "%.0f", display: 255),
        SliderSpec(label: "중간 (감마)", key: \.levelGamma, min: 0.2, max: 3, format: "%.2f"),
        SliderSpec(label: "출력 검정", key: \.levelOutBlack, min: 0, max: 0.9, format: "%.0f", display: 255),
        SliderSpec(label: "출력 흰색", key: \.levelOutWhite, min: 0.1, max: 1, format: "%.0f", display: 255),
    ], auto: true),
    CardSpec(id: "curve", title: "커브",
             bypass: { s, _ in s.curves = CurveSet() }),
    CardSpec(id: "balance", title: "컬러 밸런스", bypass: { s, _ in
        s.color.master = ColorShift(); s.color.shadow = ColorShift()
        s.color.mid = ColorShift(); s.color.high = ColorShift()
    }),
    CardSpec(id: "editor", title: "컬러 에디터", bypass: { s, _ in s.color.editor = ColorRange.basic }),
    CardSpec(id: "skin", title: "스킨 톤", enableKey: \.color.skin.enabled),
    CardSpec(id: "bw", title: "흑백", rows: [
        SliderSpec(label: "빨강", key: \.color.bw.red, min: -100, max: 100, colors: TrackColors.tone(.systemRed)),
        SliderSpec(label: "노랑", key: \.color.bw.yellow, min: -100, max: 100, colors: TrackColors.tone(.systemYellow)),
        SliderSpec(label: "초록", key: \.color.bw.green, min: -100, max: 100, colors: TrackColors.tone(.systemGreen)),
        SliderSpec(label: "청록", key: \.color.bw.cyan, min: -100, max: 100, colors: TrackColors.tone(.systemTeal)),
        SliderSpec(label: "파랑", key: \.color.bw.blue, min: -100, max: 100, colors: TrackColors.tone(.systemBlue)),
        SliderSpec(label: "자홍", key: \.color.bw.magenta, min: -100, max: 100, colors: TrackColors.tone(.systemPink)),
        SliderSpec(label: "섀도 색조", key: \.color.bw.shadowTone.hue, min: 0, max: 360, format: "%.0f°", colors: TrackColors.hue),
        SliderSpec(label: "섀도 양", key: \.color.bw.shadowTone.amount, min: 0, max: 1, format: "%.0f", display: 100),
        SliderSpec(label: "하이라이트 색조", key: \.color.bw.highlightTone.hue, min: 0, max: 360, format: "%.0f°", colors: TrackColors.hue),
        SliderSpec(label: "하이라이트 양", key: \.color.bw.highlightTone.amount, min: 0, max: 1, format: "%.0f", display: 100),
    ], enableKey: \.color.bw.enabled),
    CardSpec(id: "sharpen", title: "캡처 샤프닝", rows: [
        SliderSpec(label: "양", key: \.sharpness, min: 0, max: 2, format: "%.0f", display: 100),
        SliderSpec(label: "디테일", key: \.detail, min: 0, max: 1, format: "%.0f", display: 100),
    ], rawOnly: true),
    CardSpec(id: "usm", title: "샤프닝", rows: [
        SliderSpec(label: "양", key: \.sharpenAmount, min: 0, max: 300, format: "%.0f"),
        SliderSpec(label: "반경 (원본 px)", key: \.sharpenRadius, min: 0.3, max: 3, format: "%.1f"),
        SliderSpec(label: "임계값", key: \.sharpenThreshold, min: 0, max: 10, format: "%.1f"),
        SliderSpec(label: "헤일로 억제", key: \.sharpenHalo, min: 0, max: 100, format: "%.0f"),
    ]),
    CardSpec(id: "noise", title: "노이즈 제거", rows: [
        SliderSpec(label: "밝기", key: \.lumaNoise, min: 0, max: 1, format: "%.0f", display: 100),
        SliderSpec(label: "색", key: \.colorNoise, min: 0, max: 1, format: "%.0f", display: 100),
        SliderSpec(label: "모아레", key: \.moire, min: 0, max: 1, format: "%.0f", display: 100),
        SliderSpec(label: "단일 픽셀", key: \.hotPixels, min: 0, max: 100, format: "%.0f"),
    ], rawOnly: true),
    CardSpec(id: "lens", title: "렌즈 보정", rows: [
        SliderSpec(label: "왜곡", key: \.lensDistortion, min: -100, max: 100),
        SliderSpec(label: "색수차 빨강/청록", key: \.lensCA, min: -100, max: 100),
        SliderSpec(label: "색수차 파랑/노랑", key: \.lensCABlue, min: -100, max: 100),
        SliderSpec(label: "주변부 광량", key: \.lensVignette, min: 0, max: 100, format: "%.0f"),
        SliderSpec(label: "주변부 선명도", key: \.lensSharpFalloff, min: 0, max: 100, format: "%.0f"),
    ], popups: [PopupSpec(label: "렌즈 프로필 (RAW)", items: ["끔", "자동"], key: \.lensCorrection)],
             bypass: { s, _ in
                 s.lensCorrection = 0; s.lensDistortion = 0; s.lensCA = 0; s.lensCABlue = 0
                 s.lensVignette = 0; s.lensSharpFalloff = 0
             }),
    CardSpec(id: "grain", title: "필름 그레인", rows: [
        SliderSpec(label: "세기", key: \.grainAmount, min: 0, max: 100, format: "%.0f"),
        SliderSpec(label: "알갱이 크기", key: \.grainSize, min: 0, max: 100, format: "%.0f"),
    ], popups: [PopupSpec(label: "종류", items: ["미세", "은염", "부드럽게", "색 입자"], key: \.grainType)]),
    CardSpec(id: "vignette", title: "비네팅", rows: [
        SliderSpec(label: "양", key: \.vignette, min: -100, max: 100),
    ]),
]

/// 보정 항목을 카드로 쌓는다. 카드마다 켜고 끄기와 초기화가 있다.
final class InspectorViewController: NSViewController {
    /// (새 값, 슬라이더를 끄는 중인지)
    var onChange: ((DevelopSettings, Bool) -> Void)?
    let histogram = HistogramView()
    private let meter = NSTextField(labelWithString: " ")

    private let stack = FlippedStackView()
    private var doc: RawDocument?
    var settings = DevelopSettings()
    private var bypassed: Set<String> = []
    private var rows: [(SliderSpec, SliderRow)] = []
    private var cards: [(CardSpec, Card)] = []
    let curveEditor = CurveEditorView()
    /// 캔버스에서 색을 집어 달라 (0 컬러 에디터 범위 더하기, 1 스킨 톤 고르기).
    var onPickColor: ((Int) -> Void)?
    var onAutoWB: (() -> Void)?
    /// 카드 "자동" 단추 (노출·레벨)
    var onAutoCard: ((String) -> Void)?
    /// 레벨 스포이트 (2 검정 점, 3 흰 점, 4 회색 점)
    var onLevelPick: ((Int) -> Void)?
    fileprivate var popups: [(PopupSpec, NSPopUpButton)] = []
    /// "기본 모습" 줄: 그 카메라의 보정표가 있을 때만 보인다 (없으면 Apple 기본)
    private var lookRows: [NSView] = []
    fileprivate var popupTargets: [PopupTarget] = []
    fileprivate var buttonTargets: [ClosureTarget] = []
    /// -1 RGB(전체 레벨), 0~2 빨강·초록·파랑
    fileprivate var levelChannel = -1
    fileprivate let levelsView = LevelsView()
    fileprivate var levelMasterRows: [SliderRow] = []
    fileprivate var channelRows: [SliderRow] = []
    fileprivate let channelPopup = NSPopUpButton()
    fileprivate var basePopup: NSPopUpButton?
    fileprivate var editorIndex = 0
    fileprivate let editorPopup = NSPopUpButton()
    fileprivate var editorRows: [SliderRow] = []
    fileprivate let editorRemove = NSButton(title: "이 범위 지우기", target: nil, action: nil)
    fileprivate var skinRows: [SliderRow] = []
    fileprivate let skinSwatch = NSView()
    /// 컬러 에디터 (기본·고급·스킨 톤, ColorEditor.swift)
    let colorEditor = ColorEditorView()
    /// 선택한 색 범위 보기 (캔버스)
    var onViewRange: ((ColorRange?) -> Void)?
    /// UI 시험용: 컬러 밸런스 휠 (0 마스터, 1 섀도, 2 미드톤, 3 하이라이트)
    func wheel(_ i: Int) -> ColorWheelView? { wheels.indices.contains(i) ? wheels[i].1 : nil }
    fileprivate var wheels: [(WritableKeyPath<DevelopSettings, ColorShift>, ColorWheelView)] = []
    /// 커브 채널 고르기 (팝업)
    private let curveChannel = CurveChannelPopup()

    // 위: 레이어 고르기·더하기 / 아래: 전체 강도·초기화·⋯
    /// (레이어 id, 이름) 목록. nil id = 배경
    var layerList: (() -> [(String?, String)])?
    var currentLayer: (() -> String?)?
    var onPickLayer: ((String?) -> Void)?
    var addLayerMenu: (() -> NSMenu)?
    var moreMenu: (() -> NSMenu)?
    var onResetAll: (() -> Void)?
    private let layerPopup = NSPopUpButton()
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "조정 레이어 더하기")!,
                                     target: nil, action: nil)
    private let intensityRow = SliderRow(label: "강도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)

    override func loadView() {
        let root = NSView()
        let content = buildScroll()
        // 위: 레이어
        layerPopup.controlSize = .regular
        layerPopup.target = self
        layerPopup.action = #selector(layerPicked)
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.toolTip = "조정 레이어 더하기"
        let top = NSStackView(views: [layerPopup, addButton])
        top.spacing = 8
        let topBox = Card.plain(top)
        // 아래: 강도·초기화·⋯
        intensityRow.onChange = { [weak self] v, d in
            guard let self else { return }
            self.settings.intensity = Float(v)
            self.onChange?(self.effective(), d)
        }
        let resetAll = NSButton(title: "초기화", target: self, action: #selector(resetAllTapped))
        resetAll.bezelStyle = .appPush
        resetAll.controlSize = .large
        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "더 보기")!, target: self, action: #selector(moreTapped(_:)))
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        let buttons = NSStackView(views: [resetAll, more])
        buttons.spacing = 8
        resetAll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.widthAnchor.constraint(equalToConstant: 26).isActive = true
        resetAll.widthAnchor.constraint(equalTo: buttons.widthAnchor, constant: -34).isActive = true
        let bottom = NSStackView(views: [intensityRow, buttons])
        bottom.orientation = .vertical
        bottom.spacing = 12
        bottom.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        let line = NSBox(); line.boxType = .separator
        for v in [topBox, content, line, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBox.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            topBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            topBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topBox.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            line.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            intensityRow.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -28),
            layerPopup.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -32),
        ])
        view = root
        // 사진이 패널보다 먼저 열렸으면(탭을 늦게 연 경우) 그 사진으로 바로 채우고 켠다.
        // 예전엔 늘 끈 채로 시작해, 유리 배치로 바꾼 뒤 조정 슬라이더가 안 눌렸다.
        if let doc { show(doc) } else { setEnabled(false); refreshLayers() }
    }

    /// 레이어 팝업을 지금 사진의 레이어로 채운다
    func refreshLayers() {
        guard isViewLoaded else { return }
        layerPopup.removeAllItems()
        let list = layerList?() ?? [(nil, "배경 (RAW 현상)")]
        for (id, name) in list {
            layerPopup.addItem(withTitle: name)
            layerPopup.lastItem?.representedObject = id
            layerPopup.lastItem?.image = NSImage(systemSymbolName: id == nil ? "camera.aperture" : "square.3.layers.3d",
                                                 accessibilityDescription: nil)
        }
        let cur = currentLayer?()
        layerPopup.selectItem(at: list.firstIndex { $0.0 == cur } ?? 0)
        intensityRow.value = Double(settings.intensity)
    }

    @objc private func layerPicked() { onPickLayer?(layerPopup.selectedItem?.representedObject as? String) }
    @objc private func addTapped() {
        addLayerMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }
    @objc private func moreTapped(_ sender: NSButton) {
        moreMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc private func resetAllTapped() { onResetAll?() }

    private func buildScroll() -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 빈 NSView를 documentView로 두면 높이가 0이 된다. 스택을 바로 넣는다.
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        histogram.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(histogram)
        histogram.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        meter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        meter.textColor = .secondaryLabelColor
        stack.addArrangedSubview(meter)
        stack.setCustomSpacing(4, after: histogram)

        developCards.filter { $0.id != "skin" }.forEach(addCard)
        return scroll
    }

    /// 형태 탭이 바꾼 값을 받아 둔다. 안 그러면 다음 슬라이더 조작이 옛 형태 값으로 덮어쓴다.
    func adoptGeometry(_ s: DevelopSettings) { settings.adoptGeometry(from: s) }

    func showSample(_ rgb: [Int]?) {
        guard let c = rgb else { meter.stringValue = " "; return }
        let lab = Self.lab(c)
        meter.stringValue = String(format: "R %3d  G %3d  B %3d   ·   L %3.0f  a %+4.0f  b %+4.0f", c[0], c[1], c[2], lab.0, lab.1, lab.2)
    }

    /// 화면(Display P3) 8비트 값 → CIE Lab (D65).
    static func lab(_ c: [Int]) -> (Double, Double, Double) {
        func lin(_ v: Int) -> Double { let x = Double(v) / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c[0]), g = lin(c[1]), b = lin(c[2])
        // Display P3 → XYZ (D65)
        let X = 0.4866 * r + 0.2657 * g + 0.1982 * b
        let Y = 0.2290 * r + 0.6917 * g + 0.0793 * b
        let Z = 0.0000 * r + 0.0451 * g + 1.0439 * b
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(X / 0.95047), fy = f(Y), fz = f(Z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    func show(_ doc: RawDocument) {
        self.doc = doc
        settings = doc.settings
        bypassed = []
        // 두 번 누르기·달라붙기의 기준은 카메라 기록값 (색온도·샤프닝처럼 0이 아닌 값도 있다).
        for (spec, row) in rows { row.defaultValue = Double(doc.asShot[keyPath: spec.key]) }
        for (spec, card) in cards {
            card.isHidden = spec.rawOnly && !doc.isRaw
            card.isOn = spec.enableKey.map { settings[keyPath: $0] } ?? true
        }
        let hasLook = doc.isRaw && Look.available(for: doc.info.camera)
        lookRows.forEach { $0.isHidden = !hasLook }
        sync()
        setEnabled(true)
        refreshLayers()
    }

    private func setEnabled(_ on: Bool) {
        rows.forEach { $0.1.slider.isEnabled = on }
    }

    private func sync() {
        for (spec, row) in rows { row.value = Double(settings[keyPath: spec.key]) }
        curveEditor.curves = settings.curves
        syncEditor()
        for (p, popup) in popups { popup.selectItem(at: Int(settings[keyPath: p.key])) }
        syncChannelLevels()
        for (key, wheel) in wheels { wheel.shift = settings[keyPath: key] }
    }

    /// 꺼진 카드는 중립값으로 대신한다.
    private func effective() -> DevelopSettings {
        guard let doc else { return settings }
        var s = settings
        for (spec, _) in cards where bypassed.contains(spec.id) && spec.enableKey == nil {
            if let bypass = spec.bypass {
                bypass(&s, doc.asShot)
            } else {
                for r in spec.rows { s[keyPath: r.key] = doc.asShot[keyPath: r.key] }
            }
        }
        return s
    }

    private func addCard(_ spec: CardSpec) {
        let card = Card(title: spec.title)
        if let help = spec.help { card.titleLabel?.toolTip = help }
        if spec.auto {
            let b = CardAutoButton(title: "자동") { [weak self] in
                if spec.id == "wb" { self?.onAutoWB?() } else { self?.onAutoCard?(spec.id) }
            }
            b.toolTip = "이 카드만 자동으로 맞춥니다"
            card.accessory.addArrangedSubview(b)
        }
        card.onToggle = { [weak self] on in
            guard let self else { return }
            if let key = spec.enableKey {
                self.settings[keyPath: key] = on
            } else if on { self.bypassed.remove(spec.id) } else { self.bypassed.insert(spec.id) }
            self.onChange?(self.effective(), false)
        }
        card.onReset = { [weak self] in
            guard let self, let doc = self.doc else { return }
            for r in spec.rows { self.settings[keyPath: r.key] = doc.asShot[keyPath: r.key] }
            if spec.id == "lens" { self.settings.lensCorrection = doc.asShot.lensCorrection }
            if spec.id == "curve" { self.settings.curves = CurveSet() }
            if spec.id == "editor" {
                self.settings.color.editor = ColorRange.basic; self.editorIndex = 0
                let on = self.settings.color.skin.enabled; self.settings.color.skin = SkinTone(); self.settings.color.skin.enabled = on
            }
            if spec.id == "skin" { let on = self.settings.color.skin.enabled; self.settings.color.skin = SkinTone(); self.settings.color.skin.enabled = on }
            if spec.id == "balance" {
                self.settings.color.master = ColorShift(); self.settings.color.shadow = ColorShift()
                self.settings.color.mid = ColorShift(); self.settings.color.high = ColorShift()
            }
            self.sync()
            self.onChange?(self.effective(), false)
        }
        for r in spec.rows {
            let row = SliderRow(label: r.label, min: r.min, max: r.max, format: r.format, display: r.display)
            row.slider.trackColors = r.colors
            row.onChange = { [weak self] v, dragging in
                guard let self else { return }
                self.settings[keyPath: r.key] = Float(v)
                self.onChange?(self.effective(), dragging)
            }
            rows.append((r, row))
            card.body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        }
        for p in spec.popups {
            let popup = NSPopUpButton()
            popup.controlSize = .small
            popup.addItems(withTitles: p.items)
            let target = PopupTarget { [weak self] i in
                guard let self else { return }
                self.settings[keyPath: p.key] = Float(i)
                self.onChange?(self.effective(), false)
            }
            popup.target = target
            popup.action = #selector(PopupTarget.fire(_:))
            popupTargets.append(target)
            popups.append((p, popup))
            let row = NSStackView(views: [small(p.label), popup])
            card.body.addArrangedSubview(row)
            if p.key == \DevelopSettings.look { lookRows.append(row) }
        }
        if spec.id == "levels" { buildChannelLevels(in: card) }
        if spec.id == "curve" { buildCurve(in: card) }
        if spec.id == "balance" { buildBalance(in: card) }
        if spec.id == "editor" { buildEditor(in: card) }
        if spec.id == "wb" { buildWBPresets(in: card) }
        if spec.id == "base" { buildBasePresets(in: card) }
        if spec.id == "skin" { buildSkin(in: card) }
        card.applyCollapse()
        cards.append((spec, card))
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }
}

extension InspectorViewController {
    fileprivate func buildCurve(in card: Card) {
        curveChannel.addItems(withTitles: CurveSet.channels.map(\.0))
        curveChannel.selectItem(at: 0)
        curveChannel.controlSize = .regular
        curveChannel.target = self
        curveChannel.action = #selector(curveChannelChanged)
        // 스포이트 셋: 누른 곳을 검정 / 무채색 / 흰색으로 (커브 점을 만든다)
        let picks = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "검정 점")!,
            NSImage(systemSymbolName: "eyedropper.halffull", accessibilityDescription: "회색 점")!,
            NSImage(systemSymbolName: "eyedropper.full", accessibilityDescription: "흰 점")!,
        ], trackingMode: .momentary, target: self, action: #selector(curvePickSegment(_:)))
        picks.setToolTip("검정 점: 누른 곳을 검정으로", forSegment: 0)
        picks.setToolTip("회색 점: 누른 곳을 무채색으로", forSegment: 1)
        picks.setToolTip("흰 점: 누른 곳을 흰색으로", forSegment: 2)
        let head = NSStackView(views: [curveChannel, picks])
        head.spacing = 8
        curveEditor.onChange = { [weak self] curves, dragging in
            guard let self else { return }
            self.settings.curves = curves
            self.onChange?(self.effective(), dragging)
        }
        for v in [head, curveEditor] as [NSView] {
            card.body.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        }
        curveEditor.heightAnchor.constraint(equalTo: curveEditor.widthAnchor).isActive = true
    }

    /// 3방향 색상: 하이라이트·미드톤·섀도 휠을 세로로. 휠 옆 호는 세기(왼쪽)와 밝기(오른쪽),
    /// 휠마다 오른쪽 위에 되돌리기. 위 고르기 칸에서 "마스터"를 고르면 전체 휠 하나만.
    fileprivate func buildBalance(in card: Card) {
        // 순서는 설정 번호와 맞춘다 (0 마스터, 1 섀도, 2 미드톤, 3 하이라이트)
        let zones: [(String, WritableKeyPath<DevelopSettings, ColorShift>)] = [
            ("마스터", \.color.master), ("섀도", \.color.shadow), ("미드톤", \.color.mid), ("하이라이트", \.color.high),
        ]
        var cells: [NSView] = []
        for (name, key) in zones {
            let wheel = ColorWheelView()
            wheel.onChange = { [weak self] shift, dragging in
                guard let self else { return }
                self.settings[keyPath: key] = shift
                self.onChange?(self.effective(), dragging)
            }
            wheels.append((key, wheel))
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "\(name) 되돌리기")!,
                                 target: nil, action: nil)
            reset.isBordered = false
            reset.contentTintColor = .tertiaryLabelColor
            reset.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            reset.toolTip = "\(name) 되돌리기"
            let target = ClosureTarget { [weak self, weak wheel] in
                guard let self else { return }
                self.settings[keyPath: key] = ColorShift()
                wheel?.shift = ColorShift()
                self.onChange?(self.effective(), false)
            }
            buttonTargets.append(target)
            reset.target = target
            reset.action = #selector(ClosureTarget.fire)
            let cell = NSView()
            for v in [wheel, label, reset] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            NSLayoutConstraint.activate([
                wheel.topAnchor.constraint(equalTo: cell.topAnchor),
                wheel.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                wheel.widthAnchor.constraint(equalToConstant: 176),
                wheel.heightAnchor.constraint(equalToConstant: 128),
                label.topAnchor.constraint(equalTo: wheel.bottomAnchor, constant: 4),
                label.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                reset.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
                reset.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
            cells.append(cell)
        }
        let mode = NSPopUpButton()
        mode.controlSize = .small
        mode.addItems(withTitles: ["3방향 색상", "마스터"])
        let modeTarget = PopupTarget { i in
            UserDefaults.standard.set(i, forKey: "balanceMode")
            cells[0].isHidden = i == 0
            for c in cells[1...] { c.isHidden = i == 1 }
        }
        popupTargets.append(modeTarget)
        mode.target = modeTarget
        mode.action = #selector(PopupTarget.fire(_:))
        let saved = UserDefaults.standard.integer(forKey: "balanceMode")
        mode.selectItem(at: saved)
        card.body.addArrangedSubview(mode)
        mode.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        // 보이는 순서: 마스터(마스터 모드), 하이라이트, 미드톤, 섀도
        for i in [0, 3, 2, 1] {
            card.body.addArrangedSubview(cells[i])
            cells[i].widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        }
        cells[0].isHidden = saved == 0
        for c in cells[1...] { c.isHidden = saved == 1 }
    }

    /// 개발용: 카드가 보이게 속성 패널을 굴린다.
    func reveal(_ id: String) {
        guard let card = cards.first(where: { $0.0.id == id })?.1 else { return }
        view.layoutSubtreeIfNeeded()
        card.scrollToVisible(card.bounds)
    }

    func selectCurveChannel(_ index: Int) {
        curveChannel.selectItem(at: index)
        curveChannelChanged()
    }

    @objc fileprivate func curveChannelChanged() {
        let (_, key, color) = CurveSet.channels[max(curveChannel.indexOfSelectedItem, 0)]
        curveEditor.channelColor = color
        curveEditor.channel = key
    }
}

// MARK: - 컬러 에디터·스킨 톤

extension InspectorViewController {
    fileprivate func buildEditor(in card: Card) {
        colorEditor.onChange = { [weak self] st, dragging in
            guard let self else { return }
            self.settings.color.editor = st.color.editor
            self.settings.color.skin = st.color.skin
            self.onChange?(self.effective(), dragging)
        }
        colorEditor.onPick = { [weak self] purpose in self?.onPickColor?(purpose) }
        colorEditor.onViewRange = { [weak self] r in self?.onViewRange?(r) }
        card.body.addArrangedSubview(colorEditor)
        colorEditor.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
    }

    fileprivate func syncEditor() {
        guard isViewLoaded else { return }
        colorEditor.sync(settings, doc: doc)
    }

    private func swatch(_ hue: Float) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            NSColor(hue: CGFloat(hue / 360), saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc fileprivate func editorPicked() { editorIndex = editorPopup.indexOfSelectedItem; syncEditor() }
    @objc fileprivate func editorPickTapped() { onPickColor?(0) }
    @objc fileprivate func editorRemoveTapped() {
        guard editorIndex >= ColorRange.basic.count, settings.color.editor.indices.contains(editorIndex) else { return }
        settings.color.editor.remove(at: editorIndex)
        editorIndex -= 1
        onChange?(effective(), false)
        syncEditor()
    }

    fileprivate func buildSkin(in card: Card) {
        skinSwatch.wantsLayer = true
        skinSwatch.layer?.cornerRadius = 4
        skinSwatch.widthAnchor.constraint(equalToConstant: 28).isActive = true
        skinSwatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let pick = NSButton(title: "피부색 집기", image: NSImage(systemSymbolName: "eyedropper.halffull", accessibilityDescription: nil)!,
                            target: self, action: #selector(skinPickTapped))
        pick.bezelStyle = .appPush
        pick.controlSize = .small
        let top = NSStackView(views: [skinSwatch, pick])
        card.body.addArrangedSubview(top)
        let rows: [(String, Double, Double, WritableKeyPath<SkinTone, Float>)] = [
            ("색조 균일", 0, 100, \.hueAmount), ("채도 균일", 0, 100, \.satAmount), ("밝기 균일", 0, 100, \.lightAmount),
            ("범위 넓이", 10, 90, \.width),
        ]
        skinRows = rows.map { (label, lo, hi, key) in
            let r = SliderRow(label: label, min: lo, max: hi, format: "%.0f")
            r.onChange = { [weak self] v, d in
                guard let self else { return }
                self.settings.color.skin[keyPath: key] = Float(v)
                self.onChange?(self.effective(), d)
            }
            card.body.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
            return r
        }
    }

    @objc fileprivate func skinPickTapped() { onPickColor?(1) }

    // MARK: 채널별 레벨·스포이트

    fileprivate func buildChannelLevels(in card: Card) {
        // 한 줄: 채널 팝업 · 스포이트 셋 · ⋯ (숫자로 입력 펼치기)
        channelPopup.controlSize = .regular
        channelPopup.addItems(withTitles: ["RGB", "빨강", "초록", "파랑"])
        channelPopup.target = self
        channelPopup.action = #selector(channelPicked)
        let picks = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "검정 점")!,
            NSImage(systemSymbolName: "eyedropper.halffull", accessibilityDescription: "회색 점")!,
            NSImage(systemSymbolName: "eyedropper.full", accessibilityDescription: "흰 점")!,
        ], trackingMode: .momentary, target: self, action: #selector(levelPickSegment(_:)))
        picks.setToolTip("검정 점: 누른 곳을 검정으로", forSegment: 0)
        picks.setToolTip("회색 점: 누른 곳을 무채색으로 (화이트 밸런스)", forSegment: 1)
        picks.setToolTip("흰 점: 누른 곳을 흰색으로", forSegment: 2)
        let numbers = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "숫자로 입력")!,
                               target: self, action: #selector(toggleLevelNumbers))
        numbers.isBordered = false
        numbers.contentTintColor = .secondaryLabelColor
        numbers.toolTip = "숫자로 입력"
        let head = NSStackView(views: [channelPopup, picks, numbers])
        head.spacing = 8
        card.body.insertArrangedSubview(head, at: 0)
        head.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        levelsView.onChange = { [weak self] v, dragging in
            guard let self else { return }
            if self.levelChannel < 0 {
                self.settings.levelInBlack = v[0]; self.settings.levelInWhite = v[1]; self.settings.levelGamma = v[2]
                self.settings.levelOutBlack = v[3]; self.settings.levelOutWhite = v[4]
            } else {
                self.settings.levelsRGB[self.levelChannel] = v
            }
            self.onChange?(self.effective(), dragging)
            if !dragging { self.sync() }
        }
        histogram.mirror = levelsView
        card.body.insertArrangedSubview(levelsView, at: 1)
        levelsView.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        // 채널별 숫자 줄 (⋯로 펼친다)
        let labels = ["입력 검정", "입력 흰색", "중간 (감마)", "출력 검정", "출력 흰색"]
        let ranges: [(Double, Double, String, Double)] = [(0, 0.9, "%.0f", 255), (0.1, 1, "%.0f", 255), (0.2, 3, "%.2f", 1),
                                                          (0, 0.9, "%.0f", 255), (0.1, 1, "%.0f", 255)]
        channelRows = zip(labels, ranges).enumerated().map { (j, pair) in
            let (label, r) = pair
            let row = SliderRow(label: label, min: r.0, max: r.1, format: r.2, display: r.3, defaultValue: [0, 1, 1, 0, 1][j])
            row.onChange = { [weak self] v, d in
                guard let self, self.levelChannel >= 0 else { return }
                self.settings.levelsRGB[self.levelChannel][j] = Float(v)
                self.onChange?(self.effective(), d)
            }
            return row
        }
        for r in channelRows {
            card.body.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: card.body.widthAnchor).isActive = true
        }
        levelMasterRows = rows.filter { spec, _ in
            [\DevelopSettings.levelInBlack, \.levelInWhite, \.levelGamma, \.levelOutBlack, \.levelOutWhite].contains(spec.key)
        }.map(\.1)
        applyLevelNumbers()
    }

    fileprivate func syncChannelLevels() {
        guard isViewLoaded else { return }
        channelPopup.selectItem(at: levelChannel + 1)
        if levelChannel >= 0, settings.levelsRGB.indices.contains(levelChannel) {
            for (row, v) in zip(channelRows, settings.levelsRGB[levelChannel]) { row.value = Double(v) }
            levelsView.values = settings.levelsRGB[levelChannel]
        } else {
            levelsView.values = [settings.levelInBlack, settings.levelInWhite, settings.levelGamma, settings.levelOutBlack, settings.levelOutWhite]
        }
        levelsView.channel = levelChannel + 1
        applyLevelNumbers()
    }

    /// 숫자 줄: RGB면 전체 레벨 줄, 채널이면 그 채널 줄. ⋯를 눌러야 보인다.
    fileprivate func applyLevelNumbers() {
        let show = UserDefaults.standard.bool(forKey: "levels.numbers")
        levelMasterRows.forEach { $0.isHidden = !show || levelChannel >= 0 }
        channelRows.forEach { $0.isHidden = !show || levelChannel < 0 }
    }

    @objc fileprivate func toggleLevelNumbers() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "levels.numbers"), forKey: "levels.numbers")
        applyLevelNumbers()
    }

    @objc fileprivate func channelPicked() { levelChannel = channelPopup.indexOfSelectedItem - 1; syncChannelLevels() }
    @objc fileprivate func curvePickSegment(_ s: NSSegmentedControl) { onLevelPick?([30, 31, 32][s.selectedSegment]) }

    /// 커브 스포이트로 집은 색 (화면 값 0~1): 30 검정 점, 31 회색 점, 32 흰 점
    func pickedCurve(_ purpose: Int, rgb c: SIMD3<Float>) {
        var cv = settings.curves
        func setEnd(_ curve: inout ToneCurve, x: CGFloat, y: CGFloat) {
            var p = curve.points
            if y == 0 { p[0] = CGPoint(x: min(x, (p.count > 1 ? p[1].x : 1) - 0.01), y: 0) }
            else { p[p.count - 1] = CGPoint(x: max(x, (p.count > 1 ? p[p.count - 2].x : 0) + 0.01), y: 1) }
            curve.points = p
        }
        func addPoint(_ curve: inout ToneCurve, x: CGFloat, y: CGFloat) {
            var p = curve.points.filter { abs($0.x - x) > 0.02 || $0.x == 0 || $0.x == 1 }
            guard x > 0.02, x < 0.98, p.count < ToneCurve.maxPoints else { return }
            p.append(CGPoint(x: x, y: y))
            curve.points = p.sorted { $0.x < $1.x }
        }
        switch purpose {
        case 30: setEnd(&cv.rgb, x: CGFloat(max(c.x, c.y, c.z)), y: 0)
        case 32: setEnd(&cv.rgb, x: CGFloat(min(c.x, c.y, c.z)), y: 1)
        default:
            let m = CGFloat((c.x + c.y + c.z) / 3)
            addPoint(&cv.red, x: CGFloat(c.x), y: m)
            addPoint(&cv.green, x: CGFloat(c.y), y: m)
            addPoint(&cv.blue, x: CGFloat(c.z), y: m)
        }
        settings.curves = cv
        sync()
        onChange?(effective(), false)
    }

    @objc fileprivate func levelPickSegment(_ s: NSSegmentedControl) { onLevelPick?([2, 4, 3][s.selectedSegment]) }
    @objc fileprivate func levelPickTapped(_ b: NSButton) { onLevelPick?(b.tag) }

    /// 레벨 스포이트로 집은 값 (화면 값 0~1): 검정 점이면 입력 검정, 흰 점이면 입력 흰색.
    func pickedLevel(_ purpose: Int, value: Float) {
        if purpose == 2 { settings.levelInBlack = min(max(value, 0), settings.levelInWhite - 0.05) }
        if purpose == 3 { settings.levelInWhite = max(min(value, 1), settings.levelInBlack + 0.05) }
        sync()
        onChange?(effective(), false)
    }

    // MARK: 화이트 밸런스·기본 커브 프리셋

    static let wbPresets: [(String, Float?, Float?)] = [
        ("촬영", nil, nil), ("자동", nil, nil), ("주광", 5500, 10), ("흐림", 6500, 10), ("그늘", 7500, 10),
        ("텅스텐", 2850, 0), ("형광등", 3800, 21), ("플래시", 5500, 0),
    ]

    fileprivate func buildWBPresets(in card: Card) {
        let popup = NSPopUpButton()
        popup.controlSize = .small
        for (name, _, _) in Self.wbPresets { popup.addItem(withTitle: name) }
        popup.target = self
        popup.action = #selector(wbPresetPicked(_:))
        let row = NSStackView(views: [small("프리셋"), popup])
        card.body.insertArrangedSubview(row, at: 0)
    }

    @objc fileprivate func wbPresetPicked(_ p: NSPopUpButton) {
        guard let doc else { return }
        let (_, t, tint) = Self.wbPresets[p.indexOfSelectedItem]
        switch p.indexOfSelectedItem {
        case 0: settings.temperature = doc.asShot.temperature; settings.tint = doc.asShot.tint
        case 1: onAutoWB?(); return
        default: settings.temperature = t ?? 5500; settings.tint = tint ?? 0
        }
        sync()
        onChange?(effective(), false)
    }

    static let basePresets: [(String, Float, Float)] = [("선형", 0, 0), ("부드럽게", 0.6, -12), ("표준", 1, 0), ("높은 대비", 1, 25)]

    fileprivate func buildBasePresets(in card: Card) {
        let popup = NSPopUpButton()
        popup.controlSize = .small
        for (name, _, _) in Self.basePresets { popup.addItem(withTitle: name) }
        popup.selectItem(at: 2)
        popup.target = self
        popup.action = #selector(basePresetPicked(_:))
        basePopup = popup
        card.body.insertArrangedSubview(NSStackView(views: [small("커브"), popup]), at: 0)
    }

    @objc fileprivate func basePresetPicked(_ p: NSPopUpButton) {
        let (_, boost, contrast) = Self.basePresets[p.indexOfSelectedItem]
        settings.filmCurve = boost
        settings.filmContrast = contrast
        sync()
        onChange?(effective(), false)
    }

    fileprivate func small(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }

    /// 캔버스에서 집은 색 (화면 값 HSV). 0이면 컬러 에디터 범위를 더하고, 1이면 스킨 톤 기준색으로.
    func pickedColor(hue: Float, sat: Float, value: Float, purpose: Int) {
        if purpose == 0 {
            guard settings.color.editor.count < ColorRange.basic.count + 35 else { NSSound.beep(); return }
            let n = settings.color.editor.count - ColorRange.basic.count + 1
            settings.color.editor.append(ColorRange(name: "고른 색 \(n)", hue: hue, width: 30))
            editorIndex = settings.color.editor.count - 1
            reveal("editor")
            colorEditor.sync(settings, doc: doc)
            colorEditor.select(editorIndex)
        } else {
            settings.color.skin.hue = hue
            settings.color.skin.sat = sat
            settings.color.skin.light = value
            settings.color.skin.enabled = true
            if settings.color.skin.hueAmount == 0 && settings.color.skin.satAmount == 0 && settings.color.skin.lightAmount == 0 {
                settings.color.skin.hueAmount = 50; settings.color.skin.satAmount = 30; settings.color.skin.lightAmount = 20
            }
            reveal("editor")
            colorEditor.showTab(2)
        }
        onChange?(effective(), false)
        if let doc { show(doc) }
    }
}

/// 고르기 칸의 동작을 닫힘으로 받는다.
/// 커브 채널 팝업
final class CurveChannelPopup: NSPopUpButton {}

final class PopupTarget: NSObject {
    let action: (Int) -> Void
    init(_ action: @escaping (Int) -> Void) { self.action = action }
    @objc func fire(_ sender: NSPopUpButton) { action(sender.indexOfSelectedItem) }
}

class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 카드 제목 줄의 작은 "자동" 단추
final class CardAutoButton: NSButton {
    private var run: () -> Void = {}
    convenience init(title: String, run: @escaping () -> Void) {
        self.init(frame: .zero)
        self.run = run
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 10, weight: .semibold)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }
    @objc private func fire() { run() }
}

final class Card: NSView {
    let body = NSStackView()
    var onToggle: ((Bool) -> Void)?
    var onReset: (() -> Void)?
    /// 켜고 끄기 스위치 (오른쪽 위 파란 스위치)
    private let toggle = NSSwitch()
    /// 제목 줄 오른쪽에 붙이는 단추 (자동·⋯ 등)
    let accessory = NSStackView()
    private let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "초기화")!,
                                 target: nil, action: nil)

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor

        toggle.state = .on
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .bold)
        name.toolTip = "제목을 누르면 접고 펼칩니다"
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel = name
        reset.target = self
        reset.action = #selector(resetTapped)
        reset.isBordered = false
        reset.contentTintColor = .tertiaryLabelColor
        reset.toolTip = "초기화"
        reset.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        accessory.spacing = 6
        collapseKey = "collapsed." + title
        let header = NSStackView(views: [name, NSView(), reset, accessory, toggle])
        header.spacing = 8
        header.alignment = .centerY

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10

        let v = NSStackView(views: [header, body])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: v.widthAnchor),
            body.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off; body.alphaValue = newValue ? 1 : 0.4 }
    }

    @objc private func toggled() {
        body.alphaValue = toggle.state == .on ? 1 : 0.4
        onToggle?(toggle.state == .on)
    }

    @objc private func resetTapped() { onReset?() }

    private(set) var titleLabel: NSTextField?
    private var collapseKey = ""

    /// 제목을 누르면 접는다. 접은 상태는 다음 실행에도 남는다.
    var collapsed: Bool {
        get { UserDefaults.standard.bool(forKey: collapseKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: collapseKey)
            applyCollapse()
        }
    }

    func applyCollapse() {
        let empty = body.arrangedSubviews.isEmpty
        body.isHidden = empty || collapsed
        titleLabel?.textColor = collapsed ? .secondaryLabelColor : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        // 끌기가 끝난 뒤 늦게 한 번 더 오는 누름(단추가 이미 떼어짐)은 무시한다.
        // 슬라이더를 끈 뒤 그 누름이 카드로 넘어와 카드가 접혔다 (실제 마우스로 확인).
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        // 제목 줄을 누르면 접기·펼치기
        let p = convert(event.locationInWindow, from: nil)
        if let t = titleLabel, !body.arrangedSubviews.isEmpty, p.y > bounds.height - 40, p.x < t.frame.maxX + 60 {
            collapsed.toggle()
        } else {
            super.mouseDown(with: event)
        }
    }
    override var isFlipped: Bool { false }

    /// 제목 없이 내용만 담는 둥근 판 (조정 패널 맨 위 레이어 줄)
    static func plain(_ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        return box
    }

    /// 켜고 끌 수 없는 카드 (형태 탭).
    func hideToggle() { toggle.isHidden = true }
}

/// 조정 슬라이더 한 줄: 이름, 값 칸(눌러서 숫자 입력), 슬라이더.
/// - 슬라이더나 이름을 두 번 누르면 기본값으로 돌아간다.
/// - 기본값 가까이 끌면 기본값에 달라붙는다 (트랙패드 촉각 피드백).
final class SliderRow: NSView, NSTextFieldDelegate {
    let slider: SnapSlider
    var onChange: ((Double, Bool) -> Void)?
    var value: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = newValue; updateLabel() }
    }
    /// 두 번 누르기와 달라붙기의 기준. 조정 탭은 카메라 기록값으로 바꿔 둔다.
    var defaultValue: Double {
        get { slider.defaultValue }
        set { slider.defaultValue = newValue }
    }
    private let valueField = ClickFocusTextField()
    private let format: String
    private let display: Double
    private let name: NSTextField

    init(label: String, min: Double, max: Double, format: String, display: Double = 1, defaultValue: Double? = nil) {
        self.format = format
        self.display = display
        slider = SnapSlider(value: 0, minValue: min, maxValue: max, target: nil, action: nil)
        slider.defaultValue = defaultValue ?? (min <= 0 && max >= 0 ? 0 : min)
        name = ResetLabel(labelWithString: label)
        super.init(frame: .zero)
        (name as? ResetLabel)?.onDoubleClick = { [weak self] in self?.resetToDefault() }
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        slider.onReset = { [weak self] in self?.resetToDefault() }
        name.font = .systemFont(ofSize: 12)
        name.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        name.toolTip = "두 번 누르면 기본값으로"
        // 값 칸: 평소엔 글자처럼 보이고, 누르면 숫자를 넣을 수 있다.
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        valueField.alignment = .right
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.isEditable = true
        valueField.isSelectable = true
        valueField.focusRingType = .exterior
        valueField.delegate = self
        valueField.toolTip = "눌러서 숫자로 입력"
        valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        let top = NSStackView(views: [name, NSView(), valueField])
        let v = NSStackView(views: [top, slider])
        v.orientation = .vertical
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: v.widthAnchor),
            slider.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])
        updateLabel()
        setAccessibilityElement(false)
        slider.setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // 이름을 두 번 누르면 초기화
        if event.clickCount == 2, name.convert(name.bounds, to: self).insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            resetToDefault()
        } else {
            super.mouseDown(with: event)
        }
    }

    func resetToDefault() {
        slider.doubleValue = slider.defaultValue
        updateLabel()
        onChange?(slider.doubleValue, false)
    }

    @objc private func changed() {
        updateLabel()
        // 마우스를 떼는 순간의 이벤트면 끄기가 끝난 것이다. 그때 정밀 디모자이크로 다시 그린다.
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
        onChange?(slider.doubleValue, dragging)
    }

    private func updateLabel() {
        guard valueField.currentEditor() == nil else { return }
        valueField.stringValue = String(format: format, slider.doubleValue * display)
    }

    /// 입력한 숫자를 받는다. 단위 글자(%, K, °, px)는 무시하고, 범위를 넘으면 자른다.
    func controlTextDidEndEditing(_ obj: Notification) {
        let text = valueField.stringValue.replacingOccurrences(of: ",", with: ".")
        let allowed = text.filter { "0123456789.-+".contains($0) }
        if let v = Double(allowed) {
            let x = min(max(v / display, slider.minValue), slider.maxValue)
            slider.doubleValue = x
            onChange?(x, false)
        }
        updateLabel()
        window?.makeFirstResponder(nil)
    }
}

/// 두 번 누르면 알리는 이름표 (슬라이더 이름을 두 번 눌러 기본값으로)
final class ResetLabel: NSTextField {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

/// 누를 때만 초점을 받는 입력칸. 창이 뜰 때 첫 숫자칸이 초점을 가져가면 값 갱신이 멈춰 옛 값(색온도 2000K 등)이 보였다.
final class ClickFocusTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        let t = NSApp.currentEvent?.type
        return t == .leftMouseDown || (t == .keyDown && window?.firstResponder === currentEditor())
    }
}

/// 기본값에 달라붙고, 두 번 누르면 기본값으로 돌아가는 슬라이더.
final class SnapSlider: NSSlider {
    override class var cellClass: AnyClass? { get { PixelSliderCell.self } set {} }
    var defaultValue: Double = 0 { didSet { needsDisplay = true } }
    /// 트랙 색 그라디언트 (색온도·틴트 등). 없으면 기본값에서 지금 값까지 채운다.
    var trackColors: [NSColor]? { didSet { needsDisplay = true } }
    var onReset: (() -> Void)?
    private var snapped = false

    // 두 번 누르면 기본값: 슬라이더 칸이 끌기 추적을 시작할 때 누름 횟수를 본다 (PixelSliderCell.startTracking).
    // mouseDown을 덮어쓰면 실제 마우스 끌기가 끊기고, 두 번 누르기 인식기는 끌기 추적이
    // 두 번째 누름을 먼저 가져가 실제 마우스로는 불리지 않았다.
    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc func doubleClicked() { onReset?() }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool { snapAndSend(action, to: target) }

    /// 끄는 동안 기본값 근처면 기본값으로 붙인다.
    private func snapAndSend(_ action: Selector?, to target: Any?) -> Bool {
        let range = maxValue - minValue
        let snapFraction = AppSettings.snapEnabled ? AppSettings.snapPercent / 100 : 0
        if range > 0, snapFraction > 0, defaultValue >= minValue, defaultValue <= maxValue,
           abs(super.doubleValue - defaultValue) < range * snapFraction, super.doubleValue != defaultValue {
            super.doubleValue = defaultValue
            if !snapped, AppSettings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            snapped = true
        } else if snapFraction == 0 || abs(super.doubleValue - defaultValue) >= range * snapFraction {
            snapped = false
        }
        return super.sendAction(action, to: target)
    }
}

func sectionTitle(_ s: String) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .systemFont(ofSize: 11, weight: .semibold)
    t.textColor = .secondaryLabelColor
    return t
}

/// 색상 조정 슬라이더 모양: 가는 트랙, 세로 알약 손잡이, 기본값에서 지금 값까지 채움, 색 트랙.
final class PixelSliderCell: NSSliderCell {
    private var slider: SnapSlider? { controlView as? SnapSlider }

    /// 두 번째 누름이면 끌지 않고 기본값으로
    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        if let e = NSApp.currentEvent, e.type == .leftMouseDown, e.clickCount >= 2, let s = slider {
            s.doubleClicked()
            return false
        }
        return super.startTracking(at: startPoint, in: controlView)
    }

    /// 값 → 막대 위 x. 시스템 손잡이 위치 계산과 같게 (손잡이 반폭만큼 안쪽에서 움직인다).
    private func x(for v: Double, in r: NSRect) -> CGFloat {
        let t = maxValue > minValue ? (v - minValue) / (maxValue - minValue) : 0
        let half = super.knobRect(flipped: controlView?.isFlipped ?? false).width / 2
        let inset = half > 0 ? half : 5
        return r.minX + inset + (r.width - inset * 2) * CGFloat(min(max(t, 0), 1))
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let h: CGFloat = 4
        let track = NSRect(x: rect.minX + 1, y: rect.midY - h / 2, width: rect.width - 2, height: h)
        let path = NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2)
        let enabled = isEnabled
        if let colors = slider?.trackColors, colors.count >= 2 {
            NSGradient(colors: colors.map { $0.withAlphaComponent(enabled ? 0.9 : 0.35) })?.draw(in: path, angle: 0)
            return
        }
        NSColor.white.withAlphaComponent(enabled ? 0.13 : 0.07).setFill()
        path.fill()
        // 기본값(없으면 왼쪽 끝)에서 지금 값까지
        let d = slider?.defaultValue ?? minValue
        let origin = (d >= minValue && d <= maxValue) ? d : minValue
        let x0 = x(for: origin, in: rect), x1 = x(for: doubleValue, in: rect)
        let fill = NSRect(x: min(x0, x1), y: track.minY, width: abs(x1 - x0), height: h)
        guard fill.width > 0.5 else { return }
        NSColor.white.withAlphaComponent(enabled ? 0.42 : 0.2).setFill()
        NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2).fill()
    }

    // knobRect는 바꾸지 않는다. 바꾸면 실제 마우스로 끌 때 슬라이더가 누름을 받자마자 추적을 끝내
    // 값이 안 움직이고 누름이 뒤의 카드로 넘어갔다 (창 막대의 확대 슬라이더는 멀쩡해서 비교로 찾음).
    // 알약 손잡이는 drawKnob에서 시스템 손잡이 가운데에 그린다.

    override func drawKnob(_ knobRect: NSRect) {
        let pill = NSRect(x: knobRect.midX - 4, y: knobRect.midY - 8, width: 8, height: 16)
        let p = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.shadowBlurRadius = 2
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.set()
        NSColor(white: isEnabled ? 0.8 : 0.45, alpha: 1).setFill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 색 슬라이더 트랙
enum TrackColors {
    static let temperature = [NSColor(red: 0.25, green: 0.55, blue: 1, alpha: 1), NSColor(white: 0.55, alpha: 1),
                              NSColor(red: 1, green: 0.78, blue: 0.2, alpha: 1)]
    static let tint = [NSColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1), NSColor(white: 0.55, alpha: 1),
                       NSColor(red: 0.95, green: 0.3, blue: 0.75, alpha: 1)]
    /// 어두운 쪽 → 그 색 (흑백 채널·채널 혼합)
    static func tone(_ c: NSColor) -> [NSColor] { [NSColor(white: 0.25, alpha: 1), c] }
    /// 색조 0~360°
    /// 채도: 회색 → 빨강
    static let saturation = [NSColor(white: 0.5, alpha: 1), NSColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1)]
    static let hue: [NSColor] = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
        NSColor(hue: CGFloat($0.truncatingRemainder(dividingBy: 1)), saturation: 0.75, brightness: 0.95, alpha: 1)
    }
}
