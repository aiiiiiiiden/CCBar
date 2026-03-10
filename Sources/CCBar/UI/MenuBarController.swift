import Cocoa

final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var sessions: [SessionInfo] = []
    private var currentIconState: IconState = .idle

    enum IconState: Equatable {
        case urgent     // 퍼미션/질문 대기 — 빨간 말풍선
        case waiting    // 턴 종료 대기 — 하얀 말풍선
        case active     // 에이전트 작업 중 — 하얀 채워진 터미널
        case idle       // 세션 없음 — 하얀 테두리 터미널
    }

    static func determineIconState(from sessions: [SessionInfo]) -> IconState {
        if sessions.contains(where: {
            $0.status == .waitingPermission || $0.status == .waitingQuestion
        }) {
            return .urgent
        } else if sessions.contains(where: { $0.status == .waitingTurnEnd }) {
            return .waiting
        } else if sessions.contains(where: { $0.status == .active }) {
            return .active
        } else {
            return .idle
        }
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateIcon(state: .idle)

        menu = NSMenu()
        statusItem?.menu = menu

        rebuildMenu()
    }

    func update(sessions: [SessionInfo]) {
        self.sessions = sessions.sorted { $0.lastActivity > $1.lastActivity }

        let newState = Self.determineIconState(from: sessions)

        if newState != currentIconState {
            currentIconState = newState
            updateIcon(state: newState)
        }

        rebuildMenu()
    }

    private func updateIcon(state: IconState) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .urgent:
            let image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "CCBar - Needs Input")
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = image?.withSymbolConfiguration(config)
        case .waiting:
            let image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "CCBar - Waiting")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white])
            button.image = image?.withSymbolConfiguration(config)
        case .active:
            let image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "CCBar - Active")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white])
            button.image = image?.withSymbolConfiguration(config)
        case .idle:
            let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "CCBar - Idle")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white])
            button.image = image?.withSymbolConfiguration(config)
        }
    }

    private func rebuildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()

        // Header
        let header = NSMenuItem(title: "CCBar", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let waitingSessions = sessions.filter(\.isWaitingForInput)

        if !waitingSessions.isEmpty {
            addSectionHeader(to: menu, title: "Waiting for input")
            for session in waitingSessions {
                let item = NSMenuItem(title: "  \(session.projectName)", action: nil, keyEquivalent: "")
                menu.addItem(item)
            }
        }

        // Footer
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func addSectionHeader(to menu: NSMenu, title: String) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        header.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        menu.addItem(header)
    }
}
