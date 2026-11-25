import Foundation
import XCTest
@testable import MunaCore

final class PhoneTests: XCTestCase {
    func testDevices() {
        let output = """
        List of devices attached
        R58N12ABC       device usb:1-1 product:a52 model:SM_A525F device:a52 transport_id:3
        192.168.1.5:5555        unauthorized transport_id:4

        """
        let devices = PhoneADB.parseDevices(output)
        XCTAssertEqual(devices.map(\.serial), ["R58N12ABC", "192.168.1.5:5555"])
        XCTAssertEqual(devices.first?.model, "SM A525F")
        XCTAssertTrue(devices[0].ready)
        XCTAssertFalse(devices[1].ready)
        XCTAssertEqual(devices[1].model, "192.168.1.5:5555")
    }

    func testBattery() {
        let output = "Current Battery Service state:\n  AC powered: false\n  USB powered: true\n  level: 87\n  scale: 100\n"
        XCTAssertEqual(PhoneADB.parseBattery(output)?.percent, 87)
        XCTAssertEqual(PhoneADB.parseBattery(output)?.charging, true)
        XCTAssertNil(PhoneADB.parseBattery("nothing"))
    }

    func testInputTextLikeLinux() {
        // the same as linux/src/phone/phoneControl.js escapeInputText
        XCTAssertEqual(PhoneADB.escapeInputText("hello world"), "hello%sworld")
        XCTAssertEqual(PhoneADB.escapeInputText("a&b;c"), #"a\&b\;c"#)
        XCTAssertEqual(PhoneADB.escapeInputText(#"50% $x "q""#), #"50\%%s\$x%s\"q\""#)
    }
}
