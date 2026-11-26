import Foundation

/// An Android phone seen by adb.
public struct PhoneDevice: Equatable, Identifiable {
    public let serial: String
    /// "device", "unauthorized", "offline" …
    public let state: String
    public let model: String
    public var id: String { serial }
    public var ready: Bool { state == "device" }
}

/// Talking to an Android phone with adb, as Muna on Linux does without its helper
/// (linux/service/phone, linux/src/phone/phoneControl.js): the phones connected, the battery,
/// the screen (a picture), touches and keys with the phone's own `input` commands.
public enum PhoneADB {
    /// Where adb usually is on a Mac (Homebrew, Android Studio's SDK) and elsewhere.
    public static func findAdb() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let fromEnv = environment["MUNA_ADB"], !fromEnv.isEmpty { return fromEnv }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        let candidates = path + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(home)/Library/Android/sdk/platform-tools/adb",
                                 "/opt/android-sdk/platform-tools/adb", "/usr/lib/android-sdk/platform-tools/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The phones in `adb devices -l`.
    /// What `adb mdns services` prints → (name, "pairing" or "connect", address).
    public static func parseMdns(_ output: String) -> [(name: String, type: String, address: String)] {
        let pattern = try! NSRegularExpression(pattern: "^(\\S+)\\s+_adb-tls-(pairing|connect)\\._tcp\\.?\\s+(\\S+:\\d+)$")
        return output.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line), let c = Range(match.range(at: 3), in: line) else { return nil }
            return (String(line[a]), String(line[b]), String(line[c]))
        }
    }

    public static func parseDevices(_ output: String) -> [PhoneDevice] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let model = parts.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return PhoneDevice(serial: parts[0], state: parts[1], model: model ?? parts[0])
        }
    }

    /// The charge in `dumpsys battery` (percent), and whether it charges.
    public static func parseBattery(_ output: String) -> (percent: Int, charging: Bool)? {
        var level: Int?
        var scale = 100
        var charging = false
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "level": level = Int(parts[1])
            case "scale": scale = Int(parts[1]) ?? 100
            case "AC powered", "USB powered", "Wireless powered": if parts[1] == "true" { charging = true }
            default: break
            }
        }
        guard let level, scale > 0 else { return nil }
        return (level * 100 / scale, charging)
    }

    /// What `adb shell input text` needs: spaces as %s and the shell's special characters escaped.
    public static func escapeInputText(_ text: String) -> String {
        let plain = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._,@:/+=-")
        return text.map { ch -> String in
            if plain.contains(ch) { return String(ch) }
            return ch == " " ? "%s" : "\\\(ch)"
        }.joined()
    }

    // the phone's key codes
    public static let back = 4
    public static let home = 3
    public static let recents = 187
    public static let wake = 224
    public static let sleep = 223
    public static let power = 26
}
