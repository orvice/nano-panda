import Darwin
import Foundation

struct SavedCloudConfiguration: Codable {
    let id: UUID
    let value: CloudConfiguration
}

struct CloudPendingWrite: Codable {
    let payload: CloudSyncPayload
    let localServers: [MCPServer]
    var confirmed = false

    func replayLocalChanges(from current: [MCPServer]) -> [MCPServer] {
        let observed = Dictionary(uniqueKeysWithValues: localServers.map { ($0.id, $0) })
        let actual = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var entries = Dictionary(uniqueKeysWithValues: payload.servers.map { ($0.id, $0) })
        for id in Set(observed.keys).union(actual.keys) where observed[id] != actual[id] {
            entries[id] = actual[id]
        }
        return entries.values.sorted { $0.id < $1.id }
    }
}

enum CloudRestoreScope: Codable, Equatable {
    case all
    case selected(Set<String>)
}

struct CloudLocalState: Codable {
    let configurationID: UUID
    var baseline: CloudSyncPayload?
    var etag: String?
    var summary: CloudSyncSummary?
    var pending: CloudPendingWrite?
    var restoration: CloudRestoreScope?
}

extension RegistryStore {
    private var cloudConfigurationURL: URL { directory.appendingPathComponent("cloud-configuration.json") }
    private var cloudStateURL: URL { directory.appendingPathComponent("cloud-baseline.json") }

    func loadCloudConfiguration() throws -> SavedCloudConfiguration? {
        try LocalFile.read(cloudConfigurationURL).map { try JSONDecoder().decode(SavedCloudConfiguration.self, from: $0) }
    }

    func saveCloudConfiguration(_ value: CloudConfiguration) throws {
        try value.validate()
        let current = try loadCloudConfiguration()
        let sameDestination = current?.value.target.hasSameLocation(as: value.target) == true
            && current?.value.encryption == value.encryption
        let config = SavedCloudConfiguration(id: sameDestination ? current?.id ?? UUID() : UUID(), value: value)
        try LocalFile.write(try JSONEncoder().encode(config), to: cloudConfigurationURL, permissions: 0o600)
        if !sameDestination { try LocalFile.restore(nil, to: cloudStateURL) }
    }

    func disconnectCloud() throws {
        try LocalFile.restore(nil, to: cloudStateURL)
        try LocalFile.restore(nil, to: cloudConfigurationURL)
    }

    func cloudState(configurationID: UUID) throws -> CloudLocalState {
        if let data = try LocalFile.read(cloudStateURL) {
            let state = try JSONDecoder().decode(CloudLocalState.self, from: data)
            if state.configurationID == configurationID {
                try state.baseline?.validate()
                if let pending = state.pending {
                    try pending.payload.validate()
                    try validateCloudServers(pending.localServers)
                }
                return state
            }
        }
        return CloudLocalState(configurationID: configurationID)
    }

    func saveCloudState(_ state: CloudLocalState) throws {
        try LocalFile.write(try JSONEncoder().encode(state), to: cloudStateURL, permissions: 0o600)
    }

    func replaceCloudServers(_ entries: [MCPServer], replacing expected: Registry) throws {
        try locked {
            guard try load() == expected else {
                throw PandaError.stale("中央配置库在云端操作期间已变化，请重试。")
            }
            guard expected.servers != entries else { return }
            let backupDirectory = directory.appendingPathComponent("cloud-registry-backups", isDirectory: true)
            let backupURL = backupDirectory.appendingPathComponent(UUID().uuidString + ".json")
            let backup = try LocalFile.read(registryURL) ?? JSONEncoder().encode(expected)
            try LocalFile.write(backup, to: backupURL, permissions: 0o600)
            var updated = expected
            updated.servers = entries
            try write(updated)
        }
    }

    func withCloudOperation<Result>(_ operation: () throws -> Result) throws -> Result {
        let descriptor = try acquireCloudOperation()
        defer { close(descriptor) }
        return try operation()
    }

    func acquireCloudOperation() throws -> Int32 {
        try LocalFile.privateDirectory(directory)
        let path = directory.appendingPathComponent(".cloud-sync.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalFile.posixError(path) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = LocalFile.posixError(path)
            close(descriptor)
            if error.code == Int(EWOULDBLOCK) {
                throw PandaError.transaction("此设备已有云端操作正在运行。")
            }
            throw error
        }
        return descriptor
    }
}

private extension CloudTarget {
    func hasSameLocation(as other: Self) -> Bool {
        switch (self, other) {
        case let (.s3(a), .s3(b)):
            return a.endpoint == b.endpoint && a.bucket == b.bucket
                && a.objectKey == b.objectKey && a.pathStyle == b.pathStyle
        case let (.webDAV(a), .webDAV(b)):
            return a.endpoint == b.endpoint && a.objectKey == b.objectKey
                // Some WebDAV servers resolve the same path relative to the authenticated user.
                && a.username == b.username
        default:
            return false
        }
    }
}
