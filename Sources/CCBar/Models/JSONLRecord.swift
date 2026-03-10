import Foundation

struct JSONLRecord: Codable {
    let type: String
    let uuid: String?
    let parentUuid: String?
    let timestamp: String?
    let sessionId: String?
    let subtype: String?
    let durationMs: Int?
    let message: MessageContent?
    let data: ProgressData?
    let parentToolUseID: String?
    let toolUseID: String?
    let userType: String?
    let sourceToolAssistantUUID: String?
}

struct MessageContent: Codable {
    let role: String?
    let content: MessageContentValue?
    let model: String?
    let id: String?
}

// content can be a String or an Array of ContentBlock
enum MessageContentValue: Codable {
    case text(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

struct ContentBlock: Codable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: AnyCodable?
    // tool_result fields
    let toolUseId: String?
    let content: ContentBlockContent?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

/// tool_result의 content는 String 또는 Array 형태로 올 수 있다
enum ContentBlockContent: Codable {
    case string(String)
    case parts([AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let parts = try? container.decode([AnyCodable].self) {
            self = .parts(parts)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .parts:
            try container.encodeNil()
        }
    }
}

struct ProgressData: Codable {
    let type: String?
    let message: ProgressMessage?
    let hookEvent: String?
    let hookName: String?
    let command: String?
}

struct ProgressMessage: Codable {
    let type: String?
    let message: MessageContent?
}

// Simple AnyCodable for tool inputs
struct AnyCodable: Codable {
    static func extractQuestionText(from input: AnyCodable?) -> String {
        if let dict = input?.value as? [String: Any],
           let questions = dict["questions"] as? [[String: Any]],
           let question = questions.first?["question"] as? String {
            return question
        }
        return "Waiting for your answer..."
    }

    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else {
            try container.encodeNil()
        }
    }
}
