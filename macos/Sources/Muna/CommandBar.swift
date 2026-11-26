import AppKit
import Carbon
import Combine
import MunaCore
import SwiftUI

/// One line of the Command Bar's list.
struct CommandResult: Identifiable {
    enum Icon {
        case symbol(String)
        case file(String)
    }

    let id: String
    let icon: Icon
    let title: String
    let subtitle: String
    /// Asks for a second Enter first (stopping a process, emptying a folder); what it then says.
    var confirm: String? = nil
    let run: () -> Void
}

/// The Command Bar, as on Linux (linux/src/commandbar): one field for everything. Type to start an
/// app, to calculate ("12*(3+4)"), to convert units ("5 km to mi"), to find something you copied,
/// or to search the web. Up / Down choose, Enter does it, Esc leaves.
final class CommandModel: ObservableObject {
    @Published var query = "" { didSet { update() } }
    @Published private(set) var results: [CommandResult] = []
    @Published var selected = 0
    /// The result waiting for its second Enter.
    @Published private(set) var armed: String?
    private var generation = 0
    /// Ask to leave (after running something, or Esc).
    var onDone: () -> Void = {}
    /// "scratch": open the Scratchpad.
    var onScratchpad: () -> Void = {}

    private let clipboard: ClipboardModel
    private let snippets: SnippetsModel
    private var apps: [(name: String, path: String)] = []

    static let examples = ["12*(3+4)", "5 km to mi", ";snippets", "scratch", "kill …", "ports", "clean"]
    static let maxApps = 5
    static let maxClips = 3

