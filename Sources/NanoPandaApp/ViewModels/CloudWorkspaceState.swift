import Foundation
import NanoPandaCore
import Observation

@MainActor @Observable
final class CloudWorkspaceState {
    enum Operation: Equatable {
        case loading, testing, configuring, syncing, snapshots, restoring
    }

    enum ConnectionFeedback: Equatable {
        case passed(milliseconds: Int)
        case failed(String)
    }

    let engine: CloudSyncEngine
    private(set) var configuration: CloudConfiguration?
    private(set) var operation: Operation?
    private(set) var summary: CloudSyncSummary?
    private(set) var localChangesPending = false
    private(set) var conflict: CloudConflictPreview?
    private(set) var conflictVersion = 0
    private(set) var connectionFeedback: ConnectionFeedback?
    private(set) var snapshots: [CloudSnapshotSummary] = []
    private(set) var loadedSnapshots = false
    private(set) var restorePreview: CloudSnapshotPreview?
    private(set) var syncError: String?
    private(set) var configurationError: String?
    private(set) var snapshotError: String?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var autoPending = false
    @ObservationIgnored private var snapshotListPending = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored var reloadRegistry: (() throws -> Void)?
    @ObservationIgnored var presentConflicts: (() -> Void)?

    init(store: RegistryStore) {
        engine = CloudSyncEngine(store: store)
    }

    var isWorking: Bool { operation != nil }
    var isSyncing: Bool { operation == .syncing || operation == .restoring }

    var status: String {
        if isSyncing { return "同步中" }
        if conflict != nil { return "待解决冲突" }
        if syncError != nil { return "同步失败" }
        if configurationError != nil && configuration == nil { return "配置不可用" }
        if configuration == nil { return "未配置" }
        return summary == nil || localChangesPending ? "待同步" : "已同步"
    }

    var canSync: Bool { configuration != nil && !isWorking }

