import Foundation
import XCTest
@testable import MunaCore

/// The task against linux/service/agents/test/fake_claude.py, which speaks Claude Code's stream-json.
final class ClaudeTaskTests: XCTestCase {
    private var fake: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../linux/service/agents/test/fake_claude.py").standardized.path
    }

    func testTurnPermissionAndFollowUp() throws {
        guard FileManager.default.fileExists(atPath: fake), FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("needs python3 and the fake claude")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "claude-test")
        let task = ClaudeTask(id: "t1", cwd: folder.path, prompt: "Add a README", binary: fake, queue: queue)
        var permissions: [ClaudeTask.Permission] = []
        var finished: [Bool] = []
        var limits: [[String: Any]] = []
        task.onPermission = { task, permission in
            permissions.append(permission)
            task.answer(permission.requestId, permissions.count == 1 ? .allow : .deny)
        }
        task.onFinished = { _, ok in finished.append(ok) }
        task.onRateLimit = { limits.append($0) }

        func until(_ what: String, _ condition: @escaping () -> Bool) {
            let done = expectation(description: what)
            func check() { queue.asyncAfter(deadline: .now() + 0.05) { condition() ? done.fulfill() : check() } }
            check()
            wait(for: [done], timeout: 10)
        }

        queue.sync { task.start() }
        until("first turn") { finished.count == 1 }
        queue.sync {
            XCTAssertEqual(task.status, .idle)
            XCTAssertEqual(task.model, "claude-fake")
            XCTAssertFalse(task.sessionId.isEmpty)
            XCTAssertEqual(permissions.first?.verb, "Writing")
            XCTAssertEqual(permissions.first?.detail, "README.md")      // relative to the task's folder
            XCTAssertEqual(task.transcript.map(\.kind), [.user, .text, .tool, .note, .text, .result])
            XCTAssertEqual(task.transcript[2].ok, true)
            XCTAssertEqual(task.transcript[2].text, "Writing README.md")
            XCTAssertEqual(task.transcript.last?.text, "")              // the answer was the last message already
            XCTAssertEqual(task.costUsd, 0.01, accuracy: 0.0001)
            XCTAssertEqual(task.tokens, 15)
            XCTAssertEqual(limits.count, 1)
            XCTAssertTrue(task.running)
            task.send("Now add a license")
        }
        until("second turn") { finished.count == 2 }
        queue.sync {
            XCTAssertEqual(task.transcript.last?.text, "Nothing was changed.")   // denied this time
            XCTAssertEqual(task.costUsd, 0.02, accuracy: 0.0001)                 // the session's cost so far
            task.stop()
        }
        until("stopped") { !task.running }
        queue.sync { XCTAssertEqual(task.status, .stopped) }
    }

    func testDescribeTool() {
        XCTAssertEqual(ClaudeTask.describeTool("Bash", ["command": "npm   test"]).verb, "Running")
        XCTAssertEqual(ClaudeTask.describeTool("Bash", ["command": "npm   test"]).detail, "npm test")
        XCTAssertEqual(ClaudeTask.describeTool("Edit", ["file_path": "/p/src/a.js"], cwd: "/p").detail, "src/a.js")
        XCTAssertEqual(ClaudeTask.describeTool("TodoWrite", ["todos": [1]]).detail, "the to-do list")
        XCTAssertEqual(ClaudeTask.describeTool("Mystery", nil).verb, "Mystery")
    }

    func testMissingBinary() {
        let queue = DispatchQueue(label: "claude-missing")
        let task = ClaudeTask(id: "t2", cwd: "/tmp", prompt: "x", binary: "/nonexistent/claude", queue: queue)
        queue.sync { task.start() }
        queue.sync {
            XCTAssertEqual(task.status, .failed)
            XCTAssertTrue(task.error.hasPrefix("Claude Code could not start"))
        }
    }
}
