import Foundation
import UserNotifications

final class NotificationManager {
    private var lastNotificationTime: [String: Date] = [:]  // sessionId -> last notify time
    private let debounceInterval: TimeInterval = 30.0
    private var notificationCenter: UNUserNotificationCenter?

    func requestPermission() {
        guard let center = getNotificationCenter() else {
            print("Notifications unavailable (no app bundle). Using fallback.")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            } else if granted {
                print("Notification permission granted.")
            }
        }
    }

    func notify(session: SessionInfo) {
        guard let body = notificationBody(for: session) else { return }

        // Debounce: don't notify more than once per 30s per session
        let now = Date()
        if let lastTime = lastNotificationTime[session.id],
           now.timeIntervalSince(lastTime) < debounceInterval {
            return
        }
        lastNotificationTime[session.id] = now

        let title = "CCBar - \(session.projectName)"

        guard let center = getNotificationCenter() else {
            sendFallbackNotification(title: title, body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ccbar-\(session.id)-\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil  // deliver immediately
        )

        center.add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error)")
            }
        }
    }

    func clearNotifications(forSession sessionId: String) {
        lastNotificationTime.removeValue(forKey: sessionId)
    }

    private func notificationBody(for session: SessionInfo) -> String? {
        switch session.status {
        case .waitingTurnEnd:
            return "Agent finished. Waiting for your input."
        case .waitingPermission:
            return "Agent needs permission to continue."
        case .waitingQuestion:
            return session.questionText ?? "Agent has a question for you."
        default:
            return nil
        }
    }

    private func getNotificationCenter() -> UNUserNotificationCenter? {
        if let center = notificationCenter {
            return center
        }
        // UNUserNotificationCenter requires a valid bundle identifier
        guard Bundle.main.bundleIdentifier != nil else {
            return nil
        }
        do {
            let center = UNUserNotificationCenter.current()
            notificationCenter = center
            return center
        }
    }

    private func sendFallbackNotification(title: String, body: String) {
        // Escape for AppleScript string literals to prevent injection
        let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }
}
