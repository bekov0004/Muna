import Foundation
import XCTest
@testable import MunaCore

final class DataFilesTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // --- files written by Muna on Linux are read as they are ---------------------------------------

    func testReadsLinuxNotes() throws {
        try write("notes.json", #"{"version":1,"notes":[{"id":3,"text":"Call the bank","at":1764060000000,"private":false},{"id":2,"text":"secret","at":1764050000000,"private":true}]}"#)
        let store = NotesStore(store: JSONStore(name: "notes.json", directory: folder))
        XCTAssertEqual(store.notes.map(\.text), ["Call the bank", "secret"])
        XCTAssertEqual(store.notes.map(\.isPrivate), [false, true])
        XCTAssertEqual(store.notes[0].at, 1_764_060_000_000)
    }

    func testBrokenEntriesAreSkippedAndIdsRepaired() throws {
        try write("notes.json", #"{"version":1,"notes":[{"id":5,"text":"a"},{"text":42},{"id":5,"text":"b"},{"text":"c"}]}"#)
        let store = NotesStore(store: JSONStore(name: "notes.json", directory: folder))
        XCTAssertEqual(store.notes.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(store.notes.map(\.id), [5, 6, 7])
    }

    func testMissingOrBrokenFileIsEmpty() throws {
        try write("todo.json", "{not json")
        XCTAssertTrue(TodoStore(store: JSONStore(name: "todo.json", directory: folder)).items.isEmpty)
        XCTAssertTrue(NotesStore(store: JSONStore(name: "nothing.json", directory: folder)).notes.isEmpty)
    }

    func testNotesAreSavedInTheSharedShape() throws {
        let store = NotesStore(store: JSONStore(name: "notes.json", directory: folder))
        XCTAssertFalse(try store.add("   "))
        XCTAssertTrue(try store.add("  first  "))
        XCTAssertTrue(try store.add(String(repeating: "x", count: 1500)))
        try store.setPrivate(id: 1, true)
        let file = try json("notes.json")
        XCTAssertEqual(file["version"] as? Int, 1)
        let notes = try XCTUnwrap(file["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual((notes[0]["text"] as? String)?.count, NotesStore.maxLength)   // newest first, cut
        XCTAssertEqual(notes[1]["text"] as? String, "first")
        XCTAssertEqual(notes[1]["private"] as? Bool, true)
        XCTAssertNotNil(notes[1]["at"] as? Int64)
        // only the user may read it
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("notes.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // and it reads back the same
        XCTAssertEqual(NotesStore(store: JSONStore(name: "notes.json", directory: folder)).notes, store.notes)
    }

    func testTodo() throws {
        let store = TodoStore(store: JSONStore(name: "todo.json", directory: folder))
        try store.add("one")
        try store.add("two")
        try store.toggle(id: 1)
        XCTAssertEqual(store.openCount, 1)
        XCTAssertTrue(store.hasDone)
        try store.clearDone()
        XCTAssertEqual(store.items.map(\.text), ["two"])
        let items = try XCTUnwrap(try json("todo.json")["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["done"] as? Bool, false)
        XCTAssertEqual(items.first?["id"] as? Int, 2)
    }
}

final class GroupsTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("muna-groups-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var anvar: Device { Device(ip: "10.0.0.2", alias: "Anvar", deviceModel: "Muna", fingerprint: "fp-anvar") }
    private var pixel: Device { Device(ip: "10.0.0.4", alias: "Pixel", deviceModel: "Pixel 8") }

    func testReadsLinuxGroups() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":1,"groups":[{"id":"gmwvtguh3md","name":"Office","members":[{"fingerprint":"fp-anvar","alias":"Anvar","deviceModel":"Muna","deviceType":"desktop"},{"fingerprint":"","alias":"Pixel","deviceModel":"Pixel 8","deviceType":"desktop"}]}]}"#.utf8)
            .write(to: folder.appendingPathComponent("localsend-groups.json"))
        let store = GroupsStore(store: JSONStore(name: "localsend-groups.json", directory: folder))
        XCTAssertEqual(store.groups.first?.name, "Office")
        let moved = Device(ip: "10.0.0.99", alias: "renamed", deviceModel: "Muna", fingerprint: "fp-anvar")
        let presence = try XCTUnwrap(store.groups.first).presence(in: [moved, pixel])
        XCTAssertEqual(presence.found.map(\.ip), ["10.0.0.99", "10.0.0.4"])   // by fingerprint, then by name
        XCTAssertTrue(presence.missing.isEmpty)
    }

    func testRulesLikeLinux() throws {
        let store = GroupsStore(store: JSONStore(name: "localsend-groups.json", directory: folder))
        XCTAssertThrowsError(try store.save(name: "  ", members: [anvar.asMember])) { XCTAssertEqual($0 as? GroupError, .noName) }
        XCTAssertThrowsError(try store.save(name: "Office", members: [])) { XCTAssertEqual($0 as? GroupError, .noMembers) }
        let first = try store.save(name: "Office", members: [anvar.asMember])
        try store.save(name: "Friends", members: [pixel.asMember])
        // the same name in another case replaces it, in its place
        let replaced = try store.save(name: "OFFICE", members: [anvar.asMember, pixel.asMember])
        XCTAssertEqual(store.groups.map(\.name), ["OFFICE", "Friends"])
        XCTAssertNotEqual(replaced.id, first.id)
        XCTAssertEqual(String(try store.save(name: String(repeating: "n", count: 99), members: [pixel.asMember]).name.count), "60")
        try store.delete(id: replaced.id)
        XCTAssertEqual(GroupsStore(store: JSONStore(name: "localsend-groups.json", directory: folder)).groups.map(\.name).first, "Friends")
    }

    func testMembership() {
        let member = GroupMember(fingerprint: "", alias: "Pixel")
        XCTAssertTrue(pixel.isMember(member))
        XCTAssertFalse(anvar.isMember(member))
        XCTAssertFalse(Device(ip: "1.1.1.1", alias: "x", fingerprint: "").isMember(GroupMember(fingerprint: "", alias: "")))
        XCTAssertEqual(sortDevices([pixel, anvar]).map(\.alias), ["Anvar", "Pixel"])   // Munas first
        XCTAssertEqual(pixel.key, "10.0.0.4:53317")
        XCTAssertEqual(anvar.key, "fp-anvar")
    }
}

final class LocalSendTests: XCTestCase {
    func testInfoIsWhatLinuxSends() throws {
        let data = try JSONEncoder().encode(DeviceInfo(alias: "mac", fingerprint: "abc"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["deviceModel"] as? String, "Muna")
        XCTAssertEqual(object["version"] as? String, "2.0")
        XCTAssertEqual(object["port"] as? Int, 53317)
        XCTAssertEqual(object["protocol"] as? String, "https")
        XCTAssertNil(object["announce"])
        // a LocalSend app's answer (no fingerprint, extra fields) still makes a device
        let answer = #"{"alias":"Test Pixel","version":"2.0","deviceModel":"Pixel 8","deviceType":"mobile","download":false,"extra":1}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(answer.utf8))
        let device = try XCTUnwrap(Device(ip: "10.0.0.5", port: 53317, protocol: "http", info: info))
        XCTAssertEqual(device.deviceType, "mobile")
        XCTAssertEqual(device.fingerprint, "")
        XCTAssertFalse(device.isMuna)
    }

    func testSafeNames() {
        XCTAssertEqual(ReceivedFileNames.safe("../../etc/passwd"), "passwd")
        XCTAssertEqual(ReceivedFileNames.safe("a\\b\\report.pdf"), "report.pdf")
        XCTAssertEqual(ReceivedFileNames.safe(".bashrc"), "_bashrc")
        XCTAssertEqual(ReceivedFileNames.safe(".."), "file")
        XCTAssertEqual(ReceivedFileNames.safe("bad\u{1}name.txt"), "badname.txt")
        XCTAssertEqual(ReceivedFileNames.safe(""), "file")
    }

    func testFreeNames() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.pdf", "/tmp/x/a (1).pdf"]
        XCTAssertEqual(ReceivedFileNames.free(in: folder, name: "a.pdf", exists: { taken.contains($0.path) }).lastPathComponent, "a (2).pdf")
        XCTAssertEqual(ReceivedFileNames.free(in: folder, name: "b.pdf", exists: { taken.contains($0.path) }).lastPathComponent, "b.pdf")
        XCTAssertEqual(ReceivedFileNames.free(in: folder, name: "noext", exists: { $0.lastPathComponent == "noext" }).lastPathComponent, "noext (1)")
    }
}

final class PanelLayoutTests: XCTestCase {
    private let linuxCells = ["media": 5, "calendar": 4, "mirror": 3, "timer": 3, "todo": 4, "notes": 4, "shortcuts": 4]

    func testSameWidthAsLinux() {
        // Linux's rig: media, calendar, mirror, timer open 740 wide on a 1920 px monitor
        let layout = PanelLayout(screenWidth: 1920, widgets: ["media", "calendar", "mirror", "timer"], cells: { self.linuxCells[$0] ?? 4 })
        XCTAssertEqual(layout.width, 740)
        XCTAssertEqual(layout.pages.count, 1)
        XCTAssertEqual(layout.pages[0].map(\.width), [220, 176, 132, 132])
    }

    func testPagesAndMinimum() {
        XCTAssertEqual(PanelLayout(screenWidth: 1920, widgets: ["timer"], cells: { self.linuxCells[$0] ?? 4 }).width, 560)
        // a narrow screen: what does not fit goes on the next page
        let all = ["media", "calendar", "mirror", "timer", "todo", "notes", "shortcuts"]
        let layout = PanelLayout(screenWidth: 1280, widgets: all, cells: { self.linuxCells[$0] ?? 4 })
        XCTAssertLessThanOrEqual(layout.width, 1280 * 0.72)
        XCTAssertGreaterThan(layout.pages.count, 1)
        XCTAssertEqual(layout.pages.flatMap { $0.map(\.id) }, all)
        // wide enough for the notch and its ears
        XCTAssertEqual(PanelLayout(screenWidth: 1920, widgets: ["timer"], cells: { _ in 3 }, atLeast: 600).width, 600)
    }
}
