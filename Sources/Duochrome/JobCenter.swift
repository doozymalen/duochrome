import AppKit

/// Progress and time remaining for long jobs (previews, thumbnails, export, PSD save).
/// Callable from any thread; the UI updates on the main thread.
final class JobCenter {
    static let shared = JobCenter()
    static let changed = Notification.Name("DuochromeJobsChanged")

    struct Job {
        var title: String
        var total: Int
        var done: Int
        var started: CFAbsoluteTime
        /// True for a single-chunk job (unknown step count) — shows elapsed time only
        var indeterminate: Bool
        var detail: String = ""
        var finishedAt: CFAbsoluteTime?
    }

    private let lock = NSLock()
    private(set) var jobs: [String: Job] = [:]

    /// Creates the job entry (if missing) or adds work to it
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

    /// Starts a single-chunk job (elapsed instead of remaining time)
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

    /// One item done (removed from the list shortly after all finish)
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

    /// Skipped item (removed from the workload)
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

    /// True if any job is unfinished
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.contains { $0.finishedAt == nil }
    }

    /// Jobs to show now (including those finished within 1.5 s)
    func snapshot() -> [(String, Job)] {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        return jobs.filter { $0.value.finishedAt.map { now - $0 < 1.5 } ?? true }.sorted { $0.value.started < $1.value.started }
    }

    /// Description like "3/20 · 남은 시간 약 12초"
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
        // Frequent calls keep the UI busy, so batch once per 0.2 s
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

/// Jobs panel: floats at the bottom right of the main window showing title, bar, progress, and time remaining per job. Hidden with no jobs.
final class JobsPanel: NSPanel, NSWindowDelegate {
    private let stack = NSStackView()
    private weak var host: NSWindow?
    private var timer: Timer?
    /// User's choice: auto (shows only with jobs), closed (hidden even with jobs), pinned (shown even without jobs)
    enum Visibility: Int { case auto, closed, open }
    var visibility: Visibility {
        get { Visibility(rawValue: UserDefaults.standard.integer(forKey: "jobs.panel")) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "jobs.panel") }
    }
    /// Jobs button in the top bar: accent-colored while jobs run (so work is visible even with the panel closed)
    static weak var barButton: NSButton?
    private static var barBusy: Bool?
    static func refreshBarButton() {
        guard let b = barButton else { return }
        let busy = JobCenter.shared.isBusy
        // Change the image only when busy actually changes (job events arrive several times a second)
        guard busy != barBusy else { return }
        barBusy = busy
        b.contentTintColor = busy ? .controlAccentColor : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let img = NSImage(systemSymbolName: busy ? "hourglass.bottomhalf.filled" : "hourglass", accessibilityDescription: "작업 진행")?
            .withSymbolConfiguration(config) { b.image = img }
    }

    /// Whether the panel is visible now (for the menu checkmark)
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

    /// Close button (called only on user click, not on quit): don't show again until reopened, even with jobs
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userClose()
        return false
    }

    private func userClose() {
        visibility = .closed
        hideNow()
    }

    /// Window menu · ⌥⌘J: close if visible, pin open if hidden
    func toggle() {
        if isVisible { userClose() } else { visibility = .open; reload() }
    }

    private func hideNow() {
        orderOut(nil)
        timer?.invalidate(); timer = nil
    }

    /// Redraws at most four times a second even if job events flood in
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
        // Stop spinning bars before discarding (leftover animation kept the bar from resolving)
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
            // Bottom right of the main window (over the right panel)
            f.origin = NSPoint(x: host.frame.maxX - f.width - 24, y: host.frame.minY + 24)
        }
        setFrame(f, display: true)
        if !isVisible { orderFront(nil) }
        // Refresh every second so the remaining-time text doesn't sit still
        if timer == nil, !jobs.isEmpty {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        }
    }
}
