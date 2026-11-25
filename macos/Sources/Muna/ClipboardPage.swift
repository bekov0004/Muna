import MunaCore
import SwiftUI

/// The clipboard history: a click copies an item again (then Cmd+V pastes it); pinned items stay.
struct ClipboardPage: View {
    @EnvironmentObject var clipboard: ClipboardModel
    @EnvironmentObject var ui: PanelState

    private var shown: [ClipItem] {
        let words = ui.clipboardQuery.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return clipboard.items }
        return clipboard.items.filter { item in
            let text = item.searchText.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CapsuleField(placeholder: "Search what you copied", text: $ui.clipboardQuery) {}
                if clipboard.items.contains(where: { !$0.saved }) {
                    Pill(label: "Clear") { clipboard.clear() }
                }
            }
            if shown.isEmpty {
                Text(clipboard.items.isEmpty ? "What you copy shows up here" : "Nothing matches")
                    .font(.system(size: 12))
                    .foregroundColor(MunaColor.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
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

    var body: some View {
        HStack(spacing: 8) {
            if let files = item.files, let first = files.first.flatMap({ URL(string: $0) }) {
                FileIcon(url: first, size: 18)
                Text(files.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) and \(files.count - 1) more")
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundColor(MunaColor.secondary).frame(width: 18)
                Text(item.isPrivate ? "Private" : (item.text ?? "").replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if copied {
                Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundColor(MunaColor.ok)
            }
            IconButton(symbol: item.saved ? "pin.fill" : "pin", tint: item.saved ? MunaColor.accent : MunaColor.secondary) {
                clipboard.togglePinned(item)
            }
            IconButton(symbol: "xmark") { clipboard.remove(item) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(MunaColor.tile))
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
    }
}
