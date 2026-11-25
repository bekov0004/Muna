import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// How far a sending got: 'waiting' until the receiver accepts, then 'sending'.
public struct SendProgress: Equatable, Sendable {
    public var phase: String
    public var sent: Int64
    public var total: Int64
    public var skipped: Int
}

public struct SendResult: Equatable, Sendable {
    public var count: Int
    public var skipped: Int
}

/// A short, readable reason a sending failed.
public struct SendError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public static let cancelled = SendError("Cancelled")
}

/// What sending needs from the network (a fake one in tests).
public protocol LocalSendTransport: AnyObject {
    func probe(ip: String) async -> Device?
    func send(to device: Device, files: [URL], onState: @escaping (SendProgress) -> Void) async throws -> SendResult
}

/// LocalSend over HTTPS / HTTP with URLSession (shared/protocols/localsend.md).
public final class LocalSendClient: NSObject, LocalSendTransport, URLSessionDataDelegate {
    /// Who this device is when it sends.
    public var identity: () -> DeviceInfo
    /// Answers TLS questions: the other devices' certificates are self-signed, and some ask for ours.
    /// (The app sets it on macOS; without it the system's rules apply.)
    public var challengeHandler: ((URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    public var probeTimeout: TimeInterval = 2

    private var session: URLSession!
    private let lock = NSLock()
    private var uploadProgress: [Int: (Int64) -> Void] = [:]

    public init(identity: @escaping () -> DeviceInfo) {
        self.identity = identity
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 90       // the receiver's user may take a minute to answer
        configuration.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // --- finding ------------------------------------------------------------------------------

    public func probe(ip: String) async -> Device? {
        for scheme in ["https", "http"] {
            guard let url = URL(string: "\(scheme)://\(ip):\(LocalSend.port)\(LocalSend.apiPath)/info") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = probeTimeout
            do {
                let (data, status) = try await perform(request)
                guard status == 200, let info = try? JSONDecoder().decode(DeviceInfo.self, from: data) else { return nil }
                return Device(ip: ip, port: LocalSend.port, protocol: scheme, info: info)
            } catch {
                // Nobody there: no need to try the other protocol. A refusal to talk TLS (or plain HTTP) is.
                if let error = error as? URLError,
                   [.cannotConnectToHost, .timedOut, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost, .cancelled]
                   .contains(error.code) {
                    return nil
                }
            }
        }
        return nil
    }

    /// Introduces this device to another one (POST /register); the answer is not needed.
    public func register(with device: Device) async {
        guard let url = URL(string: "\(device.protocol)://\(device.ip):\(device.port)\(LocalSend.apiPath)/register") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = probeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(identity())
        _ = try? await perform(request)
    }

    // --- sending ------------------------------------------------------------------------------

    public func send(to device: Device, files: [URL], onState: @escaping (SendProgress) -> Void) async throws -> SendResult {
        struct Entry { let id: String; let url: URL; let size: Int64; let type: String }
        var entries: [Entry] = []
        var skipped = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { skipped += 1; continue }
            entries.append(Entry(id: "file\(entries.count)", url: url, size: Int64(values?.fileSize ?? 0), type: Self.mimeType(of: url)))
        }
        guard !entries.isEmpty else { throw SendError("Nothing to send (folders are not supported yet)") }
        let total = entries.reduce(0) { $0 + $1.size }
        let base = "\(device.protocol)://\(device.ip):\(device.port)\(LocalSend.apiPath)"

        var me = identity()
        me.protocol = "http"
        me.announce = nil
        var sessionId: String?
        do {
            onState(SendProgress(phase: "waiting", sent: 0, total: total, skipped: skipped))
            var prepare = URLRequest(url: URL(string: "\(base)/prepare-upload")!)
            prepare.httpMethod = "POST"
            prepare.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var described: [String: PrepareUpload.File] = [:]
            for entry in entries {
                described[entry.id] = PrepareUpload.File(id: entry.id, fileName: entry.url.lastPathComponent, size: entry.size, fileType: entry.type)
            }
            prepare.httpBody = try JSONEncoder().encode(PrepareUpload(info: me, files: described))
            let (data, status) = try await perform(prepare)
            switch status {
            case 200: break
            case 204: return SendResult(count: 0, skipped: skipped)
            case 403: throw SendError("\(device.alias) declined")
            case 409, 429: throw SendError("\(device.alias) is busy")
            default: throw SendError("\(device.alias) answered \(status)")
            }
            guard let answer = try? JSONDecoder().decode(PrepareUploadAnswer.self, from: data) else {
                throw SendError("\(device.alias) answered something odd")
            }
            sessionId = answer.sessionId

            var sent: Int64 = 0
            onState(SendProgress(phase: "sending", sent: 0, total: total, skipped: skipped))
            for entry in entries {
                guard let token = answer.files[entry.id] else { continue }
                var components = URLComponents(string: "\(base)/upload")!
                components.queryItems = [URLQueryItem(name: "sessionId", value: answer.sessionId),
                                         URLQueryItem(name: "fileId", value: entry.id),
                                         URLQueryItem(name: "token", value: token)]
                var upload = URLRequest(url: components.url!)
                upload.httpMethod = "POST"
                upload.setValue(entry.type, forHTTPHeaderField: "Content-Type")
                let before = sent
                let status = try await uploadFile(upload, from: entry.url) { bytes in
                    onState(SendProgress(phase: "sending", sent: min(before + bytes, total), total: total, skipped: skipped))
                }
                guard status == 200 else { throw SendError("\(device.alias) stopped the transfer") }
                sent = before + entry.size
                // not every URLSession reports the bytes as they go: the file is whole now
                onState(SendProgress(phase: "sending", sent: sent, total: total, skipped: skipped))
            }
            return SendResult(count: entries.count, skipped: skipped)
        } catch {
            if let sessionId, !((error as? SendError)?.message.hasSuffix("declined") ?? false) {
                var cancel = URLRequest(url: URL(string: "\(base)/cancel?sessionId=\(sessionId)")!)
                cancel.httpMethod = "POST"
                cancel.timeoutInterval = 5
                Task { _ = try? await self.perform(cancel) }
            }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw SendError.cancelled }
            if let error = error as? SendError { throw error }
            throw SendError("Could not reach \(device.alias)")
        }
    }

    static func mimeType(of url: URL) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        #endif
        return "application/octet-stream"
    }

