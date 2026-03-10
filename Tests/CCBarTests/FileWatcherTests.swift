import XCTest

@testable import CCBar

final class FileWatcherTests: XCTestCase {
    var tempDir: String!
    var watcher: FileWatcher!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "CCBarTest-\(UUID().uuidString)"
        let projectDir = tempDir + "/test-project"
        try! FileManager.default.createDirectory(
            atPath: projectDir, withIntermediateDirectories: true)
        watcher = FileWatcher(claudeDir: tempDir)
    }

    override func tearDown() {
        watcher.stop()
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testDiscoverNewJSONLFile() {
        let expectation = XCTestExpectation(description: "Event detected")

        let jsonlPath = tempDir + "/test-project/session-123.jsonl"
        let record = """
            {"type":"system","subtype":"turn_duration","durationMs":5000,"sessionId":"session-123","uuid":"u1","timestamp":"2026-03-08T08:00:00Z"}

            """
        FileManager.default.createFile(atPath: jsonlPath, contents: nil)

        watcher.onEvent = { event in
            if case .turnEnded(let sid, let duration, _) = event {
                XCTAssertEqual(sid, "session-123")
                XCTAssertEqual(duration, 5000)
                expectation.fulfill()
            }
        }

        // First scan discovers the file but starts from end
        watcher.scanNow()

        // Now append data
        if let handle = FileHandle(forWritingAtPath: jsonlPath) {
            handle.seekToEndOfFile()
            handle.write(record.data(using: .utf8)!)
            handle.closeFile()
        }

        // Second scan reads new data
        watcher.scanNow()

        wait(for: [expectation], timeout: 2.0)
    }

    func testMultipleLines() {
        let jsonlPath = tempDir + "/test-project/session-456.jsonl"
        FileManager.default.createFile(atPath: jsonlPath, contents: nil)

        // First scan discovers file
        watcher.scanNow()

        var events: [DetectedEvent] = []
        watcher.onEvent = { event in
            events.append(event)
        }

        let lines = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/f"}}]},"sessionId":"session-456","uuid":"u1"}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"sessionId":"session-456","uuid":"u2"}
            {"type":"system","subtype":"turn_duration","durationMs":3000,"sessionId":"session-456","uuid":"u3"}

            """

        if let handle = FileHandle(forWritingAtPath: jsonlPath) {
            handle.seekToEndOfFile()
            handle.write(lines.data(using: .utf8)!)
            handle.closeFile()
        }

        watcher.scanNow()

        XCTAssertEqual(events.count, 3)
    }

    func testFileRemoval() {
        let jsonlPath = tempDir + "/test-project/session-789.jsonl"
        FileManager.default.createFile(atPath: jsonlPath, contents: nil)

        watcher.scanNow()

        // Remove file
        try! FileManager.default.removeItem(atPath: jsonlPath)

        // Scan again - should handle gracefully
        watcher.scanNow()
    }

    func testFileRemovalEmitsSessionEnded() {
        let jsonlPath = tempDir + "/test-project/session-end-test.jsonl"
        FileManager.default.createFile(atPath: jsonlPath, contents: nil)

        // First scan discovers the file
        watcher.scanNow()

        let expectation = XCTestExpectation(description: "sessionEnded emitted on file removal")

        watcher.onEvent = { event in
            if case .sessionEnded(let sid) = event {
                XCTAssertEqual(sid, "session-end-test")
                expectation.fulfill()
            }
        }

        // Remove file
        try! FileManager.default.removeItem(atPath: jsonlPath)

        // Next scan should emit sessionEnded
        watcher.scanNow()

        wait(for: [expectation], timeout: 2.0)
    }

    func testMultipleFileRemovalsEmitMultipleSessionEnded() {
        let path1 = tempDir + "/test-project/session-a.jsonl"
        let path2 = tempDir + "/test-project/session-b.jsonl"
        FileManager.default.createFile(atPath: path1, contents: nil)
        FileManager.default.createFile(atPath: path2, contents: nil)

        watcher.scanNow()

        var endedSessions: Set<String> = []
        let expectation = XCTestExpectation(description: "both sessions ended")
        expectation.expectedFulfillmentCount = 2

        watcher.onEvent = { event in
            if case .sessionEnded(let sid) = event, let sid = sid {
                endedSessions.insert(sid)
                expectation.fulfill()
            }
        }

        try! FileManager.default.removeItem(atPath: path1)
        try! FileManager.default.removeItem(atPath: path2)

        watcher.scanNow()

        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(endedSessions.contains("session-a"))
        XCTAssertTrue(endedSessions.contains("session-b"))
    }

    func testIncrementalReading() {
        let jsonlPath = tempDir + "/test-project/session-inc.jsonl"
        FileManager.default.createFile(atPath: jsonlPath, contents: nil)

        watcher.scanNow()

        var eventCount = 0
        watcher.onEvent = { _ in eventCount += 1 }

        // First append
        let line1 = """
            {"type":"system","subtype":"turn_duration","durationMs":1000,"sessionId":"s","uuid":"u1"}

            """
        if let h = FileHandle(forWritingAtPath: jsonlPath) {
            h.seekToEndOfFile()
            h.write(line1.data(using: .utf8)!)
            h.closeFile()
        }
        watcher.scanNow()
        XCTAssertEqual(eventCount, 1)

        // Second append
        let line2 = """
            {"type":"system","subtype":"turn_duration","durationMs":2000,"sessionId":"s","uuid":"u2"}

            """
        if let h = FileHandle(forWritingAtPath: jsonlPath) {
            h.seekToEndOfFile()
            h.write(line2.data(using: .utf8)!)
            h.closeFile()
        }
        watcher.scanNow()
        XCTAssertEqual(eventCount, 2)
    }
}
