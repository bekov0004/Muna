import Foundation
import XCTest
@testable import MunaCore

final class AgentSessionsTests: XCTestCase {
    func testFindsWorkingAndRecentSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muna-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude/-home-me-app")
        let codex = root.appendingPathComponent("codex/2026/11/25")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let now = Date()
        func write(_ url: URL, _ lines: [String], age: TimeInterval) throws {
            try Data(lines.joined(separator: "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write(claude.appendingPathComponent("s-working.jsonl"),
                  [#"{"type":"user","cwd":"/home/me/old"}"#, #"{"type":"assistant","cwd":"/home/me/app"}"#, "not json"], age: 5)
        try write(claude.appendingPathComponent("s-ours.jsonl"), [#"{"cwd":"/home/me/app"}"#], age: 1)
        try write(claude.appendingPathComponent("s-old.jsonl"), [#"{"cwd":"/home/me/app"}"#], age: 8 * 86400)
        try write(codex.appendingPathComponent("rollout-1.jsonl"),
                  [#"{"type":"session_meta","payload":{"cwd":"/home/me/site"}}"#], age: 600)
        let sessions = AgentSessions.scan(claudeRoot: root.appendingPathComponent("claude").path,
                                          codexRoot: root.appendingPathComponent("codex").path, except: ["s-ours"], now: now)
        XCTAssertEqual(sessions.map(\.sessionId), ["s-working", "rollout-1"])
        XCTAssertEqual(sessions.map(\.working), [true, false])
        XCTAssertEqual(sessions.map(\.project), ["app", "site"])
        XCTAssertEqual(sessions.map(\.agent), ["Claude Code", "Codex"])
    }
}
