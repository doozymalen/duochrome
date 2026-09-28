import AppKit

/// 조정값 묶음 ("조정 복사/적용" 창의 갈래). 설정 JSON의 최상위 키로 나눈다.
enum AdjustGroup: String, CaseIterable {
    case whiteBalance, exposure, hdr, clarity, levelsCurves, color, detail, lens, grain, geometry, retouch, layers

    var title: String {
        switch self {
        case .whiteBalance: "화이트 밸런스"
        case .exposure: "노출·대비·밝기·채도·기본 커브"
        case .hdr: "하이 다이내믹 레인지"
        case .clarity: "클래리티·구조·디헤이즈"
        case .levelsCurves: "레벨·커브"
        case .color: "컬러 밸런스·컬러 에디터·흑백"
        case .detail: "샤프닝·노이즈·모아레"
        case .lens: "렌즈 보정·비네팅"
        case .grain: "필름 그레인"
        case .geometry: "형태 (회전·키스톤·크롭)"
        case .retouch: "리터칭 점"
        case .layers: "조정 레이어"
        }
    }

    var keys: [String] {
        switch self {
        case .whiteBalance: ["temperature", "tint"]
        case .exposure: ["exposure", "contrast", "brightness", "saturation", "filmCurve", "filmContrast", "look", "intensity"]
        case .hdr: ["highlight", "shadow", "white", "black", "highlightRecoveryOn"]
        case .clarity: ["clarity", "structure", "dehaze", "clarityMethod", "dehazeHue", "dehazeTint"]
        case .levelsCurves: ["levelInBlack", "levelInWhite", "levelGamma", "levelOutBlack", "levelOutWhite", "levelsRGB", "curves"]
        case .color: ["color", "colorEditor"]
        case .detail: ["sharpness", "detail", "lumaNoise", "colorNoise", "moire", "sharpenAmount", "sharpenRadius",
                       "sharpenThreshold", "sharpenHalo", "hotPixels"]
        case .lens: ["lensCorrection", "vignette", "lensDistortion", "lensCA", "lensCABlue", "lensVignette", "lensSharpFalloff"]
        case .grain: ["grainAmount", "grainSize", "grainType"]
        case .geometry: ["quarterTurns", "flipH", "flipV", "rotation", "keystoneV", "keystoneH", "keystoneAspect", "crop", "cropAspect"]
        case .retouch: ["spots"]
        case .layers: ["layers"]
        }
    }

    /// 여러 사진에 붙일 때 기본으로 빼는 것 (사진마다 달라서).
    var defaultOn: Bool { ![.geometry, .retouch, .layers].contains(self) }

    static func keys(_ groups: Set<AdjustGroup>) -> Set<String> { Set(groups.flatMap(\.keys)) }

    /// 두 설정 사이에 바뀐 갈래 (작업 내역 이름에 쓴다).
    static func changed(_ a: [String: Any], _ b: [String: Any]) -> [AdjustGroup] {
        func same(_ k: String) -> Bool {
            switch (a[k], b[k]) {
            case (nil, nil): return true
            case let (x?, y?): return (x as AnyObject).isEqual(y)
            default: return false
            }
        }
        return allCases.filter { g in g.keys.contains { !same($0) } }
    }
}

/// "조정 적용…" 창: 붙일 갈래를 고른다. 고른 것은 다음에도 기억한다.
final class PasteGroupsSheet: NSWindowController {
    var onApply: ((Set<AdjustGroup>) -> Void)?
    private var boxes: [(AdjustGroup, NSButton)] = []

