import Foundation

/// LocalSend as Muna speaks it (shared/protocols/localsend.md).
public enum LocalSend {
    public static let port = 53317
    public static let apiPath = "/api/localsend/v2"
    public static let multicastAddress = "224.0.0.167"
    public static let protocolVersion = "2.0"
    /// Every Muna says this model; that is how Munas know each other.
    public static let munaModel = "Muna"
    public static let maxIncomingFiles = 500
    public static let askTimeout: TimeInterval = 60
}

/// What a device says about itself (/info, /register, announcements).
public struct DeviceInfo: Codable, Equatable {
    public var alias: String
    public var version: String?
    public var deviceModel: String?
    public var deviceType: String?
    public var fingerprint: String?
    public var port: Int?
    public var `protocol`: String?
    public var download: Bool?
    public var announce: Bool?

    public init(alias: String, fingerprint: String, protocol: String = "https", announce: Bool? = nil) {
        self.alias = alias
        version = LocalSend.protocolVersion
        deviceModel = LocalSend.munaModel
        deviceType = "desktop"
        self.fingerprint = fingerprint
        port = LocalSend.port
        self.protocol = `protocol`
        download = false
        self.announce = announce
    }
}

/// A device found on the network.
public struct Device: Codable, Hashable, Identifiable, Sendable {
    public var ip: String
    public var port: Int
    public var `protocol`: String
    public var alias: String
    public var deviceModel: String
    public var deviceType: String
    public var fingerprint: String

    public init(ip: String, port: Int = LocalSend.port, protocol: String = "https", alias: String,
                deviceModel: String = "", deviceType: String = "desktop", fingerprint: String = "") {
        self.ip = ip
        self.port = port
        self.protocol = `protocol`
        self.alias = alias
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
    }

    /// The device at `ip` that answered /info with `info`; nil when the answer is not LocalSend's.
    public init?(ip: String, port: Int, protocol: String, info: DeviceInfo) {
        guard !info.alias.isEmpty || info.version != nil else { return nil }
        self.init(ip: ip, port: port, protocol: `protocol`, alias: info.alias, deviceModel: info.deviceModel ?? "",
                  deviceType: info.deviceType ?? "desktop", fingerprint: info.fingerprint ?? "")
    }

    /// Tells devices apart: by the fingerprint (it survives a new address), else by where they are.
    public var key: String { fingerprint.isEmpty ? "\(ip):\(port)" : fingerprint }

    /// Another Muna (on any platform).
    public var isMuna: Bool { deviceModel == LocalSend.munaModel }

    public var id: String { key }

    /// Whether this is that saved group member: same fingerprint, else same name.
    public func isMember(_ member: GroupMember) -> Bool {
        (!member.fingerprint.isEmpty && fingerprint == member.fingerprint) ||
            (!member.alias.isEmpty && alias == member.alias)
    }

    public var asMember: GroupMember {
        GroupMember(fingerprint: fingerprint, alias: alias, deviceModel: deviceModel, deviceType: deviceType)
    }
}

/// Other Munas first, then by name (the order of the device row).
public func sortDevices(_ devices: [Device]) -> [Device] {
    devices.sorted { a, b in
        if a.isMuna != b.isMuna { return a.isMuna }
        return a.alias.localizedStandardCompare(b.alias) == .orderedAscending
    }
}

/// The body of POST /prepare-upload.
public struct PrepareUpload: Codable {
    public struct File: Codable, Equatable {
        public var id: String
        public var fileName: String
        public var size: Int64
        public var fileType: String

        public init(id: String, fileName: String, size: Int64, fileType: String) {
            self.id = id
            self.fileName = fileName
            self.size = size
            self.fileType = fileType
        }
    }

    public var info: DeviceInfo
    public var files: [String: File]

    public init(info: DeviceInfo, files: [String: File]) {
        self.info = info
        self.files = files
    }
}

/// The answer to an accepted POST /prepare-upload.
public struct PrepareUploadAnswer: Codable, Equatable {
    public var sessionId: String
    public var files: [String: String]

    public init(sessionId: String, files: [String: String]) {
        self.sessionId = sessionId
        self.files = files
    }
}

public enum ReceivedFileNames {
    /// A file name that cannot leave the folder: no path parts, no control characters, no leading dots.
    public static func safe(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 }))
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "file" }
        guard cleaned.hasPrefix(".") else { return cleaned }
        return "_" + cleaned.drop(while: { $0 == "." })
    }

    /// A name in the folder that is not taken: "a.pdf", "a (1).pdf", "a (2).pdf" ...
    public static func free(in folder: URL, name: String, exists: (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }) -> URL {
        let dot = name.lastIndex(of: ".")
        let (stem, ext): (String, String)
        if let dot, dot > name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            stem = name
            ext = ""
        }
        for index in 0..<1000 {
            let candidate = folder.appendingPathComponent(index == 0 ? name : "\(stem) (\(index))\(ext)")
            if !exists(candidate) { return candidate }
        }
        return folder.appendingPathComponent(UUID().uuidString + ext)
    }
}
