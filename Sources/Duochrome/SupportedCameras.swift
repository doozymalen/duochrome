import AppKit
import CoreImage

/// 지원 카메라 보기 (도움말 > 지원 카메라): 이 맥에서 실제로 되는 기종을 그 자리에서 묻는다.
/// - RAW 현상: macOS RAW 해독기(CIRAWFilter)가 아는 기종. macOS를 올리면 늘어난다.
/// - 테더링: 테더링 도우미의 libgphoto2가 아는 기종 (테더링 도구를 설치한 뒤에만).
enum SupportedCameras {
    private static var window: NSWindow?
    private static var lists: [[String]] = [[], []]
    private static let tabs = NSSegmentedControl(labels: ["RAW 현상", "테더링"], trackingMode: .selectOne, target: nil, action: nil)
    private static let search = NSSearchField()
    private static let count = NSTextField(labelWithString: "")
    private static let scroll = NSTextView.scrollableTextView()
    private static var text: NSTextView { scroll.documentView as! NSTextView }
    private static let handler = Handler()

    private final class Handler: NSObject, NSSearchFieldDelegate {
        @objc func changed(_ sender: Any?) { SupportedCameras.refresh() }
        func controlTextDidChange(_ obj: Notification) { SupportedCameras.refresh() }
    }

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        lists[0] = CIRAWFilter.supportedCameraModels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        tabs.selectedSegment = 0
        tabs.target = handler; tabs.action = #selector(Handler.changed(_:))
        search.placeholderString = "기종 찾기 (예: ILCE, Z 8, X-T5)"
        search.delegate = handler
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 8, height: 8)
        let stack = NSStackView(views: [tabs, search, count, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for v in [search, scroll] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 620), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "지원 카메라"
        w.isReleasedWhenClosed = false
        w.contentView = stack
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        refresh()
        loadTetherList()
    }

    private static func refresh() {
        let tab = max(0, tabs.selectedSegment)
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = lists[tab]
        let shown = q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
        if tab == 1 && all.isEmpty {
            count.stringValue = "테더링 도구가 아직 없거나 목록을 읽는 중입니다. 테더링 모드를 한 번 열면 도구가 설치됩니다."
        } else if tab == 0 {
            count.stringValue = "이 맥의 macOS가 여는 기종 \(all.count)개" + (q.isEmpty ? "" : " 중 \(shown.count)개") +
                " · 목록에 없어도 DNG는 열립니다. 실제로 열리는지는 사진을 열어 보면 알 수 있습니다."
        } else {
            count.stringValue = "libgphoto2가 아는 기종 \(all.count)개" + (q.isEmpty ? "" : " 중 \(shown.count)개") +
                " · 조리개·셔터 원격 변경과 라이브 뷰는 기종마다 다를 수 있습니다."
        }
        text.string = shown.joined(separator: "\n")
    }

    /// 테더링 도우미의 파이썬으로 libgphoto2 기종 목록을 읽는다 (설치 전이면 비워 둔다)
    private static func loadTetherList() {
        let py = GPhotoCamera.python
        guard FileManager.default.isExecutableFile(atPath: py.path) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = py
            p.arguments = ["-c", """
            import gphoto2 as gp
            l = gp.CameraAbilitiesList(); l.load()
            for i in range(l.count()): print(l.get_abilities(i).model)
            """]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = Array(Set((String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)))
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            DispatchQueue.main.async { lists[1] = names; refresh() }
        }
    }
}
