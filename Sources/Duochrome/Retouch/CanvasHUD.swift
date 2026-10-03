import AppKit

/// Bar floating at the bottom of the canvas while a tool needs confirming (crop, liquify, perspective…):
/// a short instruction and its buttons (reset/cancel · done), like the reference editor.
final class CanvasBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self, radius: 16, interactive: true)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        buttons.spacing = 6
        let row = NSStackView(views: [label, buttons])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, _ items: [(String, () -> Void)]) {
        label.stringValue = text
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = items.map(\.1)
        for (k, (title, _)) in items.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            b.bezelStyle = .appPush
            b.controlSize = .small
            b.tag = k
            if k == items.count - 1 { b.keyEquivalent = "" ; b.contentTintColor = .controlAccentColor }
            buttons.addArrangedSubview(b)
        }
        isHidden = false
    }

    func hide() { isHidden = true }

    @objc private func pressed(_ b: NSButton) {
        guard actions.indices.contains(b.tag) else { return }
        actions[b.tag]()
    }
}

/// Command name shown briefly in the middle of the canvas ("화면 맞춤", "전체 선택"…), then fades out
final class FlashLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private var token = 0

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self, radius: 14)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        alphaValue = 0
        // Hidden, not just transparent, when idle: the floating style's arrow-cursor area would otherwise
        // keep the arrow over the middle of the photo
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(_ text: String) {
        label.stringValue = text
        token += 1
        let t = token
        isHidden = false
        alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.token == t else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                guard let self, self.token == t else { return }
                self.isHidden = true
                self.window?.invalidateCursorRects(for: self)
            })
        }
    }
}
