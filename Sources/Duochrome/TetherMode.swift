import AppKit
import ImageCaptureCore

/// 카메라 연결. macOS 기본 ImageCaptureCore를 쓴다 (회사별 SDK 없이 USB로 촬영·내려받기).
/// 카메라가 원격 촬영을 지원하면 "촬영" 버튼이 켜지고, 찍힌 파일은 세션 폴더로 바로 받는다.
/// 조리개·셔터 같은 카메라 설정 원격 변경은 ImageCaptureCore에 없어서 libgphoto2 도우미(GPhotoTether.swift)가 맡는다.
final class TetherCamera: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    var onStatus: ((String) -> Void)?
    var onDownloaded: ((URL) -> Void)?
    var folder: URL
    private(set) var camera: ICCameraDevice?
    private let browser = ICDeviceBrowser()
    private var tetherStarted = Date.distantFuture

    init(folder: URL) {
        self.folder = folder
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
    }

    func start() {
        // 권한 안내 문구는 Info.plist(NSCameraUsageDescription). 권한 요청 API는 iOS 전용이라 macOS에서는 쓰지 않는다.
        browser.start()
        onStatus?("카메라를 찾는 중… USB로 연결하고 카메라를 켜 주세요.")
    }

    func stop() {
        browser.stop()
        camera?.requestCloseSession()
    }

    var canShoot: Bool { camera?.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) ?? false }

    func shoot() {
        guard let camera, canShoot else { onStatus?("이 카메라는 원격 촬영을 지원하지 않습니다."); return }
        camera.requestTakePicture()
        onStatus?("촬영 중…")
    }

    // MARK: 장치 찾기

    /// 아이폰·아이패드도 "카메라"로 잡힌다. 세션을 열면 휴대폰에 잠금 해제 요청이 뜨므로 건드리지 않는다.
    static func isPhone(_ device: ICDevice) -> Bool {
        let kind = (device.productKind ?? "") + " " + (device.name ?? "")
        return ["iPhone", "iPad", "iPod", "Vision"].contains { kind.localizedCaseInsensitiveContains($0) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice, !Self.isPhone(device) else { return }
        camera = cam
        cam.delegate = self
        onStatus?("\(cam.name ?? "카메라") 연결 중…")
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device === camera else { return }
        camera = nil
        onStatus?("카메라 연결이 끊겼습니다.")
    }

    // MARK: 장치

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { onStatus?("카메라를 열 수 없습니다: \(error.localizedDescription)"); return }
        guard let cam = device as? ICCameraDevice else { return }
        if cam.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) {
            cam.requestEnableTethering()
            tetherStarted = Date()
            onStatus?("\(cam.name ?? "카메라") 연결됨 — 촬영 버튼이나 카메라 셔터로 찍으면 바로 들어옵니다.")
        } else {
            tetherStarted = Date()
            onStatus?("\(cam.name ?? "카메라") 연결됨 — 원격 촬영은 지원하지 않습니다. 카메라에서 찍으면 새 파일을 받아 옵니다.")
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) { if device === camera { camera = nil; onStatus?("카메라 연결이 끊겼습니다.") } }
    func device(_ device: ICDevice, didEncounterError error: Error?) { if let error { onStatus?("카메라 오류: \(error.localizedDescription)") } }

    /// 새로 찍힌 파일만 받는다 (연결 전에 카드에 있던 사진은 건드리지 않는다).
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        for case let file as ICCameraFile in items {
            let created = file.creationDate ?? file.fileCreationDate ?? Date.distantPast
            guard created >= tetherStarted.addingTimeInterval(-2) else { continue }
            guard Library.supported.contains((file.name ?? "").split(separator: ".").last.map { $0.lowercased() } ?? "") else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            camera.requestDownloadFile(file, options: [.downloadsDirectoryURL: folder, .overwrite: false],
                                       downloadDelegate: self,
                                       didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                                       contextInfo: nil)
            onStatus?("받는 중: \(file.name ?? "")")
        }
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        if let error { onStatus?("받기 실패: \(error.localizedDescription)"); return }
        let name = options[ICDownloadOption.savedFilename.rawValue] as? String ?? file.name ?? ""
        let url = folder.appendingPathComponent(name)
        onStatus?("받음: \(name)")
        onDownloaded?(url)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// 감시 폴더: 카메라 회사 프로그램처럼 다른 프로그램이 세션 폴더에 떨군 새 사진을 가져온다.
