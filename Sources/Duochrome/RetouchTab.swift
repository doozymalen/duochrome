import AppKit

/// 새로 찍을 리터칭 점의 설정. 사진마다가 아니라 도구 설정이라 앱 전체에 한 벌이다.
struct RetouchBrush {
    var kind: RetouchSpot.Kind = .heal
    /// 원본 픽셀 기준 반지름.
    var radius: Double = 40
    var feather: Double = 0.5
    var opacity: Double = 1
    /// 패치 도구: 끌면 올가미가 된다.
    var patch = false

    static var saved: RetouchBrush {
        let d = UserDefaults.standard
        var b = RetouchBrush()
        if d.object(forKey: "brush.radius") != nil {
            b.kind = d.string(forKey: "brush.kind") == "clone" ? .clone : .heal
            b.radius = d.double(forKey: "brush.radius")
            b.feather = d.double(forKey: "brush.feather")
            b.opacity = d.double(forKey: "brush.opacity")
            b.patch = d.bool(forKey: "brush.patch")
        }
        return b
    }

    func save() {
        let d = UserDefaults.standard
        d.set(kind.rawValue, forKey: "brush.kind")
        d.set(radius, forKey: "brush.radius")
        d.set(feather, forKey: "brush.feather")
        d.set(opacity, forKey: "brush.opacity")
        d.set(patch, forKey: "brush.patch")
    }
}

/// 리터칭 탭: 복구 브러시·복제 도장, 크기·부드러움·불투명도, 점 목록.
final class RetouchTabController: NSViewController {
    var brush = RetouchBrush.saved {
        didSet {
            brush.save()
            onBrushChange?(brush)
            if isViewLoaded { syncBrush() }   // 코드에서 바꿔도 패널이 따라오게
        }
    }
    var onBrushChange: ((RetouchBrush) -> Void)?
    var onRemoveLast: (() -> Void)?
    var onRemoveAll: (() -> Void)?
    var onRemoveSelected: (() -> Void)?

