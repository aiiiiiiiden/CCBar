import Foundation

struct HookEvent: Codable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let permissionMode: String?
    let hookEventName: String?
    let toolName: String?
    let toolInput: AnyCodable?
    let toolResult: AnyCodable?
    let reason: String?
    let userPrompt: String?
    let agentId: String?
    let agentType: String?
    let notificationType: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResult = "tool_result"
        case reason
        case userPrompt = "user_prompt"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case notificationType = "notification_type"
    }
}
