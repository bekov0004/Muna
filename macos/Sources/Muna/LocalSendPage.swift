import AppKit
import MunaCore
import SwiftUI

/// LocalSend: the files to send, the devices and groups to send them to, the transfers; and what
/// another device wants to send here. Works with Muna on Linux and Mac and with the LocalSend apps.
struct LocalSendPage: View {
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        if let incoming = localSend.incoming {
            IncomingCard(incoming: incoming)
        } else if let message = localSend.message {
            MessageCard(message: message)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                BasketSection()
                DevicesSection()
            }
        }
    }
}

// --- what comes in ------------------------------------------------------------------------------

struct IncomingCard: View {
    let incoming: IncomingSnapshot
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption("From \(incoming.sender)")
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundColor(tint)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(MunaColor.tile))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(incoming.fileNames.prefix(4).joined(separator: ", ") + (incoming.fileNames.count > 4 ? " …" : ""))
                        .font(.system(size: 12))
                        .foregroundColor(MunaColor.secondary)
                        .lineLimit(2)
                    if incoming.state == .receiving {
                        ProgressView(value: Double(incoming.received), total: Double(max(incoming.total, 1)))
                            .tint(MunaColor.accent)
                        Text("\(sizeText(incoming.received)) of \(sizeText(incoming.total))")
                            .font(.system(size: 11))
                            .foregroundColor(MunaColor.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(MunaColor.tile))
            HStack(spacing: 8) {
                Spacer()
                switch incoming.state {
                case .asking:
                    Pill(label: "Decline") { localSend.decline() }
                    Pill(label: "Accept", accent: true) { localSend.accept() }
                case .receiving:
                    EmptyView()
                case .done:
                    Pill(label: "Show in Finder", accent: true) { localSend.showReceived() }
                    Pill(label: "OK") { localSend.dismissIncoming() }
                case .failed, .declined:
                    Pill(label: "OK") { localSend.dismissIncoming() }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        let count = incoming.fileNames.count
        let files = "\(count) file\(count == 1 ? "" : "s")"
        switch incoming.state {
        case .asking: return "\(incoming.sender) wants to send \(files) (\(sizeText(incoming.total)))"
        case .receiving: return "Receiving \(files)…"
        case .done: return "Received \(files) · in Downloads"
        case .declined: return "Declined"
        case .failed: return incoming.error ?? "The transfer stopped"
        }
    }

    private var symbol: String {
        switch incoming.state {
        case .asking, .receiving: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed, .declined: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch incoming.state {
        case .done: return MunaColor.ok
        case .failed, .declined: return MunaColor.warning
        default: return MunaColor.accent
        }
    }
}

/// A text someone sent: who, the text, Copy, and Open when it is one link.
struct MessageCard: View {
    let message: ReceivedText
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(message.from) sent a text").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    IconButton(symbol: "xmark") { localSend.dismissMessage() }
                }
                Text(message.text)
                    .font(.system(size: 13))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(MunaColor.tile))
            HStack(spacing: 8) {
                Spacer()
                if let link {
                    Pill(label: "Open") {
                        NSWorkspace.shared.open(link)
                        localSend.dismissMessage()
                    }
                }
                Pill(label: localSend.messageCopied ? "Copied" : "Copy", accent: true) { localSend.copyMessage() }
                Spacer()
            }
            Spacer(minLength: 0)
        }
    }

    /// The text is one web link.
    private var link: URL? {
        let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.contains(where: \.isWhitespace), let url = URL(string: words),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}

// --- the files to send --------------------------------------------------------------------------

struct BasketSection: View {
    @EnvironmentObject var localSend: LocalSendController
    @EnvironmentObject var tray: TrayModel
    @EnvironmentObject var ui: PanelState

    var body: some View {
        if ui.writingText {
            writing
        } else {
            basketView
        }
    }

