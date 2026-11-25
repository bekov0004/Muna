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
                    Pill(label: "Send with LocalSend") {
                        localSend.session.offer(tray.files)
                        model.tab = .localSend
                        localSend.session.refresh()
                    }
                    Pill(label: "Clear") { tray.clear() }
                }
            }
            if tray.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 26)).foregroundColor(MunaColor.secondary)
                    Text("Drop files on the capsule to keep them here").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tray.files, id: \.self) { url in
                            TrayItem(url: url)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("Drag a file out to put it somewhere; a click opens it.")
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
            }
        }
    }
}

struct TrayItem: View {
    let url: URL
    @EnvironmentObject var tray: TrayModel
    @EnvironmentObject var ui: PanelState

    private var hover: Bool { ui.hoveredTrayFile == url }

    var body: some View {
        VStack(spacing: 6) {
            FileIcon(url: url, size: 48)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 96)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? MunaColor.tileHover : MunaColor.tile))
        .overlay(alignment: .topTrailing) {
            IconButton(symbol: "xmark") { tray.remove(url) }
                .padding(5)
                .opacity(hover ? 1 : 0.55)
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
}
