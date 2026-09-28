import AppKit

/// 상단 바의 AI 엔진 단추: 엔진은 이 단추를 누르거나 AI 도구를 고를 때만 켠다.
/// 꺼짐(회색) · 켜는 중(주황) · 켜짐(초록). 켜진 뒤 쓰지 않으면 설정한 시간 뒤 자동으로 꺼진다.
enum AIEngineButton {
    static let changed = Notification.Name("DuochromeAIEngineChanged")
    static weak var button: NSButton?
    private static var observer: Any?

    enum Look { case off, starting, on, fallback }

    /// 지금 설정(코랩 / 이 맥)에 따른 상태
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
    /// 상단 바 단추 · AI 메뉴: 켜기 / 끄기
    @objc func toggleAIEngine(_ sender: Any?) {
        switch AIEngineButton.look {
        case .off: startAIEngine()
        case .starting: break   // 켜는 중에는 무시 (끝나면 다시 누를 수 있다)
        case .on, .fallback:
            DispatchQueue.global(qos: .utility).async {
                if AIRemote.current != .local { ColabEngine.shared.stop("단추로 끔") }
                AIEngine.shared.stop()
            }
        }
    }

    /// AI 엔진 켜기: 무거운 일 담당(코랩 또는 이 맥)을 켠다. 지우기용 맥 엔진은 지우기 도구를 고를 때 따로 켠다
    func startAIEngine() {
        if AIRemote.current != .local {
            // 기본은 코랩, 안 되면 이 맥 엔진을 예비로 켠다
            ColabEngine.shared.start(fallback: { AIEngine.shared.warmUp() })
        } else {
            AIEngine.shared.warmUp()
        }
    }
}