    /// Writing the text message: Return keeps it, Cancel leaves it as it was.
    private var writing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Text") {
                Pill(label: "Cancel") { ui.writingText = false }
                Pill(label: "Done", accent: true) { keepText() }
            }
            CapsuleField(placeholder: "Write a text to send", text: $ui.localSendText) { keepText() }
            Text("Return keeps it; then choose who gets it. Muna and LocalSend show it at once.")
                .font(.system(size: 11))
                .foregroundColor(MunaColor.secondary)
        }
    }

    private func keepText() {
        localSend.session.setText(ui.localSendText)
        ui.writingText = false
    }

    private func startWriting() {
        ui.localSendText = localSend.session.text
        ui.writingText = true
    }

    private var basketView: some View {
        let basket = localSend.session.basket
        let total = basket.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        let text = localSend.session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = basket.isEmpty ? (text.isEmpty ? "Files" : "Text")
            : "Files · \(basket.count) · \(sizeText(total))\(text.isEmpty ? "" : " · Text")"
        return VStack(alignment: .leading, spacing: 6) {
            Caption(caption) {
                Pill(label: "Text") { startWriting() }
                if !tray.files.isEmpty {
                    Pill(label: "Add from Tray") { localSend.session.offer(tray.files) }
                }
                Pill(label: "Choose…") { choose() }
                if !basket.isEmpty || !text.isEmpty {
                    Pill(label: "Clear") {
                        localSend.session.setText("")
                        localSend.session.clearBasket()
                    }
                }
            }
            if basket.isEmpty && text.isEmpty {
                Text("Drop files on the capsule, add them from the Tray, or write a text")
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
                    .frame(height: 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if !text.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "text.cursor").font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                                Text("“\(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))”")
                                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    .frame(maxWidth: 180)
                                Text("Text").font(.system(size: 10)).foregroundColor(MunaColor.secondary)
                                IconButton(symbol: "square.and.pencil") { startWriting() }
                                IconButton(symbol: "xmark") { localSend.session.setText("") }
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 4)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(MunaColor.tile))
                            .contentShape(Capsule())
                            .onTapGesture { startWriting() }
                        }
                        ForEach(basket, id: \.self) { url in
                            HStack(spacing: 6) {
                                FileIcon(url: url, size: 16)
                                Text(url.lastPathComponent).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    .frame(maxWidth: 140)
                                Text(sizeText(Self.size(of: url))).font(.system(size: 10)).foregroundColor(MunaColor.secondary)
                                IconButton(symbol: "xmark") { localSend.session.remove([url]) }
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 4)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(MunaColor.tile))
                        }
                    }
                }
                .frame(height: 28)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Files to send"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            localSend.session.offer(panel.urls)
        }
    }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

// --- devices, groups, transfers -----------------------------------------------------------------

struct DevicesSection: View {
    @EnvironmentObject var localSend: LocalSendController
    @EnvironmentObject var ui: PanelState

