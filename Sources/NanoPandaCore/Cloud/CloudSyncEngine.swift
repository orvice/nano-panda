import CryptoKit
import Darwin
import Foundation

public actor CloudSyncEngine {
    private struct Session {
        let configuration: SavedCloudConfiguration
        let remote: CloudRemote

        var target: CloudTarget { configuration.value.target }
        var encryption: CloudEncryption { configuration.value.encryption }
    }

    private enum MainObject: Equatable {
        case missing
        case content(CloudRemoteObject)
        case oversized(CloudRemoteMetadata)

        var object: CloudRemoteObject? {
            if case let .content(object) = self { return object }
            return nil
        }

        var etag: String? {
            switch self {
            case .missing: return nil
            case let .content(object): return object.etag
            case let .oversized(metadata): return metadata.etag
            }
        }
    }

    private let store: RegistryStore
    private let execute: CloudHTTPExecutor?

    public init(store: RegistryStore, execute: CloudHTTPExecutor? = nil) {
        self.store = store
        self.execute = execute
    }

    public func configuration() throws -> CloudConfiguration? { try store.loadCloudConfiguration()?.value }

    public func saveConfiguration(_ configuration: CloudConfiguration) throws {
        try store.withCloudOperation { try store.saveCloudConfiguration(configuration) }
    }

    public func lastSyncSummary() throws -> CloudSyncSummary? {
        guard let config = try store.loadCloudConfiguration() else { return nil }
        return try store.cloudState(configurationID: config.id).summary
    }

    public func hasUnsyncedRegistryChanges() throws -> Bool {
        guard let config = try store.loadCloudConfiguration() else { return false }
        let state = try store.cloudState(configurationID: config.id)
        if state.pending != nil || state.restoration != nil { return true }
        return try !store.load().servers.hasSameCloudConfigurations(as: state.baseline?.servers ?? [])
    }

    public func testConnection(_ configuration: CloudConfiguration) async throws {
        try await makeRemote(configuration.target).testConnection()
    }

    public func disconnect() throws {
        try store.withCloudOperation { try store.disconnectCloud() }
    }

    public func synchronize(
        mode: CloudSyncMode = .merge, resolution: CloudConflictResolution? = nil
    ) async throws -> CloudSyncResult {
        let lock = try store.acquireCloudOperation()
        defer { close(lock) }
        return try await synchronize(in: session(), mode: mode, resolution: resolution)
    }

    private func synchronize(
        in session: Session, mode: CloudSyncMode = .merge, resolution: CloudConflictResolution? = nil
    ) async throws -> CloudSyncResult {
        let key = session.target.objectKey
        var state = try store.cloudState(configurationID: session.configuration.id)
        var conditionalWriteSupported = true
        let mergeMode: CloudSyncMode = mode == .merge && state.restoration == .all ? .forceLocal : mode
        let restoredIDs: Set<String>
        if mode == .merge, case let .selected(ids) = state.restoration {
            restoredIDs = ids
        } else {
            restoredIDs = []
        }

        for _ in 0..<4 {
            try Task.checkCancellation()
            let registry = try store.load()
            let observed = try await readMain(in: session, replacingDamagedData: mode == .forceLocal)
            let remotePayload = try decodeSync(observed.object, in: session, replacingDamagedData: mode == .forceLocal)
            if mode == .forceRemote, remotePayload == nil {
                throw PandaError.invalid("远端尚无可用于覆盖本机的中央配置库。")
            }

            var baseline = state.baseline
            var localServers = registry.servers
            if let pending = state.pending,
               pending.payload == remotePayload || pending.confirmed {
                baseline = pending.payload
                if mergeMode == .merge { localServers = pending.replayLocalChanges(from: registry.servers) }
            }
            let merge = CloudSyncMerge(
                base: baseline, local: localServers, remote: remotePayload, explicitlyRestored: restoredIDs
            )
            let conflicts = mergeMode == .merge ? merge.conflicts : []
            let remoteDigest = observed.object.map { Data(SHA256.hash(data: $0.data)) }
            let preview = CloudConflictPreview(
                conflicts: conflicts, configurationID: session.configuration.id,
                localServers: registry.servers, remoteRevision: remotePayload?.revision,
                remoteDigest: remoteDigest
            )
            if let resolution {
                guard mergeMode == .merge, preview.matches(resolution.preview) else {
                    if !conflicts.isEmpty { return .conflicts(preview) }
                    throw PandaError.stale("云端同步内容在预览后已变化，请重新同步。")
                }
            } else if !conflicts.isEmpty {
                return .conflicts(preview)
            }

            let merged = try merge.result(mode: mergeMode, choices: resolution?.choices ?? [:])
            if let remotePayload,
               mode == .forceRemote || (merged.servers.hasSameCloudConfigurations(as: remotePayload.servers)
                   && merged.tombstones == remotePayload.tombstones) {
                return try finish(
                    registry: registry, payload: remotePayload, etag: observed.etag,
                    baseline: state.baseline, configurationID: session.configuration.id,
                    uploaded: state.pending?.payload == remotePayload
                )
            }

            let data = try CloudEnvelope.encode(merged, kind: .sync, encryption: session.encryption)
            // A second read narrows the race for providers that lack or ignore conditional writes.
            let beforeWrite: MainObject
            if case .oversized = observed {
                beforeWrite = try await session.remote.metadata(key).map(MainObject.oversized) ?? .missing
            } else {
                beforeWrite = try await readMain(in: session, replacingDamagedData: mode == .forceLocal)
            }
            guard observed == beforeWrite else { continue }
            let condition = try writeCondition(for: beforeWrite, supported: conditionalWriteSupported)

            if let pending = state.pending, pending.payload == remotePayload || pending.confirmed {
                // Commit the recovered revision before recording another candidate.
                try store.replaceCloudServers(localServers.ordered(like: registry.servers), replacing: registry)
                state.baseline = pending.payload
                state.etag = observed.etag
                state.pending = nil
                try store.saveCloudState(state)
                continue
            }

            state.pending = CloudPendingWrite(payload: merged, localServers: registry.servers)
            try store.saveCloudState(state)
            do {
                _ = try await session.remote.write(data, to: key, condition: condition)
            } catch CloudRemoteError.preconditionFailed {
                continue
            } catch CloudRemoteError.conditionalWriteUnsupported where conditionalWriteSupported && condition != .none {
                conditionalWriteSupported = false
                continue
            }
            let written = try await session.remote.read(key)
            guard written?.data == data else { continue }
            state.pending?.confirmed = true
            try store.saveCloudState(state)
            return try finish(
                registry: registry, payload: merged, etag: written?.etag,
                baseline: baseline, configurationID: session.configuration.id, uploaded: true
            )
        }
        throw PandaError.stale("远端数据持续发生变化，云端同步已暂停，请重试。")
    }

    public func createSnapshot(note: String?, sourceDevice: String) async throws -> CloudSnapshotSummary {
        let lock = try store.acquireCloudOperation()
        defer { close(lock) }
        let active = try session()
        let id = UUID().uuidString.lowercased()
        let snapshot = CloudSnapshotPayload(id: id, note: note, sourceDevice: sourceDevice, servers: try store.load().servers)
        let data = try CloudEnvelope.encode(snapshot, kind: .snapshot, encryption: active.encryption)
        let key = try snapshotKey(id: id, in: active)
        do {
            _ = try await active.remote.write(data, to: key, condition: .missing)
        } catch CloudRemoteError.conditionalWriteUnsupported {
            guard try await active.remote.read(key) == nil else {
                throw PandaError.stale("远端版本快照已存在，请重试。")
            }
            _ = try await active.remote.write(data, to: key, condition: .none)
        }
        return snapshot.summary
    }

    public func listSnapshots() async throws -> [CloudSnapshotSummary] {
        let lock = try store.acquireCloudOperation()
        defer { close(lock) }
        let active = try session()
        let prefix = active.target.snapshotPrefix
        let keys = try await active.remote.list(prefix: prefix)
        var summaries = [CloudSnapshotSummary]()
        for key in Set(keys) where key.hasPrefix(prefix) && key.hasSuffix(".json") {
            let id = String(key.dropFirst(prefix.count).dropLast(".json".count))
            guard let expectedKey = try? snapshotKey(id: id, in: active), key == expectedKey,
                  let object = try await active.remote.read(key) else { continue }
            let snapshot = try decodeSnapshot(object, id: id, in: active)
            summaries.append(snapshot.summary)
        }
        return summaries.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    public func deleteSnapshot(_ id: String) async throws {
        let lock = try store.acquireCloudOperation()
        defer { close(lock) }
        let active = try session()
        try await active.remote.delete(snapshotKey(id: id, in: active))
    }

    public func previewSnapshot(_ id: String) async throws -> CloudSnapshotPreview {
        let lock = try store.acquireCloudOperation()
        defer { close(lock) }
        let active = try session()
        let key = try snapshotKey(id: id, in: active)
        guard let object = try await active.remote.read(key) else {
            throw PandaError.stale("此远端版本快照已不存在。")
        }
        let snapshot = try decodeSnapshot(object, id: id, in: active)
        let current = try store.load().servers
        return CloudSnapshotPreview(
            snapshot: snapshot.summary, changes: cloudSnapshotChanges(from: current, to: snapshot.servers),
            configurationID: active.configuration.id, localServers: current,
            remoteDigest: Data(SHA256.hash(data: object.data)), remoteETag: object.etag
        )
    }

    public func restoreSnapshot(_ preview: CloudSnapshotPreview, selectedIDs: Set<String>? = nil) async throws -> CloudSyncResult {
        let lock = try store.acquireCloudOperation()
        defer { close(lock) }
        let active = try session()
        guard preview.configurationID == active.configuration.id else {
            throw PandaError.stale("远端目标在预览后已变化，请重新打开预览。")
        }
        let key = try snapshotKey(id: preview.snapshot.id, in: active)
        guard let object = try await active.remote.read(key),
              preview.remoteDigest == Data(SHA256.hash(data: object.data)), preview.remoteETag == object.etag else {
            throw PandaError.stale("远端版本快照在预览后已变化，请重新打开预览。")
        }
        let snapshot = try decodeSnapshot(object, id: preview.snapshot.id, in: active)
        let registry = try store.load()
        guard registry.servers == preview.localServers else {
            throw PandaError.stale("中央配置库在预览后已变化，请重新打开预览。")
        }
        let entries: [MCPServer]
        if let selectedIDs {
            guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: snapshot.servers.map(\.id)) else {
                throw PandaError.invalid("请选择要恢复的 MCP 条目。")
            }
            entries = registry.servers.filter { !selectedIDs.contains($0.id) }
                + snapshot.servers.filter { selectedIDs.contains($0.id) }
        } else {
            entries = snapshot.servers
        }
        try store.replaceCloudServers(entries.ordered(like: registry.servers), replacing: registry)
        var state = try store.cloudState(configurationID: active.configuration.id)
        state.restoration = selectedIDs.map(CloudRestoreScope.selected) ?? .all
        try store.saveCloudState(state)
        return try await synchronize(in: active)
    }

    private func session() throws -> Session {
        guard let configuration = try store.loadCloudConfiguration() else {
            throw PandaError.invalid("请先保存云端同步配置。")
        }
        return try Session(configuration: configuration, remote: makeRemote(configuration.value.target))
    }

    private func makeRemote(_ target: CloudTarget) throws -> CloudRemote {
        if let execute { return try CloudRemote(target: target, execute: execute) }
        return try CloudRemote(target: target)
    }

    private func readMain(in session: Session, replacingDamagedData: Bool) async throws -> MainObject {
        let key = session.target.objectKey
        do {
            return try await session.remote.read(key).map(MainObject.content) ?? .missing
        } catch CloudRemoteError.objectTooLarge where replacingDamagedData {
            return try await session.remote.metadata(key).map(MainObject.oversized) ?? .missing
        }
    }

    private func decodeSync(_ object: CloudRemoteObject?, in session: Session, replacingDamagedData: Bool) throws -> CloudSyncPayload? {
        guard let object else { return nil }
        do {
            let payload = try CloudEnvelope.decode(CloudSyncPayload.self, from: object.data, kind: .sync, encryption: session.encryption)
            try payload.validate()
            return payload
        } catch where replacingDamagedData {
            return nil
        }
    }

    private func decodeSnapshot(_ object: CloudRemoteObject, id: String, in session: Session) throws -> CloudSnapshotPayload {
        let snapshot = try CloudEnvelope.decode(CloudSnapshotPayload.self, from: object.data, kind: .snapshot, encryption: session.encryption)
        try snapshot.validate(id: id)
        return snapshot
    }

    private func snapshotKey(id: String, in session: Session) throws -> String {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw PandaError.invalid("远端版本快照标识无效。")
        }
        return session.target.snapshotPrefix + id + ".json"
    }

    private func finish(
        registry: Registry, payload: CloudSyncPayload, etag: String?, baseline: CloudSyncPayload?,
        configurationID: UUID, uploaded: Bool
    ) throws -> CloudSyncResult {
        let entries = payload.servers.ordered(like: registry.servers)
        try store.replaceCloudServers(entries, replacing: registry)
        let changes = cloudSnapshotChanges(from: baseline?.servers ?? [], to: payload.servers)
        let summary = CloudSyncSummary(
            date: Date(), added: changes.filter { $0.kind == .added }.count,
            modified: changes.filter { $0.kind == .modified }.count,
            deleted: changes.filter { $0.kind == .deleted }.count, uploaded: uploaded
        )
        try store.saveCloudState(CloudLocalState(configurationID: configurationID, baseline: payload, etag: etag, summary: summary))
        return .synced(summary)
    }

    private func writeCondition(for object: MainObject, supported: Bool) throws -> CloudWriteCondition {
        if supported {
            if object == .missing { return .missing }
            if let etag = object.etag, etag.isStrongCloudETag { return .matches(etag) }
        }
        if case .oversized = object {
            throw PandaError.invalid("覆盖超限的远端数据需要支持条件写入的远端服务。")
        }
        return .none
    }
}

private extension String {
    var isStrongCloudETag: Bool {
        let bytes = utf8
        guard bytes.count >= 2, bytes.first == 34, bytes.last == 34 else { return false }
        return bytes.dropFirst().dropLast().allSatisfy { $0 == 33 || (35...126).contains($0) }
    }
}

private extension CloudConflictPreview {
    func matches(_ previous: Self) -> Bool {
        configurationID == previous.configurationID && localServers == previous.localServers
            && remoteRevision == previous.remoteRevision && remoteDigest == previous.remoteDigest
            && conflicts.map(\.id) == previous.conflicts.map(\.id)
    }
}

private extension Array where Element == MCPServer {
    func hasSameCloudConfigurations(as others: [MCPServer]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
        return count == others.count && allSatisfy { server in
            byID[server.id].map(server.hasSameCloudConfiguration(as:)) == true
        }
    }

    func ordered(like existing: [MCPServer]) -> [MCPServer] {
        var entries = Dictionary(uniqueKeysWithValues: map { ($0.id, $0) })
        return existing.compactMap { entries.removeValue(forKey: $0.id) } + entries.values.sorted { $0.id < $1.id }
    }
}
