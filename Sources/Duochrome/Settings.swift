import AppKit

/// App settings (UserDefaults). Changed in the Settings window, read by features here.
enum AppSettings {
    private static var d: UserDefaults { .standard }

    // General
    /// Startup mode: the library (grid view) unless chosen otherwise (-1 last used mode, otherwise an AppMode number)
    static var startMode: Int { get { d.object(forKey: "set.startMode") as? Int ?? AppMode.library.rawValue } set { d.set(newValue, forKey: "set.startMode") } }
    /// Default look for new photos: 1 camera-fitted, 0 Apple default
    static var defaultLook: Int { get { d.object(forKey: "set.defaultLook") as? Int ?? 0 } set { d.set(newValue, forKey: "set.defaultLook") } }
    static var snapEnabled: Bool { get { d.object(forKey: "set.snap") as? Bool ?? true } set { d.set(newValue, forKey: "set.snap") } }
    /// Snap distance (% of range)
    static var snapPercent: Double { get { d.object(forKey: "set.snapPercent") as? Double ?? 1.5 } set { d.set(newValue, forKey: "set.snapPercent") } }
    static var haptics: Bool { get { d.object(forKey: "set.haptics") as? Bool ?? true } set { d.set(newValue, forKey: "set.haptics") } }

    // Catalog
    static var catalogPath: String? { get { d.string(forKey: "set.catalogPath") } set { d.set(newValue, forKey: "set.catalogPath") } }
    static var recentCatalogs: [String] { get { d.stringArray(forKey: "set.recentCatalogs") ?? [] } set { d.set(newValue, forKey: "set.recentCatalogs") } }
    /// Backup interval: 0 off, 1 ask on quit, 2 every quit, 3 daily, 4 weekly, 5 monthly
    static var backupInterval: Int { get { d.object(forKey: "set.backupInterval") as? Int ?? 1 } set { d.set(newValue, forKey: "set.backupInterval") } }
    static var backupFolder: String {
        get { d.string(forKey: "set.backupFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Duochrome/Backups").path }
        set { d.set(newValue, forKey: "set.backupFolder") }
    }
    static var backupKeep: Int { get { d.object(forKey: "set.backupKeep") as? Int ?? 10 } set { d.set(newValue, forKey: "set.backupKeep") } }
    static var backupPreviews: Bool { get { d.bool(forKey: "set.backupPreviews") } set { d.set(newValue, forKey: "set.backupPreviews") } }
    static var lastBackup: Date? { get { d.object(forKey: "set.lastBackup") as? Date } set { d.set(newValue, forKey: "set.lastBackup") } }

    // Previews and cache
    static var previewSize: Int { get { d.object(forKey: "set.previewSize") as? Int ?? 2560 } set { d.set(newValue, forKey: "set.previewSize") } }
    /// 0 16-bit linear TIFF (default, ~40 MB each, ~130 ms to open), 1 10-bit HEIF (~0.4 MB each but slow to decode, ~750 ms)
    static var previewQuality: Int { get { d.object(forKey: "set.previewQuality") as? Int ?? 0 } set { d.set(newValue, forKey: "set.previewQuality") } }
    /// 0 all on import, 1 only when viewed
    static var previewWhen: Int { get { d.object(forKey: "set.previewWhen") as? Int ?? 0 } set { d.set(newValue, forKey: "set.previewWhen") } }
    static var previewWorkers: Int { get { d.object(forKey: "set.previewWorkers") as? Int ?? 2 } set { d.set(newValue, forKey: "set.previewWorkers") } }
    static var previewLimitGB: Int { get { d.object(forKey: "set.previewLimitGB") as? Int ?? 5 } set { d.set(newValue, forKey: "set.previewLimitGB") } }

    // Tethering
    static var tetherFolder: String? { get { d.string(forKey: "set.tetherFolder") } set { d.set(newValue, forKey: "set.tetherFolder") } }
    /// File naming rule: {날짜} {시각} {순번} {원래이름}
    static var tetherNaming: String { get { d.string(forKey: "set.tetherNaming") ?? "{원래이름}" } set { d.set(newValue, forKey: "set.tetherNaming") } }
}

