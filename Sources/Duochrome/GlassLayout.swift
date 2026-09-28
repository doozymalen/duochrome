import AppKit

/// 리퀴드 글래스 배치: 가운데 내용이 창 전체(창 막대 밑까지)에 깔리고,
/// 왼쪽·오른쪽 패널이 그 위에 맑은 유리로 뜬다. 대량 보정·테더링·라이브러리가 같이 쓴다 (심화 보정도 같은 모양).
/// 패널 폭은 안쪽 가장자리를 끌어 바꾸고, 모드마다 따로 기억한다.
final class GlassLayoutController: NSViewController {
    static let gap: CGFloat = 8
    /// 대량 보정·테더링·심화 보정이 같이 쓰는 패널 폭 (모드를 옮겨도 좌우 패널 크기가 같다)
    static let sharedKey = "main"
    static let leftRange: ClosedRange<CGFloat> = 288...428
    static let rightRange: ClosedRange<CGFloat> = leftRange
    static var sharedLeft: CGFloat {
        min(max(UserDefaults.standard.object(forKey: "glass.\(sharedKey).left") as? CGFloat ?? 288, leftRange.lowerBound), leftRange.upperBound)
    }
    /// 오른쪽 패널은 왼쪽과 같은 폭 (좌우 대칭)
    static var sharedRight: CGFloat { sharedLeft }

    let content: NSViewController
    let left: NSViewController?
    let right: NSViewController?
    private let key: String
    private let leftRange: ClosedRange<CGFloat>
    private let rightRange: ClosedRange<CGFloat>
    /// 좌우 폭을 묶는다 (한쪽을 끌면 양쪽이 같이 변한다). 공통 키를 쓰는 모드는 켠다.
    private var linked: Bool { key == Self.sharedKey }

    /// 패널을 뺀 작업 영역이 바뀔 때 (왼쪽·오른쪽에서 가려진 폭, 여백 포함)
    var onInsetsChange: ((_ left: CGFloat, _ right: CGFloat) -> Void)?

    private let leftPanel = GlassPanel()
    private let rightPanel = GlassPanel()
    private var leftWidthC: NSLayoutConstraint?
    private var rightWidthC: NSLayoutConstraint?

    init(content: NSViewController, left: NSViewController?, right: NSViewController?, key: String,
         leftRange: ClosedRange<CGFloat>, rightRange: ClosedRange<CGFloat>, leftDefault: CGFloat, rightDefault: CGFloat) {
        self.content = content
        self.left = left
        self.right = right
        self.key = key
        self.leftRange = leftRange
        self.rightRange = rightRange
        let d = UserDefaults.standard
        leftWidth = min(max(d.object(forKey: "glass.\(key).left") as? CGFloat ?? leftDefault, leftRange.lowerBound), leftRange.upperBound)
        rightWidth = min(max(d.object(forKey: "glass.\(key).right") as? CGFloat ?? rightDefault, rightRange.lowerBound), rightRange.upperBound)
        if key == Self.sharedKey { rightWidth = leftWidth }
        showsLeft = d.object(forKey: "glass.\(key).showLeft") as? Bool ?? true
        showsRight = d.object(forKey: "glass.\(key).showRight") as? Bool ?? true
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 패널 폭 (유리 패널 자체의 폭)
    var leftWidth: CGFloat {
        didSet {
            leftWidth = min(max(leftWidth, leftRange.lowerBound), leftRange.upperBound)
            leftWidthC?.constant = leftWidth
            UserDefaults.standard.set(leftWidth, forKey: "glass.\(key).left")
            if linked, rightWidth != leftWidth { rightWidth = leftWidth }
            notify()
        }
    }
    var rightWidth: CGFloat {
        didSet {
            rightWidth = min(max(rightWidth, rightRange.lowerBound), rightRange.upperBound)
            rightWidthC?.constant = rightWidth
            UserDefaults.standard.set(rightWidth, forKey: "glass.\(key).right")
            if linked, leftWidth != rightWidth { leftWidth = rightWidth }
            notify()
        }
    }
    var showsLeft: Bool { didSet { UserDefaults.standard.set(showsLeft, forKey: "glass.\(key).showLeft"); applyShown(animated: true) } }
    var showsRight: Bool { didSet { UserDefaults.standard.set(showsRight, forKey: "glass.\(key).showRight"); applyShown(animated: true) } }

    /// 작업 영역 왼쪽·오른쪽 가림 폭
    var insets: (left: CGFloat, right: CGFloat) {
        (showsLeft && left != nil ? Self.gap + leftWidth : 0, showsRight && right != nil ? Self.gap + rightWidth : 0)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = StudioStyle.window.cgColor
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content.view)
        // 내용은 창 막대 밑까지 (safe area가 아니라 맨 위에)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: root.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        TitleBand.install(in: root, above: content.view)
        let top = root.safeAreaLayoutGuide.topAnchor
        let g = Self.gap
        if let left {
            addChild(left)
            leftPanel.embed(left.view)
            leftPanel.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(leftPanel)
            let w = leftPanel.widthAnchor.constraint(equalToConstant: leftWidth)
            leftWidthC = w
            NSLayoutConstraint.activate([
                leftPanel.topAnchor.constraint(equalTo: top, constant: g),
                leftPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -g),
                leftPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: g),
                w,
            ])
            addHandle(to: leftPanel, in: root, trailing: true) { [weak self] dx in self?.leftWidth += dx }
        }
        if let right {
            addChild(right)
            rightPanel.embed(right.view)
            rightPanel.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(rightPanel)
            let w = rightPanel.widthAnchor.constraint(equalToConstant: rightWidth)
            rightWidthC = w
            NSLayoutConstraint.activate([
                rightPanel.topAnchor.constraint(equalTo: top, constant: g),
                rightPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -g),
                rightPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -g),
                w,
            ])
            addHandle(to: rightPanel, in: root, trailing: false) { [weak self] dx in self?.rightWidth -= dx }
        }
        view = root
        applyShown(animated: false)
    }

    /// 패널 안쪽 가장자리를 끌어 폭을 바꾸는 손잡이
    private func addHandle(to panel: NSView, in root: NSView, trailing: Bool, drag: @escaping (CGFloat) -> Void) {
        let h = ResizeHandle()
        h.onDrag = drag
        h.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(h)   // loadView 안이라 view는 아직 없다 (view를 부르면 loadView가 되풀이돼 죽었다)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            h.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            h.widthAnchor.constraint(equalToConstant: 8),
            trailing ? h.centerXAnchor.constraint(equalTo: panel.trailingAnchor) : h.centerXAnchor.constraint(equalTo: panel.leadingAnchor),
        ])
        if trailing { leftHandle = h } else { rightHandle = h }
    }
    private weak var leftHandle: ResizeHandle?
    private weak var rightHandle: ResizeHandle?

    private func applyShown(animated: Bool) {
        guard isViewLoaded else { return }
        for (panel, handle, shown) in [(leftPanel, leftHandle, showsLeft), (rightPanel, rightHandle, showsRight)] {
            handle?.isHidden = !shown
            if animated {
                if shown { panel.isHidden = false }
                NSAnimationContext.runAnimationGroup({ c in
                    c.duration = 0.18
                    panel.animator().alphaValue = shown ? 1 : 0
                }, completionHandler: { panel.isHidden = !shown })
            } else {
                panel.alphaValue = shown ? 1 : 0
                panel.isHidden = !shown
            }
        }
        notify()
    }

    private func notify() {
        let i = insets
        onInsetsChange?(i.left, i.right)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        notify()
    }
}

