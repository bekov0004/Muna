import Foundation
import XCTest
@testable import MunaCore

final class HTTPParserTests: XCTestCase {
    func testHeadAndBodyInPieces() throws {
        let parser = HTTPRequestParser()
        let request = "POST /api/localsend/v2/upload?sessionId=s%201&fileId=f0&token=t HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789"
        var events: [HTTPRequestParser.Event] = []
        for byte in Data(request.utf8) {   // one byte at a time
            events += try parser.feed(Data([byte]))
        }
        guard case .head(let head) = events.first else { return XCTFail("no head") }
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/api/localsend/v2/upload")
        XCTAssertEqual(head.query, ["sessionId": "s 1", "fileId": "f0", "token": "t"])
        XCTAssertEqual(head.contentLength, 10)
        let body = events.compactMap { event -> Data? in if case .body(let d) = event { return d } else { return nil } }.reduce(Data(), +)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "0123456789")
        XCTAssertEqual(events.last, .end)
    }

    func testChunkedAndTwoRequestsOnOneConnection() throws {
        let parser = HTTPRequestParser()
        let text = "POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\n\r\nGET /b HTTP/1.1\r\nConnection: close\r\n\r\n"
        let events = try parser.feed(Data(text.utf8))
        let bodies = events.compactMap { event -> String? in if case .body(let d) = event { return String(decoding: d, as: UTF8.self) } else { return nil } }
        XCTAssertEqual(bodies.joined(), "Wikipedia")
        let heads = events.compactMap { event -> HTTPRequestHead? in if case .head(let h) = event { return h } else { return nil } }
        XCTAssertEqual(heads.map(\.path), ["/a", "/b"])
        XCTAssertFalse(heads[1].keepAlive)
        XCTAssertEqual(events.filter { $0 == .end }.count, 2)
    }

    func testTooLargeHead() {
        XCTAssertThrowsError(try HTTPRequestParser().feed(Data(repeating: 65, count: HTTPRequestParser.maxHeadSize + 1)))
    }

    func testResponse() {
        let text = String(decoding: HTTPResponse.message(403, "Rejected").serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 22\r\n"))
        XCTAssertTrue(text.hasSuffix("{\"message\":\"Rejected\"}"))
    }
}

final class ReceiverTests: XCTestCase {
    var folder: URL!
    let queue = DispatchQueue(label: "receiver-test")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-recv-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeReceiver() -> LocalSendReceiver {
        LocalSendReceiver(queue: queue, identity: { DeviceInfo(alias: "mac", fingerprint: "fp-mac") }, folder: { self.folder })
    }

    /// Runs one request through the receiver like the server does; waits for the answer.
    private func request(_ receiver: LocalSendReceiver, _ method: String, _ path: String, query: [String: String] = [:],
                         body: Data = Data(), during: ((LocalSendRequestHandler) -> Void)? = nil) -> HTTPResponse {
        let answered = expectation(description: "answer")
        var response: HTTPResponse?
        queue.async {
            let handler = receiver.handler(for: HTTPRequestHead(method: method, path: LocalSend.apiPath + path, query: query))
            stride(from: 0, to: body.count, by: 7).forEach { handler.body(body.subdata(in: $0..<min($0 + 7, body.count))) }
            during?(handler)
            handler.end { response = $0; answered.fulfill() }
        }
        wait(for: [answered], timeout: 5)
        return response ?? HTTPResponse(status: 0)
    }

    private func prepareBody(_ names: [String]) throws -> Data {
        var files: [String: PrepareUpload.File] = [:]
        for (index, name) in names.enumerated() {
            files["f\(index)"] = PrepareUpload.File(id: "f\(index)", fileName: name, size: 5, fileType: "text/plain")
        }
        return try JSONEncoder().encode(PrepareUpload(info: DeviceInfo(alias: "linux-pc", fingerprint: "fp-linux", protocol: "http"), files: files))
    }

    func testInfo() throws {
        let response = request(makeReceiver(), "GET", "/info")
        XCTAssertEqual(response.status, 200)
        let info = try JSONDecoder().decode(DeviceInfo.self, from: response.body)
        XCTAssertEqual(info.deviceModel, "Muna")
        XCTAssertEqual(info.fingerprint, "fp-mac")
        XCTAssertEqual(request(makeReceiver(), "GET", "/nothing").status, 404)
    }

