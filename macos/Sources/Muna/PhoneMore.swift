import AppKit
import Combine
import CoreImage
import Darwin
import MunaCore
import SwiftUI
import VideoToolbox

// The rest of Linux's phone on the Mac: pairing over Wi-Fi with a QR code, the live picture (the
// phone's screenrecord, H.264, decoded by VideoToolbox), Muna Phone's link (picture and touches
// over the network, the dark screen), and the Phone widget of the capsule.

// --- pairing ----------------------------------------------------------------------------------------

/// A QR code for the phone's Wireless debugging; adb finds the phone by mDNS, pairs, connects.
final class PhonePairing: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var status = ""          // waiting, pairing, connecting, failed
    @Published private(set) var message = ""
    private var name = "", password = "", host = ""
    private var since = Date()
    private var tried: Set<String> = []
    private var busy = false
    private var timer: Timer?
    private weak var phone: PhoneModel?

    private static func random(_ alphabet: String, _ count: Int) -> String { String((0..<count).map { _ in alphabet.randomElement()! }) }

    func start(_ phone: PhoneModel) {
        self.phone = phone
        name = "muna-" + Self.random("abcdefghjkmnpqrstuvwxyz23456789", 5)
        password = Self.random("0123456789", 6)
        since = Date()
        tried = []
        text = "WIFI:T:ADB;S:\(name);P:\(password);;"
        status = "waiting"
        message = ""
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.advance() }
    }

    func cancel() {
        timer?.invalidate()
        text = nil
        status = ""
    }

    private func advance() {
        guard let phone, !busy, status == "waiting" || status == "connecting" else { return }
        if Date().timeIntervalSince(since) > 180 { status = "failed"; message = "Time is up. Try again."; timer?.invalidate(); return }
        busy = true
        let (name, password, current, host) = (self.name, self.password, status, self.host)
        let tried = self.tried
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let services = PhoneADB.parseMdns(String(decoding: phone.run(["mdns", "services"]), as: UTF8.self))
            var next = "", text = "", newHost = host, address = ""
            if current == "waiting" {
                if let entry = services.first(where: { $0.type == "pairing" && $0.name == name }), !tried.contains(entry.address) {
                    address = entry.address
                    newHost = String(entry.address.split(separator: ":").first ?? "")
                    let result = String(decoding: phone.run(["pair", entry.address, password]), as: UTF8.self)
                    if result.localizedCaseInsensitiveContains("Successfully paired") { (next, text) = ("connecting", "Paired. Connecting…") }
                    else { (next, text) = ("failed", result.split(separator: "\n").first.map(String.init) ?? "Pairing failed") }
                }
            } else if let entry = services.first(where: { $0.type == "connect" && $0.address.hasPrefix(host + ":") }) {
                let result = String(decoding: phone.run(["connect", entry.address]), as: UTF8.self)
                (next, text) = result.localizedCaseInsensitiveContains("connected to") ? ("done", "") : ("failed", result.split(separator: "\n").first.map(String.init) ?? "Could not connect")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if !address.isEmpty { self.tried.insert(address); self.host = newHost }
                if next == "done" { self.cancel(); phone.refreshDevices() }
                else if !next.isEmpty { self.status = next; self.message = text; if next == "failed" { self.timer?.invalidate() } }
            }
        }
    }
}

/// A QR code drawn by Core Image.
func qrImage(_ text: String, side: CGFloat) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: side / output.extent.width, y: side / output.extent.height))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

struct PairingBlock: View {
    @EnvironmentObject var pairing: PhonePairing
    @EnvironmentObject var phone: PhoneModel

