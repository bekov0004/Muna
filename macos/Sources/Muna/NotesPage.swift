import AppKit
import MunaCore
import SwiftUI

/// Quick notes on the left, the to-do list on the right (the same files as Muna on Linux).
struct NotesPage: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NotesColumn()
            TodoColumn()
        }
    }
}

struct NotesColumn: View {
    @EnvironmentObject var notes: NotesModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(notes.notes.isEmpty ? "Notes" : "Notes · \(notes.notes.count)")
            CapsuleField(placeholder: "Write a note, Enter saves it", text: $draft) {
                if notes.add(draft) { draft = "" }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(notes.notes) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Text(note.isPrivate ? "Private note" : note.text)
                                .font(.system(size: 12))
                                .foregroundColor(note.isPrivate ? MunaColor.secondary : MunaColor.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            IconButton(symbol: "xmark") { notes.remove(note) }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(MunaColor.tile))
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(note.text, forType: .string)
                            }
                            Button("Delete") { notes.remove(note) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct TodoColumn: View {
    @EnvironmentObject var todo: TodoModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(todo.items.isEmpty ? "To do" : "To do · \(todo.openCount) open") {
                if todo.hasDone {
                    Pill(label: "Clear done") { todo.clearDone() }
                }
            }
            CapsuleField(placeholder: "Add a to-do", text: $draft) {
                if todo.add(draft) { draft = "" }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(todo.items) { item in
                        HStack(spacing: 8) {
                            Button {
                                todo.toggle(item)
                            } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(item.done ? MunaColor.ok : MunaColor.secondary)
                            }
                            .buttonStyle(.plain)
                            Text(item.text)
                                .font(.system(size: 12))
                                .strikethrough(item.done)
                                .foregroundColor(item.done ? MunaColor.secondary : MunaColor.text)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            IconButton(symbol: "xmark") { todo.remove(item) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(MunaColor.tile))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