    private let kind = NSSegmentedControl(labels: ["복구 브러시", "복제 도장", "패치"], trackingMode: .selectOne, target: nil, action: nil)
    private let size = SliderRow(label: "크기 (반지름, 원본 픽셀)", min: 4, max: 400, format: "%.0f px", defaultValue: 40)
    private let feather = SliderRow(label: "가장자리 부드러움", min: 0, max: 1, format: "%.0f", display: 100, defaultValue: 0.5)
    private let opacity = SliderRow(label: "불투명도", min: 0, max: 1, format: "%.0f%%", display: 100, defaultValue: 1)
    private let countLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let tool = Card(title: "브러시")
        kind.segmentDistribution = .fillEqually
        kind.target = self
        kind.action = #selector(kindChanged)
        for v in [kind, size, feather, opacity] as [NSView] {
            tool.body.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: tool.body.widthAnchor).isActive = true
        }
        size.onChange = { [weak self] v, _ in self?.brush.radius = v }
        feather.onChange = { [weak self] v, _ in self?.brush.feather = v }
        opacity.onChange = { [weak self] v, _ in self?.brush.opacity = v }
        let hint = NSTextField(wrappingLabelWithString:
            "리터칭 도구(Q)로 사진을 누르면 점이 생깁니다. 패치는 고칠 곳을 올가미로 두르면 닮은 곳에서 가져와 둘레에 맞추고, 초록 올가미를 끌어 원본 자리를 바꿉니다. 원본 자리는 결이 가장 닮은 곳으로 자동으로 고르고, 초록 원을 끌어 옮길 수 있습니다. 흰 원을 끌면 점이 움직이고, 고른 점은 Delete로 지웁니다. 복구 브러시는 둘레 밝기와 색에 맞추고, 복제 도장은 그대로 옮깁니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        tool.body.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: tool.body.widthAnchor).isActive = true

        let list = Card(title: "리터칭 점")
        countLabel.font = .systemFont(ofSize: 12)
        let last = NSButton(title: "마지막 점", target: self, action: #selector(removeLast))
        let sel = NSButton(title: "고른 점", target: self, action: #selector(removeSelected))
        let all = NSButton(title: "모두", target: self, action: #selector(removeAll))
        last.toolTip = "마지막 점 지우기"; sel.toolTip = "고른 점 지우기"; all.toolTip = "모든 점 지우기"
        for b in [last, sel, all] { b.controlSize = .small; b.bezelStyle = .appPush }
        let trash = NSImageView(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "지우기")!)
        trash.contentTintColor = .tertiaryLabelColor
        let buttons = NSStackView(views: [trash, last, sel, all])
        buttons.spacing = 6
        buttons.distribution = .gravityAreas
        list.body.addArrangedSubview(countLabel)
        list.body.addArrangedSubview(buttons)

        for card in [tool, list] {
            card.hideToggle()
            card.applyCollapse()
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view = scroll
        syncBrush()
        showCount(0)
    }

    private func syncBrush() {
        kind.selectedSegment = brush.patch ? 2 : (brush.kind == .heal ? 0 : 1)
        size.value = brush.radius
        feather.value = brush.feather
        opacity.value = brush.opacity
    }

    func showCount(_ n: Int) { countLabel.stringValue = n == 0 ? "아직 없습니다" : "\(n)개" }

    @objc private func kindChanged() {
        var b = brush
        b.patch = kind.selectedSegment == 2
        if !b.patch { b.kind = kind.selectedSegment == 0 ? .heal : .clone }
        brush = b
    }
    @objc private func removeLast() { onRemoveLast?() }
    @objc private func removeAll() { onRemoveAll?() }
    @objc private func removeSelected() { onRemoveSelected?() }
}

/// 캔버스 위 리터칭 층. 점마다 대상(흰 원)과 원본(초록 점선 원)을 잇는다.
final class RetouchOverlayView: NSView {
    weak var canvas: CanvasView?
    var spots: [RetouchSpot] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }
    var brushRadius: Double = 40
    /// 원본 좌표 ↔ 뷰 좌표.
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// 빈 곳을 눌렀을 때 (원본 좌표).
    var onAdd: ((CGPoint) -> Void)?
    /// 빈 곳에서 끌었을 때: 붓질 (원본 좌표 점들).
    var onAddStroke: (([CGPoint]) -> Void)?
    /// 패치 도구면 끈 자리가 올가미가 된다.
    var patchMode = false
    var onAddPatch: (([CGPoint]) -> Void)?
    private var drawing: [CGPoint] = []   // 뷰 좌표
    /// 점을 옮겼을 때 (몇 번째, 새 값, 끄는 중인지).
    var onEdit: ((Int, RetouchSpot, Bool) -> Void)?
    var onDelete: ((Int) -> Void)?

    private enum Grab {
        case target(Int), source(Int)
        var index: Int { switch self { case .target(let i), .source(let i): return i } }
    }
    private var grab: Grab?
    private var grabOffset = CGPoint.zero
    private var hover: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    /// 원본 반지름을 뷰 길이로 (형태 보정의 배율까지 반영하려고 실제로 옮겨서 잰다).
    private func viewRadius(_ s: RetouchSpot) -> CGFloat {
        guard let toView else { return 0 }
        let a = toView(s.target), b = toView(CGPoint(x: s.targetX + s.radius, y: s.targetY))
        return hypot(b.x - a.x, b.y - a.y)
    }

    private func polyline(_ pts: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pts[0])
        for q in pts.dropFirst() { p.line(to: q) }
        if pts.count == 1 { p.line(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }

    /// 뷰 좌표 점에서 획까지 거리.
    private func distance(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return hypot(p.x - pts[0].x, p.y - pts[0].y) }
        var best = CGFloat.greatestFiniteMagnitude
        for (a, b) in zip(pts, pts.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-6)))
            best = min(best, hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t)))
        }
        return best
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let toView else { return }
        if drawing.count > 1, patchMode {
            let p = polyline(drawing)
            p.close()
            p.lineWidth = 1.5
            p.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            p.stroke()
            NSColor.white.withAlphaComponent(0.12).setFill()
            p.fill()
        } else if drawing.count > 1 {
            let p = polyline(drawing)
            p.lineWidth = max(CGFloat(brushRadius) * (canvas?.zoom ?? 1) * 2, 2)
            NSColor.white.withAlphaComponent(0.35).setStroke()
            p.stroke()
        }
        for (i, s) in spots.enumerated() where s.isPatch {
            let tp = polyline(s.points.map(toView)); tp.close()
            let sp = polyline(s.points.map { toView(CGPoint(x: $0.x + s.offset.x, y: $0.y + s.offset.y)) }); sp.close()
            sp.lineWidth = 1.5
            sp.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.systemGreen.setStroke()
            sp.stroke()
            tp.lineWidth = i == selected ? 2.5 : 1.5
            (i == selected ? NSColor.controlAccentColor : NSColor.white).setStroke()
            tp.stroke()
        }
        for (i, s) in spots.enumerated() where s.isStroke && !s.isPatch {
            let r = viewRadius(s)
            let tp = s.points.map(toView)
            let sp = s.points.map { toView(CGPoint(x: $0.x + s.offset.x, y: $0.y + s.offset.y)) }
            let src = polyline(sp)
            src.lineWidth = 1.5
            src.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.systemGreen.setStroke()
            src.stroke()
            let body = polyline(tp)
            body.lineWidth = r * 2
            (i == selected ? NSColor.controlAccentColor : NSColor.white).withAlphaComponent(0.3).setStroke()
            body.stroke()
            let spine = polyline(tp)
            spine.lineWidth = 1.5
            (i == selected ? NSColor.controlAccentColor : NSColor.white).setStroke()
            spine.stroke()
        }
        for (i, s) in spots.enumerated() where !s.isStroke {
            let t = toView(s.target), src = toView(s.source), r = viewRadius(s)
            let line = NSBezierPath()
            line.move(to: src); line.line(to: t)
            line.lineWidth = 1
            NSColor.white.withAlphaComponent(0.5).setStroke()
            line.stroke()
            let so = NSBezierPath(ovalIn: CGRect(x: src.x - r, y: src.y - r, width: r * 2, height: r * 2))
            so.setLineDash([4, 3], count: 2, phase: 0)
            so.lineWidth = 1.5
            NSColor.systemGreen.setStroke()
            so.stroke()
            let to = NSBezierPath(ovalIn: CGRect(x: t.x - r, y: t.y - r, width: r * 2, height: r * 2))
            to.lineWidth = i == selected ? 2.5 : 1.5
            (i == selected ? NSColor.controlAccentColor : NSColor.white).setStroke()
            to.stroke()
        }
        // 브러시 미리보기.
        if let h = hover, grab == nil, !patchMode, let fromView {
            let p = fromView(h)
            let probe = RetouchSpot(targetX: p.x, targetY: p.y, sourceX: p.x, sourceY: p.y, radius: brushRadius)
            let r = viewRadius(probe)
            let c = NSBezierPath(ovalIn: CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2))
            c.lineWidth = 1
            NSColor.white.withAlphaComponent(0.6).setStroke()
            c.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let toView, let fromView else { return }
        // 위에 그린 점부터 (나중 점이 위).
        for (i, s) in spots.enumerated().reversed() {
            let r = max(viewRadius(s), 6)
            if s.isPatch {
                let tp = s.points.map(toView)
                let sp = s.points.map { toView(CGPoint(x: $0.x + s.offset.x, y: $0.y + s.offset.y)) }
                if Self.inside(p, sp) { grab = .source(i); selected = i; grabOffset = .zero; lastDrag = fromView(p); return }
                if Self.inside(p, tp) { grab = .target(i); selected = i; grabOffset = .zero; lastDrag = fromView(p); return }
                continue
            }
            if s.isStroke {
                let tp = s.points.map(toView)
                let sp = s.points.map { toView(CGPoint(x: $0.x + s.offset.x, y: $0.y + s.offset.y)) }
                if distance(p, sp) <= max(r * 0.6, 6) {
                    grab = .source(i); selected = i; grabOffset = .zero; lastDrag = fromView(p); return
                }
                if distance(p, tp) <= r {
                    grab = .target(i); selected = i; grabOffset = .zero; lastDrag = fromView(p); return
                }
                continue
            }
            let t = toView(s.target), src = toView(s.source)
            if hypot(p.x - src.x, p.y - src.y) <= r {
                grab = .source(i); selected = i; grabOffset = CGPoint(x: src.x - p.x, y: src.y - p.y); return
            }
            if hypot(p.x - t.x, p.y - t.y) <= r {
                grab = .target(i); selected = i; grabOffset = CGPoint(x: t.x - p.x, y: t.y - p.y); return
            }
        }
        grab = nil
        drawing = [p]
    }

    private var lastDrag: CGPoint?

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if grab == nil, !drawing.isEmpty {
            // 반지름의 1/3 간격으로만 점을 남긴다 (올가미는 3pt마다).
            let step = patchMode ? 3 : max(CGFloat(brushRadius) * (canvas?.zoom ?? 1) / 3, 2)
            if let last = drawing.last, hypot(p.x - last.x, p.y - last.y) >= step { drawing.append(p); needsDisplay = true }
            return
        }
        guard let grab, let fromView else { return }
        if spots.indices.contains(grab.index), spots[grab.index].isStroke {
            // 획은 끈 거리만큼 통째로 옮긴다 (원본 자리를 끌면 원본만).
            let q = fromView(p)
            guard let last = lastDrag else { return }
            let d = CGPoint(x: q.x - last.x, y: q.y - last.y)
            lastDrag = q
            var s = spots[grab.index]
            switch grab {
            case .target: s.move(by: d)
            case .source: s.sourceX += d.x; s.sourceY += d.y
            }
            spots[grab.index] = s
            onEdit?(grab.index, s, true)
            return
        }
        let q = fromView(CGPoint(x: p.x + grabOffset.x, y: p.y + grabOffset.y))
        switch grab {
        case .target(let i):
            // 대상과 원본을 함께 옮긴다 (거리를 지킨다).
            var s = spots[i]
            let dx = q.x - s.targetX, dy = q.y - s.targetY
            s.targetX += dx; s.targetY += dy; s.sourceX += dx; s.sourceY += dy
            spots[i] = s
            onEdit?(i, s, true)
        case .source(let i):
            var s = spots[i]
            s.source = q
            spots[i] = s
            onEdit?(i, s, true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if grab == nil, !drawing.isEmpty, let fromView {
            let pts = drawing
            drawing = []
            needsDisplay = true
            // 거의 안 끌었으면 점 하나.
            let len = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            if patchMode {
                if len >= 20, pts.count >= 3 { onAddPatch?(pts.map(fromView)) }
            } else if len < 6 { onAdd?(fromView(pts[0])) } else { onAddStroke?(pts.map(fromView)) }
            return
        }
        if let grab {
            switch grab {
            case .target(let i), .source(let i): onEdit?(i, spots[i], false)
            }
        }
        grab = nil
    }

    /// 점이 다각형 안인지 (짝홀 규칙).
    static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        guard poly.count >= 3 else { return false }
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    override func keyDown(with event: NSEvent) {
        // Delete(51), 앞으로 지우기(117)
        if [51, 117].contains(event.keyCode), let i = selected {
            selected = nil
            onDelete?(i)
        } else {
            super.keyDown(with: event)
        }
    }
}
