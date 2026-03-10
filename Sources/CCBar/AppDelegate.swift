import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()
    private let sessionManager = SessionManager()
    private let notificationManager = NotificationManager()
    private let fileWatcher = FileWatcher()
    private let hookServer = HookServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup UI
        menuBarController.setup()

        // Request notification permission
        notificationManager.requestPermission()

        // Wire up event flow:
        // FileWatcher/HookServer -> SessionManager -> MenuBarController + NotificationManager

        let eventHandler: (DetectedEvent) -> Void = { [weak self] event in
            self?.sessionManager.handleEvent(event)
        }

        fileWatcher.onEvent = eventHandler
        hookServer.onEvent = eventHandler

        // SessionManager notifies UI
        sessionManager.onSessionChanged = { [weak self] session in
            guard let self = self else { return }
            let allSessions = self.sessionManager.getAllSessions()
            self.menuBarController.update(sessions: allSessions)

            // Send notification for waiting states
            switch session.status {
            case .waitingTurnEnd, .waitingPermission, .waitingQuestion:
                self.notificationManager.notify(session: session)
            case .active:
                self.notificationManager.clearNotifications(forSession: session.id)
            default:
                break
            }
        }

        // Hook server provides session data for /status endpoint
        hookServer.getSessionsForStatus = { [weak self] in
            self?.sessionManager.getAllSessions() ?? []
        }

        // Start services
        sessionManager.start()
        fileWatcher.start()

        do {
            try hookServer.start()
            sessionManager.setHookActive(true)
            print("Hook server started on \(hookServer.host):\(hookServer.port)")
        } catch {
            print("Failed to start hook server: \(error)")
            // Continue without hook server - JSONL watching with 7s timer fallback
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fileWatcher.stop()
        hookServer.stop()
        sessionManager.stop()
    }
}
