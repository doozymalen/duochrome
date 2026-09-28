import AppKit

/// 왼쪽 도구 패널. 위에 도구 탭이 있고 아래에 그 탭의 도구가 쌓인다.
/// 레이어·리터칭 같은 기능은 여기에 탭으로 더해 간다.
final class ToolPanelController: NSViewController {
    struct Tab {
        let title: String
        let symbol: String
        let controller: NSViewController
    }

    private var tabs: [Tab] = []
    private var buttons: [TabButton] = []
    private let container = TabHostView()
    private(set) var selected = 0
    var onSelect: ((Int) -> Void)?

    init(tabs: [Tab]) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        let bar = NSStackView()
        bar.distribution = .fillEqually
        bar.spacing = 2
        for (i, tab) in tabs.enumerated() {
            let b = TabButton(title: tab.title, symbol: tab.symbol)
            b.onClick = { [weak self] in self?.select(i) }
            buttons.append(b)
            bar.addArrangedSubview(b)
        }
        let line = NSBox()
        line.boxType = .separator
        for v in [bar, line, container] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 48),
            line.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: line.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        select(UserDefaults.standard.integer(forKey: "toolTab"))
    }

    func tabTitle(_ i: Int) -> String { tabs.indices.contains(i) ? tabs[i].title : "" }
    func index(of title: String) -> Int { tabs.firstIndex { $0.title == title } ?? 0 }

    func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = tabs[i].controller.view
        container.addSubview(v)
        // 탭 내용은 제약으로 잇지 않고 프레임으로만 채운다 (TabHostView.layout).
        // 제약으로 이으면 탭마다 최소 폭·높이가 달라 탭을 바꿀 때마다 사이드바 폭과 창 크기가 바뀌었다.
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoresizingMask = []
        v.frame = container.bounds
        for (j, b) in buttons.enumerated() { b.active = j == i }
        selected = i
        UserDefaults.standard.set(i, forKey: "toolTab")
        onSelect?(i)
    }
}

/// 아이콘 위, 이름 아래. 고른 탭은 둥근 알약으로 칠한다 (창 막대 모드 전환과 같은 강조).
final class TabButton: NSView {
    var onClick: (() -> Void)?
    var active = false { didSet { update() } }
    private let icon: NSImageView
    private let label: NSTextField

    init(title: String, symbol: String) {
        icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        super.init(frame: .zero)
        let v = NSStackView(views: [icon, label])
        v.orientation = .vertical
        v.spacing = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: centerXAnchor),
            v.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = title
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 고른 탭: 창 막대 모드 전환처럼 둥근 알약을 칠하고 글자를 진하게. 올려 두면 옅은 알약.
    private func update() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = (active ? NSColor.white.withAlphaComponent(0.16)
            : hovering ? NSColor.white.withAlphaComponent(0.07) : .clear).cgColor
        let c: NSColor = active ? .controlAccentColor : .secondaryLabelColor
        icon.contentTintColor = c
        label.textColor = c
        label.font = .systemFont(ofSize: 10, weight: active ? .semibold : .medium)
    }

    private var hovering = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; update() }
    override func mouseExited(with event: NSEvent) { hovering = false; update() }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - 라이브러리 탭

/// 연 폴더, 최근 폴더, 고른 사진의 촬영 정보.
final class LibraryTabController: NSViewController {
    var onOpenFolder: (() -> Void)?
    var onPickRecent: ((URL) -> Void)?
    var onImportCatalog: (() -> Void)?
    /// 카탈로그 목록 (라이브러리 모드 왼쪽과 같은 것)
    let sources = SourceListController()

    private let folderLabel = NSTextField(wrappingLabelWithString: "폴더를 열지 않았습니다")
    private let recentStack = NSStackView()
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let open = NSButton(title: "폴더 가져오기…", target: self, action: #selector(openTapped))
        open.bezelStyle = .appPush
        open.controlSize = .regular
        let catalogButton = NSButton(title: "카탈로그 가져오기…", target: self, action: #selector(catalogTapped))
        catalogButton.bezelStyle = .appPush
        let buttons = NSStackView(views: [open, catalogButton])
        buttons.spacing = 6
        folderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor

        let head = NSStackView(views: [buttons])
        head.orientation = .vertical
        head.alignment = .leading
        head.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 6, right: 14)
        let foot = NSStackView(views: [sectionTitle("촬영 정보"), infoLabel])
        foot.orientation = .vertical
        foot.alignment = .leading
        foot.spacing = 6
        foot.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 14, right: 16)
        let root = NSView()
        addChild(sources)
        for v in [head, sources.view, foot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sources.view.topAnchor.constraint(equalTo: head.bottomAnchor),
            sources.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sources.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sources.view.bottomAnchor.constraint(equalTo: foot.topAnchor),
            foot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            foot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            infoLabel.widthAnchor.constraint(equalTo: foot.widthAnchor, constant: -32),
            infoLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        view = root
        showRecent()
    }

    @objc private func openTapped() { onOpenFolder?() }
    @objc private func catalogTapped() { onImportCatalog?() }

    func showFolder(_ url: URL, count: Int) {
        folderLabel.stringValue = "\(url.lastPathComponent)  ·  \(count)장\n\(url.deletingLastPathComponent().path)"
        var recent = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        recent.removeAll { $0 == url.path }
        recent.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(8)), forKey: "recentFolders")
        showRecent()
    }

    private func showRecent() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for path in UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [] {
            let url = URL(fileURLWithPath: path)
            let b = NSButton(title: url.lastPathComponent, image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!,
                             target: self, action: #selector(recentTapped(_:)))
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = path
            b.identifier = NSUserInterfaceItemIdentifier(path)
            recentStack.addArrangedSubview(b)
        }
    }

    @objc private func recentTapped(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onPickRecent?(URL(fileURLWithPath: path))
    }

    func showInfo(_ i: ShotInfo?) {
        guard let i else { infoLabel.stringValue = ""; return }
        let exposure = [i.shutter, i.aperture, i.iso].filter { !$0.isEmpty }.joined(separator: "  ")
        infoLabel.stringValue = [i.camera, i.lens, [i.focal, exposure].filter { !$0.isEmpty }.joined(separator: "  "), i.date]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// 도구 탭 내용을 담는 칸. 내용 크기가 바깥(사이드바·창)으로 번지지 않게 프레임으로만 맞춘다.
final class TabHostView: NSView {
    override func layout() {
        super.layout()
        for v in subviews where v.frame != bounds { v.frame = bounds }
    }
}
