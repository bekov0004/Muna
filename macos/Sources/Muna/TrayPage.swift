import AppKit
import MunaCore
import SwiftUI

/// The Tray: files dropped on the capsule wait here, to be dragged out somewhere else, opened, or
/// sent with LocalSend.
struct TrayPage: View {
    @EnvironmentObject var tray: TrayModel
    @EnvironmentObject var localSend: LocalSendController
    @EnvironmentObject var model: CapsuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(tray.files.isEmpty ? "Tray" : "Tray · \(tray.files.count)") {
                if !tray.files.isEmpty {
                    // everything in the tray goes to LocalSend (one file: the send button on it)
                    Pill(label: "Send all") { send(tray.files) }
                    Pill(label: "Clear") { tray.clear() }
                }
            }
            if tray.files.isEmpty {
                TrayTarget(armed: model.isDropTarget)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tray.files, id: \.self) { url in
                            TrayItem(url: url, send: { send([url]) })
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func send(_ files: [URL]) {
        localSend.session.offer(files)
        model.tab = .localSend
        localSend.session.refresh()
    }
}

/// The empty tray, as on Linux: a dashed blue outline with the tray icon, its name and what it is for.
struct TrayTarget: View {
    let armed: Bool

    private static let blue = Color(red: 19 / 255, green: 104 / 255, blue: 201 / 255)
    private static let bright = Color(red: 61 / 255, green: 139 / 255, blue: 1)

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 26)
                .fill(armed ? Self.bright.opacity(0.12) : Color.clear)
            RoundedRectangle(cornerRadius: 26)
                .inset(by: 1.8)
                .stroke(armed ? Self.bright : Color(red: 12 / 255, green: 90 / 255, blue: 176 / 255).opacity(0.95),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round, dash: [7.5, 10]))
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(armed ? Self.bright : Self.blue)
                    .frame(width: 28, height: 28, alignment: .leading)
                Text("Files Tray")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(armed ? Self.bright : Self.blue)
                if !armed {
                    Text("Drop files here to keep them at hand")
                        .font(.system(size: 11))
                        .foregroundColor(Self.bright.opacity(0.75))
                }
            }
            .padding(.horizontal, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrayItem: View {
    let url: URL
    var send: () -> Void = {}
    @EnvironmentObject var tray: TrayModel
    @EnvironmentObject var ui: PanelState

    private var hover: Bool { ui.hoveredTrayFile == url }

    /// As on Linux: the icon (42) and the name (10, one line) in an 80-wide tile that lights on hover;
    /// its actions (show in Finder, copy, send, remove) come up in the corner.
    var body: some View {
        VStack(spacing: 4) {
            FileIcon(url: url, size: 42)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .frame(width: 80)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Color.white.opacity(0.08) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                action("folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                action("doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                }
                action("paperplane") { send() }
                action("xmark") { tray.remove(url) }
            }
            .padding(3)
            .opacity(hover ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .onHover { inside in
            if inside {
                ui.hoveredTrayFile = url
            } else if ui.hoveredTrayFile == url {
                ui.hoveredTrayFile = nil
            }
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
    }

    private func action(_ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.black.opacity(0.7)))
        }
        .buttonStyle(.plain)
    }
}
