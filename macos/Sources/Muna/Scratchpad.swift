import AppKit
import Combine
import MunaCore
import SwiftUI

/// scratchpad.json, the shape the Linux version writes: {"version": 1, "notes": [{"text", "at"}]}.
/// The Mac window edits the first note; the other notes are kept as they are.
private struct ScratchpadFile: Codable {
    var version: Int = 1
    var notes: [Note] = []

    struct Note: Codable {
        var text: String
        var at: Int64?
    }
}

/// The Scratchpad: one big text for long notes, saved by itself while typing.
final class ScratchpadModel: ObservableObject {
    @Published var text: String {
        didSet { if text != oldValue { scheduleSave() } }
    }

    private let store = JSONStore(name: "scratchpad.json")
    private var file: ScratchpadFile
    private var saveItem: DispatchWorkItem?

    init() {
        let loaded = store.load(ScratchpadFile.self) ?? ScratchpadFile()
        file = loaded
        text = loaded.notes.first?.text ?? ""
    }

    /// Saves half a second after the last change.
    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func save() {
        saveItem?.cancel()
        saveItem = nil
        let note = ScratchpadFile.Note(text: text, at: file.notes.first?.at ?? nowMilliseconds())
        if file.notes.isEmpty { file.notes.append(note) } else { file.notes[0] = note }
        file.version = 1
        try? store.save(file)
    }
}

private struct ScratchpadView: View {
    @EnvironmentObject var model: ScratchpadModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.text)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
            Divider()
            HStack {
                Text("\(model.text.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                .disabled(model.text.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}

/// The Scratchpad's window, made once and shown again.
final class ScratchpadWindowController {
    private let model: ScratchpadModel
    private var window: NSWindow?

    init(model: ScratchpadModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Scratchpad"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ScratchpadView().environmentObject(model))
            window.setContentSize(NSSize(width: 520, height: 420))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
