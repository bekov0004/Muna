import MunaCore
import SwiftUI

/// The clipboard history: a click copies an item again (then Cmd+V pastes it); pinned items stay.
struct ClipboardPage: View {
    @EnvironmentObject var clipboard: ClipboardModel
    @EnvironmentObject var ui: PanelState

    private var shown: [ClipItem] {
        let words = ui.clipNoteMode ? [] : ui.clipboardQuery.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return clipboard.items }
        return clipboard.items.filter { item in
            let text = item.searchText.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var placeholder: String {
        if ui.clipNoteMode { return "Write a note, Enter saves it" }
        return clipboard.items.isEmpty ? "Search…" : "Search \(clipboard.items.count) \(clipboard.items.count == 1 ? "item" : "items")…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // as on Linux: the search field turns into a note field with "+ Note"
            HStack(spacing: 8) {
                CapsuleField(placeholder: placeholder, text: $ui.clipboardQuery) {
                    if ui.clipNoteMode, clipboard.addNote(ui.clipboardQuery) {
                        ui.clipboardQuery = ""
                        ui.clipNoteMode = false
                    }
                }
                Pill(label: "+ Note", active: ui.clipNoteMode) {
                    ui.clipNoteMode.toggle()
                    ui.clipboardQuery = ""
                }
                if clipboard.items.contains(where: { !$0.saved }) {
                    Pill(label: "Clear") { clipboard.clear() }
                }
            }
            if shown.isEmpty {
                Text(clipboard.items.isEmpty ? "Copied text shows up here" : "Nothing found")
                    .font(.system(size: 12))
                    .foregroundColor(MunaColor.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EdgeScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(shown) { item in
                            ClipRow(item: item, copied: ui.copiedClip == item.id) {
                                clipboard.copy(item)
                                ui.copiedClip = item.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [ui] in
                                    if ui.copiedClip == item.id { ui.copiedClip = nil }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let copied: Bool
    let copy: () -> Void
    @EnvironmentObject var clipboard: ClipboardModel
    @EnvironmentObject var privacy: PrivacyModel
    @EnvironmentObject var ui: PanelState

    private var hidden: Bool { item.isPrivate && !privacy.unlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            if let files = item.files, let first = files.first.flatMap({ URL(string: $0) }) {
                FileIcon(url: first, size: 18)
                Text(files.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) and \(files.count - 1) more")
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundColor(MunaColor.secondary).frame(width: 18)
                Text(hidden ? "Private · Touch ID" : (item.text ?? "").replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if copied {
                Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundColor(MunaColor.ok)
            }
            IconButton(symbol: item.note.isEmpty ? "text.bubble" : "text.bubble.fill", tint: item.note.isEmpty ? MunaColor.secondary : MunaColor.accent) {
                ui.clipNoteDraft = item.note
                ui.noteForClip = ui.noteForClip == item.id ? nil : item.id
            }
            IconButton(symbol: item.isPrivate ? "lock.fill" : "lock.open", tint: item.isPrivate ? MunaColor.amber : MunaColor.secondary) {
                if hidden { privacy.unlock() } else { clipboard.togglePrivate(item) }
            }
            IconButton(symbol: item.saved ? "pin.fill" : "pin", tint: item.saved ? MunaColor.accent : MunaColor.secondary) {
                clipboard.togglePinned(item)
            }
            IconButton(symbol: "xmark") { clipboard.remove(item) }
        }
            if ui.noteForClip == item.id {
                CapsuleField(placeholder: "A note for this item (Enter keeps it)", text: $ui.clipNoteDraft) {
                    clipboard.setNote(item, ui.clipNoteDraft)
                    ui.noteForClip = nil
                }
                .padding(.leading, 26)
            } else if !item.note.isEmpty {
                Text(item.note).font(.system(size: 11)).foregroundColor(MunaColor.accent).lineLimit(1).padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(MunaColor.tile))
        .contentShape(Rectangle())
        .onTapGesture {
            if hidden { privacy.unlock() } else { copy() }
        }
        // drag an item out into any app
        .onDrag { dragItem() }
    }

    private func dragItem() -> NSItemProvider {
        if hidden { return NSItemProvider() }
        if let first = item.files?.first.flatMap({ URL(string: $0) }) {
            return NSItemProvider(contentsOf: first) ?? NSItemProvider()
        }
        return NSItemProvider(object: (item.text ?? "") as NSString)
    }
}
