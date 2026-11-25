import AppKit
import Combine
import MunaCore
import SwiftUI

/// AI agents, as Muna on Linux (linux/service/agents, linux/src/widgets/agents): Claude Code tasks run
/// in the background (MunaCore's ClaudeTask), their questions come to the capsule, the agents window
/// follows them, and the plan's limits (5 hours, week) come with the answers.
final class AgentsModel: ObservableObject {
    struct Limit: Equatable {
        let percent: Double
        let resetsAt: Date
    }

    @Published private(set) var tasks: [ClaudeTask] = []
    /// Bumped when a task changed (ClaudeTask is not observable itself).
    @Published private(set) var revision = 0
    var revisionPublisher: Published<Int>.Publisher { $revision }
    @Published private(set) var fiveHour: Limit?
    @Published private(set) var sevenDay: Limit?
    @Published var selectedId: String?
    /// What is written for the selected task, or for a new one.
    @Published var draft = ""
    @Published var newPrompt = ""
    @Published var newFolder = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var creating = false

    /// A task asks before using a tool / a task ended (for the capsule).
    var onPermission: (ClaudeTask, ClaudeTask.Permission) -> Void = { _, _ in }
    var onFinished: (ClaudeTask, Bool) -> Void = { _, _ in }

    let claudePath = ClaudeTask.findClaude()
    private var counter = 0

    /// Claude Code and Codex sessions running in a terminal (from their logs), looked at while shown.
    @Published private(set) var sessions: [AgentSession] = []
    private var sessionTimer: Timer?

    func watchSessions() {
        scanSessions()
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.scanSessions() }
    }

    func unwatchSessions() {
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    private func scanSessions() {
        let ours = Set(tasks.map(\.sessionId).filter { !$0.isEmpty })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = AgentSessions.scan(except: ours)
            DispatchQueue.main.async { self?.sessions = found }
        }
    }

    var selected: ClaudeTask? { tasks.first { $0.id == selectedId } ?? tasks.first }

    /// The first question waiting for an answer.
    var waiting: (task: ClaudeTask, permission: ClaudeTask.Permission)? {
        for task in tasks {
            if let permission = task.pending.first { return (task, permission) }
        }
        return nil
    }

    var runningCount: Int { tasks.filter { $0.status == .working || $0.status == .waiting || $0.status == .starting }.count }

    /// Starts a new task in a folder.
    func start(prompt: String, folder: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let claudePath else { return }
        counter += 1
        let task = ClaudeTask(id: "\(Int(Date().timeIntervalSince1970))-\(counter)", cwd: folder, prompt: prompt, binary: claudePath)
        task.onChange = { [weak self] _ in self?.revision += 1 }
        task.onPermission = { [weak self] task, permission in self?.onPermission(task, permission) }
        task.onFinished = { [weak self] task, ok in self?.onFinished(task, ok) }
        task.onRateLimit = { [weak self] info in self?.rateLimit(info) }
        tasks.insert(task, at: 0)
        selectedId = task.id
        creating = false
        newPrompt = ""
        task.start()
    }

    func send() {
        guard let task = selected else { return }
        task.send(draft)
        draft = ""
    }

    func answer(_ task: ClaudeTask, _ permission: ClaudeTask.Permission, _ decision: ClaudeTask.Decision) {
        task.answer(permission.requestId, decision)
    }

    func remove(_ task: ClaudeTask) {
        task.stop()
        tasks.removeAll { $0 === task }
        if selectedId == task.id { selectedId = tasks.first?.id }
    }

    func stopAll() {
        tasks.forEach { $0.stop() }
    }

    /// rate_limit_event: {unifiedWindows: {five_hour: {utilization, resetsAt}, seven_day: …}}
    private func rateLimit(_ info: [String: Any]) {
        guard let windows = info["unifiedWindows"] as? [String: Any] else { return }
        func limit(_ key: String) -> Limit? {
            guard let window = windows[key] as? [String: Any] else { return nil }
            let utilization = (window["utilization"] as? NSNumber)?.doubleValue ?? 0
            let resets = (window["resetsAt"] as? NSNumber)?.doubleValue ?? 0
            return Limit(percent: (utilization * 1000).rounded() / 10, resetsAt: Date(timeIntervalSince1970: resets))
        }
        fiveHour = limit("five_hour") ?? fiveHour
        sevenDay = limit("seven_day") ?? sevenDay
    }

    /// "Needs you", "Working", "Done" …
    static func statusText(_ task: ClaudeTask) -> String {
        switch task.status {
        case .starting: return "Starting"
        case .working: return task.current.isEmpty ? "Working" : task.current
        case .waiting: return "Needs you"
        case .idle: return "Done, waiting for more"
        case .done: return "Done"
        case .failed: return task.error.isEmpty ? "Failed" : task.error
        case .stopped: return "Stopped"
        }
    }

    static func statusSymbol(_ task: ClaudeTask) -> (String, Color) {
        switch task.status {
        case .starting, .working: return ("ellipsis.circle", MunaColor.accent)
        case .waiting: return ("questionmark.circle", MunaColor.amber)
        case .idle, .done: return ("checkmark.circle", MunaColor.ok)
        case .failed: return ("xmark.octagon", MunaColor.warning)
        case .stopped: return ("stop.circle", MunaColor.secondary)
        }
    }

    static func resetText(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        if minutes >= 1440 { return "resets in \(minutes / 1440) d" }
        if minutes >= 60 { return "resets in \(minutes / 60) h \(minutes % 60) min" }
        return "resets in \(minutes) min"
    }
}