    var body: some View {
        QuickBlock {
            Text("Pair a phone over Wi-Fi").font(.system(size: 13, weight: .semibold))
            if pairing.status == "failed" {
                Text(pairing.message).font(.system(size: 12)).foregroundColor(MunaColor.warning)
                HStack { Pill(label: "Try again", accent: true) { pairing.start(phone) }; Pill(label: "Cancel") { pairing.cancel() } }
            } else if let text = pairing.text {
                if let image = qrImage(text, side: 180) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(10).background(Color.white).frame(maxWidth: .infinity)
                }
                Text(pairing.status == "waiting"
                     ? "On the phone: Settings → Developer options → Wireless debugging → Pair device with QR code, and scan this. The phone and this Mac must be on the same Wi-Fi."
                     : pairing.message)
                    .font(.system(size: 11)).foregroundColor(MunaColor.secondary).fixedSize(horizontal: false, vertical: true)
                Pill(label: "Cancel") { pairing.cancel() }
            }
        }
    }
}

// --- the live picture -------------------------------------------------------------------------------

/// H.264 access units in, pictures out (VideoToolbox, on the Mac's own decoder).
final class H264VideoDecoder {
    var onImage: (CGImage) -> Void = { _ in }
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private let context = CIContext()

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// The NALs of a unit, without their start codes.
    private static func nals(_ unit: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var start = -1
        var i = 0
        while i + 2 < unit.count {
            if unit[i] == 0 && unit[i + 1] == 0 && unit[i + 2] == 1 {
                if start >= 0 { var end = i; if end > start && unit[end - 1] == 0 { end -= 1 }; result.append(Array(unit[start..<end])) }
                start = i + 3
                i += 3
                continue
            }
            i += 1
        }
        if start >= 0 && start < unit.count { result.append(Array(unit[start...])) }
        return result
    }

    func decode(_ unit: [UInt8]) {
        var slices: [[UInt8]] = []
        for nal in Self.nals(unit) where !nal.isEmpty {
            switch nal[0] & 0x1F {
            case 7: if nal != sps { sps = nal; format = nil }
            case 8: if nal != pps { pps = nal; format = nil }
            case 1, 5: slices.append(nal)
            default: break
            }
        }
        if format == nil, let sps, let pps { makeSession(sps, pps) }
        guard let session, let format, !slices.isEmpty else { return }
        // AVCC: every NAL after its length in four bytes
        var data: [UInt8] = []
        for nal in slices {
            let n = UInt32(nal.count)
            data += [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var sizes = [data.count]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr, let sample else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, buffer, _, _ in
            guard status == noErr, let buffer, let self else { return }
            let image = CIImage(cvImageBuffer: buffer)
            if let cg = self.context.createCGImage(image, from: image.extent) { self.onImage(cg) }
        }
    }

    private func makeSession(_ sps: [UInt8], _ pps: [UInt8]) {
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        format = description
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        var made: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
                                     imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &made)
        session = made
    }
}

/// The phone's screen as a live picture: through Muna Phone's link when the app is on the phone,
/// else the phone's own screenrecord through adb. Touches go the same way.
final class PhoneStream {
    private weak var phone: PhoneModel?
    private var running = false
    private var record: Process?
    private(set) var link: PhoneLinkConnection?
    private var lastShown = Date.distantPast
    var onState: (String) -> Void = { _ in }

    init(phone: PhoneModel) { self.phone = phone }

    var isOn: Bool { running }

    func start(serial: String) {
        guard !running else { return }
        running = true
        Thread { [weak self] in self?.loop(serial) }.start()
    }

    func stop() {
        running = false
        record?.terminate()
        link?.close()
    }

