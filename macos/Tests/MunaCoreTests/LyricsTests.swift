import Foundation
import XCTest
@testable import MunaCore

final class LyricsTests: XCTestCase {
    func testParseLikeLinux() {
        let lines = LyricsClient.parseLrc("[ar:Someone]\n[00:12.50] First line\n[01:02.00][00:05.00] Twice\nno stamp\n[00:12.50]")
        XCTAssertEqual(lines, [LyricLine(t: 5000, text: "Twice"), LyricLine(t: 12500, text: "First line"),
                               LyricLine(t: 12500, text: ""), LyricLine(t: 62000, text: "Twice")])
        let result = LyricsResult(lines: lines)
        XCTAssertNil(result.line(at: 4.9))
        XCTAssertEqual(result.line(at: 13)?.text, "")
        XCTAssertEqual(result.line(at: 100)?.text, "Twice")
        XCTAssertEqual(LyricsClient.parseLrc(nil), [])
    }

    /// Against a small stand-in for lrclib.net (python), then from the cache with the service gone.
    func testLookupAndCache() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { throw XCTSkip("needs python3") }
        let script = """
        import http.server, json, urllib.parse
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
                if u.path == '/api/get' and q.get('track_name') == ['Song']:
                    body = json.dumps({'syncedLyrics': '[00:01.00] one\\n[00:02.00] two', 'plainLyrics': 'one\\ntwo'}).encode()
                    self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
                elif u.path == '/api/search':
                    body = b'[]'; self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(body)
                else:
                    self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
        http.server.HTTPServer(('127.0.0.1', 18999), H).serve_forever()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        try process.run()
        Thread.sleep(forTimeInterval: 0.8)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("muna-lyrics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = LyricsClient(base: "http://127.0.0.1:18999", cache: cache)
        let done = expectation(description: "lyrics")
        Task {
            let found = await client.lookup(artist: "A", title: "Song", album: "", length: 180)
            XCTAssertEqual(found?.lines?.map(\.text), ["one", "two"])
            XCTAssertEqual(found?.plain, "one\ntwo")
            let none = await client.lookup(artist: "A", title: "Unknown", album: "", length: 10)
            XCTAssertEqual(none, LyricsResult())
            process.terminate()
            process.waitUntilExit()
            // the service is gone: a new client finds the answer in the cache
            let again = await LyricsClient(base: "http://127.0.0.1:18999", cache: cache)
                .lookup(artist: "A", title: "Song", album: "", length: 180)
            XCTAssertEqual(again?.lines?.count, 2)
            let offline = await LyricsClient(base: "http://127.0.0.1:18999", cache: cache)
                .lookup(artist: "B", title: "Other", album: "", length: 1)
            XCTAssertNil(offline)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }
}