// --- the question in the capsule -----------------------------------------------------------------

/// A task asks before doing something: in the capsule, with Deny / Always / Allow.
struct AgentPermissionView: View {
    @EnvironmentObject var agents: AgentsModel
    let openWindow: () -> Void

    var body: some View {
        let _ = agents.revision
        if let waiting = agents.waiting {
            VStack(alignment: .leading, spacing: 10) {
                Caption("\(waiting.task.project) · Claude wants to") {
                    Pill(label: "Open agents") { openWindow() }
                }
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 24)).foregroundColor(MunaColor.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(waiting.permission.verb) \(waiting.permission.detail)")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                        if !waiting.permission.description.isEmpty {
                            Text(waiting.permission.description).font(.system(size: 11)).foregroundColor(MunaColor.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Spacer()
                    Pill(label: "Deny") { agents.answer(waiting.task, waiting.permission, .deny) }
                    Pill(label: "Always in this task") { agents.answer(waiting.task, waiting.permission, .always) }
                    Pill(label: "Allow", accent: true) { agents.answer(waiting.task, waiting.permission, .allow) }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundColor(MunaColor.ok)
                Text("Nothing to answer").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// --- the quick panel's page ---------------------------------------------------------------------------

struct AgentsPage: View {
    @EnvironmentObject var agents: AgentsModel
    let openWindow: () -> Void

    var body: some View {
        let _ = agents.revision
        VStack(spacing: 10) {
            QuickBlock {
                if agents.claudePath == nil {
                    Text("Claude Code is not installed (the claude command was not found).")
                        .font(.system(size: 12))
                        .foregroundColor(MunaColor.secondary)
                } else if agents.tasks.isEmpty {
                    Text("No tasks yet. Start one: Claude Code works in a folder and asks before it changes anything.")
                        .font(.system(size: 12))
                        .foregroundColor(MunaColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(agents.tasks.prefix(5), id: \.id) { task in
                        let (symbol, tint) = AgentsModel.statusSymbol(task)
                        HStack(spacing: 8) {
                            Image(systemName: symbol).foregroundColor(tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(AgentsModel.statusText(task)).font(.system(size: 11)).foregroundColor(MunaColor.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            agents.selectedId = task.id
                            openWindow()
                        }
                    }
                }
                Pill(label: agents.tasks.isEmpty ? "New task…" : "Open the agents window", accent: true) {
                    if agents.tasks.isEmpty { agents.creating = true }
                    openWindow()
                }
            }
            let recent = agents.sessions.filter { $0.working }.prefix(4) + agents.sessions.filter { !$0.working }.prefix(2)
            if !recent.isEmpty {
                QuickBlock {
                    Text("IN TERMINALS").font(.system(size: 10, weight: .heavy)).foregroundColor(MunaColor.caption)
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, session in
                        HStack(spacing: 8) {
                            Circle().fill(session.working ? MunaColor.ok : Color.white.opacity(0.25)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(session.project) · \(session.agent)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(session.working ? "Working now" : "Last active \(session.modified.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundColor(MunaColor.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            LimitsBlock()
        }
        .onAppear { agents.watchSessions() }
        .onDisappear { agents.unwatchSessions() }
    }
}

/// The plan's use: the 5-hour window and the week.
struct LimitsBlock: View {
    @EnvironmentObject var agents: AgentsModel

    var body: some View {
        if agents.fiveHour != nil || agents.sevenDay != nil {
            QuickBlock {
                if let five = agents.fiveHour {
                    MeterRow(label: "5 hours", share: five.percent / 100, value: "\(Int(five.percent))% · \(AgentsModel.resetText(five.resetsAt))")
                }
                if let week = agents.sevenDay {
                    MeterRow(label: "Week", share: week.percent / 100, value: "\(Int(week.percent))% · \(AgentsModel.resetText(week.resetsAt))")
                }
            }
        }
    }
}

// --- the agents window --------------------------------------------------------------------------------

final class AgentsWindowController {
    private var window: NSWindow?
    private let agents: AgentsModel

    init(agents: AgentsModel) {
        self.agents = agents
    }

    func show() {
        if window == nil {
            let root = AgentsView().environmentObject(agents)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Agents"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(NSSize(width: 960, height: 640))
            window.minSize = NSSize(width: 700, height: 440)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AgentsView: View {
    @EnvironmentObject var agents: AgentsModel

    var body: some View {
        let _ = agents.revision
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { agents.creating = true } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("New task")
                    Spacer()
                    Text("Agents").font(.system(size: 14, weight: .bold))
                    Spacer()
                    Spacer().frame(width: 30)
                }
                .padding(.top, 28)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(agents.tasks, id: \.id) { task in
                            TaskRow(task: task, selected: !agents.creating && agents.selected === task)
                                .onTapGesture {
                                    agents.creating = false
                                    agents.selectedId = task.id
                                }
                        }
                    }
                }
                Spacer(minLength: 0)
                if let five = agents.fiveHour {
                    LimitLine(label: "5 hours", limit: five)
                }
                if let week = agents.sevenDay {
                    LimitLine(label: "Week", limit: week)
                }
            }
            .padding(12)
            .frame(width: 260)
            .background(Color(white: 0.09))
            Group {
                if agents.creating || agents.tasks.isEmpty {
                    NewTaskView()
                } else if let task = agents.selected {
                    TaskView(task: task)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .foregroundColor(MunaColor.text)
        .frame(minWidth: 700, minHeight: 440)
    }
}

struct TaskRow: View {
    let task: ClaudeTask
    let selected: Bool

    var body: some View {
        let (symbol, tint) = AgentsModel.statusSymbol(task)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundColor(tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(task.prompt).font(.system(size: 11)).foregroundColor(MunaColor.secondary).lineLimit(1)
                Text(AgentsModel.statusText(task)).font(.system(size: 11)).foregroundColor(tint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? MunaColor.accent.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
    }
}

struct LimitLine: View {
    let label: String
    let limit: AgentsModel.Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(Int(limit.percent))% · \(AgentsModel.resetText(limit.resetsAt))").font(.system(size: 10)).foregroundColor(MunaColor.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(MunaColor.accent).frame(width: proxy.size.width * CGFloat(min(limit.percent / 100, 1)))
                }
            }
            .frame(height: 5)
        }
    }
}

struct NewTaskView: View {
    @EnvironmentObject var agents: AgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New task").font(.system(size: 20, weight: .bold))
            if agents.claudePath == nil {
                Text("Claude Code is not installed: the claude command was not found (in ~/.local/bin, Homebrew or npm).")
                    .foregroundColor(MunaColor.warning)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").font(.system(size: 12, weight: .semibold))
                    Text(agents.newFolder).font(.system(size: 12)).foregroundColor(MunaColor.secondary).lineLimit(1)
                }
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            Text("What should Claude do?").font(.system(size: 12, weight: .semibold))
            TextEditor(text: $agents.newPrompt)
                .font(.system(size: 13))
                .frame(minHeight: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            HStack {
                Spacer()
                Button("Start") { agents.start(prompt: agents.newPrompt, folder: agents.newFolder) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(agents.claudePath == nil || agents.newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Claude Code works in the folder and asks before it changes anything: the question comes to the capsule and here.")
                .font(.system(size: 11))
                .foregroundColor(MunaColor.secondary)
            Spacer()
        }
        .padding(28)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: agents.newFolder)
        if panel.runModal() == .OK, let url = panel.url {
            agents.newFolder = url.path
        }
    }
}

struct TaskView: View {
    let task: ClaudeTask
    @EnvironmentObject var agents: AgentsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(task.project) · \(AgentsModel.statusText(task))").font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text("\(String(format: "$%.2f", task.costUsd)) · \(task.model.isEmpty ? "claude" : task.model)")
                        .font(.system(size: 11))
                        .foregroundColor(MunaColor.secondary)
                }
                Spacer()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: task.cwd)) } label: { Image(systemName: "folder") }
                    .help("Open the folder")
                if task.running {
                    Button { task.interrupt() } label: { Image(systemName: "pause.fill") }
                        .help("Stop what it is doing now")
                    Button("Stop") { task.stop() }
                }
                Button { agents.remove(task) } label: { Image(systemName: "trash") }
                    .help("Forget this task")
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(task.transcript) { entry in
                        EntryView(entry: entry)
                    }
                    ForEach(task.pending) { permission in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Claude wants to: \(permission.verb)").font(.system(size: 13, weight: .semibold))
                            Text(permission.detail)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            HStack {
                                Spacer()
                                Button("Deny") { agents.answer(task, permission, .deny) }
                                Button("Always in this task") { agents.answer(task, permission, .always) }
                                Button("Allow") { agents.answer(task, permission, .allow) }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(MunaColor.amber, lineWidth: 1))
                    }
                }
                .padding(18)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Tell Claude more, or ask it to change something…", text: $agents.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { agents.send() }
                Button { agents.send() } label: { Image(systemName: "paperplane.fill") }
                    .disabled(agents.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
    }
}

struct EntryView: View {
    let entry: ClaudeTask.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(entry.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(MunaColor.accent.opacity(0.3)))
            }
        case .text:
            Text(entry.text).font(.system(size: 13)).textSelection(.enabled)
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: entry.ok == nil ? "ellipsis" : entry.ok == true ? "checkmark" : "xmark")
                        .foregroundColor(entry.ok == false ? MunaColor.warning : MunaColor.ok)
                    Text(entry.text).font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                }
                if !entry.output.isEmpty {
                    Text(entry.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(MunaColor.secondary)
                        .lineLimit(6)
                        .padding(.leading, 20)
                }
            }
        case .note:
            Text(entry.text).font(.system(size: 11)).foregroundColor(MunaColor.secondary)
        case .result:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.ok == false ? "Stopped with an error" : "Done").font(.system(size: 13, weight: .semibold))
                if !entry.text.isEmpty {
                    Text(entry.text).font(.system(size: 12)).textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).stroke(entry.ok == false ? MunaColor.warning : MunaColor.ok, lineWidth: 1))
        case .error:
            Text(entry.text).font(.system(size: 12)).foregroundColor(MunaColor.warning)
        }
    }
}