    convenience init(title: String, source: String?) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: w)
        let saved = Set((UserDefaults.standard.stringArray(forKey: "pasteGroups") ?? []).compactMap(AdjustGroup.init))
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 15, weight: .semibold)
        let sub = NSTextField(labelWithString: source.map { "복사한 사진: \($0)" } ?? "복사한 조정이 없습니다")
        sub.textColor = .secondaryLabelColor
        var views: [NSView] = [head, sub]
        for g in AdjustGroup.allCases {
            let b = NSButton(checkboxWithTitle: g.title, target: nil, action: nil)
            b.state = (saved.isEmpty ? g.defaultOn : saved.contains(g)) ? .on : .off
            boxes.append((g, b))
            views.append(b)
        }
        let all = NSButton(title: "모두", target: self, action: #selector(checkAll))
        let none = NSButton(title: "없음", target: self, action: #selector(checkNone))
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "적용", target: self, action: #selector(apply))
        ok.keyEquivalent = "\r"
        views.append(NSStackView(views: [all, none, NSView(), cancel, ok]))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        views.last!.widthAnchor.constraint(equalToConstant: 340).isActive = true
        w.contentView = stack
    }

    @objc private func checkAll() { boxes.forEach { $0.1.state = .on } }
    @objc private func checkNone() { boxes.forEach { $0.1.state = .off } }
    @objc private func cancel() { close() }

    override func close() {
        if let w = window, let p = w.sheetParent { p.endSheet(w) } else { super.close() }
    }

    @objc private func apply() {
        let groups = Set(boxes.filter { $0.1.state == .on }.map(\.0))
        UserDefaults.standard.set(groups.map(\.rawValue), forKey: "pasteGroups")
        close()
        onApply?(groups)
    }
}

// MARK: - 작업 내역

/// 되돌리기 목록을 그대로 보여 준다. 누르면 그 시점으로 간다.
final class HistoryTabController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [String] = [] { didSet { table.reloadData(); selectCurrent() } }
    /// 지금 상태가 몇 번째 항목인지.
    var current = 0 { didSet { selectCurrent() } }
    var onJump: ((Int) -> Void)?
    /// 스냅샷 이름들 (목록 맨 위에 따로 보인다)
    var snapshots: [String] = [] { didSet { table.reloadData(); selectCurrent() } }
    var onSnapshot: ((Int) -> Void)?
    var onMakeSnapshot: (() -> Void)?
    var onDeleteSnapshot: ((Int) -> Void)?
    private let table = NSTableView()
    private var syncing = false

    override func loadView() {
        let col = NSTableColumn(identifier: .init("h"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear   // 유리 패널이 비치게
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let title = sectionTitle("작업 내역")
        title.toolTip = "누르면 그 시점으로 돌아갑니다"
        let snap = NSButton(title: "스냅샷 만들기", target: self, action: #selector(makeSnap))
        snap.bezelStyle = .appPush
        snap.controlSize = .small
        let menu = NSMenu()
        menu.addItem(withTitle: "이 스냅샷 지우기", action: #selector(deleteSnap), keyEquivalent: "").target = self
        table.menu = menu
        let root = NSView()
        for v in [title, snap, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            snap.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            snap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    @objc private func makeSnap() { onMakeSnapshot?() }
    @objc private func deleteSnap() {
        let r = table.clickedRow
        guard r >= 0, r < snapshots.count else { NSSound.beep(); return }
        onDeleteSnapshot?(r)
    }

    private func selectCurrent() {
        guard isViewLoaded, entries.indices.contains(current) else { return }
        syncing = true
        table.selectRowIndexes([snapshots.count + current], byExtendingSelection: false)
        table.scrollRowToVisible(snapshots.count + current)
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshots.count + entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row < snapshots.count {
            let t = NSTextField(labelWithString: "◆ " + snapshots[row])
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .controlAccentColor
            return t
        }
        let i = row - snapshots.count
        let t = NSTextField(labelWithString: entries[i])
        t.font = .systemFont(ofSize: 12)
        // 되돌린 뒤의 (다시 실행할 수 있는) 항목은 흐리게.
        t.textColor = i > current ? .tertiaryLabelColor : .labelColor
        return t
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow >= 0 else { return }
        if table.selectedRow < snapshots.count { onSnapshot?(table.selectedRow); return }
        onJump?(table.selectedRow - snapshots.count)
    }
}
