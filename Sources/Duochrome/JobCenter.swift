import AppKit

/// 오래 걸리는 작업(미리보기 만들기·썸네일·내보내기·PSD 저장)의 진행 상황과 남은 시간.
/// 어느 스레드에서나 부르고, 화면은 주 스레드에서 고친다.
final class JobCenter {
    static let shared = JobCenter()
    static let changed = Notification.Name("DuochromeJobsChanged")

    struct Job {
        var title: String
        var total: Int
        var done: Int
        var started: CFAbsoluteTime
        /// 한 덩어리 작업(단계 수를 모름)이면 참 — 지난 시간만 보인다
        var indeterminate: Bool
        var detail: String = ""
        var finishedAt: CFAbsoluteTime?
    }

    private let lock = NSLock()
    private(set) var jobs: [String: Job] = [:]

    /// 작업 칸을 만들거나(없으면) 할 일을 더한다
    func add(_ key: String, title: String, count: Int = 1) {
        lock.lock()
        if var j = jobs[key], j.finishedAt == nil {
            j.total += count
            jobs[key] = j
        } else {
            jobs[key] = Job(title: title, total: count, done: 0, started: CFAbsoluteTimeGetCurrent(), indeterminate: false)
        }
        lock.unlock()
        notify()
    }

    /// 한 덩어리 작업 시작 (남은 시간 대신 지난 시간)
    func begin(_ key: String, title: String, detail: String = "") {
        lock.lock()
        jobs[key] = Job(title: title, total: 1, done: 0, started: CFAbsoluteTimeGetCurrent(), indeterminate: true, detail: detail)
        lock.unlock()
        notify()
    }

    func detail(_ key: String, _ text: String) {
        lock.lock(); jobs[key]?.detail = text; lock.unlock()
        notify()
    }

    /// 하나 끝남 (다 끝나면 잠시 뒤 목록에서 뺀다)
    func step(_ key: String, _ n: Int = 1) {
        lock.lock()
        guard var j = jobs[key] else { lock.unlock(); return }
        j.done = min(j.total, j.done + n)
        if j.done >= j.total { j.finishedAt = CFAbsoluteTimeGetCurrent() }
        jobs[key] = j
        lock.unlock()
        notify()
        if j.finishedAt != nil { scheduleCleanup() }
    }

    /// 건너뛴 일 (할 일에서 뺀다)
    func skip(_ key: String) {
        lock.lock()
        guard var j = jobs[key] else { lock.unlock(); return }
        j.total = max(j.done, j.total - 1)
        if j.done >= j.total { j.finishedAt = CFAbsoluteTimeGetCurrent() }
        jobs[key] = j
        lock.unlock()
        notify()
        if j.finishedAt != nil { scheduleCleanup() }
    }

    func end(_ key: String) {
        lock.lock()
        if var j = jobs[key] { j.done = j.total; j.finishedAt = CFAbsoluteTimeGetCurrent(); jobs[key] = j }
        lock.unlock()
        notify()
        scheduleCleanup()
    }

    /// 아직 끝나지 않은 작업이 있으면 참
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.contains { $0.finishedAt == nil }
    }

    /// 지금 보일 작업들 (끝난 지 1.5초 안 된 것 포함)
    func snapshot() -> [(String, Job)] {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        return jobs.filter { $0.value.finishedAt.map { now - $0 < 1.5 } ?? true }.sorted { $0.value.started < $1.value.started }
    }

    /// "3/20 · 남은 시간 약 12초" 같은 설명
    static func describe(_ j: Job) -> String {
        let elapsed = CFAbsoluteTimeGetCurrent() - j.started
        if j.finishedAt != nil { return "끝남 · \(duration(elapsed))" }
        if j.indeterminate { return (j.detail.isEmpty ? "" : j.detail + " · ") + "\(duration(elapsed)) 지남" }
        var s = "\(j.done)/\(j.total)"
        if j.done > 0 {
            let remain = elapsed / Double(j.done) * Double(j.total - j.done)
            s += " · 남은 시간 약 \(duration(remain))"
        } else {
            s += " · 남은 시간 재는 중"
        }
        return s
    }

    static func duration(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s < 60 ? "\(max(s, 1))초" : "\(s / 60)분 \(s % 60)초"
    }

    private var pendingNotify = false
    private func notify() {
        lock.lock()
        if pendingNotify { lock.unlock(); return }
        pendingNotify = true
        lock.unlock()
        // 자주 부르면 화면이 바빠지므로 0.2초에 한 번 모아서
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pendingNotify = false; self.lock.unlock()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    private func scheduleCleanup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let now = CFAbsoluteTimeGetCurrent()
            self.jobs = self.jobs.filter { $0.value.finishedAt.map { now - $0 < 1.5 } ?? true }
            self.lock.unlock()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
}

