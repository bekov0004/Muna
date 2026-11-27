import AppKit
import Combine
import MunaCore

/// An incoming transfer as the views see it (a copy made on the receiver's queue).
struct IncomingSnapshot: Equatable {
    var id: String
    var sender: String
    var fileNames: [String]
    var state: IncomingTransfer.State
    var received: Int64
    var total: Int64
    var error: String?
    var saved: [URL]
}

/// LocalSend for the views: finding devices, sending to several at once, groups, receiving.
final class LocalSendController: ObservableObject {
    /// Bumped whenever the sending side changed (the session is not observable itself).
    @Published private(set) var revision = 0
    @Published private(set) var incoming: IncomingSnapshot?
    /// A text someone sent (LocalSend's text message), until it is put away.
    @Published private(set) var message: ReceivedText?
    /// The received text was copied (its Copy button says "Copied").
    @Published private(set) var messageCopied = false
    @Published private(set) var receiving = false
    @Published private(set) var receiveProblem: String?

    let session: SendSession
    var incomingPublisher: Published<IncomingSnapshot?>.Publisher { $incoming }
    var messagePublisher: Published<ReceivedText?>.Publisher { $message }
    var revisionPublisher: Published<Int>.Publisher { $revision }
    /// The capsule shows a short message (a sending ended while it was closed).
    var notify: (String, String, Bool) -> Void = { _, _, _ in }
    /// Someone wants to send: the capsule opens.
    var onIncoming: () -> Void = {}

    private let certificate: LocalSendCertificate?
    private let client: LocalSendClient
    private let receiverQueue: DispatchQueue
    private let receiver: LocalSendReceiver
    private var server: LocalSendServer?
    private let multicast: LocalSendMulticast
    private var pending: IncomingTransfer?

    static var alias: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    init() {
        let certificate = LocalSendCertificate.load()
        let fingerprint = certificate?.fingerprint ?? (0..<32).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
        let identity = { DeviceInfo(alias: LocalSendController.alias, fingerprint: fingerprint) }
        let client = LocalSendClient(identity: identity)
        client.challengeHandler = { challenge in
            let method = challenge.protectionSpace.authenticationMethod
            if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
                // every LocalSend device has a self-signed certificate
                return (.useCredential, URLCredential(trust: trust))
            }
            if method == NSURLAuthenticationMethodClientCertificate, let certificate {
                return (.useCredential, certificate.credential)
            }
            return (.performDefaultHandling, nil)
        }
        let receiverQueue = DispatchQueue(label: "dev.muna.localsend")
        self.certificate = certificate
        self.client = client
        self.receiverQueue = receiverQueue
        session = SendSession(transport: client, groups: GroupsStore())
        receiver = LocalSendReceiver(queue: receiverQueue, identity: identity, folder: { Preferences.shared.receiveFolder })
        multicast = LocalSendMulticast(queue: receiverQueue)

        session.onChange = { [weak self] in self?.revision += 1 }
        session.onFinished = { [weak self] title, details, ok in self?.notify(title, details, ok) }
        receiver.onIncoming = { [weak self] transfer in
            self?.pending = transfer
            self?.publish(transfer)
            DispatchQueue.main.async { self?.onIncoming() }
        }
        receiver.onChange = { [weak self] transfer in self?.publish(transfer) }
        receiver.onMessage = { [weak self] sender, text in
            DispatchQueue.main.async {
                self?.message = ReceivedText(from: sender.alias, text: text)
                self?.messageCopied = false
                self?.onIncoming()
            }
        }
        multicast.onAnnouncement = { [weak self] info, ip in
            guard let self, info.fingerprint != fingerprint else { return }
            let scheme = info.protocol == "http" ? "http" : "https"
            if let device = Device(ip: ip, port: info.port ?? LocalSend.port, protocol: scheme, info: info) {
                Task { await self.client.register(with: device) }
                DispatchQueue.main.async { self.session.found(device) }
            }
        }
    }

    // --- receiving ---------------------------------------------------------------------------------

    private var receiveObserver: AnyCancellable?

    /// Receiving follows the setting (the menu, the settings window and the LocalSend page change it).
    func start() {
        apply(Preferences.shared.localSendReceive)
        receiveObserver = Preferences.shared.$localSendReceive.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.apply(on)
        }
    }

    func setReceiving(_ on: Bool) {
        Preferences.shared.localSendReceive = on
    }

    /// Muna quits: stop the server, keep the setting.
    func shutdown() {
        apply(false)
    }

    private func apply(_ on: Bool) {
        receiverQueue.async { [weak self] in
            guard let self else { return }
            if on {
                guard self.server == nil else { return }
                guard let certificate = self.certificate else {
                    self.receivingChanged(false, "No certificate (the openssl tool is needed)")
                    return
                }
                let server = LocalSendServer(receiver: self.receiver, certificate: certificate)
                self.server = server
                server.start { problem in
                    if let problem {
                        self.server = nil
                        self.receivingChanged(false, problem)
                        return
                    }
                    try? self.multicast.start()
                    self.multicast.announce(self.receiver.identity())
                    self.receivingChanged(true, nil)
                }
            } else {
                self.server?.stop()
                self.server = nil
                self.multicast.stop()
                self.receiver.stop()
                self.receivingChanged(false, nil)
            }
        }
    }

    private func receivingChanged(_ on: Bool, _ problem: String?) {
        DispatchQueue.main.async {
            self.receiving = on
            self.receiveProblem = problem
        }
    }

    private func publish(_ transfer: IncomingTransfer) {
        let snapshot = IncomingSnapshot(id: transfer.id, sender: transfer.sender.alias, fileNames: transfer.files.map(\.name),
                                        state: transfer.state, received: transfer.received, total: transfer.total,
                                        error: transfer.error, saved: transfer.savedFiles)
        DispatchQueue.main.async { self.incoming = snapshot }
    }

    func accept() { receiverQueue.async { self.pending?.accept() } }
    func decline() { receiverQueue.async { self.pending?.decline() } }

    func dismissMessage() { message = nil }

    func copyMessage() {
        guard let message else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        messageCopied = true
    }

    /// The incoming card is put away.
    func dismissIncoming() {
        guard let incoming, incoming.state != .asking, incoming.state != .receiving else { return }
        self.incoming = nil
    }

    func showReceived() {
        guard let files = incoming?.saved, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }
}

/// A text another device sent.
struct ReceivedText: Equatable {
    let from: String
    let text: String
}
