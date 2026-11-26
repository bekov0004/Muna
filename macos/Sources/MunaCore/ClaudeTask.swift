import Foundation

/// One Claude Code task run by Muna in the background, as Muna on Linux does it
/// (linux/service/agents/claudeTask.js): `claude -p` with the stream-json input and output.
///   we send     control_request initialize; user messages (any time, also later)
///   it sends    system/init, assistant (text, tool_use), user (tool_result), rate_limit_event, result,
///               and control_request can_use_tool before anything that needs permission (answered with
///               control_response: allow with the input, or deny).
/// The process stays up between turns, so the task can be given more to do; a task that ended can be
/// continued with --resume and its session id. Everything is reported on `queue`.
public final class ClaudeTask {
    public enum Status: String { case starting, working, waiting, idle, done, failed, stopped }

    public struct Entry: Identifiable {
        public enum Kind: String { case user, text, tool, result, error, note }
        public let id = UUID()
        public let kind: Kind
        public var text: String
        public var tool = ""
        public var ok: Bool?
        public var output = ""
        public let at = Date()
    }

    /// Claude asks before using a tool.
    public struct Permission: Identifiable {
        public let requestId: String
        public let tool: String
        public let verb: String
        public let detail: String
        public let description: String
        let input: [String: Any]
        let suggestions: [Any]
        public var id: String { requestId }
    }

    public enum Decision { case allow, always, deny }

    public let id: String
    public let cwd: String
    public let prompt: String
    public let binary: String
    public let queue: DispatchQueue
    public private(set) var model: String
    public private(set) var sessionId: String
    public private(set) var status = Status.starting
    /// What it is doing now, in a few words.
    public private(set) var current = ""
    public let startedAt = Date()
    public private(set) var lastAt = Date()
    public private(set) var costUsd: Double = 0
    public private(set) var tokens = 0
    public private(set) var turns = 0
    public private(set) var error = ""
    public private(set) var transcript: [Entry] = []
    public private(set) var pending: [Permission] = []

    public var onChange: (ClaudeTask) -> Void = { _ in }
    public var onPermission: (ClaudeTask, Permission) -> Void = { _, _ in }
    public var onFinished: (ClaudeTask, Bool) -> Void = { _, _ in }
    /// rate_limit_event: the plan's 5-hour and weekly use.
    public var onRateLimit: ([String: Any]) -> Void = { _ in }

    static let transcriptMax = 400
    static let textMax = 4000

    private var process: Process?
    private var stdin: FileHandle?
    private var stderrLines: [String] = []
    private var toolEntries: [String: Int] = [:]   // tool_use id → index in the transcript
    private var requestCounter = 0
    private var stopping = false
    private var sessionCost: Double = 0
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var outputEnded = false
    private var exitStatus: Int32?

    public init(id: String, cwd: String, prompt: String, model: String = "", binary: String, sessionId: String = "",
                queue: DispatchQueue = .main) {
        self.id = id
        self.cwd = cwd
        self.prompt = prompt
        self.model = model
        self.binary = binary
        self.sessionId = sessionId
        self.queue = queue
    }

    public var running: Bool { process != nil }
    public var project: String { URL(fileURLWithPath: cwd).lastPathComponent }

    // --- where claude is ------------------------------------------------------------------------