    func testAcceptAndReceive() throws {
        let receiver = makeReceiver()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("a.txt"))   // taken: the new one is "a (1).txt"
        var asked: IncomingTransfer?
        receiver.onIncoming = { transfer in
            asked = transfer
            transfer.accept()
        }
        let prepared = request(receiver, "POST", "/prepare-upload", body: try prepareBody(["a.txt", "../evil.sh"]))
        XCTAssertEqual(prepared.status, 200)
        XCTAssertEqual(asked?.sender.alias, "linux-pc")
        let answer = try JSONDecoder().decode(PrepareUploadAnswer.self, from: prepared.body)
        XCTAssertEqual(answer.files.count, 2)
        // a wrong token is refused, and the body goes nowhere
        XCTAssertEqual(request(receiver, "POST", "/upload", query: ["sessionId": answer.sessionId, "fileId": "f0", "token": "nope"], body: Data("xxxxx".utf8)).status, 403)
        for (id, text) in [("f0", "hello"), ("f1", "world")] {
            let response = request(receiver, "POST", "/upload",
                                   query: ["sessionId": answer.sessionId, "fileId": id, "token": answer.files[id]!], body: Data(text.utf8))
            XCTAssertEqual(response.status, 200)
        }
        XCTAssertEqual(asked?.state, .done)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a (1).txt"), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("evil.sh"), encoding: .utf8), "world")
        XCTAssertEqual(asked?.received, 10)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".muna-part") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    /// LocalSend's text message: shown at once (204), no question, nothing written.
    func testTextMessage() throws {
        let receiver = makeReceiver()
        var asked = false
        var got: (String, String)?
        receiver.onIncoming = { _ in asked = true }
        receiver.onMessage = { sender, text in got = (sender.alias, text) }
        let body = try JSONEncoder().encode(PrepareUpload(info: DeviceInfo(alias: "phone", fingerprint: "fp-phone"),
            files: ["t": PrepareUpload.File(id: "t", fileName: "message.txt", size: 5, fileType: "text/plain", preview: "Hello — привет")]))
        XCTAssertEqual(request(receiver, "POST", "/prepare-upload", body: body).status, 204)
        XCTAssertFalse(asked)
        XCTAssertEqual(got?.0, "phone")
        XCTAssertEqual(got?.1, "Hello — привет")
        XCTAssertNil(receiver.current)
    }

    func testDeclineBusyAndTimeout() throws {
        let receiver = makeReceiver()
        receiver.onIncoming = { $0.decline() }
        XCTAssertEqual(request(receiver, "POST", "/prepare-upload", body: try prepareBody(["a.txt"])).status, 403)
        // while one waits for the user, another sender is told it is busy; the first times out
        receiver.askTimeout = 0.5
        var first: IncomingTransfer?
        receiver.onIncoming = { first = $0 }
        let waiting = expectation(description: "first answer")
        var firstStatus = 0
        let body = try prepareBody(["a.txt"])
        queue.async {
            let handler = receiver.handler(for: HTTPRequestHead(method: "POST", path: LocalSend.apiPath + "/prepare-upload"))
            handler.body(body)
            handler.end { firstStatus = $0.status; waiting.fulfill() }
        }
        XCTAssertEqual(request(receiver, "POST", "/prepare-upload", body: body).status, 409)
        wait(for: [waiting], timeout: 5)
        XCTAssertEqual(firstStatus, 403)
        XCTAssertEqual(first?.state, .declined)
        XCTAssertEqual(request(receiver, "POST", "/prepare-upload", body: Data("{bad".utf8)).status, 400)
    }

    func testSenderGoneRemovesParts() throws {
        let receiver = makeReceiver()
        receiver.onIncoming = { $0.accept() }
        let answer = try JSONDecoder().decode(PrepareUploadAnswer.self,
                                              from: request(receiver, "POST", "/prepare-upload", body: try prepareBody(["big.bin"])).body)
        let gone = expectation(description: "aborted")
        queue.async {
            let handler = receiver.handler(for: HTTPRequestHead(method: "POST", path: LocalSend.apiPath + "/upload",
                                                                query: ["sessionId": answer.sessionId, "fileId": "f0", "token": answer.files["f0"]!]))
            handler.body(Data("12".utf8))
            handler.aborted()
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
        queue.sync {}
        XCTAssertEqual(receiver.current?.state, .failed)
        XCTAssertEqual(receiver.current?.error, "The sender stopped")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}

/// A network of pretend devices for the session.
final class FakeTransport: LocalSendTransport {
    var devices: [String: Device] = [:]
    var declines: Set<String> = []
    var sent: [String] = []
    let lock = NSLock()

    func probe(ip: String) async -> Device? { devices[ip] }

    func send(to device: Device, files: [URL], text: String?, onState: @escaping (SendProgress) -> Void) async throws -> SendResult {
        onState(SendProgress(phase: "waiting", sent: 0, total: 10, skipped: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        if declines.contains(device.alias) { throw SendError("\(device.alias) declined") }
        onState(SendProgress(phase: "sending", sent: 5, total: 10, skipped: 0))
        lock.lock(); sent.append(device.alias); lock.unlock()
        return SendResult(count: files.count, skipped: 0)
    }
}

final class SendSessionTests: XCTestCase {
    func testGroupSendSummaryAndRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = FakeTransport()
        transport.devices = [
            "10.0.0.2": Device(ip: "10.0.0.2", alias: "Anvar", deviceModel: "Muna", fingerprint: "fp-anvar"),
            "10.0.0.3": Device(ip: "10.0.0.3", alias: "Dilnoza", deviceModel: "Muna", fingerprint: "fp-dilnoza"),
            "10.0.0.4": Device(ip: "10.0.0.4", alias: "Pixel", deviceModel: "Pixel 8"),
        ]
        transport.declines = ["Pixel"]
        let queue = DispatchQueue(label: "session-test")
        let groups = GroupsStore(store: JSONStore(name: "groups.json", directory: folder))
        let session = SendSession(transport: transport, groups: groups, queue: queue)
        session.hosts = { ["10.0.0.4", "10.0.0.3", "10.0.0.2", "10.0.0.9"] }
        var finished: [String] = []
        session.onFinished = { title, details, _ in finished.append("\(title) | \(details)") }

        func until(_ what: String, _ condition: @escaping () -> Bool) {
            let done = expectation(description: what)
            func check() { queue.asyncAfter(deadline: .now() + 0.02) { condition() ? done.fulfill() : check() } }
            check()
            wait(for: [done], timeout: 5)
        }

        queue.sync { session.scan() }
        until("scan") { session.phase == .pick }
        queue.sync {
            XCTAssertEqual(session.devices.map(\.alias), ["Anvar", "Dilnoza", "Pixel"])   // Munas first
            session.offer([URL(fileURLWithPath: "/tmp/a.txt")])
            session.toggle(session.devices[0])
            session.toggle(session.devices[2])
            try? session.saveGroup(named: "Office")
            XCTAssertEqual(session.activeGroup?.name, "Office")
        }
        // a member who is not on the network
        try queue.sync {
            let office = try XCTUnwrap(session.groups.first)
            try groups.save(id: office.id, name: "Office", members: office.members + [GroupMember(fingerprint: "fp-bekzod", alias: "Bekzod")])
            session.clearSelection()
            session.selectGroup(try XCTUnwrap(session.groups.first))
            XCTAssertEqual(session.selectedDevices.map(\.alias), ["Anvar", "Pixel"])
            session.send()
            XCTAssertEqual(session.phase, .sending)
        }
        until("sent") { session.phase == .done }
        queue.sync {
            XCTAssertEqual(session.message, "1 of 3 received")
            XCTAssertEqual(session.transfers.map { "\($0.name):\($0.phase.rawValue)" }, ["Anvar:done", "Pixel:failed", "Bekzod:missing"])
            XCTAssertEqual(session.transfers[1].message, "Pixel declined")
            XCTAssertEqual(session.basket.count, 1)   // kept for "Try again"
            XCTAssertEqual(finished.last, "1 of 3 received | Not received: Pixel, Bekzod")
        }
        // Pixel now accepts: try again
        transport.declines = []
        queue.sync { session.retryFailed() }
        until("retry") { session.phase == .done }
        queue.sync {
            XCTAssertEqual(session.message, "2 of 3 received")
            XCTAssertEqual(transport.sent.sorted(), ["Anvar", "Pixel"])
            session.dismiss()
            // one device, the quick way
            session.send(to: session.devices[1])
        }
        until("one") { session.phase == .done }
        queue.sync {
            XCTAssertEqual(session.message, "Sent to Dilnoza")
            XCTAssertTrue(session.basket.isEmpty)
            session.deleteGroup(session.groups[0].id)
            XCTAssertTrue(session.groups.isEmpty)
        }
    }
}

/// The real client against shared/testing/fakels.py (plain HTTP, like a LocalSend app without TLS).
final class ClientTests: XCTestCase {
    func testProbeAndSendToFakeDevices() throws {
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../shared/testing/fakels.py").standardized
        guard FileManager.default.fileExists(atPath: fake.path), FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("needs python3 and shared/testing/fakels.py")
        }
        var processes: [Process] = []
        defer { processes.forEach { $0.terminate() } }
        for (ip, alias, mode) in [("127.0.0.12", "Ali", "accept"), ("127.0.0.13", "Vali", "decline")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [fake.path, ip, alias, "Muna", "fp-\(alias)", mode, "0.2"]
            try process.run()
            processes.append(process)
        }
        Thread.sleep(forTimeInterval: 1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("muna-client-\(UUID().uuidString).txt")
        try Data(String(repeating: "muna ", count: 20000).utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let client = LocalSendClient(identity: { DeviceInfo(alias: "mac", fingerprint: "fp-mac") })
        let done = expectation(description: "client")
        Task {
            let ali = await client.probe(ip: "127.0.0.12")
            XCTAssertEqual(ali?.alias, "Ali")
            XCTAssertEqual(ali?.protocol, "http")
            XCTAssertTrue(ali?.isMuna ?? false)
            let nobody = await client.probe(ip: "127.0.0.19")
            XCTAssertNil(nobody)
            if let ali {
                var phases: [String] = []
                var last: Int64 = 0
                let result = try? await client.send(to: ali, files: [file, FileManager.default.temporaryDirectory]) { progress in
                    if phases.last != progress.phase { phases.append(progress.phase) }
                    last = progress.sent
                }
                XCTAssertEqual(result, SendResult(count: 1, skipped: 1))
                XCTAssertEqual(phases, ["waiting", "sending"])
                XCTAssertEqual(last, 100_000)
                let received = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/ls-group/Ali/\(file.lastPathComponent)"))
                XCTAssertEqual(received?.count, 100_000)
            }
            if let ali {
                // a text: LocalSend shows it at once (204)
                let result = try? await client.send(to: ali, files: [], text: "a text") { _ in }
                XCTAssertEqual(result, SendResult(count: 1, skipped: 0))
                XCTAssertEqual(try? String(contentsOfFile: "/tmp/ls-group/Ali/message-preview.txt", encoding: .utf8), "a text")
            }
            if let vali = await client.probe(ip: "127.0.0.13") {
                do {
                    _ = try await client.send(to: vali, files: [file]) { _ in }
                    XCTFail("Vali declines")
                } catch {
                    XCTAssertEqual(error as? SendError, SendError("Vali declined"))
                }
            } else {
                XCTFail("Vali not found")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }
}

final class ClipboardAndTrayTests: XCTestCase {
    func testHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = ClipboardHistory(store: JSONStore(name: "clipboard.json", directory: folder))
        history.limit = 2
        history.add(text: "one")
        history.add(text: "one")              // the same again: nothing new
        history.add(text: "two")
        history.setSaved(history.items[1], true)   // "one" pinned
        history.add(text: "three")
        history.add(text: "four")             // only 2 unpinned stay
        XCTAssertEqual(history.items.compactMap(\.text), ["four", "three", "one"])
        history.add(text: "one")              // copied again: back to the top, still pinned
        XCTAssertEqual(history.items.first?.text, "one")
        XCTAssertTrue(history.items.first?.saved ?? false)
        history.add(files: [URL(fileURLWithPath: "/tmp/a.png")])
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("clipboard.json"))) as? [String: Any]
        let first = (raw?["items"] as? [[String: Any]])?.first
        XCTAssertTrue(first?["text"] is NSNull)                       // null, like Linux writes it
        XCTAssertEqual(first?["files"] as? [String], ["file:///tmp/a.png"])
        history.keepHistory = false
        let reread = ClipboardHistory(store: JSONStore(name: "clipboard.json", directory: folder))
        XCTAssertEqual(reread.items.compactMap(\.text), ["one"])       // only pinned items were written
        history.clear()
        XCTAssertEqual(history.items.count, 1)
    }

    func testTray() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-tray-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: a)
        let tray = TrayStore(store: JSONStore(name: "tray.json", directory: folder))
        tray.add([a, a, folder.appendingPathComponent("missing.txt")])
        XCTAssertEqual(tray.files, [a])
        XCTAssertEqual(TrayStore(store: JSONStore(name: "tray.json", directory: folder)).files, [a])
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(TrayStore(store: JSONStore(name: "tray.json", directory: folder)).files, [])
    }
}
