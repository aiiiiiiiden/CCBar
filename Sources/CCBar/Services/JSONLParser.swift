import Foundation

enum DetectedEvent {
    case turnEnded(sessionId: String?, durationMs: Int, cwd: String?)
    case toolUseStarted(sessionId: String?, toolUseId: String, toolName: String, cwd: String?)
    case toolUseCompleted(sessionId: String?, toolUseId: String, cwd: String?)
    case askUserQuestion(sessionId: String?, toolUseId: String, questionText: String, cwd: String?)
    case userPrompt(sessionId: String?, cwd: String?)
    case permissionWaiting(sessionId: String?, cwd: String?)
    case progressEvent(sessionId: String?, dataType: String)
    case sessionEnded(sessionId: String?)
}

final class JSONLParser {

    private let decoder = JSONDecoder()

    /// Parse a single JSONL line into one or more events.
    /// An assistant message with multiple tool_use blocks produces multiple events.
    func parseLineEvents(_ line: String) -> [DetectedEvent] {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard let data = line.data(using: .utf8) else { return [] }

        guard let record = try? decoder.decode(JSONLRecord.self, from: data) else {
            return []
        }

        return detectEvents(from: record)
    }

    /// Single-event convenience (returns first event only). Used by tests.
    func parseLine(_ line: String) -> DetectedEvent? {
        parseLineEvents(line).first
    }

    func detectEvents(from record: JSONLRecord) -> [DetectedEvent] {
        switch record.type {
        case "system":
            if let event = handleSystemRecord(record) { return [event] }
        case "assistant":
            return handleAssistantRecord(record)
        case "user":
            return handleUserRecord(record)
        case "progress":
            if let event = handleProgressRecord(record) { return [event] }
        default:
            break
        }
        return []
    }

    private func handleSystemRecord(_ record: JSONLRecord) -> DetectedEvent? {
        if record.subtype == "turn_duration", let durationMs = record.durationMs {
            return .turnEnded(sessionId: record.sessionId, durationMs: durationMs, cwd: nil)
        }
        return nil
    }

    private func handleAssistantRecord(_ record: JSONLRecord) -> [DetectedEvent] {
        guard let content = record.message?.content else { return [] }

        switch content {
        case .blocks(let blocks):
            // Collect ALL tool_use blocks, not just the first
            var events: [DetectedEvent] = []
            for block in blocks {
                if block.type == "tool_use", let id = block.id, let name = block.name {
                    if name == "AskUserQuestion" {
                        let questionText = AnyCodable.extractQuestionText(from: block.input)
                        events.append(.askUserQuestion(
                            sessionId: record.sessionId, toolUseId: id,
                            questionText: questionText, cwd: nil))
                    } else {
                        events.append(.toolUseStarted(
                            sessionId: record.sessionId, toolUseId: id, toolName: name, cwd: nil))
                    }
                }
            }
            return events
        case .text:
            return []
        }
    }

    private func handleUserRecord(_ record: JSONLRecord) -> [DetectedEvent] {
        guard let content = record.message?.content else { return [] }

        switch content {
        case .text:
            // New user prompt
            return [.userPrompt(sessionId: record.sessionId, cwd: nil)]
        case .blocks(let blocks):
            // Collect ALL tool_result blocks
            var events: [DetectedEvent] = []
            for block in blocks {
                if block.type == "tool_result", let toolUseId = block.toolUseId {
                    events.append(.toolUseCompleted(
                        sessionId: record.sessionId, toolUseId: toolUseId, cwd: nil))
                }
            }
            return events
        }
    }

    private func handleProgressRecord(_ record: JSONLRecord) -> DetectedEvent? {
        if let dataType = record.data?.type {
            return .progressEvent(sessionId: record.sessionId, dataType: dataType)
        }
        return nil
    }

}
