import Foundation

/// One device of a sending and how far it got.
public struct Transfer: Identifiable, Equatable {
    public enum Phase: String { case waiting, sending, done, failed, missing }
    public var id: String
    public var name: String
    public var phase: Phase
    public var sent: Int64 = 0
    public var total: Int64 = 0
    public var message = ""
    public var count = 0
    public var skipped = 0
    var device: Device?
    var member: GroupMember?
}

/// The LocalSend section's logic, like Muna on Linux (linux/src/localsend/localSendSession.js): the
/// devices found, the files waiting (the basket), which devices are chosen, the groups, and the
/// transfers, one per chosen device, all at once. Call it on `queue`; `onChange` comes on it too.
public final class SendSession: @unchecked Sendable {   // its state is only touched on `queue`
    public enum Phase: String { case scan, pick, sending, done }

    public let queue: DispatchQueue
    public var onChange: () -> Void = {}
    /// The end of a sending while nobody looks: (title, details, all received?).
    public var onFinished: (String, String, Bool) -> Void = { _, _, _ in }
    /// Addresses to ask for devices (the local /24 by default).
    public var hosts: () -> [String] = { LocalNetwork.subnetHosts() }

    public private(set) var phase = Phase.pick
    public private(set) var devices: [Device] = []
    public private(set) var basket: [URL] = []
    public private(set) var selected = Set<String>()
    public private(set) var activeGroupId: String?
    public private(set) var transfers: [Transfer] = []
    public private(set) var message = ""

    private let transport: LocalSendTransport
    private let groupsStore: GroupsStore
    private var uris: [URL] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var scanTask: Task<Void, Never>?
    private var scannedAt = Date.distantPast
    private var progressPending = false

    public init(transport: LocalSendTransport, groups: GroupsStore, queue: DispatchQueue = .main) {
        self.transport = transport
        groupsStore = groups
        self.queue = queue
    }

    public var groups: [DeviceGroup] { groupsStore.groups }
    public var activeGroup: DeviceGroup? { groups.first { $0.id == activeGroupId } }
    public var busy: Bool { transfers.contains { $0.phase == .waiting || $0.phase == .sending } }
    public var selectedDevices: [Device] { devices.filter { selected.contains($0.key) } }

    // --- the basket ---------------------------------------------------------------------------

    public func offer(_ files: [URL]) {
        for file in files where !basket.contains(file) {
            basket.append(file)
        }
        backToPick()
        onChange()
    }

    public func remove(_ files: [URL]) {
        basket.removeAll { files.contains($0) }
        onChange()
    }

    public func clearBasket() {
        basket = []
        onChange()
    }

    // --- choosing -------------------------------------------------------------------------------

    public func isSelected(_ device: Device) -> Bool { selected.contains(device.key) }

    public func toggle(_ device: Device) {
        if selected.remove(device.key) == nil { selected.insert(device.key) }
        if selected.isEmpty { activeGroupId = nil }
        onChange()
    }

    public func selectAll() {
        devices.forEach { selected.insert($0.key) }
        activeGroupId = nil
        onChange()
    }

    public func clearSelection() {
        selected = []
        activeGroupId = nil
        onChange()
    }

    /// Chooses the members of a group that are here (again: unchooses them).
    public func selectGroup(_ group: DeviceGroup) {
        if activeGroupId == group.id {
            clearSelection()
            return
        }
        selected = Set(group.presence(in: devices).found.map(\.key))
        activeGroupId = group.id
        onChange()
    }

    /// Saves the chosen devices as a group. Throws GroupError.
    public func saveGroup(named name: String) throws {
        let group = try groupsStore.save(name: name, members: selectedDevices.map(\.asMember))
        activeGroupId = group.id
        onChange()
    }

    public func deleteGroup(_ id: String) {
        try? groupsStore.delete(id: id)
        if activeGroupId == id { activeGroupId = nil }
        onChange()
    }

    // --- finding devices ------------------------------------------------------------------------

    /// The section was opened: look again unless a recent list or a sending is there.
    public func refresh(force: Bool = false) {
        guard !busy else { return }
        backToPick()
        if force || Date().timeIntervalSince(scannedAt) > 60 {
            scan()
        } else {
            onChange()
        }
    }

    public func scan() {
        guard !busy else { return }
        scanTask?.cancel()
        devices = []
        phase = .scan
        scannedAt = Date()
        onChange()
        let hosts = self.hosts()
        let transport = self.transport
        scanTask = Task { [weak self] in
            await LocalNetwork.scan(hosts: hosts, with: transport) { device in
                self?.queue.async { self?.found(device) }
            }
            self?.queue.async {
                guard let self, self.phase == .scan else { return }
                self.phase = .pick
                self.onChange()
            }
        }
    }

    /// A device answered (a scan, or one that announced itself).
    public func found(_ device: Device) {
        guard !devices.contains(where: { $0.ip == device.ip }) else { return }
        devices = sortDevices(devices + [device])
        // the members of the chosen group that answer late join the choice
        if let group = activeGroup, group.members.contains(where: { device.isMember($0) }) {
            selected.insert(device.key)
        }
        onChange()
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scan {
            phase = .pick
            onChange()
        }
    }