/// 쓰는 중인 파일을 읽지 않도록 크기가 두 번 연속 같을 때만 넘긴다.
final class HotFolder {
    var onNew: ((URL) -> Void)?
    private(set) var folder: URL
    private var timer: Timer?
    private var known: Set<String> = []
    private var pending: [String: Int] = [:]

    init(folder: URL) { self.folder = folder }

    func start() {
        known = Set(list().map(\.lastPathComponent))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func change(_ url: URL) { folder = url; if timer != nil { start() } }

    private func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { Library.supported.contains($0.pathExtension.lowercased()) }
    }

    private func poll() {
        for url in list() where !known.contains(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let prev = pending[url.lastPathComponent], prev == size, size > 0 {
                pending[url.lastPathComponent] = nil
                known.insert(url.lastPathComponent)
                onNew?(url)
            } else {
                pending[url.lastPathComponent] = size
            }
        }
    }
}

/// ③ 테더링 모드: 왼쪽 카메라·세션, 가운데 방금 찍은 사진, 오른쪽 세션 사진들.
final class TetherModeController: NSViewController {
    let viewer = ViewerController()
    let strip = BrowserViewController(grid: false)
    var onShoot: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onHotFolder: ((Bool) -> Void)?
    var onNextAdjust: ((Int) -> Void)?
    var onOpenInEditor: (() -> Void)?
    var onSetting: ((String, String) -> Void)?
    var onLive: ((Bool) -> Void)?
    var onAF: (() -> Void)?
    var onFocus: ((Int) -> Void)?
    var onZoom: ((String) -> Void)?
    /// 캔버스 위 라이브 뷰·구도 참고 그림·3분할 격자
    let overlay = LiveOverlayView()
    private let settingsStack = NSStackView()
    private let liveButton = NSButton(checkboxWithTitle: "라이브 뷰", target: nil, action: nil)
    private let focusRow = NSStackView()
    private let afButton = NSButton(title: "AF", target: nil, action: nil)
    private var focusButtons: [NSButton] = []
    private let zoomPop = NSPopUpButton()
    private var zoomValues: [String] = []
    private var caps = GPhotoCamera.Caps()
    private let overlayShow = NSButton(checkboxWithTitle: "구도 참고 그림 겹치기", target: nil, action: nil)
    private let gridShow = NSButton(checkboxWithTitle: "3분할 격자", target: nil, action: nil)
    private let overlayAlpha = NSSlider(value: 0.4, minValue: 0.05, maxValue: 1, target: nil, action: nil)

    private let leftVC = NSViewController()
    /// 테더링 배치 (GlassLayout.swift): 사진이 창 전체에, 왼쪽 카메라 패널·오른쪽 사진 목록이 유리로 뜬다
    lazy var split = GlassLayoutController(content: viewer, left: leftVC, right: strip, key: GlassLayoutController.sharedKey,
                                           leftRange: GlassLayoutController.leftRange, rightRange: GlassLayoutController.rightRange,
                                           leftDefault: 288, rightDefault: 290)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let folderLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let shootButton = NSButton(title: "촬영 (스페이스)", target: nil, action: nil)
    private let hot = NSButton(checkboxWithTitle: "감시 폴더 켜기", target: nil, action: nil)
    private let nextAdjust = NSPopUpButton()
    let histogram = HistogramView()

