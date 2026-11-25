import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// LocalSend's announcements on UDP 224.0.0.167:53317: says "here I am" when receiving starts, and
/// hears the others (who are then answered with /register, so they know this device too).
public final class LocalSendMulticast {
    public var onAnnouncement: (DeviceInfo, String) -> Void = { _, _ in }
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { stop() }

    /// Listens for announcements. Throws when the port cannot be used.
    public func start() throws {
        guard socketFD < 0 else { return }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.address(INADDR_ANY, port: LocalSend.port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var membership = ip_mreq()
        membership.imr_multiaddr.s_addr = inet_addr(LocalSend.multicastAddress)
        membership.imr_interface.s_addr = INADDR_ANY.bigEndian
        setsockopt(fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        socketFD = -1
    }

    /// Tells the network that this device is here.
    public func announce(_ info: DeviceInfo) {
        var info = info
        info.announce = true
        guard let data = try? JSONEncoder().encode(info) else { return }
        let fd = socketFD >= 0 ? socketFD : Self.sendSocket()
        guard fd >= 0 else { return }
        var address = Self.address(inet_addr(LocalSend.multicastAddress), port: LocalSend.port)
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if fd != socketFD { close(fd) }
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0,
              let info = try? JSONDecoder().decode(DeviceInfo.self, from: Data(buffer[0..<count])),
              info.announce == true else { return }
        var text = [CChar](repeating: 0, count: 64)
        var addr = from.sin_addr
        inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
        onAnnouncement(info, String(cString: text))
    }

    private static func sendSocket() -> Int32 {
        #if canImport(Glibc)
        return socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        return socket(AF_INET, SOCK_DGRAM, 0)
        #endif
    }

    /// `host` in network byte order (as inet_addr gives it; INADDR_ANY is 0 either way).
    private static func address(_ host: in_addr_t, port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = host
        return address
    }
}