    private func show(_ image: CGImage) {
        // the newest picture only, at most 30 a second
        let now = Date()
        guard now.timeIntervalSince(lastShown) > 0.03 else { return }
        lastShown = now
        DispatchQueue.main.async { [weak self] in
            guard let phone = self?.phone, self?.running == true else { return }
            phone.screen = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    private func loop(_ serial: String) {
        guard let phone else { return }
        // Muna Phone first
        let apk = String(decoding: phone.run(["-s", serial, "shell", "pm", "path", PhoneLinkProtocol.appId]), as: UTF8.self)
            .split(separator: "\n").first { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        if let apk, running {
            do {
                let link = try PhoneLinkConnection.launch(phone: phone, serial: serial, apk: apk)
                self.link = link
                DispatchQueue.main.async { self.onState("link") }
                if let size = link.screenSize { DispatchQueue.main.async { phone.pixels = size } }
                if Preferences.shared.bool("phone-dark-screen") { link.send("p 0") }
                let decoder = H264VideoDecoder()
                decoder.onImage = { [weak self] in self?.show($0) }
                let splitter = AnnexB()
                var buffer = [UInt8](repeating: 0, count: 16384)
                while running {
                    let n = Darwin.read(link.videoSocket, &buffer, buffer.count)
                    if n <= 0 { break }
                    for unit in splitter.push(Array(buffer[0..<n])) { decoder.decode(unit) }
                }
            } catch {
                let message = (error as? LinkError)?.text ?? error.localizedDescription
                DispatchQueue.main.async { self.onState("Muna Phone: \(message). The picture comes through adb.") }
            }
            link?.close()
            link = nil
            DispatchQueue.main.async { self.onState("adb") }
        }
        // screenrecord through adb (it stops after three minutes: again)
        while running, let adb = phone.adb {
            let size = phone.pixels
            let width = Int((min(540, size.width) / 16).rounded()) * 16
            let height = Int((size.height * CGFloat(width) / max(size.width, 1) / 16).rounded()) * 16
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            process.arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264", "--size=\(width)x\(height)", "--bit-rate=5000000", "-"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { break }
            record = process
            let decoder = H264VideoDecoder()
            decoder.onImage = { [weak self] in self?.show($0) }
            let splitter = AnnexB()
            let started = Date()
            while running {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                for unit in splitter.push([UInt8](data)) { decoder.decode(unit) }
            }
            process.terminate()
            if running { Thread.sleep(forTimeInterval: Date().timeIntervalSince(started) < 2 ? 1.2 : 0.3) }
        }
    }
}

struct LinkError: Error { let text: String }

/// Muna Phone's link (linux/src/phone/phoneLink.js launchServer): the app's server, started on the
/// phone with adb, dials back twice (control and picture) and proves the secret; "h" every 4 seconds.
final class PhoneLinkConnection {
    static let preferredPort: UInt16 = 47831
    let controlSocket: Int32
    let videoSocket: Int32
    let info: String
    private var server: Process?
    private var beat: Timer?
    private let writeLock = NSLock()
    private var closed = false

    private init(control: Int32, video: Int32, info: String, server: Process?) {
        controlSocket = control
        videoSocket = video
        self.info = info
        self.server = server
        DispatchQueue.main.async { [weak self] in
            self?.beat = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                if self?.send("h") == false { self?.close() }
            }
        }
        // the phone's lines (H, POWER …) are read so its sending never blocks
        Thread { [weak self] in
            var byte: UInt8 = 0
            while let socket = self?.controlSocket, Darwin.read(socket, &byte, 1) == 1 {}
        }.start()
    }

    var screenSize: CGSize? {
        let parts = info.split(separator: " ").first?.split(separator: "x") ?? []
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return CGSize(width: w, height: h)
    }

    @discardableResult
    func send(_ line: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        let bytes = Array((line + "\n").utf8)
        return bytes.withUnsafeBytes { Darwin.write(controlSocket, $0.baseAddress, bytes.count) } == bytes.count
    }

    func close() {
        writeLock.lock()
        let wasClosed = closed
        if !closed { let bytes = Array("q\n".utf8); _ = bytes.withUnsafeBytes { Darwin.write(controlSocket, $0.baseAddress, bytes.count) } }
        closed = true
        writeLock.unlock()
        guard !wasClosed else { return }
        DispatchQueue.main.async { [weak self] in self?.beat?.invalidate() }
        Darwin.close(controlSocket)
        Darwin.close(videoSocket)
        server?.terminate()
    }

    /// This Mac's IPv4 addresses with their prefix lengths.
    private static func localAddresses() -> [(address: String, prefix: Int)] {
        var result: [(String, Int)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = entry.pointee.ifa_netmask {
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }.nonzeroBitCount
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var copy = ip
                inet_ntop(AF_INET, &copy, &text, socklen_t(INET_ADDRSTRLEN))
                result.append((String(cString: text), bits))
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }

    private static func readLine(_ socket: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 4096 {
            guard Darwin.read(socket, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            bytes.append(byte)
        }
        return nil
    }

    private static func write(_ socket: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, bytes.count) }
    }

    /// Starts the server on the phone and waits (12 s) for its two connections.
    static func launch(phone: PhoneModel, serial: String, apk: String) throws -> PhoneLinkConnection {
        let phoneAddresses = String(decoding: phone.run(["-s", serial, "shell", "ip", "-4", "addr", "show"]), as: UTF8.self)
        guard let host = PhoneLinkProtocol.lanAddress(phone: phoneAddresses, local: localAddresses()) else {
            throw LinkError(text: "the phone and this Mac are not in the same network")
        }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LinkError(text: "no socket") }
        defer { Darwin.close(listener) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        func bindTo(_ port: UInt16) -> Bool {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
        guard bindTo(preferredPort) || bindTo(0), listen(listener, 4) == 0 else { throw LinkError(text: "cannot listen") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let port = UInt16(bigEndian: bound.sin_port)
        let token = PhoneLinkProtocol.randomToken()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: phone.adb ?? "/usr/local/bin/adb")
        server.arguments = ["-s", serial, "shell", "CLASSPATH='\(apk)'", "app_process", "/", PhoneLinkProtocol.serverClass, host, "\(port)", token]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try? server.run()
        var control: Int32 = -1, video: Int32 = -1, info = ""
        let deadline = Date().addingTimeInterval(12)
        while control < 0 || video < 0 {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&poller, 1, left) > 0 else {
                if control >= 0 { Darwin.close(control) }
                if video >= 0 { Darwin.close(video) }
                server.terminate()
                throw LinkError(text: "the phone did not connect (the Mac's firewall may block Muna)")
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var timeout = timeval(tv_sec: 8, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let hello = readLine(client), let challenge = PhoneLinkProtocol.challenge(hello: hello, token: token) else {
                write(client, "NO"); Darwin.close(client); continue
            }
            write(client, challenge.line)
            guard let auth = readLine(client), let told = PhoneLinkProtocol.check(auth: auth, token: token, nonce: challenge.nonce, phoneNonce: challenge.phoneNonce),
                  (challenge.role == "C" ? control : video) < 0 else {
                write(client, "NO"); Darwin.close(client); continue
            }
            write(client, "OK")
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
            if challenge.role == "C" { control = client } else { video = client }
            info = told
        }
        return PhoneLinkConnection(control: control, video: video, info: info, server: server)
    }
}

// --- the Phone widget of the capsule ----------------------------------------------------------------

struct PhoneCardWidget: View {
    @EnvironmentObject var phone: PhoneModel
    @EnvironmentObject var pairing: PhonePairing

    var body: some View {
        Group {
            if phone.adb == nil {
                VStack(spacing: 6) {
                    Image(systemName: "iphone").font(.system(size: 20)).foregroundColor(MunaColor.secondary)
                    Text("Install adb").font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if phone.device?.ready != true {
                VStack(spacing: 6) {
                    Image(systemName: "iphone").font(.system(size: 20)).foregroundColor(MunaColor.secondary)
                    Pill(label: "Pair over Wi-Fi", accent: true) { pairing.start(phone) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05))
                        if let image = phone.screen { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                        let size = CGSize(width: 60, height: 60 * phone.pixels.height / max(phone.pixels.width, 1))
                        if hypot(drag.translation.width, drag.translation.height) < 6 { phone.tap(drag.startLocation, in: size) }
                        else { phone.swipe(from: drag.startLocation, to: drag.location, in: size, seconds: 0.3) }
                    })
                    VStack(spacing: 4) {
                        IconButton(symbol: "chevron.backward") { phone.key(PhoneADB.back) }
                        IconButton(symbol: "circle") { phone.key(PhoneADB.home) }
                    }
                }
            }
        }
        .onAppear { phone.watch() }
        .onDisappear { phone.unwatch() }
    }
}