    override func loadView() {
        viewer.bar = makeBar()
        let left = leftVC
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        status.font = .systemFont(ofSize: 12)
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        shootButton.bezelStyle = .appPush
        shootButton.controlSize = .large
        shootButton.keyEquivalent = " "
        shootButton.target = self
        shootButton.action = #selector(shootTapped)
        let choose = NSButton(title: "세션 폴더 바꾸기…", target: self, action: #selector(chooseTapped))
        choose.bezelStyle = .appPush
        hot.target = self
        hot.action = #selector(hotChanged)
        hot.state = UserDefaults.standard.bool(forKey: "tether.hot") ? .on : .off
        for t in ["다음 촬영에 조정 적용 안 함", "직전 사진의 조정 적용", "복사해 둔 조정 적용"] { nextAdjust.addItem(withTitle: t) }
        nextAdjust.selectItem(at: UserDefaults.standard.integer(forKey: "tether.next"))
        nextAdjust.target = self
        nextAdjust.action = #selector(nextChanged)
        let edit = NSButton(title: "대량 보정에서 열기", target: self, action: #selector(editTapped))
        edit.bezelStyle = .appPush
        let note = NSTextField(wrappingLabelWithString:
            "카메라를 USB로 연결하면 바로 찾습니다(유선 전용, 공개 라이브러리 libgphoto2). 카메라 셔터로 찍어도 들어옵니다. 카메라 회사 프로그램으로 찍어 이 폴더에 저장해도 감시 폴더로 바로 들어옵니다. 초점·확대 단추는 카메라가 지원할 때만 보입니다.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        histogram.translatesAutoresizingMaskIntoConstraints = false
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 6
        liveButton.target = self; liveButton.action = #selector(liveTapped)
        liveButton.isEnabled = false
        focusRow.orientation = .horizontal
        focusRow.spacing = 4
        afButton.target = self; afButton.action = #selector(afTapped)
        afButton.bezelStyle = .appPush; afButton.controlSize = .small
        afButton.toolTip = "자동 초점 한 번"
        focusRow.addArrangedSubview(afButton)
        for (t, step, tip) in [("◀◀", -3, "가까이 크게"), ("◀", -1, "가까이 조금"), ("▶", 1, "멀리 조금"), ("▶▶", 3, "멀리 크게")] {
            let b = NSButton(title: t, target: self, action: #selector(focusTapped(_:)))
            b.bezelStyle = .appPush; b.controlSize = .small
            b.tag = step
            b.toolTip = "수동 초점: \(tip)"
            focusRow.addArrangedSubview(b)
            focusButtons.append(b)
        }
        zoomPop.controlSize = .small
        zoomPop.target = self; zoomPop.action = #selector(zoomChanged)
        focusRow.addArrangedSubview(zoomPop)
        focusRow.isHidden = true
        let pick = NSButton(title: "구도 참고 그림 고르기…", target: self, action: #selector(pickReference))
        pick.bezelStyle = .appPush
        overlayShow.target = self; overlayShow.action = #selector(overlayChanged)
        gridShow.target = self; gridShow.action = #selector(overlayChanged)
        gridShow.state = UserDefaults.standard.bool(forKey: "tether.grid") ? .on : .off
        overlayAlpha.doubleValue = UserDefaults.standard.object(forKey: "tether.overlayAlpha") as? Double ?? 0.4
        overlayAlpha.target = self; overlayAlpha.action = #selector(overlayChanged)
        overlayAlpha.controlSize = .small
        overlayAlpha.toolTip = "겹치는 그림의 불투명도"
        if let p = UserDefaults.standard.string(forKey: "tether.overlayImage"), let img = NSImage(contentsOfFile: p) {
            overlay.reference.image = img
            overlayShow.state = UserDefaults.standard.bool(forKey: "tether.overlayOn") ? .on : .off
        }
        let alphaLabel = NSTextField(labelWithString: "겹치는 그림 불투명도")
        alphaLabel.font = .systemFont(ofSize: 11)
        alphaLabel.textColor = .secondaryLabelColor
        for v in [sectionTitle("카메라"), status, shootButton, settingsStack, liveButton, focusRow,
                  sectionTitle("오버레이"), pick, overlayShow, alphaLabel, overlayAlpha, gridShow,
                  sectionTitle("세션"), folderLabel, choose, countLabel, hot,
                  sectionTitle("들어오는 사진"), nextAdjust, sectionTitle("히스토그램"), histogram, edit, note] as [NSView] {
            stack.addArrangedSubview(v)
        }
        for v in [status, folderLabel, note, histogram, nextAdjust, shootButton, settingsStack, overlayAlpha] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        left.view = scroll

        split.onInsetsChange = { [weak self] l, r in
            self?.viewer.setSideInsets(left: l, right: r)
            self?.overlay.needsLayout = true
        }
        overlay.frame = viewer.canvas.bounds
        overlay.autoresizingMask = [.width, .height]
        viewer.canvas.addSubview(overlay)
        applyOverlay()
        addChild(split)
        view = split.view
        setCanShoot(false)
        setStatus("카메라가 연결되지 않았습니다.")
        hot.toolTip = "카메라 회사 프로그램 같은 다른 프로그램이 세션 폴더에 저장한 새 사진을 바로 가져옵니다."
    }

    func setStatus(_ s: String) { status.stringValue = s }

    // MARK: 카메라 설정 (연결된 카메라가 알려 준 값과 고를 수 있는 값)

    private static let settingOrder: [(String, String)] = [
        ("aperture", "조리개"), ("shutterspeed", "셔터"), ("iso", "ISO"), ("exposurecompensation", "노출 보정"),
        ("whitebalance", "화이트 밸런스"), ("colortemperature", "색온도"), ("imageformat", "화질"),
        ("drivemode", "드라이브"), ("focusmode", "초점 방식"), ("capturetarget", "저장 위치"),
    ]

    func showCameraSettings(_ s: [String: GPhotoCamera.Setting]) {
        settingsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (key, title) in Self.settingOrder {
            guard let item = s[key], !item.choices.isEmpty else { continue }
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.widthAnchor.constraint(equalToConstant: 78).isActive = true
            let p = NSPopUpButton()
            p.controlSize = .small
            p.addItems(withTitles: item.choices)
            p.selectItem(withTitle: item.value)
            p.isEnabled = !item.readonly
            p.identifier = NSUserInterfaceItemIdentifier(key)
            p.target = self; p.action = #selector(settingChanged(_:))
            let row = NSStackView(views: [l, p])
            row.spacing = 6
            settingsStack.addArrangedSubview(row)
        }
        if let b = s["batterylevel"] {
            let l = NSTextField(labelWithString: "배터리 \(b.value)")
            l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            settingsStack.addArrangedSubview(l)
        }
    }

    func setConnected(_ on: Bool) {
        liveButton.isEnabled = on
        if !on {
            settingsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            setCaps(GPhotoCamera.Caps())
            setLive(false)
        }
    }

    /// 연결한 카메라에서 되는 초점·확대만 보인다
    func setCaps(_ c: GPhotoCamera.Caps) {
        caps = c
        afButton.isHidden = !c.af
        focusButtons.forEach { $0.isHidden = !c.focus }
        zoomValues = c.zoom
        zoomPop.removeAllItems()
        zoomPop.addItems(withTitles: c.zoom.map { Double($0) != nil ? "확대 \($0)×" : "확대 \($0)" })
        zoomPop.isHidden = c.zoom.count < 2
        updateFocusRow()
    }

    private func updateFocusRow() {
        focusRow.isHidden = liveButton.state != .on || !(caps.af || caps.focus || caps.zoom.count >= 2)
    }

    func setLive(_ on: Bool) {
        liveButton.state = on ? .on : .off
        updateFocusRow()
        overlay.live.isHidden = !on
        if !on { overlay.live.image = nil }
        overlay.needsLayout = true
    }

    func showFrame(_ img: CGImage) {
        guard liveButton.state == .on else { return }
        overlay.live.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        if overlay.live.isHidden { overlay.live.isHidden = false; overlay.needsLayout = true }
    }

    @objc private func settingChanged(_ p: NSPopUpButton) {
        guard let key = p.identifier?.rawValue, let v = p.titleOfSelectedItem else { return }
        onSetting?(key, v)
    }
    @objc private func liveTapped() { onLive?(liveButton.state == .on) }
    @objc private func afTapped() { onAF?() }
    @objc private func focusTapped(_ b: NSButton) { onFocus?(b.tag) }
    @objc private func zoomChanged() {
        let i = zoomPop.indexOfSelectedItem
        if zoomValues.indices.contains(i) { onZoom?(zoomValues[i]) }
    }

    // MARK: 구도 오버레이

    @objc private func pickReference() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.prompt = "겹치기"
        guard p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url) else { return }
        UserDefaults.standard.set(url.path, forKey: "tether.overlayImage")
        overlay.reference.image = img
        overlayShow.state = .on
        overlayChanged()
    }

    @objc private func overlayChanged() {
        UserDefaults.standard.set(overlayShow.state == .on, forKey: "tether.overlayOn")
        UserDefaults.standard.set(gridShow.state == .on, forKey: "tether.grid")
        UserDefaults.standard.set(overlayAlpha.doubleValue, forKey: "tether.overlayAlpha")
        applyOverlay()
    }

    private func applyOverlay() {
        overlay.reference.isHidden = overlayShow.state != .on || overlay.reference.image == nil
        overlay.reference.alphaValue = CGFloat(overlayAlpha.doubleValue)
        overlay.grid.isHidden = gridShow.state != .on
        overlay.grid.needsDisplay = true
        overlay.needsLayout = true
    }
    func setFolder(_ url: URL, count: Int) {
        folderLabel.stringValue = url.path
        countLabel.stringValue = "이 세션 \(count)장"
    }
    func setCanShoot(_ on: Bool) { shootButton.isEnabled = on; barShoot?.isEnabled = on }
    var hotFolderOn: Bool { hot.state == .on }
    var nextMode: Int { nextAdjust.indexOfSelectedItem }

    @objc private func shootTapped() { onShoot?() }
    @objc private func chooseTapped() { onChooseFolder?() }
    @objc private func editTapped() { onOpenInEditor?() }
    @objc private func hotChanged() {
        UserDefaults.standard.set(hot.state == .on, forKey: "tether.hot")
        barHot?.isOn = hot.state == .on
        onHotFolder?(hot.state == .on)
    }

    // MARK: - 테더링 모드별 막대: [촬영] [감시 폴더 · 노출 경고] [대량 보정에서 열기]

    private weak var barShoot: ModeBarButton?
    private weak var barHot: ModeBarButton?
    private weak var barClip: ModeBarButton?

    private func makeBar() -> ModeBar {
        let shoot = ModeBarButton("camera.aperture", "촬영 (스페이스)", target: self, action: #selector(shootTapped))
        shoot.isEnabled = shootButton.isEnabled
        let hotB = ModeBarButton("folder.badge.gearshape", "감시 폴더 켜기·끄기", target: self, action: #selector(hotBarTapped))
        hotB.isOn = hot.state == .on
        let clip = ModeBarButton("exclamationmark.triangle", "노출 경고 (⌥⌘O)", target: self, action: #selector(clipTapped))
        let edit = ModeBarButton("slider.horizontal.3", "대량 보정에서 열기", target: self, action: #selector(editTapped))
        barShoot = shoot; barHot = hotB; barClip = clip
        return ModeBar([shoot, ModeBar.gap(), hotB, clip, ModeBar.gap(), edit])
    }

    @objc private func hotBarTapped() {
        hot.state = hot.state == .on ? .off : .on
        hotChanged()
    }

    @objc private func clipTapped() { toggleClipping() }

    func toggleClipping() {
        viewer.canvas.showClipping.toggle()
        barClip?.isOn = viewer.canvas.showClipping
    }
    @objc private func nextChanged() {
        UserDefaults.standard.set(nextAdjust.indexOfSelectedItem, forKey: "tether.next")
        onNextAdjust?(nextAdjust.indexOfSelectedItem)
    }
}