    private var session: SendSession { localSend.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.phase == .sending || session.phase == .done {
                transfers
            } else if ui.namingGroup {
                namingRow
            } else {
                caption
                devices
            }
        }
    }

    // choosing

    @ViewBuilder private var caption: some View {
        let chosen = session.selectedDevices.count
        if chosen > 0 {
            let group = session.activeGroup
            Caption(group.map { "\($0.name) · \(chosen) of \($0.members.count) here" } ?? "Send to · \(chosen) chosen") {
                Pill(label: "Clear") { session.clearSelection() }
                if let group {
                    Pill(label: ui.confirmDeleteGroup == group.id ? "Delete it?" : "Delete group", active: ui.confirmDeleteGroup == group.id) {
                        if ui.confirmDeleteGroup == group.id {
                            ui.confirmDeleteGroup = nil
                            session.deleteGroup(group.id)
                        } else {
                            ui.confirmDeleteGroup = group.id
                        }
                    }
                } else {
                    Pill(label: "Save as group") {
                        ui.groupName = ""
                        ui.groupNameError = ""
                        ui.namingGroup = true
                    }
                }
                Pill(label: session.hasContent ? "Send to \(chosen)" : "Add files or a text", accent: session.hasContent,
                     disabled: !session.hasContent) { session.send() }
            }
        } else {
            Caption(session.phase == .scan ? "Looking for devices…" : "Send to") {
                if session.devices.count >= 2 {
                    Pill(label: "All") { session.selectAll() }
                }
                Pill(label: "Refresh") { session.refresh(force: true) }
                Pill(label: localSend.receiving ? "Receiving: on" : "Receiving: off", active: localSend.receiving) {
                    localSend.setReceiving(!localSend.receiving)
                }
            }
        }
    }

    @ViewBuilder private var devices: some View {
        if session.devices.isEmpty {
            Text(session.phase == .scan
                 ? "Looking on this network… (on the other side: Muna or LocalSend, with receiving on)"
                 : "No devices found. The others need receiving on and the same network")
                .font(.system(size: 11))
                .foregroundColor(MunaColor.secondary)
                .frame(height: 40)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.groups) { group in
                        let here = group.presence(in: session.devices).found.count
                        let active = session.activeGroupId == group.id
                        Tile(symbol: active ? "checkmark" : "person.3.fill", name: group.name,
                             detail: "\(here) of \(group.members.count) here", selected: active, dashed: true) {
                            ui.confirmDeleteGroup = nil
                            session.selectGroup(group)
                        }
                    }
                    ForEach(session.devices) { device in
                        let selected = session.isSelected(device)
                        Tile(symbol: selected ? "checkmark" : Self.symbol(for: device), name: device.alias,
                             detail: device.deviceModel.isEmpty ? "LocalSend" : device.deviceModel,
                             selected: selected, muna: device.isMuna) {
                            ui.confirmDeleteGroup = nil
                            session.toggle(device)
                        }
                    }
                }
            }
            .frame(height: 44)
        }
        // why receiving could not start (another LocalSend on this Mac holds the port …): always in sight
        if let problem = localSend.receiveProblem {
            Text("Receiving here: \(problem)").font(.system(size: 11)).foregroundColor(MunaColor.warning)
        }
    }

    static func symbol(for device: Device) -> String {
        switch device.deviceType {
        case "mobile": return "iphone"
        case "web": return "globe"
        case "headless", "server": return "server.rack"
        default: return "desktopcomputer"
        }
    }

    // naming a group

    @ViewBuilder private var namingRow: some View {
        let names = session.selectedDevices.map(\.alias)
        Caption("New group · \(names.count) device\(names.count == 1 ? "" : "s")") {
            Pill(label: "Cancel") { ui.namingGroup = false }
            Pill(label: "Save", accent: true) { saveGroup() }
        }
        CapsuleField(placeholder: "Name, for example: Office", text: $ui.groupName) { saveGroup() }
        Text(names.joined(separator: ", ")).font(.system(size: 11)).foregroundColor(MunaColor.secondary).lineLimit(1)
        if !ui.groupNameError.isEmpty {
            Text(ui.groupNameError).font(.system(size: 11)).foregroundColor(MunaColor.warning)
        }
    }

    private func saveGroup() {
        let name = ui.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ui.groupNameError = "Write a name first"
            return
        }
        do {
            try session.saveGroup(named: name)
            ui.namingGroup = false
        } catch {
            ui.groupNameError = "\(error)"
        }
    }

    // sending

    @ViewBuilder private var transfers: some View {
        let all = session.transfers
        let counted = all.filter { $0.phase != .missing }
        let finished = counted.filter { $0.phase != .waiting && $0.phase != .sending }.count
        let left = all.filter { $0.phase == .failed || $0.phase == .missing }.count
        if session.phase == .sending {
            Caption(all.count == 1 ? "Sending to \(all[0].name)" : "Sending · \(finished) of \(counted.count) done") {
                Pill(label: "Cancel") { session.cancel() }
            }
        } else {
            Caption(session.message) {
                if left > 0 {
                    Pill(label: all.count == 1 ? "Try again" : "Try again (\(left))", accent: true) { session.retryFailed() }
                }
                Pill(label: "OK") { session.dismiss() }
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(all) { transfer in
                    TransferTile(transfer: transfer)
                }
            }
        }
        .frame(height: 52)
    }
}

/// A device or a group to choose.
struct Tile: View {
    let symbol: String
    let name: String
    let detail: String
    var selected = false
    var muna = false
    var dashed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(selected ? .white : muna ? MunaColor.muna : MunaColor.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(selected ? MunaColor.accent : (muna ? MunaColor.muna : MunaColor.accent).opacity(0.22)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 10)).foregroundColor(muna ? MunaColor.muna : MunaColor.secondary).lineLimit(1)
                }
                .frame(minWidth: 60, alignment: .leading)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? MunaColor.accent.opacity(0.34) : MunaColor.tile))
            .overlay(Capsule().strokeBorder(Color.white.opacity(dashed ? 0.18 : 0), style: StrokeStyle(lineWidth: 1, dash: [3])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// How far a sending to one device got.
struct TransferTile: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundColor(MunaColor.secondary).lineLimit(1)
                if transfer.phase == .waiting || transfer.phase == .sending {
                    ProgressView(value: Double(transfer.sent), total: Double(max(transfer.total, 1)))
                        .tint(MunaColor.accent)
                        .frame(width: 90)
                }
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(Capsule().fill(MunaColor.tile))
    }

    private var symbol: String {
        switch transfer.phase {
        case .waiting: return "ellipsis"
        case .sending: return "arrow.up"
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .missing: return "wifi.slash"
        }
    }

    private var tint: Color {
        switch transfer.phase {
        case .done: return MunaColor.ok
        case .failed, .missing: return MunaColor.warning
        default: return MunaColor.accent
        }
    }

    private var detail: String {
        switch transfer.phase {
        case .waiting: return "Waiting to accept…"
        case .sending:
            let percent = transfer.total > 0 ? Int(100 * transfer.sent / transfer.total) : 0
            return "\(percent)% · \(sizeText(transfer.sent))"
        case .done: return "Received"
        case .failed: return transfer.message
        case .missing: return "Not on the network"
        }
    }
}
