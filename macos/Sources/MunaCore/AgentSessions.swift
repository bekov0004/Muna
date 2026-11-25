import Foundation

/// AI coding agents running in a terminal, from their own local session logs, as Muna on Linux reads
/// them (linux/service/agents/module.js): Claude Code in ~/.claude/projects, Codex in
/// ~/.codex/sessions. A session written to in the last 20 seconds is working.
public struct AgentSession: Equatable {
    public let agent: String          // "Claude Code" or "Codex"
    public let path: String
    public let cwd: String
    public let modified: Date
    public let working: Bool

    /// The project: the last part of its folder.
    public var project: String { cwd.isEmpty ? "session" : URL(fileURLWithPath: cwd).lastPathComponent }
    /// The log's name without .jsonl (Claude Code's session id).
    public var sessionId: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

public enum AgentSessions {
    public static let activeSeconds: TimeInterval = 20
    public static let weekSeconds: TimeInterval = 7 * 86400

    public static var claudeRoot: String {
        ProcessInfo.processInfo.environment["MUNA_CLAUDE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    }

    public static var codexRoot: String {
        ProcessInfo.processInfo.environment["MUNA_CODEX_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions").path
    }

    /// The sessions of the last week, newest first; `except`: session ids Muna runs itself.
    public static func scan(claudeRoot: String = claudeRoot, codexRoot: String = codexRoot, except: Set<String> = [],
                            now: Date = Date()) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for (agent, root, depth) in [("Claude Code", claudeRoot, 2), ("Codex", codexRoot, 4)] {
            for (path, modified) in logs(in: root, depth: depth) where now.timeIntervalSince(modified) <= weekSeconds {
                let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                guard !except.contains(id) else { continue }
                sessions.append(AgentSession(agent: agent, path: path, cwd: lastCwd(of: path), modified: modified,
                                             working: now.timeIntervalSince(modified) <= activeSeconds))
            }
        }
        return sessions.sorted { $0.modified > $1.modified }
    }

    /// The .jsonl files at most `depth` folders below `root`, with their modification times.
    static func logs(in root: String, depth: Int) -> [(String, Date)] {
        let fileManager = FileManager.default
        var result: [(String, Date)] = []
        func walk(_ folder: String, _ level: Int) {
            guard level <= depth, let names = try? fileManager.contentsOfDirectory(atPath: folder) else { return }
            for name in names {
                let path = "\(folder)/\(name)"
                var isFolder: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isFolder) else { continue }
                if isFolder.boolValue {
                    walk(path, level + 1)
                } else if name.hasSuffix(".jsonl"),
                          let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                    result.append((path, modified))
                }
            }
        }
        walk(root, 1)
        return result
    }

    /// The folder the session works in: the last "cwd" in its log (Codex keeps it in payload.cwd).
    static func lastCwd(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 65536 ? size - 65536 : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let cwd = object["cwd"] as? String, !cwd.isEmpty { return cwd }
            if let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return ""
    }
}
