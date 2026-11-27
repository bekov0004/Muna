import Foundation

/// A file of an incoming transfer.
public final class IncomingFile {
    public let id: String
    public let name: String
    public let size: Int64
    public let token: String
    public internal(set) var received: Int64 = 0
    public internal(set) var done = false
    /// Where it goes (set when the user accepts).
    public internal(set) var url: URL?
    var partURL: URL?
    var handle: FileHandle?

    init(id: String, name: String, size: Int64) {
        self.id = id
        self.name = name
        self.size = size
        token = UUID().uuidString
    }
}

/// One incoming transfer: who sends what, and what became of it. The user decides with accept() or
/// decline(); then the files arrive. Everything happens on the receiver's queue.
public final class IncomingTransfer: Identifiable {
    public enum State: String { case asking, receiving, done, failed, declined }

    public let id = UUID().uuidString            // the LocalSend session id
    public let sender: DeviceInfo
    public let files: [IncomingFile]
    public let folder: URL
    public internal(set) var state = State.asking
    public internal(set) var error: String?
    public var total: Int64 { files.reduce(0) { $0 + $1.size } }
    public var received: Int64 { files.reduce(0) { $0 + $1.received } }
    public var savedFiles: [URL] { files.filter(\.done).compactMap(\.url) }

    var decide: ((Bool) -> Void)?
    weak var receiver: LocalSendReceiver?

    init(sender: DeviceInfo, files: [IncomingFile], folder: URL) {
        self.sender = sender
        self.files = files
        self.folder = folder
    }

    public func accept() { receiver?.queue.async { self.decide?(true) } }
    public func decline() { receiver?.queue.async { self.decide?(false) } }
}

/// Answers one request; created when its head arrived, then fed its body and its end.
public protocol LocalSendRequestHandler: AnyObject {
    func body(_ data: Data)
    func end(respond: @escaping (HTTPResponse) -> Void)
    /// The connection went away before the answer.
    func aborted()
}

/// The receiving side of LocalSend without the network (shared/protocols/localsend.md#receiving):
/// the transport (an HTTPS server) passes each request in, and sends back what it answers.
/// Call everything on `queue`; the callbacks come on it too.
public final class LocalSendReceiver {
    public let queue: DispatchQueue
    /// Who this device is (protocol https).
    public var identity: () -> DeviceInfo
    /// Where accepted files go.
    public var folder: () -> URL
    /// A transfer asks the user (call accept() or decline() on it).
    public var onIncoming: (IncomingTransfer) -> Void = { _ in }
    /// A transfer moved on (state, progress).
    public var onChange: (IncomingTransfer) -> Void = { _ in }
    /// Someone sent a text (LocalSend's text message): shown at once, nothing is uploaded.
    public var onMessage: (DeviceInfo, String) -> Void = { _, _ in }
    public static let maxText = 100_000
    public var askTimeout: TimeInterval = LocalSend.askTimeout

    public private(set) var current: IncomingTransfer?

    public init(queue: DispatchQueue, identity: @escaping () -> DeviceInfo, folder: @escaping () -> URL) {
        self.queue = queue
        self.identity = identity
        self.folder = folder
    }

    public func handler(for head: HTTPRequestHead) -> LocalSendRequestHandler {
        let api = LocalSend.apiPath
        switch (head.method, head.path) {
        case ("GET", api + "/info"), ("POST", api + "/register"):
            return Fixed { [weak self] in .json(200, self?.identity() ?? DeviceInfo(alias: "", fingerprint: "")) }
        case ("POST", api + "/prepare-upload"):
            return Prepare(receiver: self)
        case ("POST", api + "/upload"):
            return Upload(receiver: self, query: head.query)
        case ("POST", api + "/cancel"):
            return Fixed { [weak self] in
                if let current = self?.current, current.id == head.query["sessionId"] {
                    self?.fail(current, "The sender cancelled")
                }
                return HTTPResponse(status: 200)
            }
        default:
            return Fixed { .message(404, "Not found") }
        }
    }

    /// Stops what is going on (receiving was switched off).
    public func stop() {
        if let current, current.state == .asking || current.state == .receiving {
            current.decide?(false)
            fail(current, "Stopped")
        }
        current = nil
    }

    // --- the steps -----------------------------------------------------------------------------

