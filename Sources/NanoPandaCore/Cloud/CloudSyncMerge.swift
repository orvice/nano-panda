import Foundation

enum CloudEntry {
    case missing
    case deleted(CloudTombstone?)
    case active(MCPServer)

    var server: MCPServer? {
        if case let .active(value) = self { return value }
        return nil
    }

    var tombstone: CloudTombstone? {
        if case let .deleted(value) = self { return value }
        return nil
    }

    func hasSameConfiguration(as other: Self) -> Bool {
        switch (self, other) {
        case let (.active(a), .active(b)): return a.hasSameCloudConfiguration(as: b)
        case (.deleted, .deleted), (.missing, .missing): return true
        default: return false
        }
    }
}

struct CloudSyncMerge {
    private struct Comparison {
        let id: String
        let base: CloudEntry
        let local: CloudEntry
        let remote: CloudEntry
        let explicitlyRestored: Bool

        var merged: CloudEntry? {
            if local.hasSameConfiguration(as: remote) { return remote }
            if !explicitlyRestored, local.hasSameConfiguration(as: base) { return remote }
            if remote.hasSameConfiguration(as: base) { return local }
            return nil
        }
    }

    private let comparisons: [Comparison]

    init(
        base: CloudSyncPayload?, local: [MCPServer], remote: CloudSyncPayload?,
        explicitlyRestored: Set<String>
    ) {
        let baseEntries = Self.entries(base)
        let localEntries = Dictionary(uniqueKeysWithValues: local.map { ($0.id, CloudEntry.active($0)) })
        let remoteEntries = remote.map(Self.entries) ?? baseEntries
        comparisons = Set(baseEntries.keys).union(localEntries.keys).union(remoteEntries.keys).sorted().map { id in
            let original = baseEntries[id] ?? .missing
            return Comparison(
                id: id, base: original,
                local: localEntries[id] ?? Self.deletion(from: original),
                // An omitted remote entry is not a deletion without a tombstone.
                remote: remoteEntries[id] ?? original,
                explicitlyRestored: explicitlyRestored.contains(id)
            )
        }
    }

    var conflicts: [CloudConflict] {
        comparisons.compactMap { entry in
            guard entry.merged == nil else { return nil }
            return CloudConflict(id: entry.id, base: entry.base.server, local: entry.local.server, remote: entry.remote.server)
        }
    }

    func result(mode: CloudSyncMode, choices: [String: CloudConflictChoice]) throws -> CloudSyncPayload {
        let revision = UUID()
        let deletedNow = CloudTombstone(date: Date(), revision: revision)
        var servers = [MCPServer]()
        var tombstones = [String: CloudTombstone]()
        for entry in comparisons {
            let selected: CloudEntry
            switch mode {
            case .forceLocal:
                // A forced overwrite must also publish deletion of remote-only entries.
                selected = entry.local.server == nil ? .deleted(nil) : entry.local
            case .forceRemote:
                selected = entry.remote
            case .merge:
                if let merged = entry.merged {
                    selected = merged
                } else {
                    guard let choice = choices[entry.id] else {
                        throw PandaError.invalid("请先解决所有云端同步冲突。")
                    }
                    selected = choice == .local ? entry.local : entry.remote
                }
            }
            switch selected {
            case let .active(server): servers.append(server)
            case .deleted:
                tombstones[entry.id] = entry.remote.tombstone ?? selected.tombstone ?? entry.base.tombstone ?? deletedNow
            case .missing: break
            }
        }
        return CloudSyncPayload(revision: revision, servers: servers, tombstones: tombstones)
    }

    private static func entries(_ payload: CloudSyncPayload?) -> [String: CloudEntry] {
        guard let payload else { return [:] }
        var entries = payload.tombstones.mapValues { CloudEntry.deleted($0) }
        for server in payload.servers { entries[server.id] = .active(server) }
        return entries
    }

    private static func deletion(from original: CloudEntry) -> CloudEntry {
        switch original {
        case .active: return .deleted(nil)
        case .missing, .deleted: return original
        }
    }
}
