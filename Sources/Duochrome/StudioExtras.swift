import AppKit

// MARK: - 사진 탭, 배치 도구 옵션, 색 조정 프리셋 보기

/// 스크롤을 스스로 가진 옵션 내용 (옵션 패널이 다시 스크롤로 감싸지 않는다)
protocol SelfScrollingOptions {}

/// 캔버스 아래 떠 있는 사진 탭 (여러 사진을 열어 두고 오간다)
final class StudioTabsBar: NSView {
    var onPick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        StudioStyle.floating(self)
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ names: [String], current: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = names.count < 2
        for (i, n) in names.enumerated() {
            let tab = NSStackView()
            tab.spacing = 2
            tab.wantsLayer = true
            tab.layer?.cornerRadius = 6
            tab.layer?.backgroundColor = (i == current ? NSColor.controlAccentColor.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(0.06)).cgColor
            tab.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
            let b = NSButton(title: n, target: self, action: #selector(pick(_:)))
            b.isBordered = false
            b.tag = i
            b.font = .systemFont(ofSize: 11, weight: i == current ? .semibold : .regular)
            b.lineBreakMode = .byTruncatingMiddle
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 130).isActive = true
            let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "탭 닫기")!, target: self, action: #selector(close(_:)))
            x.isBordered = false
            x.tag = i
            x.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
            x.contentTintColor = .tertiaryLabelColor
            x.toolTip = "탭 닫기"
            tab.addArrangedSubview(b); tab.addArrangedSubview(x)
            stack.addArrangedSubview(tab)
        }
    }

    @objc private func pick(_ b: NSButton) { onPick?(b.tag) }
    @objc private func close(_ b: NSButton) { onClose?(b.tag) }
}

extension MainWindowController {
    /// 연 사진을 탭 목록에 넣는다 (show에서 부른다, 12개까지)
    func rememberTab(_ item: PhotoItem) {
        var t = studioTabs.filter { $0 !== item }
        if let i = studioTabs.firstIndex(where: { $0 === item }) { t.insert(item, at: min(i, t.count)) } else { t.append(item) }
        if t.count > 12 { t.removeFirst(t.count - 12) }
        studioTabs = t
        reloadTabs()
    }

    func reloadTabs() {
        studioMode.tabs.reload(studioTabs.map(\.name), current: studioTabs.firstIndex { $0 === photoItem } ?? -1)
        studioMode.updateCanvasInsets()
    }

    func pickTab(_ i: Int) {
        guard studioTabs.indices.contains(i) else { return }
        show(studioTabs[i])
    }

    func closeTab(_ i: Int) {
        guard studioTabs.indices.contains(i) else { return }
        let wasCurrent = studioTabs[i] === photoItem
        studioTabs.remove(at: i)
        if wasCurrent, !studioTabs.isEmpty { show(studioTabs[min(i, studioTabs.count - 1)]) }
        reloadTabs()
    }
}

/// 배치 도구 옵션: 고른 이미지·글자·모양 레이어의 크기·회전·가운데 맞추기, 자유 변형
final class ArrangeOptionsView: NSStackView {
    weak var host: MainWindowController?
    private let scale = SliderRow(label: "크기", min: 5, max: 400, format: "%.0f%%", defaultValue: 100)
    private let rotation = SliderRow(label: "회전", min: -180, max: 180, format: "%.0f°", defaultValue: 0)
    private let info = NSTextField(wrappingLabelWithString: "")
    /// 끌기를 시작할 때의 레이어 (크기·회전은 이것 기준)
    private var base: AdjustLayer?