/// Settings window (⌘,). Split by icon tabs at the top, like standard macOS.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    weak var host: MainWindowController?

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.title = "설정"
        self.init(window: w)
        for (title, symbol, make) in [
            ("일반", "gearshape", { SettingsPane.general() }),
            ("카탈로그", "books.vertical", { SettingsPane.catalog() }),
            ("미리보기", "photo.stack", { SettingsPane.previews() }),
            ("내보내기", "square.and.arrow.up", { SettingsPane.export() }),
            ("테더링", "camera", { SettingsPane.tether() }),
            ("AI", "sparkles", { SettingsPane.ai() }),
            ("단축키", "command", { SettingsPane.shortcuts() }),
        ] as [(String, String, () -> NSViewController)] {
            let vc = make()
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
    }

    func show(tab: Int? = nil) {
        if let tab, let tabs = contentViewController as? NSTabViewController, tabs.tabViewItems.indices.contains(tab) {
            tabs.selectedTabViewItemIndex = tab
        }
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Settings tab content. Each row: label (right-aligned) + control (macOS Settings window style).
enum SettingsPane {
    final class Pane: NSViewController {
        let grid = NSGridView()
        var actions: [SettingsAction] = []
        override func loadView() {
            grid.rowSpacing = 10
            grid.columnSpacing = 12
            grid.translatesAutoresizingMaskIntoConstraints = false
            let root = NSView()
            root.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
                grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
                grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -30),
                grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
                root.widthAnchor.constraint(equalToConstant: 620),
            ])
            view = root
        }

        func row(_ label: String, _ v: NSView, note: String? = nil) {
            _ = view
            let l = NSTextField(labelWithString: label.isEmpty ? "" : label + ":")
            l.alignment = .right
            var content: NSView = v
            if let note {
                let n = NSTextField(wrappingLabelWithString: note)
                n.font = .systemFont(ofSize: 11)
                n.textColor = .secondaryLabelColor
                n.preferredMaxLayoutWidth = 380
                let st = NSStackView(views: [v, n])
                st.orientation = .vertical
                st.alignment = .leading
                st.spacing = 4
                content = st
            }
            let r = grid.addRow(with: [l, content])
            r.rowAlignment = .firstBaseline
            grid.column(at: 0).xPlacement = .trailing
        }

        func separator() {
            _ = view
            let b = NSBox(); b.boxType = .separator
            let r = grid.addRow(with: [NSGridCell.emptyContentView, b])
            r.topPadding = 4; r.bottomPadding = 4
            b.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }

        func popup(_ items: [String], selected: Int, _ onChange: @escaping (Int) -> Void) -> NSPopUpButton {
            let p = NSPopUpButton()
            p.addItems(withTitles: items)
            p.selectItem(at: max(0, min(selected, items.count - 1)))
            let a = SettingsAction { onChange(p.indexOfSelectedItem) }
            actions.append(a)
            p.target = a; p.action = #selector(SettingsAction.fire)
            return p
        }

        func check(_ title: String, _ on: Bool, _ onChange: @escaping (Bool) -> Void) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = on ? .on : .off
            let a = SettingsAction { onChange(b.state == .on) }
            actions.append(a)
            b.target = a; b.action = #selector(SettingsAction.fire)
            return b
        }

        func button(_ title: String, _ onClick: @escaping () -> Void) -> NSButton {
            let a = SettingsAction(onClick)
            actions.append(a)
            return NSButton(title: title, target: a, action: #selector(SettingsAction.fire))
        }

        func folder(_ path: String, _ onChange: @escaping (String) -> Void) -> NSView {
            let label = NSTextField(labelWithString: path)
            label.lineBreakMode = .byTruncatingHead
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            let pick = button("바꾸기…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let u = p.url { label.stringValue = u.path; onChange(u.path) }
            }
            return NSStackView(views: [label, pick])
        }
    }

    static func general() -> NSViewController {
        let p = Pane()
        let modes = ["라이브러리 (격자 보기)", "마지막으로 쓴 모드", "대량 보정", "심화 보정", "테더링"]
        let modeValues = [AppMode.library.rawValue, -1, AppMode.edit.rawValue, AppMode.studio.rawValue, AppMode.tether.rawValue]
        p.row("시작할 때", p.popup(modes, selected: modeValues.firstIndex(of: AppSettings.startMode) ?? 0) { AppSettings.startMode = modeValues[$0] })
        // With no look tables at all there's nothing to choose (Apple default only)
        if Look.anyAvailable {
            p.row("새 사진 기본 모습", p.popup(["Apple 기본", "카메라 맞춤"], selected: AppSettings.defaultLook) { AppSettings.defaultLook = $0 },
                  note: "카메라 맞춤은 Looks 폴더에 보정표가 있는 카메라에만 걸리고, 없는 카메라는 Apple 기본으로 현상합니다. 이미 조정한 사진은 그대로입니다.")
        }
        p.separator()
        p.row("슬라이더", p.check("기본값 근처에서 달라붙기", AppSettings.snapEnabled) { AppSettings.snapEnabled = $0 })
        p.row("달라붙는 거리", p.popup(["좁게 (범위의 0.8%)", "보통 (1.5%)", "넓게 (3%)"],
                                     selected: [0.8, 1.5, 3].firstIndex(of: AppSettings.snapPercent) ?? 1) { AppSettings.snapPercent = [0.8, 1.5, 3][$0] })
        p.row("", p.check("달라붙을 때 트랙패드 촉각 피드백", AppSettings.haptics) { AppSettings.haptics = $0 })
        return p
    }

    static func catalog() -> NSViewController {
        let p = Pane()
        let path = AppSettings.catalogPath ?? Catalog.defaultURL.path
        let label = NSTextField(labelWithString: path)
        label.lineBreakMode = .byTruncatingHead
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        p.row("지금 카탈로그", label)
        p.row("", NSStackView(views: [
            p.button("다른 카탈로그 열기…") { SettingsWindowController.shared.host?.openCatalogPanel(nil) },
            p.button("새 카탈로그…") { SettingsWindowController.shared.host?.newCatalogPanel(nil) },
            p.button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
        ]), note: "카탈로그를 바꾸면 창을 다시 엽니다.")
        p.separator()
        p.row("백업", p.popup(["하지 않음", "끌 때마다 물어보기", "끌 때마다", "매일", "매주", "매달"],
                            selected: AppSettings.backupInterval) { AppSettings.backupInterval = $0 })
        p.row("백업 위치", p.folder(AppSettings.backupFolder) { AppSettings.backupFolder = $0 })
        p.row("보관 개수", p.popup(["3개", "5개", "10개", "20개", "모두"], selected: [3, 5, 10, 20, 0].firstIndex(of: AppSettings.backupKeep) ?? 2) {
            AppSettings.backupKeep = [3, 5, 10, 20, 0][$0]
        })
        p.row("", p.check("미리보기도 백업 (용량이 큽니다)", AppSettings.backupPreviews) { AppSettings.backupPreviews = $0 })
        let last = NSTextField(labelWithString: AppSettings.lastBackup.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "아직 없음")
        p.row("마지막 백업", NSStackView(views: [last, p.button("지금 백업") {
            SettingsWindowController.shared.host?.backupCatalogNow(nil)
            last.stringValue = AppSettings.lastBackup.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "아직 없음"
        }]))
        return p
    }

    static func previews() -> NSViewController {
        let p = Pane()
        p.row("미리보기 크기", p.popup(["긴 변 1680px", "긴 변 2560px", "긴 변 3840px"], selected: [1680, 2560, 3840].firstIndex(of: AppSettings.previewSize) ?? 1) {
            AppSettings.previewSize = [1680, 2560, 3840][$0]
        }, note: "크면 확대해도 원본을 덜 풀지만 용량이 늘어납니다.")
        p.row("품질", p.popup(["16비트 TIFF — 빠름 (한 장 약 40MB)", "10비트 HEIF — 작음 (한 장 약 0.4MB, 느림)"], selected: AppSettings.previewQuality) { AppSettings.previewQuality = $0 })
        p.row("만드는 때", p.popup(["가져올 때 모두", "볼 때만"], selected: AppSettings.previewWhen) { AppSettings.previewWhen = $0 })
        p.row("동시에 만들기", p.popup(["1장", "2장", "3장", "4장"], selected: AppSettings.previewWorkers - 1) { AppSettings.previewWorkers = $0 + 1 },
              note: "메모리 16GB 맥에서는 2장이 알맞습니다.")
        p.row("용량 한도", p.popup(["2 GB", "5 GB", "10 GB", "20 GB", "50 GB"], selected: [2, 5, 10, 20, 50].firstIndex(of: AppSettings.previewLimitGB) ?? 1) {
            AppSettings.previewLimitGB = [2, 5, 10, 20, 50][$0]
        }, note: "넘으면 오래 안 본 미리보기부터 지웁니다. 지워도 보정값은 안전하고, 다시 볼 때 새로 만듭니다.")
        p.row("", p.button("미리보기 모두 지우기") { SettingsWindowController.shared.host?.clearPreviews(nil) })
        return p
    }

    static func export() -> NSViewController {
        let p = Pane()
        var r = ExportRecipe.saved
        p.row("기본 폴더", p.folder(r.folder) { r.folder = $0; r.save() })
        p.row("기본 형식", p.popup(ExportRecipe.Format.allCases.map(\.title), selected: ExportRecipe.Format.allCases.firstIndex(of: r.format) ?? 0) {
            r.format = ExportRecipe.Format.allCases[$0]; r.save()
        })
        p.row("색 공간", p.popup(ExportRecipe.Space.allCases.map(\.title), selected: ExportRecipe.Space.allCases.firstIndex(of: r.space) ?? 0) {
            r.space = ExportRecipe.Space.allCases[$0]; r.save()
        })
        let mark = NSTextField(string: r.watermark)
        mark.placeholderString = "예: © doozymalen.com"
        mark.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let a = SettingsAction { r.watermark = mark.stringValue; r.save() }
        p.actions.append(a)
        mark.target = a; mark.action = #selector(SettingsAction.fire)
        p.row("기본 워터마크", mark, note: "내보내기 창에서 사진마다 바꿀 수 있습니다.")
        return p
    }

    static func tether() -> NSViewController {
        let p = Pane()
        p.row("세션 폴더", p.folder(AppSettings.tetherFolder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Duochrome/Tether").path) {
            AppSettings.tetherFolder = $0
        })
        let naming = NSTextField(string: AppSettings.tetherNaming)
        naming.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let a = SettingsAction { AppSettings.tetherNaming = naming.stringValue }
        p.actions.append(a)
        naming.target = a; naming.action = #selector(SettingsAction.fire)
        p.row("파일 이름", naming, note: "{날짜} {시각} {순번} {원래이름}을 쓸 수 있습니다. 예: {날짜}_{순번}")
        return p
    }

    static func ai() -> NSViewController {
        let p = Pane()
        p.row("무거운 AI 처리", p.popup(["코랩 L4 (추천)", "코랩 A100 (빠르지만 비쌈)", "이 맥 (느리고 품질 낮음)"], selected: AIRemote.current.rawValue) {
            UserDefaults.standard.set($0, forKey: "set.aiRemote"); AIEngineButton.refresh()
        }, note: "생성형 채우기·확장, 노이즈 제거, 2배 확대에 씁니다. 지우기와 선택 기능은 늘 이 맥에서 합니다. L4가 없으면 T4로, 코랩에 연결되지 않으면 이 맥에서 처리합니다.")
        p.row("자동으로 끄기", p.popup(["5분", "10분", "20분", "30분"], selected: [5, 10, 20, 30].firstIndex(of: ColabEngine.idleMinutes) ?? 1) {
            ColabEngine.idleMinutes = [5, 10, 20, 30][$0]
        }, note: "코랩은 켜져 있는 시간만큼 사용량이 줄어듭니다. 이 시간 동안 AI 일이 없으면 끄고, Duochrome을 닫을 때도 끕니다.")
        p.separator()
        let state = NSTextField(labelWithString: ColabEngine.hfToken == nil ? "없음" : "저장됨")
        state.textColor = .secondaryLabelColor
        let field = NSSecureTextField()
        field.placeholderString = "hf_로 시작하는 읽기 토큰"
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let save = p.button("저장") {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            ColabEngine.hfToken = v
            field.stringValue = ""
            state.stringValue = "저장됨"
        }
        let remove = p.button("지우기") { ColabEngine.hfToken = nil; state.stringValue = "없음" }
        p.row("허깅페이스 토큰", NSStackView(views: [field, save, remove]),
              note: "사진 생성 모델(플럭스 필)을 코랩에서 받는 데 씁니다. huggingface.co 설정 > 토큰에서 '읽기' 토큰을 만들어 붙여 넣으세요. 이 맥의 사용자 폴더(본인만 읽을 수 있는 파일)에만 저장되고, 코랩에는 파일로만 건넵니다.")
        p.row("", state)
        p.separator()
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        p.row("코랩 계정", NSStackView(views: [
            p.button("연결 확인·로그인") {
                status.stringValue = "확인 중… (처음이면 브라우저에 구글 로그인 창이 뜹니다)"
                DispatchQueue.global().async {
                    let r: String
                    do {
                        try ColabEngine.shared.login {
                            let a = NSAlert()
                            a.messageText = "코랩 계정 연결"
                            a.informativeText = "브라우저에서 구글 계정을 고르고 허용하면 인증 코드가 나옵니다. 그 코드를 복사해 여기에 붙여 넣으세요."
                            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                            f.placeholderString = "인증 코드"
                            a.accessoryView = f
                            a.addButton(withTitle: "연결"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
                            a.window.initialFirstResponder = f
                            return a.runModal() == .alertFirstButtonReturn ? f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                        }
                        r = "연결됨"
                    } catch { r = error.localizedDescription }
                    DispatchQueue.main.async { status.stringValue = r }
                }
            },
            p.button("사용량 사기…") { NSWorkspace.shared.open(URL(string: "https://colab.research.google.com/signup")!) },
        ]), note: "L4는 유료 사용량이 있어야 배정됩니다 (시간당 약 1.7, 100에 약 1만 4천원).")
        p.row("", status)
        return p
    }

    static func shortcuts() -> NSViewController { ShortcutSettingsController() }
}