    func start() async {
        guard !loaded, begin(.loading) else { return }
        defer { finish() }
        do {
            configuration = try await engine.configuration()
            loaded = true
            try await reloadStatus()
            configurationError = nil
            scheduleAutomaticSync()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func loadSnapshotsIfNeeded() {
        guard configuration != nil, !loadedSnapshots, snapshotError == nil else { return }
        if isWorking {
            snapshotListPending = true
        } else {
            Task { await refreshSnapshots() }
        }
    }

    func clearConnectionFeedback() { connectionFeedback = nil }

    func testConnection(_ draft: CloudConfiguration) async {
        guard begin(.testing) else { return }
        defer { finish() }
        connectionFeedback = nil
        let startedAt = ContinuousClock.now
        do {
            try await engine.testConnection(draft)
            let elapsed = startedAt.duration(to: .now).components
            connectionFeedback = .passed(milliseconds: Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))
        } catch {
            connectionFeedback = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func saveConfiguration(_ draft: CloudConfiguration, reloadSnapshots: Bool = true) async -> Bool {
        guard begin(.configuring) else { return false }
        defer { finish() }
        configurationError = nil
        let previous = configuration
        do {
            try await engine.saveConfiguration(draft)
            configuration = draft
            loaded = true
            try await reloadStatus()
            if previous?.target != draft.target || previous?.encryption != draft.encryption {
                conflict = nil
                restorePreview = nil
                syncError = nil
                snapshots = []
                loadedSnapshots = false
                snapshotError = nil
                if reloadSnapshots { await loadSnapshots() }
            }
            if draft.automaticSync {
                scheduleAutomaticSync()
            } else {
                autoTask?.cancel()
                autoPending = false
            }
            return true
        } catch {
            configurationError = error.localizedDescription
            return false
        }
    }

    func setAutomaticSync(_ enabled: Bool) async {
        guard var draft = configuration, draft.automaticSync != enabled else { return }
        draft.automaticSync = enabled
        await saveConfiguration(draft, reloadSnapshots: false)
    }

    func disconnect() async {
        guard begin(.configuring) else { return }
        defer { finish() }
        configurationError = nil
        do {
            try await engine.disconnect()
            configuration = nil
            summary = nil
            localChangesPending = false
            conflict = nil
            restorePreview = nil
            syncError = nil
            connectionFeedback = nil
            snapshots = []
            loadedSnapshots = false
            snapshotError = nil
            autoTask?.cancel()
            autoPending = false
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func synchronize(mode: CloudSyncMode = .merge, resolution: CloudConflictResolution? = nil) async {
        guard configuration != nil, begin(.syncing) else { return }
        defer { finish() }
        autoTask?.cancel()
        autoPending = false
        syncError = nil
        do {
            let result = try await engine.synchronize(mode: mode, resolution: resolution)
            try await accept(result)
        } catch {
            if case PandaError.stale = error { conflict = nil }
            syncError = reloadAfterError(error)
        }
    }

    func refreshSnapshots() async {
        guard configuration != nil, begin(.snapshots) else { return }
        defer { finish() }
        await loadSnapshots()
    }

    func createSnapshot(note: String?) async -> Bool {
        guard configuration != nil, begin(.snapshots) else { return false }
        defer { finish() }
        snapshotError = nil
        do {
            let sourceDevice = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let snapshot = try await engine.createSnapshot(note: note, sourceDevice: sourceDevice)
            snapshots.insert(snapshot, at: 0)
            await loadSnapshots()
            return true
        } catch {
            snapshotError = error.localizedDescription
            return false
        }
    }

    func deleteSnapshot(_ id: String) async {
        guard configuration != nil, begin(.snapshots) else { return }
        defer { finish() }
        snapshotError = nil
        do {
            try await engine.deleteSnapshot(id)
            snapshots.removeAll { $0.id == id }
        } catch {
            snapshotError = error.localizedDescription
        }
    }

    func previewSnapshot(_ id: String) async -> Bool {
        guard configuration != nil, begin(.snapshots) else { return false }
        defer { finish() }
        snapshotError = nil
        restorePreview = nil
        do {
            restorePreview = try await engine.previewSnapshot(id)
            return true
        } catch {
            snapshotError = error.localizedDescription
            return false
        }
    }

    func restoreSnapshot(_ preview: CloudSnapshotPreview, selectedIDs: Set<String>?) async -> Bool {
        guard configuration != nil, begin(.restoring) else { return false }
        defer { finish() }
        snapshotError = nil
        syncError = nil
        do {
            let result = try await engine.restoreSnapshot(preview, selectedIDs: selectedIDs)
            try await accept(result)
            restorePreview = nil
            return true
        } catch {
            snapshotError = reloadAfterError(error)
            localChangesPending = (try? await engine.hasUnsyncedRegistryChanges()) ?? localChangesPending
            return false
        }
    }

    func registryDidChange() {
        localChangesPending = true
        scheduleAutomaticSync()
    }

    func scheduleAutomaticSync() {
        guard configuration?.automaticSync == true, conflict == nil else { return }
        autoPending = true
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) }
            catch { return }
            guard let self else { return }
            autoTask = nil
            guard autoPending, canSync, conflict == nil else { return }
            autoPending = false
            await synchronize()
        }
    }

    private func loadSnapshots() async {
        snapshotError = nil
        do {
            snapshots = try await engine.listSnapshots()
            loadedSnapshots = true
        } catch {
            snapshotError = error.localizedDescription
        }
    }

    private func reloadStatus() async throws {
        let lastSummary = try await engine.lastSyncSummary()
        localChangesPending = try await engine.hasUnsyncedRegistryChanges()
        summary = lastSummary
    }

    private func accept(_ result: CloudSyncResult) async throws {
        switch result {
        case let .synced(value):
            summary = value
            conflict = nil
            localChangesPending = try await engine.hasUnsyncedRegistryChanges()
            try reloadRegistry?()
        case let .conflicts(value):
            conflict = value
            conflictVersion += 1
            autoPending = false
            try reloadRegistry?()
            presentConflicts?()
        }
    }

    private func reloadAfterError(_ error: Error) -> String {
        do { try reloadRegistry?() }
        catch let reloadError { return error.localizedDescription + "\n" + reloadError.localizedDescription }
        return error.localizedDescription
    }

    private func begin(_ next: Operation) -> Bool {
        guard operation == nil else { return false }
        operation = next
        return true
    }

    private func finish() {
        operation = nil
        if snapshotListPending {
            snapshotListPending = false
            loadSnapshotsIfNeeded()
        }
        if autoPending && autoTask == nil { scheduleAutomaticSync() }
    }
}