    init(host: MainWindowController) {
        self.host = host
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let title = NSTextField(labelWithString: "배치")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        scale.onChange = { [weak self] v, d in self?.transform(scale: v / 100, rotation: nil, dragging: d) }
        rotation.onChange = { [weak self] v, d in self?.transform(scale: nil, rotation: v, dragging: d) }
        func button(_ t: String, _ a: Selector) -> NSButton { let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .appPush; b.controlSize = .small; return b }
        let row1 = NSStackView(views: [button("가로 가운데", #selector(centerH)), button("세로 가운데", #selector(centerV))])
        let row2 = NSStackView(views: [button("자유 변형 (⌘T)", #selector(freeTransform))])
        let hint = NSTextField(wrappingLabelWithString: "캔버스에서 끌어 옮깁니다. 스냅을 켜면 안내선·가장자리·가운데에 붙습니다(⇧⌘;).")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        for v in [title, info, scale, rotation, row1, row2, hint] as [NSView] {
            addArrangedSubview(v)
            if v is SliderRow || v === hint || v === info { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var target: (Int, AdjustLayer)? {
        guard let h = host, let s = h.photo?.settings, let id = h.layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return nil }
        let l = s.layers[i]
        return l.isImage || l.isText || l.kind == "shape" ? (i, l) : nil
    }

    func sync() {
        base = nil
        scale.value = 100
        if let (_, l) = target {
            rotation.value = l.image?.rotation ?? l.text?.rotation ?? 0
            info.stringValue = "\(l.name) — \(l.isImage ? "이미지" : l.isText ? "글자" : "모양") 레이어"
        } else {
            rotation.value = 0
            info.stringValue = "옮길 이미지·글자·모양 레이어를 왼쪽 목록에서 고르세요."
        }
        for v in [scale, rotation] { v.alphaValue = target == nil ? 0.4 : 1 }
    }

    /// 크기·회전: 끌기 시작한 레이어 기준으로 (모양은 가운데를 중심으로 점을 옮긴다)
    private func transform(scale k: Double?, rotation deg: Double?, dragging: Bool) {
        guard let h = host, var s = h.photo?.settings, let (i, cur) = target else { return }
        guard !cur.locked else { NSSound.beep(); return }
        if base == nil { base = cur }
        guard let b = base else { return }
        var l = b
        if var im = b.image {
            if let k { im.width = b.image!.width * k; im.height = b.image!.height.map { $0 * k } }
            if let deg { im.rotation = deg }
            l.image = im
        }
        if var t = b.text {
            if let k { t.size = b.text!.size * k; t.boxWidth = b.text!.boxWidth.map { $0 * k }; t.boxHeight = b.text!.boxHeight.map { $0 * k } }
            if let deg { t.rotation = deg }
            l.text = t
        }
        if var v = b.vector {
            let c = CGPoint(x: v.path.bounds.midX, y: v.path.bounds.midY)
            let kk = k ?? 1
            let r = CGFloat(deg ?? 0) * .pi / 180
            func f(_ x: Double, _ y: Double) -> (Double, Double) {
                let dx = (CGFloat(x) - c.x) * CGFloat(kk), dy = (CGFloat(y) - c.y) * CGFloat(kk)
                return (Double(c.x + dx * cos(r) - dy * sin(r)), Double(c.y + dx * sin(r) + dy * cos(r)))
            }
            for j in v.path.anchors.indices {
                var an = v.path.anchors[j]
                (an.x, an.y) = f(an.x, an.y); (an.inX, an.inY) = f(an.inX, an.inY); (an.outX, an.outY) = f(an.outX, an.outY)
                v.path.anchors[j] = an
            }
            if let k { v.strokeWidth = b.vector!.strokeWidth * k }
            l.vector = v
        }
        s.layers[i] = l
        h.apply(s, dragging: dragging)
        if !dragging { base = nil; if k != nil { scale.value = 100 } }
    }

    private func center(horizontal: Bool) {
        guard let h = host, let doc = h.photo, var s = h.photo?.settings, let (i, l) = target, !l.locked else { NSSound.beep(); return }
        let mid = doc.toNative(CGPoint(x: doc.pixelSize.width / 2, y: doc.pixelSize.height / 2))
        if var im = l.image { if horizontal { im.cx = Double(mid.x) } else { im.cy = Double(mid.y) }; s.layers[i].image = im }
        else if var v = l.vector {
            let d = horizontal ? Double(mid.x - v.path.bounds.midX) : Double(mid.y - v.path.bounds.midY)
            for j in v.path.anchors.indices {
                var an = v.path.anchors[j]
                if horizontal { an.x += d; an.inX += d; an.outX += d } else { an.y += d; an.inY += d; an.outY += d }
                v.path.anchors[j] = an
            }
            s.layers[i].vector = v
        } else if var t = l.text {
            // 글자는 가운데 정렬로 바꿔 기준점을 가운데에
            if horizontal { t.align = 1; t.x = Double(mid.x) } else { t.y = Double(mid.y) }
            s.layers[i].text = t
        }
        h.replaceSettings(s, recordUndo: true, label: horizontal ? "가로 가운데" : "세로 가운데")
    }

    @objc private func centerH() { center(horizontal: true) }
    @objc private func centerV() { center(horizontal: false) }
    @objc private func freeTransform() { host?.freeTransform(nil) }
}

/// 색 조정 도구 위: 저장한 스타일을 지금 사진에 건 작은 미리보기. 누르면 건다
final class StylePresetsView: NSView {
    weak var host: MainWindowController?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var cache: [String: NSImage] = [:]
    private var cacheKey = ""

    init(host: MainWindowController) {
        self.host = host
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "프리셋")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.spacing = 8
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        scroll.documentView = stack
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.heightAnchor.constraint(equalToConstant: 88),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 스타일 이름마다 미리보기 칸 (그림은 한 칸씩 차례로 그린다)
    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let names = MainWindowController.styleNames()
        guard let h = host, let doc = h.photo else { return }
        let key = doc.url.path + "|" + ((try? JSONEncoder().encode(doc.settings)).map { String($0.hashValue) } ?? "")
        if key != cacheKey { cache = [:]; cacheKey = key }
        if names.isEmpty {
            let t = NSTextField(labelWithString: "저장한 스타일이 없습니다 (사진 > 스타일 > 저장)")
            t.font = .systemFont(ofSize: 11); t.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(t)
            return
        }
        for n in names {
            let b = NSButton(title: n, image: cache[n] ?? NSImage(size: NSSize(width: 96, height: 64)), target: self, action: #selector(pick(_:)))
            b.imagePosition = .imageAbove
            b.isBordered = false
            b.font = .systemFont(ofSize: 10)
            b.identifier = NSUserInterfaceItemIdentifier(n)
            b.widthAnchor.constraint(equalToConstant: 100).isActive = true
            stack.addArrangedSubview(b)
        }
        renderNext(names)
    }

    private func renderNext(_ names: [String]) {
        guard let n = names.first(where: { cache[$0] == nil }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let img = self.host?.stylePreview(n) else { return }
            self.cache[n] = img
            (self.stack.arrangedSubviews.first { $0.identifier?.rawValue == n } as? NSButton)?.image = img
            self.renderNext(names)
        }
    }

    @objc private func pick(_ b: NSButton) {
        guard let n = b.identifier?.rawValue else { return }
        host?.applyStyle(named: n, strength: 1)
    }
}

/// 색 조정 도구 옵션: 위에 프리셋, 아래에 조정 패널 (조정 패널은 스스로 스크롤한다)
final class AdjustOptionsContainer: NSView, SelfScrollingOptions {
    let presets: StylePresetsView
    init(host: MainWindowController) {
        presets = StylePresetsView(host: host)
        super.init(frame: .zero)
        presets.translatesAutoresizingMaskIntoConstraints = false
        addSubview(presets)
        NSLayoutConstraint.activate([
            presets.topAnchor.constraint(equalTo: topAnchor),
            presets.leadingAnchor.constraint(equalTo: leadingAnchor),
            presets.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 조정 패널을 (대량 보정에서 옮겨) 아래에 붙인다
    func attach(_ inspector: NSView) {
        presets.reload()
        guard inspector.superview !== self else { return }
        inspector.removeFromSuperview()
        inspector.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inspector)
        NSLayoutConstraint.activate([
            inspector.topAnchor.constraint(equalTo: presets.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: trailingAnchor),
            inspector.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

extension MainWindowController {
    /// 스타일을 건 모습의 작은 그림 (지금 사진, 가이드 배율)
    func stylePreview(_ name: String) -> NSImage? {
        guard let doc = photo,
              let data = try? Data(contentsOf: Self.stylesFolder.appendingPathComponent("\(name).json")),
              let style = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var dict = settingsDict(doc.settings)
        for (k, v) in style { dict[k] = v }
        guard let d2 = try? JSONSerialization.data(withJSONObject: dict), let s = try? JSONDecoder().decode(DevelopSettings.self, from: d2) else { return nil }
        let saved = doc.settings, draft = doc.draft
        doc.settings = s
        let img = doc.image(scale: Develop.guideScale)
        doc.settings = saved; doc.draft = draft
        let k = 192 / max(img.extent.width, img.extent.height)
        let small = img.transformed(by: .init(scaleX: k, y: k))
        guard let cg = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: Render.displaySpace) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}
