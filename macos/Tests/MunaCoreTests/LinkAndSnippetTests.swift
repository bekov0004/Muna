import Foundation
import XCTest
@testable import MunaCore

final class LinkAndSnippetTests: XCTestCase {
    // Expected values are what linux/src/utils/cleanUrl.js gives (nil where it returns the text unchanged).
    func testLinkCleanerMatchesLinux() {
        let cases: [(String, String?)] = [
            ("https://example.com/page?utm_source=x&utm_medium=y&id=5#top", "https://example.com/page?id=5#top"),
            ("https://www.youtube.com/watch?v=abc&si=XyZ", "https://www.youtube.com/watch?v=abc"),
            ("https://open.spotify.com/track/1?si=abc", "https://open.spotify.com/track/1"),
            ("https://shop.com/?fbclid=1", "https://shop.com/"),
            ("HTTP://a.b/c?UTM_Campaign=1&q=2", nil),
            ("http://a.b/c?UTM_Campaign=1&q=2", "http://a.b/c?q=2"),
            ("  https://a.b/?gclid=1&&q=3  ", "https://a.b/?q=3"),
            ("https://a.b/?q=1", nil),
            ("https://a.b/", nil),
            ("hello ?utm_source=1", nil),
            ("https://a.b/?utm_=1&x", nil),
            ("https://a.b/?q=1&gclid", "https://a.b/?q=1"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(LinkCleaner.clean(input), expected, input)
        }
    }

    private func temporaryStore() -> JSONStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return JSONStore(name: "snippets.json", directory: directory)
    }

    func testSnippetsRoundTrip() throws {
        let store = temporaryStore()
        let snippets = SnippetsStore(store: store)
        XCTAssertEqual(snippets.snippets, [])
        try snippets.add(trigger: " ;mail ", text: "me@example.com")
        try snippets.add(trigger: ";sig", text: "Best, me")
        try snippets.add(trigger: ";mail", text: "other@example.com")
        XCTAssertEqual(snippets.snippets.map(\.trigger), [";mail", ";sig"])
        XCTAssertThrowsError(try snippets.add(trigger: " ", text: "x"))
        XCTAssertThrowsError(try snippets.add(trigger: ";x", text: ""))
        try snippets.update(trigger: ";sig", to: ";s", text: "Bye")
        XCTAssertEqual(SnippetsStore(store: store).snippets,
                       [Snippet(trigger: ";s", text: "Bye"), Snippet(trigger: ";mail", text: "other@example.com")])
        try snippets.remove(trigger: ";s")
        XCTAssertEqual(SnippetsStore(store: store).snippets.map(\.trigger), [";mail"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
    }

    func testSnippetsLenientLoad() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"snippets":[{"trigger":";a","text":"A"},{"trigger":5},null,{"trigger":";b","text":"B"}]}"#.utf8)
            .write(to: store.url)
        XCTAssertEqual(SnippetsStore(store: store).snippets.map(\.trigger), [";a", ";b"])
    }

    func testSnippetExpansion() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 5))!
        XCTAssertEqual(SnippetsStore.expand("{date} at {time} / {datetime}", now: now),
                       "2026-03-07 at 09:05 / 2026-03-07 09:05")
        XCTAssertEqual(SnippetsStore.expand("plain", now: now), "plain")
    }
}