    /// Folders where claude and node usually are: an app started from the Finder does not get the
    /// shell's PATH, and claude is a node script.
    public static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/opt/homebrew/bin",
                "/usr/local/bin", "/usr/bin", "/bin"]
    }

    /// Codex (npm installs it on the PATH), or nil.
    public static func findCodex() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["MUNA_CODEX_BIN"], !fromEnv.isEmpty { return fromEnv }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in path + searchPath {
            let candidate = "\(folder)/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func findClaude() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["MUNA_CLAUDE_BIN"], !fromEnv.isEmpty { return fromEnv }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in path + searchPath {
            let candidate = "\(folder)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // --- running ----------------------------------------------------------------------------------

    /// Call on `queue`.
    public func start(message: String? = nil) {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--permission-prompt-tool", "stdio"]
        if !model.isEmpty { arguments += ["--model", model] }
        if !sessionId.isEmpty { arguments += ["--resume", sessionId] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "muna"
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (path + Self.searchPath.filter { !path.contains($0) }).joined(separator: ":")
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        outputBuffer = Data()
        errorBuffer = Data()
        outputEnded = false
        exitStatus = nil
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.received(data, error: false) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.received(data, error: true) }
        }
        process.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            self?.queue.async {
                self?.exitStatus = code
                self?.checkExit()
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            fail("Claude Code could not start: \(error.localizedDescription)")
            return
        }
        self.process = process
        stdin = input.fileHandleForWriting
        stopping = false
        sessionCost = 0          // a new process counts the session's cost from zero
        status = .working
        current = "Starting"
        write(["type": "control_request", "request_id": nextRequest(), "request": ["subtype": "initialize"]])
        say(message ?? prompt)
        changed()
    }

    /// More to do: in the running process, or (the process ended) continuing the session.
    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard process != nil else {
            error = ""
            start(message: text)
            return
        }
        say(text)
        changed()
    }

    @discardableResult
    public func answer(_ requestId: String, _ decision: Decision) -> Bool {
        guard let index = pending.firstIndex(where: { $0.requestId == requestId }) else { return false }
        let request = pending.remove(at: index)
        var response: [String: Any]
        if decision == .deny {
            response = ["behavior": "deny", "message": "The user denied this in Muna."]
        } else {
            response = ["behavior": "allow", "updatedInput": request.input]
            if decision == .always, !request.suggestions.isEmpty { response["updatedPermissions"] = request.suggestions }
        }
        write(["type": "control_response", "response": ["subtype": "success", "request_id": requestId, "response": response]])
        let word = decision == .deny ? "Denied" : decision == .always ? "Allowed for this session" : "Allowed"
        add(Entry(kind: .note, text: "\(word): \(request.verb) \(request.detail)".trimmingCharacters(in: .whitespaces)))
        if pending.isEmpty && status == .waiting { status = .working }
        changed()
        return true
    }

    /// Stops what it is doing now (the session stays; more can be asked).
    public func interrupt() {
        guard process != nil else { return }
        write(["type": "control_request", "request_id": nextRequest(), "request": ["subtype": "interrupt"]])
        // permissions still asked are moot now
        for request in pending {
            write(["type": "control_response", "response": ["subtype": "success", "request_id": request.requestId,
                                                            "response": ["behavior": "deny", "message": "Interrupted."]]])
        }
        pending = []
        current = "Stopping"
        changed()
    }

    /// Ends the process (the session can still be continued).
    public func stop() {
        guard let process else { return }
        stopping = true
        interrupt()
        try? stdin?.close()
        stdin = nil
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.process === process, process.isRunning { process.terminate() }
        }
    }

    // --- the stream ----------------------------------------------------------------------------------

    private func say(_ text: String) {
        add(Entry(kind: .user, text: Self.clip(text)))
        write(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]])
        status = .working
        current = "Thinking"
    }

    private func nextRequest() -> String {
        requestCounter += 1
        return "muna-\(id)-\(requestCounter)"
    }

    private func write(_ object: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do {
            try stdin.write(contentsOf: data + Data("\n".utf8))
        } catch {
            // the process is gone; its exit is handled there
        }
    }

    private func received(_ data: Data, error: Bool) {
        if error {
            guard !data.isEmpty else { return }
            errorBuffer.append(data)
            while let end = errorBuffer.firstIndex(of: 10) {
                let line = String(decoding: errorBuffer[errorBuffer.startIndex..<end], as: UTF8.self)
                errorBuffer = Data(errorBuffer[(end + 1)...])
                stderrLines.append(line)
                if stderrLines.count > 20 { stderrLines.removeFirst() }
            }
            return
        }
        if data.isEmpty {
            outputEnded = true
            checkExit()
            return
        }
        outputBuffer.append(data)
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = Data(outputBuffer[outputBuffer.startIndex..<end])
            outputBuffer = Data(outputBuffer[(end + 1)...])
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        lastAt = Date()
        switch message["type"] as? String {
        case "system":
            if message["subtype"] as? String == "init" {
                sessionId = message["session_id"] as? String ?? sessionId
                model = message["model"] as? String ?? model
            }
            current = "Thinking"
        case "assistant":
            for block in Self.blocks(message) {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        add(Entry(kind: .text, text: Self.clip(text)))
                        current = "Writing"
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let described = Self.describeTool(name, block["input"] as? [String: Any], cwd: cwd)
                    let summary = "\(described.verb) \(described.detail)".trimmingCharacters(in: .whitespaces)
                    add(Entry(kind: .tool, text: summary, tool: name))
                    if let toolId = block["id"] as? String { toolEntries[toolId] = transcript.count - 1 }
                    current = summary
                case "thinking":
                    current = "Thinking"
                default:
                    break
                }
            }
        case "user":
            for block in Self.blocks(message) where block["type"] as? String == "tool_result" {
                if let toolId = block["tool_use_id"] as? String, let index = toolEntries.removeValue(forKey: toolId),
                   transcript.indices.contains(index) {
                    transcript[index].ok = !(block["is_error"] as? Bool ?? false)
                    transcript[index].output = String(Self.clip(Self.resultText(block["content"])).prefix(600))
                }
                current = "Thinking"
            }
        case "rate_limit_event":
            onRateLimit(message["rate_limit_info"] as? [String: Any] ?? [:])
        case "control_request":
            controlRequest(message)
        case "result":
            turns += message["num_turns"] as? Int ?? 0
            // total_cost_usd is the cost of the session so far
            if let total = (message["total_cost_usd"] as? NSNumber)?.doubleValue {
                costUsd += max(0, total - sessionCost)
                sessionCost = total
            }
            let usage = message["usage"] as? [String: Any] ?? [:]
            tokens += ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            let ok = !(message["is_error"] as? Bool ?? false) && message["subtype"] as? String == "success"
            let answer = message["result"] as? String ?? (ok ? "" : message["subtype"] as? String ?? "Error")
            // the answer is usually the last message itself: then the result does not say it again
            let repeated = transcript.last.map { $0.kind == .text && $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == answer.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false
            var entry = Entry(kind: .result, text: repeated ? "" : Self.clip(answer))
            entry.ok = ok
            add(entry)
            status = ok ? .idle : .failed
            if !ok { error = String((message["result"] as? String ?? message["subtype"] as? String ?? "error").prefix(300)) }
            current = ok ? "Done" : "Stopped with an error"
            onFinished(self, ok)
        default:
            break
        }
        changed()
    }

    private func controlRequest(_ message: [String: Any]) {
        let requestId = message["request_id"] as? String ?? ""
        let request = message["request"] as? [String: Any] ?? [:]
        guard request["subtype"] as? String == "can_use_tool" else {
            // nothing else is offered by Muna: say so, so that Claude Code does not wait
            write(["type": "control_response", "response": ["subtype": "error", "request_id": requestId,
                                                            "error": "Muna does not handle \(request["subtype"] as? String ?? "this")"]])
            return
        }
        let name = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let described = Self.describeTool(name, input, cwd: cwd)
        let permission = Permission(requestId: requestId, tool: request["display_name"] as? String ?? name, verb: described.verb,
                                    detail: described.detail, description: request["description"] as? String ?? "",
                                    input: input, suggestions: request["permission_suggestions"] as? [Any] ?? [])
        pending.append(permission)
        status = .waiting
        current = "Waiting for you: \(described.verb) \(described.detail)".trimmingCharacters(in: .whitespaces)
        onPermission(self, permission)
    }

    /// The process is over when it exited and its output was read to the end.
    private func checkExit() {
        guard let code = exitStatus, outputEnded, process != nil else { return }
        process = nil
        stdin = nil
        pending = []
        if stopping {
            status = .stopped
            current = "Stopped"
            add(Entry(kind: .note, text: "Stopped"))
        } else if status == .idle || status == .done || code == 0 {
            status = .done
            current = "Done"
        } else {
            let tail = stderrLines.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            fail(tail.isEmpty ? "Claude Code ended (\(code))" : tail)
            return
        }
        changed()
    }

    private func fail(_ text: String) {
        status = .failed
        error = String(text.prefix(300))
        current = "Failed"
        add(Entry(kind: .error, text: error))
        onFinished(self, false)
        changed()
    }

    private func add(_ entry: Entry) {
        transcript.append(entry)
        if transcript.count > Self.transcriptMax {
            let drop = transcript.count - Self.transcriptMax
            transcript.removeFirst(drop)
            toolEntries = toolEntries.compactMapValues { $0 >= drop ? $0 - drop : nil }
        }
    }

    private func changed() {
        onChange(self)
    }

    // --- words ----------------------------------------------------------------------------------------

    static let verbs = [
        "Bash": "Running", "Read": "Reading", "Write": "Writing", "Edit": "Editing", "MultiEdit": "Editing",
        "NotebookEdit": "Editing", "Grep": "Searching", "Glob": "Looking for", "WebFetch": "Fetching",
        "WebSearch": "Searching the web for", "Task": "Delegating", "Agent": "Delegating", "TodoWrite": "Planning", "LS": "Listing",
    ]

    /// A tool call in a few words: ("Editing", "src/main.js"), ("Running", "npm test").
    public static func describeTool(_ name: String, _ input: [String: Any]?, cwd: String = "") -> (verb: String, detail: String) {
        func relative(_ path: String) -> String {
            !cwd.isEmpty && path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
        }
        var detail = ""
        if let input {
            let keys = ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description"]
            for key in keys {
                if let value = input[key] as? String {
                    detail = ["file_path", "notebook_path", "path"].contains(key) ? relative(value) : value
                    break
                }
            }
            if detail.isEmpty && name == "TodoWrite" { detail = "the to-do list" }
            if detail.isEmpty, let first = input.values.compactMap({ $0 as? String }).first { detail = first }
        }
        detail = detail.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if detail.count > 120 { detail = String(detail.prefix(117)) + "…" }
        return (verbs[name] ?? name, detail)
    }

    static func clip(_ text: String) -> String {
        text.count > textMax ? String(text.prefix(textMax)) + "…" : text
    }

    static func blocks(_ message: [String: Any]) -> [[String: Any]] {
        (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.map { $0["type"] as? String == "text" ? ($0["text"] as? String ?? "") : "" }.joined(separator: "\n")
        }
        return ""
    }
}