final class SettingsAction: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

/// Shortcuts tab: batch-edit and layer-edit keys per action. Click a cell and press a key to change (⌫ clears, esc cancels).
final class ShortcutSettingsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var recording: (row: Int, scope: KeyMap.Scope)?
    private var monitor: Any?
    private let rows = KeyMap.actions

    override func loadView() {
        for (id, title, w) in [("group", "분류", 70.0), ("title", "동작", 230.0), ("bulk", "대량 보정", 140.0), ("studio", "심화 보정", 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .systemOrange
        let hint = NSTextField(wrappingLabelWithString: "칸을 누른 뒤 새 키를 누르세요. ⌫는 지우기, esc는 취소입니다. 입력칸에 쓰는 중에는 단축키가 동작하지 않습니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let resetBulk = NSButton(title: "대량 보정: 기본값", target: self, action: #selector(resetBulk))
        let resetStudio = NSButton(title: "심화 보정: 기본값", target: self, action: #selector(resetStudio))
        let bar = NSStackView(views: [resetBulk, resetStudio])
        let root = NSStackView(views: [hint, scroll, warning, bar])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        scroll.widthAnchor.constraint(equalToConstant: 620).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true
        hint.preferredMaxLayoutWidth = 620
        warning.preferredMaxLayoutWidth = 620
        view = root
        refreshWarning()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let a = rows[row]
        switch col?.identifier.rawValue {
        case "group": return label(a.group, secondary: true)
        case "title": return label(a.title)
        case "bulk", "studio":
            let scope: KeyMap.Scope = col?.identifier.rawValue == "bulk" ? .bulk : .studio
            let isRec = recording?.row == row && recording?.scope == scope
            let text = isRec ? "키를 누르세요…" : KeyMap.combos(a, scope).map(\.display).joined(separator: ", ")
            let b = NSButton(title: text.isEmpty ? "—" : text, target: self, action: #selector(record(_:)))
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.tag = row * 2 + (scope == .bulk ? 0 : 1)
            b.font = .monospacedSystemFont(ofSize: 11, weight: isRec ? .semibold : .regular)
            return b
        default: return nil
        }
    }

    private func label(_ s: String, secondary: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12)
        if secondary { t.textColor = .secondaryLabelColor }
        return t
    }

    @objc private func record(_ sender: NSButton) {
        let row = sender.tag / 2, scope: KeyMap.Scope = sender.tag % 2 == 0 ? .bulk : .studio
        recording = (row, scope)
        table.reloadData()
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let rec = self.recording, e.window === self.view.window else { return e }
            let a = self.rows[rec.row]
            if e.keyCode == 53 {            // esc: cancel
            } else if e.keyCode == 51 {     // ⌫: clear
                KeyMap.set(a, rec.scope, [])
            } else if let c = KeyCombo(event: e) {
                KeyMap.set(a, rec.scope, [KeyMap.spec(c)])
            }
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        table.reloadData()
        refreshWarning()
        SettingsWindowController.shared.host?.syncMenuKeys()
    }

    private func refreshWarning() {
        var lines: [String] = []
        for (scope, name) in [(KeyMap.Scope.bulk, "대량 보정"), (.studio, "심화 보정")] {
            for (c, titles) in KeyMap.conflicts(scope) { lines.append("\(name) \(c.display): \(titles.joined(separator: " · ")) (위쪽 동작이 먼저)") }
        }
        warning.stringValue = lines.isEmpty ? "" : "겹치는 키\n" + lines.joined(separator: "\n")
    }

    @objc private func resetBulk() { for a in rows { KeyMap.set(a, .bulk, nil) }; stopRecording() }
    @objc private func resetStudio() { for a in rows { KeyMap.set(a, .studio, nil) }; stopRecording() }
}

/// Shortcut list (for display in the Settings window). Changing and saving attach at the shortcut stage.
enum ShortcutCatalog {
    static func describe() -> String {
        var lines = ["심화 보정 (도구 단축키)"]
        for t in RetouchTool.all where !t.key.isEmpty { lines.append("  \(t.key.uppercased())    \(t.title)") }
        lines.append("")
        lines.append("대량 보정")
        for (k, v) in [("H", "이동"), ("Z", "확대"), ("C", "크롭"), ("L", "수평"), ("K", "키스톤"), ("W", "화이트 밸런스"), ("Q", "리터칭"),
                       ("B", "마스크"), ("0~5", "별점"), ("⌥1~7", "색 태그"), ("⇧⌘C / ⇧⌘V", "조정 복사 / 적용"), ("⇧⌘A", "자동 조정"),
                       ("Y", "보정 전"), ("⌘Y / ⇧⌘Y", "교정쇄 / 색역 경고"), ("⌘'", "구도 격자")] {
            lines.append("  \(k)    \(v)")
        }
        lines.append("")
        lines.append("모드: E 대량 보정 · G 격자 · P 심화 보정 · T 테더링 (⌥⌘1~4)")
        return lines.joined(separator: "\n")
    }
}

extension MainWindowController {
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.host = self
        SettingsWindowController.shared.show()
    }

    @objc func openCatalogPanel(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = false
        p.message = "Duochrome 카탈로그(.duochromecatalog)를 고르세요"
        guard p.runModal() == .OK, let u = p.url, u.pathExtension == "duochromecatalog" else { return }
        switchCatalog(to: u)
    }

    @objc func newCatalogPanel(_ sender: Any?) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "새 카탈로그.duochromecatalog"
        p.message = "새 카탈로그를 만들 곳"
        guard p.runModal() == .OK, var u = p.url else { return }
        if u.pathExtension != "duochromecatalog" { u.appendPathExtension("duochromecatalog") }
        do { _ = try Catalog(url: u); switchCatalog(to: u) } catch { NSAlert(error: error).runModal() }
    }

    @objc func backupCatalogNow(_ sender: Any?) { backupCatalogNowReal(sender) }
    @objc func clearPreviews(_ sender: Any?) { PreviewCache.shared.clear() }

    func pendingFeature(_ name: String) {
        let a = NSAlert()
        a.messageText = "\(name)은(는) 곧 들어갑니다"
        a.informativeText = "카탈로그 통합·미리보기 단계에서 연결합니다."
        a.runModal()
    }
}