    // --- sending ----------------------------------------------------------------------------------

    /// Sends the basket to every chosen device at once.
    public func send() {
        let chosen = selectedDevices
        guard !busy, !chosen.isEmpty, !basket.isEmpty else { return }
        uris = basket
        start(chosen, missing: activeGroup?.presence(in: devices).missing ?? [])
    }

    /// Sends the basket to this one device.
    public func send(to device: Device) {
        guard !busy else { return }
        selected = [device.key]
        activeGroupId = nil
        send()
    }

    /// Tries again for those that did not get the files; members not found are looked for again.
    public func retryFailed() {
        guard !busy, phase == .done else { return }
        let failed = transfers.filter { $0.phase == .failed }.compactMap(\.device)
        let missing = transfers.filter { $0.phase == .missing }.compactMap(\.member)
        let nowFound = missing.compactMap { member in devices.first { $0.isMember(member) } }
        let stillMissing = missing.filter { member in !devices.contains { $0.isMember(member) } }
        guard !(failed + nowFound).isEmpty else { return }
        start(failed + nowFound, missing: stillMissing, keep: transfers.filter { $0.phase == .done })
    }

    public func cancel() {
        tasks.values.forEach { $0.cancel() }
    }

    /// Leaves the summary of the last sending.
    public func dismiss() {
        guard !busy else { return }
        backToPick()
        onChange()
    }

    private func backToPick() {
        guard phase == .done else { return }
        phase = .pick
        transfers = []
    }

    private func start(_ devices: [Device], missing: [GroupMember], keep: [Transfer] = []) {
        cancelScan()
        phase = .sending
        message = ""
        transfers = keep
            + devices.map { Transfer(id: $0.key, name: $0.alias, phase: .waiting, device: $0) }
            + missing.map { Transfer(id: "missing:\($0.fingerprint.isEmpty ? $0.alias : $0.fingerprint)", name: $0.alias,
                                     phase: .missing, message: "Not on the network", member: $0) }
        onChange()
        let files = uris
        let transport = self.transport
        for transfer in transfers where transfer.phase == .waiting {
            guard let device = transfer.device else { continue }
            let id = transfer.id
            tasks[id] = Task { [weak self] in
                let outcome: Result<SendResult, Error>
                do {
                    let result = try await transport.send(to: device, files: files) { progress in
                        self?.queue.async { self?.progress(id, progress) }
                    }
                    outcome = .success(result)
                } catch {
                    outcome = .failure(error)
                }
                self?.queue.async { self?.ended(id, outcome) }
            }
        }
    }

    private func progress(_ id: String, _ progress: SendProgress) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].phase == .waiting || transfers[index].phase == .sending else { return }
        let phaseChanged = transfers[index].phase.rawValue != progress.phase
        transfers[index].phase = Transfer.Phase(rawValue: progress.phase) ?? .sending
        transfers[index].sent = progress.sent
        transfers[index].total = progress.total
        if phaseChanged {
            onChange()
        } else if !progressPending {
            // many devices send many updates: redraw at most ten times a second
            progressPending = true
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.progressPending = false
                self?.onChange()
            }
        }
    }

    private func ended(_ id: String, _ outcome: Result<SendResult, Error>) {
        tasks[id] = nil
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let result):
            transfers[index].phase = .done
            transfers[index].sent = transfers[index].total
            transfers[index].count = result.count
            transfers[index].skipped = result.skipped
            transfers[index].message = "Received"
        case .failure(let error):
            transfers[index].phase = .failed
            transfers[index].message = (error as? SendError)?.message ?? "\(error)"
        }
        if busy {
            onChange()
        } else {
            finish()
        }
    }

    private func finish() {
        let done = transfers.filter { $0.phase == .done }
        if done.count == transfers.count {
            basket.removeAll { uris.contains($0) }
        }
        let files = done.map(\.count).max() ?? 0
        let skipped = done.map(\.skipped).max() ?? 0
        let filesText = "\(files) file\(files == 1 ? "" : "s")"
        var details = ""
        if transfers.count == 1, let one = transfers.first {
            message = one.phase == .done ? "Sent to \(one.name)" : one.message
            if one.phase == .done { details = skipped > 0 ? "\(skipped) folder skipped" : filesText }
        } else {
            message = done.count == transfers.count ? "Sent to all \(transfers.count)" : "\(done.count) of \(transfers.count) received"
            let left = transfers.filter { $0.phase != .done }.map(\.name)
            details = left.isEmpty ? filesText : "Not received: \(left.joined(separator: ", "))"
        }
        phase = .done
        let onlyCancelled = done.isEmpty && transfers.allSatisfy { $0.message == SendError.cancelled.message || $0.phase == .missing }
        if !onlyCancelled {
            onFinished(message, details, done.count == transfers.count)
        }
        onChange()
    }
}
