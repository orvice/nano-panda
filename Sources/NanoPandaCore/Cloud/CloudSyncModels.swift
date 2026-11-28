import Foundation

public enum CloudSyncMode: Equatable, Sendable {
    case merge
    case forceLocal
    case forceRemote
}

public enum CloudConflictChoice: Equatable, Sendable {
    case local
    case remote
}

public struct CloudConflict: Identifiable, Sendable {
    public let id: String
    public let base: MCPServer?
    public let local: MCPServer?
    public let remote: MCPServer?
}

public struct CloudConflictPreview: Sendable {
    public let conflicts: [CloudConflict]
    let configurationID: UUID
    let localServers: [MCPServer]
    let remoteRevision: UUID?
    let remoteDigest: Data?

    public func resolve(choices: [String: CloudConflictChoice]) throws -> CloudConflictResolution {
        guard Set(choices.keys) == Set(conflicts.map(\.id)) else {
            throw PandaError.invalid("请为每一项云端同步冲突选择要保留的配置。")
        }
        return CloudConflictResolution(preview: self, choices: choices)
    }
}

public struct CloudConflictResolution: Sendable {
    let preview: CloudConflictPreview
    let choices: [String: CloudConflictChoice]
}

public struct CloudSyncSummary: Codable, Equatable, Sendable {
    public let date: Date
    public let added: Int
    public let modified: Int
    public let deleted: Int
    public let uploaded: Bool
}

public enum CloudSyncResult: Sendable {
    case synced(CloudSyncSummary)
    case conflicts(CloudConflictPreview)
}

public struct CloudSnapshotSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let note: String?
    public let sourceDevice: String
    public let serverCount: Int
}

public enum CloudSnapshotChangeKind: Equatable, Sendable {
    case added
    case modified
    case deleted
    case unchanged
}

public struct CloudSnapshotChange: Identifiable, Sendable {
    public let id: String
    public let current: MCPServer?
    public let target: MCPServer?
    public let kind: CloudSnapshotChangeKind
}

public struct CloudSnapshotPreview: Sendable {
    public let snapshot: CloudSnapshotSummary
    public let changes: [CloudSnapshotChange]
    let configurationID: UUID
    let localServers: [MCPServer]
    let remoteDigest: Data
    let remoteETag: String?
}

struct CloudTombstone: Codable, Equatable, Sendable {
    let date: Date
    let revision: UUID
}

struct CloudSyncPayload: Codable, Equatable, Sendable {
    let version: Int
    let revision: UUID
    let servers: [MCPServer]
    let tombstones: [String: CloudTombstone]

    init(revision: UUID, servers: [MCPServer], tombstones: [String: CloudTombstone]) {
        version = 1
        self.revision = revision
        self.servers = servers
        self.tombstones = tombstones
    }

    func validate() throws {
        guard version == 1 else { throw PandaError.invalid("此云端同步数据版本不受支持。") }
        try validateCloudServers(servers)
        guard Set(servers.map(\.id)).isDisjoint(with: tombstones.keys),
              tombstones.keys.allSatisfy(isCloudServerID) else {
            throw PandaError.invalid("云端同步数据含有无效的删除墓碑。")
        }
    }
}

struct CloudSnapshotPayload: Codable, Sendable {
    let version: Int
    let date: Date
    let note: String?
    let sourceDevice: String
    let id: String
    let servers: [MCPServer]

    init(id: String, note: String?, sourceDevice: String, servers: [MCPServer]) {
        self.version = 1
        self.id = id
        self.date = Date()
        self.note = note
        self.sourceDevice = sourceDevice
        self.servers = servers
    }

    var summary: CloudSnapshotSummary {
        CloudSnapshotSummary(id: id, date: date, note: note, sourceDevice: sourceDevice, serverCount: servers.count)
    }

    func validate(id: String) throws {
        guard version == 1, self.id == id else {
            throw PandaError.invalid("远端版本快照的版本或标识无效。")
        }
        try validateCloudServers(servers)
    }
}

func validateCloudServers(_ servers: [MCPServer]) throws {
    guard Set(servers.map(\.id)).count == servers.count else {
        throw PandaError.invalid("云端数据含有重复的 MCP 名称。")
    }
    for server in servers { try server.validate() }
}

private func isCloudServerID(_ id: String) -> Bool {
    !id.isEmpty && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
        && id.rangeOfCharacter(from: .controlCharacters) == nil
}

extension MCPServer {
    func hasSameCloudConfiguration(as other: MCPServer) -> Bool {
        id == other.id && transport == other.transport && enabledTools == other.enabledTools
            && notes == other.notes && tags == other.tags && perToolOverrides == other.perToolOverrides
    }
}

func cloudSnapshotChanges(from current: [MCPServer], to target: [MCPServer]) -> [CloudSnapshotChange] {
    let old = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    let new = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
    return Set(old.keys).union(new.keys).sorted().map { id in
        let kind: CloudSnapshotChangeKind
        switch (old[id], new[id]) {
        case let (before?, after?): kind = before.hasSameCloudConfiguration(as: after) ? .unchanged : .modified
        case (nil, _): kind = .added
        case (_, nil): kind = .deleted
        }
        return CloudSnapshotChange(id: id, current: old[id], target: new[id], kind: kind)
    }
}
