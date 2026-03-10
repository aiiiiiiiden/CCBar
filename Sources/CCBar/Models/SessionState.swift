import Foundation

enum AgentStatus: String, Codable {
    case active
    case waitingTurnEnd
    case waitingPermission
    case waitingQuestion
    case idle
}

enum WaitingReason: String, Codable {
    case turnEnded
    case permissionTimeout
    case askUserQuestion
    case noActivity
}

struct SessionInfo: Identifiable {
    let id: String  // session UUID
    var projectName: String
    var status: AgentStatus
    var waitingReason: WaitingReason?
    var lastActivity: Date
    var pendingToolUseIds: Set<String>
    var questionText: String?

    var isWaitingForInput: Bool {
        status == .waitingTurnEnd || status == .waitingPermission || status == .waitingQuestion
    }

    init(id: String, projectName: String) {
        self.id = id
        self.projectName = projectName
        self.status = .idle
        self.waitingReason = nil
        self.lastActivity = Date()
        self.pendingToolUseIds = []
        self.questionText = nil
    }
}