    fileprivate func prepare(_ body: Data, respond: @escaping (HTTPResponse) -> Void) -> IncomingTransfer? {
        guard let request = try? JSONDecoder().decode(PrepareUpload.self, from: body) else {
            respond(.message(400, "Invalid body"))
            return nil
        }
        let entries = request.files.values.sorted { $0.id < $1.id }
        guard !entries.isEmpty, entries.count <= LocalSend.maxIncomingFiles else {
            respond(.message(400, "Invalid body"))
            return nil
        }
        // a text message: one text/plain entry whose words are in `preview`; answered 204 at once, as LocalSend does
        if entries.count == 1, let words = entries[0].preview, entries[0].fileType.hasPrefix("text/") {
            respond(HTTPResponse(status: 204))
            onMessage(request.info, String(words.prefix(Self.maxText)))
            return nil
        }
        if let current, current.state == .asking || current.state == .receiving {
            respond(.message(409, "Blocked by another session"))
            return nil
        }
        let files = entries.map { IncomingFile(id: $0.id, name: ReceivedFileNames.safe($0.fileName), size: max(0, $0.size)) }
        let transfer = IncomingTransfer(sender: request.info, files: files, folder: folder())
        transfer.receiver = self
        current = transfer

        var answered = false
        let timeout = DispatchWorkItem { [weak transfer] in transfer?.decide?(false) }
        transfer.decide = { [weak self, weak transfer] accepted in
            guard let self, let transfer, !answered else { return }
            answered = true
            timeout.cancel()
            transfer.decide = nil
            guard accepted else {
                transfer.state = .declined
                self.onChange(transfer)
                respond(.message(403, "Rejected"))
                return
            }
            do {
                try FileManager.default.createDirectory(at: transfer.folder, withIntermediateDirectories: true)
            } catch {
                self.fail(transfer, "Could not write the file")
                respond(.message(500, "Could not write"))
                return
            }
            var tokens: [String: String] = [:]
            var taken = Set<String>()
            for file in transfer.files {
                // a name not taken on disk nor by another file of this transfer
                let url = ReceivedFileNames.free(in: transfer.folder, name: file.name) { candidate in
                    taken.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path)
                }
                taken.insert(url.path)
                file.url = url
                file.partURL = url.appendingPathExtension("muna-part")
                tokens[file.id] = file.token
            }
            transfer.state = .receiving
            self.onChange(transfer)
            respond(.json(200, PrepareUploadAnswer(sessionId: transfer.id, files: tokens)))
        }
        queue.asyncAfter(deadline: .now() + askTimeout, execute: timeout)
        onIncoming(transfer)
        return transfer
    }

    fileprivate func uploadTarget(_ query: [String: String]) -> (IncomingTransfer, IncomingFile)? {
        guard let transfer = current, transfer.state == .receiving, query["sessionId"] == transfer.id,
              let file = transfer.files.first(where: { $0.id == query["fileId"] }),
              file.token == query["token"], !file.done, file.handle == nil, let part = file.partURL else { return nil }
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else {
            fail(transfer, "Could not write the file")
            return nil
        }
        file.handle = handle
        return (transfer, file)
    }

    fileprivate func write(_ data: Data, to file: IncomingFile, of transfer: IncomingTransfer) {
        guard transfer.state == .receiving, let handle = file.handle else { return }
        do {
            try handle.write(contentsOf: data)
            file.received += Int64(data.count)
            onChange(transfer)
        } catch {
            fail(transfer, "Could not write the file")
        }
    }

    fileprivate func finish(_ file: IncomingFile, of transfer: IncomingTransfer) -> Bool {
        guard transfer.state == .receiving, let handle = file.handle, let part = file.partURL, let url = file.url else { return false }
        try? handle.close()
        file.handle = nil
        do {
            try FileManager.default.moveItem(at: part, to: url)
        } catch {
            fail(transfer, "Could not write the file")
            return false
        }
        file.done = true
        if transfer.files.allSatisfy(\.done) {
            transfer.state = .done
        }
        onChange(transfer)
        return true
    }

    fileprivate func fail(_ transfer: IncomingTransfer, _ message: String) {
        guard transfer.state == .asking || transfer.state == .receiving else { return }
        transfer.state = .failed
        transfer.error = message
        for file in transfer.files {
            try? file.handle?.close()
            file.handle = nil
            if let part = file.partURL, !file.done {
                try? FileManager.default.removeItem(at: part)
            }
        }
        onChange(transfer)
    }

    // --- handlers --------------------------------------------------------------------------------

    private final class Fixed: LocalSendRequestHandler {
        let answer: () -> HTTPResponse
        init(_ answer: @escaping () -> HTTPResponse) { self.answer = answer }
        func body(_ data: Data) {}
        func end(respond: @escaping (HTTPResponse) -> Void) { respond(answer()) }
        func aborted() {}
    }

    private final class Prepare: LocalSendRequestHandler {
        weak var receiver: LocalSendReceiver?
        var data = Data()
        var transfer: IncomingTransfer?
        var tooLarge = false

        init(receiver: LocalSendReceiver) { self.receiver = receiver }

        func body(_ chunk: Data) {
            if data.count + chunk.count > 4 * 1024 * 1024 { tooLarge = true; return }
            data.append(chunk)
        }

        func end(respond: @escaping (HTTPResponse) -> Void) {
            guard !tooLarge else { respond(.message(413, "Too large")); return }
            transfer = receiver?.prepare(data, respond: respond)
        }

        func aborted() {
            // the sender gave up while the user was being asked
            if let transfer, transfer.state == .asking {
                transfer.decide = nil
                receiver?.fail(transfer, "The sender stopped")
            }
        }
    }

    private final class Upload: LocalSendRequestHandler {
        weak var receiver: LocalSendReceiver?
        var target: (IncomingTransfer, IncomingFile)?

        init(receiver: LocalSendReceiver, query: [String: String]) {
            self.receiver = receiver
            target = receiver.uploadTarget(query)
        }

        func body(_ data: Data) {
            guard let (transfer, file) = target else { return }
            receiver?.write(data, to: file, of: transfer)
        }

        func end(respond: @escaping (HTTPResponse) -> Void) {
            guard let (transfer, file) = target else { respond(.message(403, "Invalid token")); return }
            target = nil
            respond((receiver?.finish(file, of: transfer) ?? false) ? HTTPResponse(status: 200) : .message(500, "Could not write"))
        }

        func aborted() {
            guard let (transfer, _) = target else { return }
            target = nil
            receiver?.fail(transfer, "The sender stopped")
        }
    }
}
