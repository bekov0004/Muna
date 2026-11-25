import Foundation
import MunaCore
import Network
import Security

/// The HTTPS server of LocalSend on port 53317: reads requests with MunaCore's parser and lets
/// MunaCore's receiver answer them. Everything runs on the receiver's queue.
final class LocalSendServer {
    private let receiver: LocalSendReceiver
    private let certificate: LocalSendCertificate
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]

    init(receiver: LocalSendReceiver, certificate: LocalSendCertificate) {
        self.receiver = receiver
        self.certificate = certificate
    }

    /// Starts listening; the result (nil, or why it cannot) comes on the receiver's queue.
    func start(_ done: @escaping (String?) -> Void) {
        let tls = NWProtocolTLS.Options()
        guard let identity = sec_identity_create(certificate.identity) else {
            done("No certificate")
            return
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(LocalSend.port))!)
        } catch {
            done("Port \(LocalSend.port) cannot be used")
            return
        }
        var reported = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !reported { reported = true; done(nil) }
            case .failed(let error):
                if !reported {
                    reported = true
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        done("Port \(LocalSend.port) is busy (is the LocalSend app running?)")
                    } else {
                        done("\(error)")
                    }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: receiver.queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections = [:]
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection, receiver: receiver)
        let key = ObjectIdentifier(connection)
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        connections[key] = connection
        connection.start()
    }

    /// One client connection: requests one after another.
    private final class Connection {
        private let connection: NWConnection
        private let receiver: LocalSendReceiver
        private let parser = HTTPRequestParser()
        private var handler: LocalSendRequestHandler?   // the request being read or answered
        private var keepAlive = true
        private var closed = false
        var onClose: () -> Void = {}

        init(_ connection: NWConnection, receiver: LocalSendReceiver) {
            self.connection = connection
            self.receiver = receiver
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
            connection.start(queue: receiver.queue)
            read()
        }

        func close() {
            connection.cancel()
            finish()
        }

        private func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    do {
                        for event in try self.parser.feed(data) {
                            self.handle(event)
                        }
                    } catch {
                        self.respond(.message(400, "Bad request"), keepAlive: false)
                        return
                    }
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.read()
                }
            }
        }

        private func handle(_ event: HTTPRequestParser.Event) {
            switch event {
            case .head(let head):
                keepAlive = head.keepAlive
                handler = receiver.handler(for: head)
            case .body(let data):
                handler?.body(data)
            case .end:
                guard let handler else { return }
                let keepAlive = self.keepAlive
                handler.end { [weak self, weak handler] response in
                    guard let self, !self.closed else { return }
                    if self.handler === handler { self.handler = nil }
                    self.respond(response, keepAlive: keepAlive)
                }
            }
        }

        private func respond(_ response: HTTPResponse, keepAlive: Bool) {
            connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] _ in
                if !keepAlive { self?.close() }
            })
        }

        private func finish() {
            guard !closed else { return }
            closed = true
            // a request that was not answered yet: its sender went away
            handler?.aborted()
            handler = nil
            onClose()
        }
    }
}