/// 유리 패널: 리퀴드 글래스 배경 + 둥근 모서리 안으로 자른 내용
final class GlassPanel: NSView {
    /// 패널·막대 위는 보통 화살표 (아래 사진 화면의 편집 포인터가 비치지 않게)
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private let clip = NSView()

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 16
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(v)
        // 내용의 최소 폭이 패널 폭을 밀지 못하게 오른쪽·아래는 한 단계 낮게 (ToolPanel의 교훈)
        let t = v.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
        let b = v.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        t.priority = .init(999); b.priority = .init(999)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: clip.topAnchor),
            v.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            t, b,
        ])
    }
}

/// 패널 폭 손잡이: 가장자리에 커서를 올리면 ↔, 끌면 폭이 바뀐다
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        guard let l = last else { return }
        let x = event.locationInWindow.x
        onDrag?(x - l)
        last = x
    }
    override func mouseUp(with event: NSEvent) { last = nil }
}

/// 창 막대 뒤 반투명 띠: 창 막대 밑까지 깔린 사진이 맑은 유리 너머로 비치고(색은 그대로, 살짝 흐림),
/// 아래에 가는 선을 그어 막대가 구분되게 한다. (불투명한 창 막대 재질은 사진을 가려 싫다)
final class TitleBand: NSView {
    /// 패널·막대 위는 보통 화살표 (아래 사진 화면의 편집 포인터가 비치지 않게)
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private let line = NSBox()

    init() {
        super.init(frame: .zero)
        let back: NSView
        if #available(macOS 26, *) {
            // 좌우 패널과 같은 유리 (.regular). .clear는 어두운 바탕 위에서 불투명한 띠처럼 보였다.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            back = glass
        } else {
            let v = NSVisualEffectView()
            v.material = .titlebar
            v.blendingMode = .withinWindow
            v.alphaValue = 0.6
            back = v
        }
        back.frame = bounds
        back.autoresizingMask = [.width, .height]
        addSubview(back)
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = NSColor.white.withAlphaComponent(0.14)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 창 막대에 가려진 높이(safe area 위쪽)만큼 root 맨 위에 붙인다. 내용 위, 패널 아래에 둔다.
    static func install(in root: NSView, above content: NSView) {
        let band = TitleBand()
        band.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(band, positioned: .above, relativeTo: content)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: root.topAnchor),
            band.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])
    }
}
