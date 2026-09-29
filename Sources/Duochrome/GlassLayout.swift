import AppKit

/// Liquid Glass layout: the center content spans the whole window (under the toolbar),
/// with left/right panels floating above as clear glass. Shared by batch edit, tethering, and library (layer edit has the same look).
/// Panel width changes by dragging the inner edge and is remembered per mode.
final class GlassLayoutController: NSViewController {
    static let gap: CGFloat = 8
    /// Panel width shared by batch edit, tethering, and layer edit (side panels keep their size across modes)
    static let sharedKey = "main"
    static let leftRange: ClosedRange<CGFloat> = 288...428
    static let rightRange: ClosedRange<CGFloat> = leftRange
    static var sharedLeft: CGFloat {
        min(max(UserDefaults.standard.object(forKey: "glass.\(sharedKey).left") as? CGFloat ?? 288, leftRange.lowerBound), leftRange.upperBound)
    }
    /// The right panel matches the left width (symmetric)
    static var sharedRight: CGFloat { sharedLeft }

    let content: NSViewController
    let left: NSViewController?
    let right: NSViewController?
    private let key: String
    private let leftRange: ClosedRange<CGFloat>
    private let rightRange: ClosedRange<CGFloat>
    /// Links left/right widths (dragging one resizes both). On for modes using the shared key.
    private var linked: Bool { key == Self.sharedKey }

    /// When the work area minus panels changes (width covered on left/right, including margins)
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

    /// Panel width (of the glass panel itself)
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

    /// Work area width covered on left/right
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
        // Content extends under the toolbar (to the very top, not the safe area)
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

    /// Handle to resize by dragging the panel's inner edge
    private func addHandle(to panel: NSView, in root: NSView, trailing: Bool, drag: @escaping (CGFloat) -> Void) {
        let h = ResizeHandle()
        h.onDrag = drag
        h.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(h)   // Inside loadView, so view doesn't exist yet (calling view recursed into loadView and crashed)
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

/// Glass panel: Liquid Glass background + content clipped to rounded corners
final class GlassPanel: NSView {
    /// Plain arrow over panels and bars (so the photo view's edit cursor doesn't show through)
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
        // Right/bottom at lower priority so content minimum width can't push the panel width (lesson from ToolPanel)
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

/// Panel width handle: ↔ cursor on hover at the edge, drag to resize
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

/// Translucent strip behind the toolbar: the photo under the toolbar shows through clear glass (color intact, slightly blurred),
/// with a hairline below to separate the bar. (The opaque toolbar material hides the photo, which is unwanted)
final class TitleBand: NSView {
    /// Plain arrow over panels and bars (so the photo view's edit cursor doesn't show through)
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private let line = NSBox()

    init() {
        super.init(frame: .zero)
        let back: NSView
        if #available(macOS 26, *) {
            // Same glass as the side panels (.regular). .clear looked like an opaque strip over dark backgrounds.
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

    /// Pinned to the top of root for the height covered by the toolbar (safe area top). Above content, below panels.
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
