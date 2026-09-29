import AppKit

/// Shortcut overview (Help > Keyboard Shortcuts, ⌘/).
enum ShortcutsWindow {
    static let groups: [(String, [(String, String)])] = [
        ("모드", [("G", "라이브러리 (대량 처리)"), ("E", "편집 (심화 보정)"), ("T", "테더링")]),
        ("사진", [("0~5", "별점"), ("⌥1~7", "색 태그"), ("← →", "앞뒤 사진"), ("↩", "라이브러리에서 편집으로 열기")]),
        ("커서 도구", [("H", "이동"), ("Z", "확대 (⌥ 누르고 축소)"), ("C", "크롭"), ("L", "수평 맞추기"), ("K", "키스톤 선"),
                   ("W", "화이트 밸런스 스포이트"), ("Q", "리터칭"), ("B", "마스크 붓"), ("[ ]", "붓 작게·크게")]),
        ("보기", [("⌘0", "화면에 맞추기"), ("⌘1", "실제 픽셀 (100%)"), ("⌘+ ⌘−", "확대·축소"), ("Y", "보정 전"),
                ("⇧Y", "전후 나란히"), ("J", "클리핑 경고"), ("M", "마스크 보기"), ("⌥M", "마스크 흑백")]),
        ("조정", [("⌘Z ⇧⌘Z", "실행 취소·다시 실행"), ("⇧⌘C", "조정 복사"), ("⇧⌘V", "조정 적용"), ("⌥⇧⌘V", "조정 골라 적용")]),
        ("파일", [("⌘O", "폴더 가져오기"), ("⇧⌘O", "사진·문서 열기"), ("⌘S", "Duochrome 문서로 저장"), ("⇧⌘E", "내보내기"),
                ("⇧⌘I", "카탈로그 가져오기")]),
    ]

    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        for (title, items) in groups {
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .secondaryLabelColor
            grid.addRow(with: [t, NSView()])
            for (key, what) in items {
                let k = NSTextField(labelWithString: key)
                k.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                k.alignment = .right
                grid.addRow(with: [k, NSTextField(labelWithString: what)])
            }
            grid.addRow(with: [NSView(), NSView()]).height = 8
        }
        grid.column(at: 0).xPlacement = .trailing
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "단축키"
        w.isReleasedWhenClosed = false
        let pad = NSView()
        pad.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: pad.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: pad.trailingAnchor, constant: -20),
        ])
        w.contentView = pad
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
