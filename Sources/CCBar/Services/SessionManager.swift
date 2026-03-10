import Foundation

final class SessionManager {
    private let queue = DispatchQueue(label: "com.ccbar.sessionmanager")
    private var _sessions: [String: SessionInfo] = [:]
    private var permissionTimers: [String: DispatchWorkItem] = [:]  // toolUseId -> timer
    private var idleTimer: DispatchSourceTimer?
    /// When true, permission detection comes from Hook events directly,
    /// so the 7s heuristic timer is skipped.
    private(set) var hookActive = false

    var onSessionChanged: ((SessionInfo) -> Void)?

    private(set) var sessions: [String: SessionInfo] {
        get { queue.sync { _sessions } }
        set { queue.sync { _sessions = newValue } }
    }

    func getSession(_ id: String) -> SessionInfo? {
        queue.sync { _sessions[id] }
    }

    func getAllSessions() -> [SessionInfo] {
        queue.sync { Array(_sessions.values) }
    }

    func setHookActive(_ active: Bool) {
        queue.sync { hookActive = active }
    }

    func start() {
        // Start idle pruning timer (checks every 60s)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.pruneIdleSessions()
        }
        timer.resume()
        idleTimer = timer
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        queue.sync {
            for (_, timer) in permissionTimers {
                timer.cancel()
            }
            permissionTimers.removeAll()
        }
    }

    func handleEvent(_ event: DetectedEvent) {
        queue.async { [weak self] in
            self?._handleEvent(event)
        }
    }

    private func mutateSession(_ id: String, _ body: (inout SessionInfo) -> Void) {
        if _sessions[id] != nil {
            body(&_sessions[id]!)
        }
    }

    private func _handleEvent(_ event: DetectedEvent) {
        switch event {
        case .turnEnded(let sessionId, _, let cwd):
            guard let sid = sessionId else { return }
            ensureSession(sid, cwd: cwd)
            mutateSession(sid) { session in
                session.status = .waitingTurnEnd
                session.waitingReason = .turnEnded
                session.lastActivity = Date()
            }
            cancelAllPermissionTimers(forSession: sid)
            notifyChange(sid)

        case .toolUseStarted(let sessionId, let toolUseId, let toolName, let cwd):
            guard let sid = sessionId else { return }
            ensureSession(sid, cwd: cwd)
            mutateSession(sid) { session in
                session.status = .active
                session.waitingReason = nil
                session.lastActivity = Date()
                session.pendingToolUseIds.insert(toolUseId)
            }

            // Start permission timer (7s) unless it's an exempt tool
            let exemptTools: Set<String> = ["Task", "AskUserQuestion"]
            if !exemptTools.contains(toolName) {
                startPermissionTimer(sessionId: sid, toolUseId: toolUseId)
            }
            notifyChange(sid)

        case .toolUseCompleted(let sessionId, let toolUseId, let cwd):
            guard let sid = sessionId else { return }
            ensureSession(sid, cwd: cwd)
            cancelPermissionTimer(toolUseId: toolUseId)
            mutateSession(sid) { session in
                session.pendingToolUseIds.remove(toolUseId)
                session.lastActivity = Date()
                if session.status == .waitingPermission || session.status == .waitingQuestion {
                    session.status = .active
                    session.waitingReason = nil
                    session.questionText = nil
                }
            }
            // Hook-based toolUseCompleted uses synthetic IDs.
            // Clear all pending timers for this session since
            // the user already responded (approved/rejected).
            if _sessions[sid]?.status == .active {
                cancelAllPermissionTimers(forSession: sid)
            }
            notifyChange(sid)

        case .askUserQuestion(let sessionId, let toolUseId, let questionText, let cwd):
            guard let sid = sessionId else { return }
            ensureSession(sid, cwd: cwd)
            mutateSession(sid) { session in
                session.status = .waitingQuestion
                session.waitingReason = .askUserQuestion
                session.questionText = questionText
                session.pendingToolUseIds.insert(toolUseId)
                session.lastActivity = Date()
            }
            notifyChange(sid)

        case .permissionWaiting(let sessionId, let cwd):
            guard let sid = sessionId else { return }
            ensureSession(sid, cwd: cwd)
            mutateSession(sid) { session in
                session.status = .waitingPermission
                session.waitingReason = .permissionTimeout
                session.lastActivity = Date()
            }
            notifyChange(sid)

        case .userPrompt(let sessionId, let cwd):
            guard let sid = sessionId else { return }
            ensureSession(sid, cwd: cwd)
            mutateSession(sid) { session in
                session.status = .active
                session.waitingReason = nil
                session.questionText = nil
                session.lastActivity = Date()
            }
            notifyChange(sid)

        case .sessionEnded(let sessionId):
            guard let sid = sessionId else { return }
            cancelAllPermissionTimers(forSession: sid)
            _sessions.removeValue(forKey: sid)
            // Capture remaining session while still on the serial queue
            let remaining = _sessions.values.first
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let session = remaining {
                    self.onSessionChanged?(session)
                } else {
                    // Create a dummy notification to trigger UI update
                    self.onSessionChanged?(SessionInfo(id: sid, projectName: ""))
                }
            }

        case .progressEvent(let sessionId, let dataType):
            guard let sid = sessionId else { return }
            ensureSession(sid)
            _sessions[sid]?.lastActivity = Date()

            // Progress events mean work is happening, reset permission timers
            if dataType == "bash_progress" || dataType == "mcp_progress" {
                // Reset all permission timers for this session
                let toolIds = _sessions[sid]?.pendingToolUseIds ?? []
                for toolId in toolIds {
                    cancelPermissionTimer(toolUseId: toolId)
                    startPermissionTimer(sessionId: sid, toolUseId: toolId)
                }
            }
        }
    }

    // For testing: synchronous event handling
    func handleEventSync(_ event: DetectedEvent) {
        queue.sync {
            _handleEvent(event)
        }
    }

    private func ensureSession(_ sessionId: String, cwd: String? = nil) {
        if _sessions[sessionId] == nil {
            let name = cwd.map { Self.directoryName(from: $0) } ?? "unknown"
            _sessions[sessionId] = SessionInfo(id: sessionId, projectName: name)
        } else if let cwd = cwd, _sessions[sessionId]?.projectName == "unknown" {
            _sessions[sessionId]?.projectName = Self.directoryName(from: cwd)
        }
    }

    /// Extract the last path component as the display name.
    static func directoryName(from path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func startPermissionTimer(sessionId: String, toolUseId: String) {
        // Skip heuristic timer when hooks provide direct permission detection
        guard !hookActive else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Check if tool is still pending
            if self._sessions[sessionId]?.pendingToolUseIds.contains(toolUseId) == true {
                self.mutateSession(sessionId) { session in
                    session.status = .waitingPermission
                    session.waitingReason = .permissionTimeout
                }
                self.notifyChange(sessionId)
            }
            self.permissionTimers.removeValue(forKey: toolUseId)
        }

        permissionTimers[toolUseId]?.cancel()
        permissionTimers[toolUseId] = workItem
        queue.asyncAfter(deadline: .now() + 7.0, execute: workItem)
    }

    private func cancelPermissionTimer(toolUseId: String) {
        permissionTimers[toolUseId]?.cancel()
        permissionTimers.removeValue(forKey: toolUseId)
    }

    private func cancelAllPermissionTimers(forSession sessionId: String) {
        let toolIds = _sessions[sessionId]?.pendingToolUseIds ?? []
        for toolId in toolIds {
            cancelPermissionTimer(toolUseId: toolId)
        }
        _sessions[sessionId]?.pendingToolUseIds.removeAll()
    }

    private func pruneIdleSessions() {
        let idleThreshold: TimeInterval = 30 * 60  // 30 minutes
        let now = Date()

        for (id, session) in _sessions {
            if now.timeIntervalSince(session.lastActivity) > idleThreshold {
                if session.status != .idle {
                    mutateSession(id) { session in
                        session.status = .idle
                        session.waitingReason = .noActivity
                    }
                    notifyChange(id)
                }
            }
        }
    }

    /// Test-only: force a session's status and reason for synchronous testing.
    func forceStatusForTesting(sessionId: String, status: AgentStatus, reason: WaitingReason?) {
        queue.sync {
            mutateSession(sessionId) { session in
                session.status = status
                session.waitingReason = reason
            }
        }
    }

    private func notifyChange(_ sessionId: String) {
        if let session = _sessions[sessionId] {
            DispatchQueue.main.async { [weak self] in
                self?.onSessionChanged?(session)
            }
        }
    }
}