/// 작업 진행 창: 메인 창 오른쪽 아래에 떠서 작업마다 제목·막대·진행·남은 시간을 보인다. 작업이 없으면 숨는다.
final class JobsPanel: NSPanel, NSWindowDelegate {
    private let stack = NSStackView()
    private weak var host: NSWindow?
    private var timer: Timer?
    /// 사용자가 고른 상태: 자동(작업이 있을 때만 뜸), 닫음(작업이 있어도 안 뜸), 열어 둠(작업이 없어도 떠 있음)
    enum Visibility: Int { case auto, closed, open }
    var visibility: Visibility {
        get { Visibility(rawValue: UserDefaults.standard.integer(forKey: "jobs.panel")) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "jobs.panel") }
    }
    /// 상단 바의 작업 진행 단추: 작업이 돌아가는 동안 강조색으로 (창을 닫아 두어도 일하는 중임을 알 수 있게)
    static weak var barButton: NSButton?
    private static var barBusy: Bool?
    static func refreshBarButton() {
        guard let b = barButton else { return }
        let busy = JobCenter.shared.isBusy
        // 바쁨이 실제로 바뀔 때만 그림을 바꾼다 (작업 소식은 1초에도 여러 번 온다)
        guard busy != barBusy else { return }
        barBusy = busy
        b.contentTintColor = busy ? .controlAccentColor : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let img = NSImage(systemSymbolName: busy ? "hourglass.bottomhalf.filled" : "hourglass", accessibilityDescription: "작업 진행")?
            .withSymbolConfiguration(config) { b.image = img }
    }

    /// 지금 창이 보이는지 (메뉴 체크 표시용)
    var isShown: Bool { isVisible }

    init(host: NSWindow) {
        self.host = host
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
                   backing: .buffered, defer: false)
        title = "작업 진행"
        delegate = self
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        contentView = stack
        NotificationCenter.default.addObserver(forName: JobCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReload()
            Self.refreshBarButton()
        }
    }

    /// 닫기 단추(사용자가 누를 때만 불린다, 앱을 끌 때는 아님): 다시 열 때까지 작업이 있어도 띄우지 않는다
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userClose()
        return false
    }

    private func userClose() {
        visibility = .closed
        hideNow()
    }

    /// 윈도우 메뉴 · ⌥⌘J: 보이면 닫고, 숨어 있으면 열어 둔다
    func toggle() {
        if isVisible { userClose() } else { visibility = .open; reload() }
    }

    private func hideNow() {
        orderOut(nil)
        timer?.invalidate(); timer = nil
    }

    /// 작업 소식이 몰려와도 1초에 최대 네 번만 다시 그린다
    private var reloadPending = false
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    func reload() {
        let jobs = JobCenter.shared.snapshot()
        // 돌던 막대는 멈춘 뒤 버린다 (움직임이 남으면 막대가 풀리지 않는다)
        for case let row as NSStackView in stack.arrangedSubviews {
            row.arrangedSubviews.compactMap { $0 as? NSProgressIndicator }.forEach { $0.stopAnimation(nil) }
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if visibility == .closed { hideNow(); return }
        if jobs.isEmpty {
            guard visibility == .open else { hideNow(); return }
            let t = NSTextField(labelWithString: "진행 중인 작업이 없습니다")
            t.font = .systemFont(ofSize: 12)
            t.textColor = .secondaryLabelColor
            t.widthAnchor.constraint(equalToConstant: 296).isActive = true
            stack.addArrangedSubview(t)
            timer?.invalidate(); timer = nil
        }
        for (_, j) in jobs {
            let t = NSTextField(labelWithString: j.title)
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.controlSize = .small
            bar.isIndeterminate = j.indeterminate && j.finishedAt == nil
            if bar.isIndeterminate { bar.startAnimation(nil) } else {
                bar.minValue = 0; bar.maxValue = Double(max(j.total, 1)); bar.doubleValue = Double(j.done)
            }
            let d = NSTextField(labelWithString: JobCenter.describe(j))
            d.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            d.textColor = .secondaryLabelColor
            let v = NSStackView(views: [t, bar, d])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 3
            bar.widthAnchor.constraint(equalToConstant: 296).isActive = true
            stack.addArrangedSubview(v)
        }
        let h = stack.fittingSize.height
        var f = frame
        let contentH = max(h, 50)
        let newFrame = frameRect(forContentRect: NSRect(x: 0, y: 0, width: 320, height: contentH))
        f.size = newFrame.size
        if let host {
            // 메인 창 오른쪽 아래 (오른쪽 패널 위)
            f.origin = NSPoint(x: host.frame.maxX - f.width - 24, y: host.frame.minY + 24)
        }
        setFrame(f, display: true)
        if !isVisible { orderFront(nil) }
        // 남은 시간 글자가 가만히 있지 않게 1초마다 다시
        if timer == nil, !jobs.isEmpty {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        }
    }
}
