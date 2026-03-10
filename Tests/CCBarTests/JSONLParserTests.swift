import XCTest

@testable import CCBar

final class JSONLParserTests: XCTestCase {
    let parser = JSONLParser()

    func testParseTurnEnd() {
        let line = """
            {"type":"system","subtype":"turn_duration","durationMs":165124,"timestamp":"2026-03-08T08:14:58.655Z","sessionId":"abc-123","uuid":"uuid-1"}
            """
        let event = parser.parseLine(line)
        if case .turnEnded(let sessionId, let durationMs, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(durationMs, 165124)
        } else {
            XCTFail("Expected turnEnded event, got \(String(describing: event))")
        }
    }

    func testParseToolUse() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading file."},{"type":"tool_use","id":"toolu_01ABC","name":"Read","input":{"file_path":"/path/to/file.ts"}}]},"sessionId":"abc-123","uuid":"uuid-2"}
            """
        let event = parser.parseLine(line)
        if case .toolUseStarted(let sessionId, let toolUseId, let toolName, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(toolUseId, "toolu_01ABC")
            XCTAssertEqual(toolName, "Read")
        } else {
            XCTFail("Expected toolUseStarted event, got \(String(describing: event))")
        }
    }

    func testParseToolResult() {
        let line = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01ABC","content":"file contents","is_error":false}]},"sessionId":"abc-123","uuid":"uuid-3"}
            """
        let event = parser.parseLine(line)
        if case .toolUseCompleted(let sessionId, let toolUseId, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(toolUseId, "toolu_01ABC")
        } else {
            XCTFail("Expected toolUseCompleted event, got \(String(describing: event))")
        }
    }

    func testParseAskUserQuestion() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01ASK","name":"AskUserQuestion","input":{"questions":[{"question":"Which tech stack?","header":"Tech Stack","multiSelect":false,"options":[{"label":"Swift","description":"Native macOS"}]}]}}]},"sessionId":"abc-123","uuid":"uuid-4"}
            """
        let event = parser.parseLine(line)
        if case .askUserQuestion(let sessionId, let toolUseId, let questionText, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(toolUseId, "toolu_01ASK")
            XCTAssertEqual(questionText, "Which tech stack?")
        } else {
            XCTFail("Expected askUserQuestion event, got \(String(describing: event))")
        }
    }

    func testParseUserPrompt() {
        let line = """
            {"type":"user","userType":"external","message":{"role":"user","content":"Hello"},"sessionId":"abc-123","uuid":"uuid-5"}
            """
        let event = parser.parseLine(line)
        if case .userPrompt(let sessionId, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
        } else {
            XCTFail("Expected userPrompt event, got \(String(describing: event))")
        }
    }

    func testParseProgress() {
        let line = """
            {"type":"progress","data":{"type":"agent_progress"},"parentToolUseID":"toolu_parent","toolUseID":"toolu_child","sessionId":"abc-123","uuid":"uuid-6"}
            """
        let event = parser.parseLine(line)
        if case .progressEvent(let sessionId, let dataType) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(dataType, "agent_progress")
        } else {
            XCTFail("Expected progressEvent, got \(String(describing: event))")
        }
    }

    func testParseEmptyLine() {
        let event = parser.parseLine("")
        XCTAssertNil(event)
    }

    func testParseInvalidJSON() {
        let event = parser.parseLine("not json")
        XCTAssertNil(event)
    }

    func testParseUnknownType() {
        let line = """
            {"type":"file-history-snapshot","uuid":"uuid-7"}
            """
        let event = parser.parseLine(line)
        XCTAssertNil(event)
    }

    // MARK: - tool_result with array content (permission reject)

    func testParseToolResultWithArrayContent() {
        // When user rejects permission, content may be an array instead of string
        let line = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_REJECT","content":[{"type":"text","text":"User rejected this tool use"}],"is_error":true}]},"sessionId":"abc-123","uuid":"uuid-8"}
            """
        let event = parser.parseLine(line)
        if case .toolUseCompleted(let sessionId, let toolUseId, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(toolUseId, "toolu_REJECT")
        } else {
            XCTFail("Expected toolUseCompleted for rejected tool, got \(String(describing: event))")
        }
    }

    func testParseToolResultWithNullContent() {
        let line = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_NULL","is_error":true}]},"sessionId":"abc-123","uuid":"uuid-9"}
            """
        let event = parser.parseLine(line)
        if case .toolUseCompleted(let sessionId, let toolUseId, _) = event {
            XCTAssertEqual(sessionId, "abc-123")
            XCTAssertEqual(toolUseId, "toolu_NULL")
        } else {
            XCTFail("Expected toolUseCompleted, got \(String(describing: event))")
        }
    }

    // MARK: - Multiple tool_use blocks

    func testParseMultipleToolUseBlocks() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}},{"type":"tool_use","id":"t2","name":"Bash","input":{}}]},"sessionId":"abc-123","uuid":"uuid-10"}
            """
        let events = parser.parseLineEvents(line)
        XCTAssertEqual(events.count, 2)

        if case .toolUseStarted(_, let id1, let name1, _) = events[0] {
            XCTAssertEqual(id1, "t1")
            XCTAssertEqual(name1, "Read")
        } else {
            XCTFail("Expected first toolUseStarted")
        }

        if case .toolUseStarted(_, let id2, let name2, _) = events[1] {
            XCTAssertEqual(id2, "t2")
            XCTAssertEqual(name2, "Bash")
        } else {
            XCTFail("Expected second toolUseStarted")
        }
    }

    func testParseMultipleToolResults() {
        let line = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"tool_result","tool_use_id":"t2","content":"ok"}]},"sessionId":"abc-123","uuid":"uuid-11"}
            """
        let events = parser.parseLineEvents(line)
        XCTAssertEqual(events.count, 2)
    }
}
