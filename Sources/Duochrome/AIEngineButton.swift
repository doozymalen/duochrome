import AppKit

/// AI engine button in the top bar: the engine starts only from this button or when an AI tool is picked.
/// Off (gray) · starting (orange) · on (green). Stops automatically after the configured idle time.
enum AIEngineButton {
    static let changed = Notification.Name("DuochromeAIEngineChanged")
    static weak var button: NSButton?
    private static var observer: Any?

    enum Look { case off, starting, on, fallback }

    /// Status for the current setting (Colab / this Mac)
    static var look: Look {
        if AIRemote.current != .local {
            switch ColabEngine.shared.state {
            case .starting: return .starting
            case .on: return .on
            case .off: return ColabEngine.shared.lastFailure != nil && AIEngine.shared.isRunningHere ? .fallback : .off
            }
        }
        return AIEngine.shared.isRunningHere ? .on : .off
    }

    static func attach(_ b: NSButton) {
        button = b
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { _ in refresh() }
        }
        refresh()
    }

    static func refresh() {
        guard let b = button else { return }
        let where_ = AIRemote.current == .local ? "이 맥" : "코랩 \(ColabEngine.shared.gpu ?? AIRemote.current.gpu ?? "")"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        switch look {
        case .off:
            b.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI 엔진")?.withSymbolConfiguration(config)
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = "AI 엔진 꺼짐 — 눌러서 켜기 (\(where_))"
        case .starting:
            b.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI 엔진")?.withSymbolConfiguration(config)
            b.contentTintColor = .systemOrange
            b.toolTip = "AI 엔진 켜는 중 (\(where_)) — 진행은 작업 진행 창에"
        case .fallback:
            b.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI 엔진")?.withSymbolConfiguration(config)
            b.contentTintColor = .systemYellow
            b.toolTip = "코랩 연결 안 됨 — 이 맥 엔진으로 처리 중 (느리고 품질 낮음). 까닭: \(ColabEngine.shared.lastFailure ?? "")\n눌러서 끄기. 다시 코랩을 쓰려면 끈 뒤 다시 누르세요"
        case .on:
            b.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI 엔진")?.withSymbolConfiguration(config)
            b.contentTintColor = .systemGreen
            b.toolTip = "AI 엔진 켜짐 (\(where_)) — 눌러서 끄기. 쓰지 않으면 \(ColabEngine.idleMinutes)분 뒤 자동으로 꺼집니다"
        }
        b.setAccessibilityLabel(b.toolTip)
    }
}

extension MainWindowController {
    /// Top bar button · AI menu: start / stop
    @objc func toggleAIEngine(_ sender: Any?) {
        switch AIEngineButton.look {
        case .off: startAIEngine()
        case .starting: break   // Ignore while starting (can be pressed again when done)
        case .on, .fallback:
            DispatchQueue.global(qos: .utility).async {
                if AIRemote.current != .local { ColabEngine.shared.stop("단추로 끔") }
                AIEngine.shared.stop()
            }
        }
    }

    /// Start the AI engine: starts the heavy-work backend (Colab or this Mac). The local inpaint engine starts separately when an erase tool is picked
    func startAIEngine() {
        if AIRemote.current != .local {
            // Colab by default; if that fails, start the local engine as fallback
            ColabEngine.shared.start(fallback: { AIEngine.shared.warmUp() })
        } else {
            AIEngine.shared.warmUp()
        }
    }
}
