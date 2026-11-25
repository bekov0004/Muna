import Foundation

/// A member of a LocalSend group: who the device is, not where it is.
public struct GroupMember: Codable, Hashable {
    public var fingerprint: String
    public var alias: String
    public var deviceModel: String
    public var deviceType: String

    public init(fingerprint: String, alias: String, deviceModel: String = "", deviceType: String = "desktop") {
        self.fingerprint = String(fingerprint.prefix(128))
        self.alias = String(alias.prefix(100))
        self.deviceModel = String(deviceModel.prefix(50))
        self.deviceType = String(deviceType.prefix(20))
    }

    enum CodingKeys: String, CodingKey { case fingerprint, alias, deviceModel, deviceType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fingerprint: (try? c.decode(String.self, forKey: .fingerprint)) ?? "",
                  alias: (try? c.decode(String.self, forKey: .alias)) ?? "",
                  deviceModel: (try? c.decode(String.self, forKey: .deviceModel)) ?? "",
                  deviceType: (try? c.decode(String.self, forKey: .deviceType)) ?? "desktop")
    }
}

/// A named set of devices to send to at once (localsend-groups.json).
public struct DeviceGroup: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var members: [GroupMember]

    public init(id: String, name: String, members: [GroupMember]) {
        self.id = id
        self.name = name
        self.members = members
    }

    /// The group's members on the network now (as found devices), and the others.
    public func presence(in devices: [Device]) -> (found: [Device], missing: [GroupMember]) {
        var found: [Device] = []
        var missing: [GroupMember] = []
        for member in members {
            if let device = devices.first(where: { $0.isMember(member) }) {
                found.append(device)
            } else {
                missing.append(member)
            }
        }
        return (found, missing)
    }
}

public enum GroupError: Error, Equatable, CustomStringConvertible {
    case noName, noMembers, tooMany

    public var description: String {
        switch self {
        case .noName: return "A group needs a name"
        case .noMembers: return "A group needs at least one device"
        case .tooMany: return "At most \(GroupsStore.maxGroups) groups"
        }
    }
}

/// The saved groups, with the same rules as Muna on Linux (shared/formats/data-files.md).
public final class GroupsStore {
    public static let maxGroups = 50
    public static let maxMembers = 200
    public static let maxNameLength = 60

    public private(set) var groups: [DeviceGroup] = []
    private let store: JSONStore

    private struct File: Codable {
        var version = 1
        var groups: [DeviceGroup]
    }

    private struct LoadedFile: Decodable {
        var groups: LossyList<DeviceGroup>
    }

    public init(store: JSONStore = JSONStore(name: "localsend-groups.json")) {
        self.store = store
        load()
    }

    public func load() {
        groups = store.load(LoadedFile.self)?.groups.elements ?? []
    }

    /// Saves a group (a new one when `id` is nil); a group with the same name (any case) is replaced.
    @discardableResult
    public func save(id: String? = nil, name: String, members: [GroupMember]) throws -> DeviceGroup {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        guard !name.isEmpty else { throw GroupError.noName }
        let clean = members.prefix(Self.maxMembers).filter { !$0.fingerprint.isEmpty || !$0.alias.isEmpty }
        guard !clean.isEmpty else { throw GroupError.noMembers }
        let lowered = name.lowercased()
        let others = groups.filter { $0.id != id && $0.name.lowercased() != lowered }
        guard others.count < Self.maxGroups else { throw GroupError.tooMany }
        let group = DeviceGroup(id: id ?? Self.newId(), name: name, members: Array(clean))
        let at = groups.firstIndex { $0.id == id || $0.name.lowercased() == lowered }
        var result = others
        result.insert(group, at: min(at ?? others.count, others.count))
        groups = result
        try store.save(File(groups: groups))
        return group
    }

    public func delete(id: String) throws {
        let before = groups.count
        groups.removeAll { $0.id == id }
        if groups.count != before {
            try store.save(File(groups: groups))
        }
    }

    static func newId() -> String {
        let time = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let random = String(Int.random(in: 0..<1296), radix: 36)
        return "g\(time)\(random)"
    }
}