    init(clipboard: ClipboardModel, snippets: SnippetsModel) {
        self.clipboard = clipboard
        self.snippets = snippets
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.findApps()
            DispatchQueue.main.async { self?.apps = found }
        }
    }

    /// The apps of /Applications, /System/Applications (and their Utilities) and ~/Applications.
    private static func findApps() -> [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", "\(home)/Applications"]
        var result: [(name: String, path: String)] = []
        var seen = Set<String>()
        for folder in folders {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                if seen.insert(name).inserted {
                    result.append((name, "\(folder)/\(entry)"))
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reset() {
        query = ""
        selected = 0
    }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + step + results.count) % results.count
    }

    func runSelected() {
        guard results.indices.contains(selected) else { return }
        let result = results[selected]
        if result.confirm != nil && armed != result.id {
            armed = result.id
            return
        }
        armed = nil
        result.run()
    }

    /// Results that take a moment (processes, ports, folder sizes): worked out in the background.
    private func later(_ work: @escaping () -> [CommandResult]) {
        let mine = generation
        results = [CommandResult(id: "busy", icon: .symbol("hourglass"), title: "Looking…", subtitle: "") {}]
        DispatchQueue.global(qos: .userInitiated).async {
            let list = work()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == mine else { return }
                self.results = list.isEmpty
                    ? [CommandResult(id: "none", icon: .symbol("questionmark.circle"), title: "Nothing found", subtitle: "") {}]
                    : list
            }
        }
    }

    /// The output of a command-line tool.
    private static func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func stopRow(_ pid: Int32, _ title: String, _ subtitle: String) -> CommandResult {
        CommandResult(id: "pid:\(pid)", icon: .symbol("stop.circle"), title: title, subtitle: subtitle,
                      confirm: "Enter again to stop it") {
            kill(pid, SIGTERM)
        }
    }

    /// "kill <name>": your processes whose name has it.
    private static func processes(named name: String) -> [CommandResult] {
        let own = ProcessInfo.processInfo.processIdentifier
        var rows: [CommandResult] = []
        for line in output("/bin/ps", ["-xo", "pid=,comm="]).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), pid != own else { continue }
            let program = URL(fileURLWithPath: String(parts[1])).lastPathComponent
            guard program.lowercased().contains(name) else { continue }
            rows.append(stopRow(pid, program, "Process \(pid)"))
            if rows.count >= 8 { break }
        }
        return rows
    }

    /// "ports": what listens on which TCP port (your programs).
    private static func listeningPorts() -> [CommandResult] {
        var rows: [CommandResult] = []
        var pid: Int32 = 0
        var program = ""
        var seen = Set<String>()
        for line in output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = String(line.dropFirst())
            switch kind {
            case "p": pid = Int32(value) ?? 0
            case "c": program = value
            case "n":
                let port = value.split(separator: ":").last.map(String.init) ?? value
                guard seen.insert("\(pid):\(port)").inserted else { continue }
                rows.append(stopRow(pid, "Port \(port) · \(program)", "TCP · process \(pid)"))
            default: break
            }
        }
        return rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// "clean": the biggest folders of ~/Library/Caches (not the system's own); Enter twice empties one.
    private static func cacheFolders() -> [CommandResult] {
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let entries = try? fileManager.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) else { return [] }
        var sized: [(URL, Int64)] = []
        for folder in entries where !folder.lastPathComponent.hasPrefix("com.apple.") && !folder.lastPathComponent.hasPrefix(".") {
            var total: Int64 = 0
            if let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let file as URL in walker {
                    total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                }
            }
            if total > 1_000_000 { sized.append((folder, total)) }
        }
        return sized.sorted { $0.1 > $1.1 }.prefix(8).map { folder, size in
            CommandResult(id: "clean:\(folder.path)", icon: .symbol("trash"), title: "\(folder.lastPathComponent) · \(sizeText(size))",
                          subtitle: "Cache: the program makes it again", confirm: "Enter again to empty it") {
                for item in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    try? fileManager.removeItem(at: item)
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func update() {
        let text = query.trimmingCharacters(in: .whitespaces)
        selected = 0
        armed = nil
        generation += 1
        let lowered = text.lowercased()
        let words = lowered.split(separator: " ", maxSplits: 1).map(String.init)
        if words.count == 2, ["kill", "stop", "quit"].contains(words[0]) {
            let name = words[1]
            later { Self.processes(named: name) }
            return
        }
        if lowered == "ports" || lowered == "port" {
            later { Self.listeningPorts() }
            return
        }
        if ["clean", "cleaner", "cache"].contains(lowered) {
            later { Self.cacheFolders() }
            return
        }
        guard !text.isEmpty else {
            results = []
            return
        }
        var list: [CommandResult] = []
        // ";trigger": the snippets (";" alone: all of them); Enter copies the text, {date} and {time} filled in
        if text.hasPrefix(";") {
            let wanted = String(text.dropFirst()).lowercased()
            for snippet in snippets.snippets where wanted.isEmpty || snippet.trigger.lowercased().hasPrefix(wanted) {
                let body = snippet.text
                list.append(CommandResult(id: "snippet:\(snippet.trigger)", icon: .symbol("text.insert"), title: ";\(snippet.trigger)",
                                          subtitle: body.replacingOccurrences(of: "\n", with: " ")) { [weak self] in
                    self?.copy(SnippetsStore.expand(body))
                    self?.onDone()
                })
                if list.count >= 8 { break }
            }
            if list.isEmpty {
                list.append(CommandResult(id: "snippets-none", icon: .symbol("text.insert"), title: "No snippet like that",
                                          subtitle: "Add snippets in Settings → Snippets") { [weak self] in self?.onDone() })
            }
            results = list
            return
        }
        if "scratchpad".hasPrefix(text.lowercased()) && text.count >= 3 {
            list.append(CommandResult(id: "scratchpad", icon: .symbol("note.text"), title: "Scratchpad", subtitle: "A window for long notes") { [weak self] in
                self?.onDone()
                self?.onScratchpad()
            })
        }
        if let value = CommandEngine.calculate(text) {
            let answer = CommandEngine.format(value)
            list.append(CommandResult(id: "calc", icon: .symbol("equal.circle"), title: answer,
                                      subtitle: "\(text) · Enter copies it") { [weak self] in
                self?.copy(answer)
                self?.onDone()
            })
        }
        if let conversion = CommandEngine.convert(text) {
            let answer = CommandEngine.format((conversion.value * 1e6).rounded() / 1e6)
            list.append(CommandResult(id: "convert", icon: .symbol("arrow.left.arrow.right.circle"), title: conversion.text,
                                      subtitle: "Enter copies \(answer)") { [weak self] in
                self?.copy(answer)
                self?.onDone()
            })
        }
        let matches = apps
            .map { (app: $0, score: CommandEngine.matchScore($0.name, text)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(Self.maxApps)
        for match in matches {
            let path = match.app.path
            list.append(CommandResult(id: "app:\(path)", icon: .file(path), title: match.app.name, subtitle: "Application") { [weak self] in
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
                self?.onDone()
            })
        }
        let clips = clipboard.items.filter { !$0.isPrivate && $0.searchText.lowercased().contains(lowered) }.prefix(Self.maxClips)
        for item in clips {
            let title = (item.text ?? item.files?.first.flatMap { URL(string: $0)?.lastPathComponent } ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            list.append(CommandResult(id: "clip:\(item.id)", icon: .symbol("doc.on.clipboard"), title: title,
                                      subtitle: "Copied before · Enter copies it again") { [weak self] in
                self?.clipboard.copy(item)
                self?.onDone()
            })
        }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        list.append(CommandResult(id: "web", icon: .symbol("magnifyingglass"), title: "Search the web for “\(text)”",
                                  subtitle: "In your browser") { [weak self] in
            if let url = URL(string: "https://www.google.com/search?q=\(encoded)") { NSWorkspace.shared.open(url) }
            self?.onDone()
        })
        results = list
    }
}

struct CommandView: View {
    @EnvironmentObject var command: CommandModel
    @EnvironmentObject var model: CapsuleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).foregroundColor(MunaColor.secondary)
                TextField("Search apps, calculate, convert, find what you copied…", text: $command.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { command.runSelected() }
                    .onExitCommand { command.onDone() }
                    .onMoveCommand { direction in
                        if direction == .down { command.move(1) }
                        if direction == .up { command.move(-1) }
                    }
                    .onChange(of: focused) { model.isEditing = $0 }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.08)))
            if command.query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    ForEach(CommandModel.examples, id: \.self) { example in
                        Pill(label: example) { command.query = example == "kill …" ? "kill " : example }
                    }
                }
                Text("Type an app's name, a calculation, a conversion, or something you copied. Enter does it, Esc leaves.")
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(command.results.enumerated()), id: \.element.id) { index, result in
                            CommandRow(result: result, selected: index == command.selected, armed: command.armed == result.id)
                                .onTapGesture {
                                    command.selected = index
                                    command.runSelected()
                                }
                        }
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

struct CommandRow: View {
    let result: CommandResult
    let selected: Bool
    var armed = false

    var body: some View {
        HStack(spacing: 10) {
            switch result.icon {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 15)).frame(width: 24, height: 24)
            case .file(let path):
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(armed ? (result.confirm ?? result.subtitle) : result.subtitle)
                    .font(.system(size: 11, weight: armed ? .semibold : .regular))
                    .foregroundColor(armed ? MunaColor.amber : MunaColor.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? MunaColor.accent.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
    }
}

/// A shortcut that works whichever app is in front (Carbon's hot keys: no permission needed).
final class HotKey {
    private var reference: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    /// ⌥Space
    static let optionSpace = (keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        self.id = id
        Self.installHandler()
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D55_4E41), id: id)   // "MUNA"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