    // --- URLSession, with cancellation ------------------------------------------------------------

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                    }
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private func uploadFile(_ request: URLRequest, from file: URL, progress: @escaping (Int64) -> Void) async throws -> Int {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let task = session.uploadTask(with: request, fromFile: file) { [weak self] _, response, error in
                    if let id = holder.task?.taskIdentifier { self?.setProgress(id, nil) }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                }
                holder.task = task
                setProgress(task.taskIdentifier, progress)
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private func setProgress(_ id: Int, _ callback: ((Int64) -> Void)?) {
        lock.lock()
        uploadProgress[id] = callback
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let callback = uploadProgress[task.taskIdentifier]
        lock.unlock()
        callback?(totalBytesSent)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let challengeHandler {
            let (disposition, credential) = challengeHandler(challenge)
            completionHandler(disposition, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private final class TaskHolder: @unchecked Sendable {
    var task: URLSessionTask?
}

// --- finding devices -------------------------------------------------------------------------------

public enum LocalNetwork {
    /// Interfaces that are never where phones and computers of the office live.
    static let virtualPrefixes = ["lo", "docker", "br-", "veth", "virbr", "tun", "tap", "vmnet", "zt",
                                  "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap"]

    /// Every address of the /24 around each of this machine's IPv4 LAN addresses, except its own.
    public static func subnetHosts() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for (name, address) in ipv4Addresses() where !virtualPrefixes.contains(where: { name.hasPrefix($0) }) {
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[0] != 127, !(parts[0] == 169 && parts[1] == 254) else { continue }
            for host in 1..<255 where host != parts[3] {
                let ip = "\(parts[0]).\(parts[1]).\(parts[2]).\(host)"
                if seen.insert(ip).inserted { result.append(ip) }
            }
        }
        return result
    }

    /// (interface name, IPv4 address) of this machine.
    public static func ipv4Addresses() -> [(String, String)] {
        var result: [(String, String)] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            #if canImport(Darwin)
            let length = socklen_t(address.pointee.sa_len)
            #else
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            #endif
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
        }
        return result
    }

    /// Asks every host (64 at once); `found` is called for each device as it answers.
    public static func scan(hosts: [String], with transport: LocalSendTransport, found: @escaping (Device) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let width = min(64, hosts.count)
            func add() {
                guard next < hosts.count else { return }
                let ip = hosts[next]
                next += 1
                group.addTask {
                    if Task.isCancelled { return }
                    if let device = await transport.probe(ip: ip) { found(device) }
                }
            }
            for _ in 0..<width { add() }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                add()
            }
        }
    }
}
