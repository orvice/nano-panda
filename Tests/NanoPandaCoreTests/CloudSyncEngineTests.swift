import Foundation
import XCTest
@testable import NanoPandaCore

final class CloudSyncEngineTests: XCTestCase {
    func testTwoDevicesPreserveLocalToolStateAndPropagateRename() async throws {
        let fixture = try Fixture()
        let first = fixture.first
        let second = fixture.second
        let original = server("original")
        try first.save(registry([original]), replacing: Registry())
        let agentFile = fixture.directory.appendingPathComponent("agent.toml")
        let agentBytes = Data("# user's local Agent configuration".utf8)
        try agentBytes.write(to: agentFile)
        var secondRegistry = Registry()
        secondRegistry.customPaths[.codex] = agentFile.path
        secondRegistry.receipts[.codex] = SyncReceipt(path: agentFile.path, digest: "local", managedIDs: ["external"])
        try second.save(secondRegistry, replacing: Registry())

        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()
        XCTAssertEqual(try second.load().servers, [original])

        var renamed = original
        renamed.id = "renamed"
        try first.save(registry([renamed]), replacing: registry([original]))
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()
        XCTAssertEqual(try second.load().servers, [renamed])
        XCTAssertEqual(try second.load().customPaths, secondRegistry.customPaths)
        XCTAssertEqual(try second.load().receipts, secondRegistry.receipts)
        XCTAssertEqual(try Data(contentsOf: agentFile), agentBytes)
    }

    func testFirstBindingRequiresAChoiceForChangedAndPreviouslyDeletedNames() async throws {
        let fixture = try Fixture()
        let shared = server("shared")
        let deleted = server("deleted")
        try fixture.first.save(registry([shared, deleted]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        try fixture.first.save(registry([shared]), replacing: registry([shared, deleted]))
        _ = try await firstEngine.synchronize()

        let local = server("shared", notes: "offline local edit")
        let unrelated = server("additional")
        try fixture.second.save(registry([local, deleted, unrelated]), replacing: Registry())
        let result = try await secondEngine.synchronize()
        guard case let .conflicts(preview) = result else { return XCTFail("Expected conflicts") }
        XCTAssertEqual(preview.conflicts.map(\.id), ["deleted", "shared"])
        XCTAssertNil(preview.conflicts.first?.remote)
        XCTAssertThrowsError(try preview.resolve(choices: ["deleted": .remote]))
        XCTAssertEqual(try fixture.second.load(), registry([local, deleted, unrelated]))

        let resolution = try preview.resolve(choices: ["deleted": .remote, "shared": .local])
        _ = try await secondEngine.synchronize(resolution: resolution)
        _ = try await firstEngine.synchronize()
        XCTAssertEqual(Set(try fixture.first.load().servers.map(\.id)), ["shared", "additional"])
        XCTAssertEqual(try fixture.first.load().servers.first, local)
    }

    func testConcurrentEditAndDeleteAreBoundToTheReviewedRemoteRevision() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        try fixture.first.save(Registry(), replacing: registry([original]))
        let local = server("shared", notes: "device two")
        try fixture.second.save(registry([local]), replacing: registry([original]))
        _ = try await firstEngine.synchronize()
        let result = try await secondEngine.synchronize()
        guard case let .conflicts(preview) = result else { return XCTFail("Expected edit/delete conflict") }
        XCTAssertEqual(preview.conflicts.first?.base, original)
        XCTAssertEqual(preview.conflicts.first?.local, local)
        XCTAssertNil(preview.conflicts.first?.remote)
        let obsolete = try preview.resolve(choices: ["shared": .remote])

        let newer = server("shared", notes: "newer remote revision")
        try fixture.first.save(registry([newer]), replacing: Registry())
        _ = try await firstEngine.synchronize()
        let refreshed = try await secondEngine.synchronize(resolution: obsolete)
        guard case let .conflicts(latest) = refreshed else { return XCTFail("Expected refreshed conflict") }
        XCTAssertEqual(latest.conflicts.first?.remote, newer)
        XCTAssertEqual(try fixture.second.load().servers, [local])
        let resolution = try latest.resolve(choices: ["shared": .remote])
        _ = try await secondEngine.synchronize(resolution: resolution)
        XCTAssertEqual(try fixture.second.load().servers, [newer])
    }

    func testS3ConditionalRaceRereadsAndMergesDisjointChanges() async throws {
        let fixture = try Fixture(useS3: true)
        let firstOriginal = server("first")
        let secondOriginal = server("second")
        let original = registry([firstOriginal, secondOriginal])
        try fixture.first.save(original, replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        let firstEdit = server("first", notes: "first edit")
        let secondEdit = server("second", notes: "second edit")
        try fixture.first.save(registry([firstEdit, secondOriginal]), replacing: original)
        try fixture.second.save(registry([firstOriginal, secondEdit]), replacing: original)
        await fixture.service.interceptNextMainWrite {
            _ = try await secondEngine.synchronize()
        }
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        XCTAssertEqual(try fixture.first.load(), registry([firstEdit, secondEdit]))
        XCTAssertEqual(try fixture.second.load(), registry([firstEdit, secondEdit]))
    }

    func testWebDAVFallbackRereadsBeforeUnconditionalWrite() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        let firstAddition = server("local-addition")
        let remoteAddition = server("remote-addition")
        try fixture.first.save(registry([original, firstAddition]), replacing: registry([original]))
        try fixture.second.save(registry([original, remoteAddition]), replacing: registry([original]))
        await fixture.service.rejectNextConditionalWrite {
            _ = try await secondEngine.synchronize()
        }
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        let expected = Set([original.id, firstAddition.id, remoteAddition.id])
        XCTAssertEqual(Set(try fixture.first.load().servers.map(\.id)), expected)
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), expected)
    }

    func testWebDAVIgnoredConditionsUseFreshRemoteReadBeforeWriting() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()
        let firstAddition = server("local-addition")
        let secondAddition = server("remote-addition")
        try fixture.first.save(registry([original, firstAddition]), replacing: registry([original]))
        try fixture.second.save(registry([original, secondAddition]), replacing: registry([original]))
        await fixture.service.ignoreWriteConditionsAndInterceptRead {
            _ = try await secondEngine.synchronize()
        }
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        let expected = Set([original.id, firstAddition.id, secondAddition.id])
        XCTAssertEqual(Set(try fixture.first.load().servers.map(\.id)), expected)
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), expected)
    }

    func testInterruptedLocalCommitRecoversPulledAndNewLocalEntries() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()

        let firstEdit = server("shared", notes: "edited on first")
        let secondAddition = server("added on second")
        let late = server("late local edit")
        let beforeWrite = registry([firstEdit])
        let afterWrite = registry([firstEdit, late])
        try fixture.first.save(beforeWrite, replacing: registry([original]))
        try fixture.second.save(registry([original, secondAddition]), replacing: registry([original]))
        _ = try await secondEngine.synchronize()
        let firstDirectory = fixture.first.directory
        await fixture.service.interceptNextMainWrite {
            try RegistryStore(directory: firstDirectory).save(afterWrite, replacing: beforeWrite)
        }
        do {
            _ = try await firstEngine.synchronize()
            XCTFail("Expected local compare-and-replace to reject the concurrent edit")
        } catch PandaError.stale {
            XCTAssertEqual(try fixture.first.load(), afterWrite)
        }

        // Use a new engine to exercise recovery after an app restart.
        _ = try await fixture.engine(for: fixture.first).synchronize()
        _ = try await secondEngine.synchronize()
        let expected = Set([firstEdit.id, secondAddition.id, late.id])
        XCTAssertEqual(Set(try fixture.first.load().servers.map(\.id)), expected)
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), expected)
    }

    func testSnapshotLifecycleRestoresSelectedAndEntireRegistryWithoutWritingAgentFiles() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        let deletedLater = server("restored")
        let initial = registry([original, deletedLater])
        try fixture.first.save(initial, replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()
        let snapshot = try await firstEngine.createSnapshot(note: "migration credentials", sourceDevice: "Mac One")
        XCTAssertEqual(snapshot.serverCount, 2)
        let snapshotData = await fixture.service.snapshotBytes()
        XCTAssertFalse(String(decoding: try XCTUnwrap(snapshotData), as: UTF8.self).contains("migration credentials"))

        let updated = server("shared", notes: "current")
        let added = server("new")
        let agentFile = fixture.directory.appendingPathComponent("claude.json")
        let agentBytes = Data(#"{"unmanaged":true}"#.utf8)
        try agentBytes.write(to: agentFile)
        var current = registry([updated, added])
        current.customPaths[.claudeCode] = agentFile.path
        try fixture.first.save(current, replacing: initial)
        _ = try await firstEngine.synchronize()
        _ = try await secondEngine.synchronize()
        await fixture.service.removeMain()
        let available = try await firstEngine.listSnapshots()
        XCTAssertEqual(available, [snapshot])

        let preview = try await firstEngine.previewSnapshot(snapshot.id)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: preview.changes.map { ($0.id, $0.kind) }),
            ["shared": .modified, "restored": .added, "new": .deleted]
        )
        _ = try await firstEngine.restoreSnapshot(preview, selectedIDs: ["restored"])
        _ = try await secondEngine.synchronize()
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), ["shared", "restored", "new"])
        XCTAssertEqual(try fixture.first.load().servers.first, updated)

        let latestPreview = try await firstEngine.previewSnapshot(snapshot.id)
        _ = try await firstEngine.restoreSnapshot(latestPreview)
        _ = try await secondEngine.synchronize()
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), [original.id, deletedLater.id])
        XCTAssertTrue(try fixture.second.load().servers.contains(original))
        XCTAssertTrue(try fixture.second.load().servers.contains(deletedLater))
        XCTAssertEqual(try fixture.first.load().customPaths, current.customPaths)
        XCTAssertEqual(try Data(contentsOf: agentFile), agentBytes)

        let backupDirectory = fixture.first.directory.appendingPathComponent("cloud-registry-backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 2)
        for url in backups { XCTAssertEqual(try mode(at: url), 0o600) }
        let prior = try backups.map { try JSONDecoder().decode(Registry.self, from: Data(contentsOf: $0)) }
        XCTAssertTrue(prior.contains(current))

        try await firstEngine.deleteSnapshot(snapshot.id)
        let deleted = try await firstEngine.listSnapshots()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testSnapshotOperationsAreIsolatedByMainObjectKeyWithinOneDirectory() async throws {
        let fixture = try Fixture()
        let firstEngine = fixture.engine(for: fixture.first)
        let secondEngine = fixture.engine(for: fixture.second)
        guard case let .webDAV(target) = fixture.configuration.target else {
            return XCTFail("Expected WebDAV fixture")
        }
        var work = target
        work.objectKey = "profiles/work.json"
        var personal = target
        personal.objectKey = "profiles/personal.json"
        try await firstEngine.saveConfiguration(CloudConfiguration(
            target: .webDAV(work), encryption: fixture.configuration.encryption
        ))
        try await secondEngine.saveConfiguration(CloudConfiguration(
            target: .webDAV(personal), encryption: fixture.configuration.encryption
        ))
        let workSnapshot = try await firstEngine.createSnapshot(note: "Work", sourceDevice: "First device")
        let personalSnapshot = try await secondEngine.createSnapshot(note: "Personal", sourceDevice: "Second device")

        let workHistory = try await firstEngine.listSnapshots()
        XCTAssertEqual(workHistory.map(\.id), [workSnapshot.id])
        let personalHistory = try await secondEngine.listSnapshots()
        XCTAssertEqual(personalHistory.map(\.id), [personalSnapshot.id])
        do {
            _ = try await firstEngine.previewSnapshot(personalSnapshot.id)
            XCTFail("Expected the snapshot ID to be unavailable under a different main object key")
        } catch PandaError.stale {}

        try await firstEngine.deleteSnapshot(personalSnapshot.id)
        try await firstEngine.deleteSnapshot(workSnapshot.id)
        let remainingPersonalHistory = try await secondEngine.listSnapshots()
        XCTAssertEqual(remainingPersonalHistory.map(\.id), [personalSnapshot.id])
    }

    func testWholeSnapshotRestoreDeletesRemoteOnlyEntriesOnFirstBinding() async throws {
        let fixture = try Fixture()
        let recorded = server("recorded")
        let remoteOnly = server("remote-only")
        try fixture.first.save(registry([recorded]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        let snapshot = try await firstEngine.createSnapshot(note: nil, sourceDevice: "First device")
        try fixture.first.save(registry([recorded, remoteOnly]), replacing: registry([recorded]))
        _ = try await firstEngine.synchronize()

        let preview = try await secondEngine.previewSnapshot(snapshot.id)
        XCTAssertEqual(preview.remoteChanges.map(\.id), ["remote-only"])
        XCTAssertEqual(preview.remoteChanges.map(\.kind), [.deleted])
        await fixture.service.failMainRead(after: 1)
        do {
            _ = try await secondEngine.restoreSnapshot(preview)
            XCTFail("Expected the forward sync to be interrupted")
        } catch CloudRemoteError.http(503) {
            XCTAssertEqual(try fixture.second.load().servers, [recorded])
        }
        let localEdit = server("added-after-restore")
        let current = try fixture.second.load()
        try fixture.second.save(registry([recorded, localEdit]), replacing: current)
        _ = try await fixture.engine(for: fixture.second).synchronize()
        _ = try await firstEngine.synchronize()

        XCTAssertEqual(Set(try fixture.first.load().servers.map(\.id)), [recorded.id, localEdit.id])
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), [recorded.id, localEdit.id])
    }

    func testWholeSnapshotRestoreLeavesNewRemoteChangesForAnotherPreview() async throws {
        let fixture = try Fixture()
        let recorded = server("recorded")
        let remoteOnly = server("remote-only")
        let concurrent = server("concurrent")
        try fixture.first.save(registry([recorded]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        let snapshot = try await firstEngine.createSnapshot(note: nil, sourceDevice: "First device")
        let beforeRemoteEdit = try await secondEngine.previewSnapshot(snapshot.id)
        try fixture.first.save(registry([recorded, remoteOnly]), replacing: try fixture.first.load())
        _ = try await firstEngine.synchronize()

        do {
            _ = try await secondEngine.restoreSnapshot(beforeRemoteEdit)
            XCTFail("Expected the reviewed remote revision to be stale")
        } catch PandaError.stale {
            XCTAssertTrue(try fixture.second.load().servers.isEmpty)
        }

        let preview = try await secondEngine.previewSnapshot(snapshot.id)
        await fixture.service.interceptNextMainWrite {
            let current = try fixture.first.load()
            var edited = current
            edited.servers.append(concurrent)
            try fixture.first.save(edited, replacing: current)
            _ = try await firstEngine.synchronize()
        }
        do {
            _ = try await secondEngine.restoreSnapshot(preview)
            XCTFail("Expected conditional write retry to stop on the unreviewed remote revision")
        } catch PandaError.stale {
            XCTAssertEqual(try fixture.second.load().servers, [recorded])
        }

        let retriedEngine = fixture.engine(for: fixture.second)
        let updated = try await retriedEngine.previewSnapshot(snapshot.id)
        XCTAssertEqual(Set(updated.remoteChanges.map(\.id)), [remoteOnly.id, concurrent.id])
        XCTAssertTrue(updated.remoteChanges.allSatisfy { $0.kind == .deleted })
        _ = try await retriedEngine.restoreSnapshot(updated)
        _ = try await firstEngine.synchronize()
        XCTAssertEqual(try fixture.first.load().servers, [recorded])
    }

    func testSnapshotRestoreAuthenticatesCurrentRemoteBeforeMutatingLocalRegistry() async throws {
        let fixture = try Fixture()
        let recorded = server("recorded")
        try fixture.first.save(registry([recorded]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        let snapshot = try await firstEngine.createSnapshot(note: nil, sourceDevice: "First device")
        let preview = try await secondEngine.previewSnapshot(snapshot.id)
        await fixture.service.damageMain()

        do {
            _ = try await secondEngine.restoreSnapshot(preview)
            XCTFail("Expected restore to reject corrupted remote data")
        } catch PandaError.invalid {
            XCTAssertEqual(try fixture.second.load(), Registry())
        }
    }

    func testSnapshotRestoreRequiresDurableStateBeforeReplacingRegistry() async throws {
        let fixture = try Fixture()
        let recorded = server("recorded")
        try fixture.first.save(registry([recorded]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        let snapshot = try await firstEngine.createSnapshot(note: nil, sourceDevice: "First device")
        let preview = try await secondEngine.previewSnapshot(snapshot.id)
        let stateFile = fixture.second.directory.appendingPathComponent("cloud-baseline.json")
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)

        do {
            _ = try await secondEngine.restoreSnapshot(preview)
            XCTFail("Expected restore to fail with unavailable cloud state")
        } catch PandaError.invalid {
            XCTAssertEqual(try fixture.second.load(), Registry())
        }
    }

    func testUncommittedSnapshotRestoreDoesNotDeleteRemoteEntries() async throws {
        let fixture = try Fixture()
        let recorded = server("recorded")
        let remoteOnly = server("remote-only")
        try fixture.first.save(registry([recorded, remoteOnly]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        try fixture.first.save(registry([recorded]), replacing: try fixture.first.load())
        let snapshot = try await firstEngine.createSnapshot(note: nil, sourceDevice: "First device")
        let preview = try await secondEngine.previewSnapshot(snapshot.id)
        let backup = fixture.second.directory.appendingPathComponent("cloud-registry-backups")
        try Data().write(to: backup)

        do {
            _ = try await secondEngine.restoreSnapshot(preview)
            XCTFail("Expected restore to fail while creating its backup")
        } catch {
            XCTAssertEqual(try fixture.second.load().servers, [])
        }
        try FileManager.default.removeItem(at: backup)
        let reopened = fixture.engine(for: fixture.second)
        _ = try await reopened.synchronize()
        XCTAssertEqual(Set(try fixture.second.load().servers.map(\.id)), [recorded.id, remoteOnly.id])
    }

    func testForceLocalCanReplaceOversizedRemoteObjectUsingItsETag() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        await fixture.service.oversizeMain()
        do {
            _ = try await firstEngine.synchronize()
            XCTFail("Expected the oversized object to be rejected")
        } catch CloudRemoteError.objectTooLarge {
            XCTAssertEqual(try fixture.first.load().servers, [original])
        }
        _ = try await firstEngine.synchronize(mode: .forceLocal)
        _ = try await secondEngine.synchronize()
        XCTAssertEqual(try fixture.second.load().servers, [original])
    }

    func testForceLocalReplacesDamagedDataAndForceRemoteMakesBackup() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        await fixture.service.damageMain()
        do {
            _ = try await firstEngine.synchronize()
            XCTFail("Expected the invalid envelope to be rejected")
        } catch {
            XCTAssertEqual(try fixture.first.load().servers, [original])
        }
        _ = try await firstEngine.synchronize(mode: .forceLocal)
        let obsolete = server("local-only")
        try fixture.second.save(registry([obsolete]), replacing: Registry())
        _ = try await secondEngine.synchronize(mode: .forceRemote)
        XCTAssertEqual(try fixture.second.load().servers, [original])
        let backupDirectory = fixture.second.directory.appendingPathComponent("cloud-registry-backups")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try JSONDecoder().decode(Registry.self, from: Data(contentsOf: backup)), registry([obsolete]))
    }

    func testDisconnectClearsOnlyPrivateCloudState() async throws {
        let fixture = try Fixture()
        let original = server("shared")
        try fixture.first.save(registry([original]), replacing: Registry())
        let (firstEngine, secondEngine) = try await fixture.connect()
        _ = try await firstEngine.synchronize()
        let config = fixture.first.directory.appendingPathComponent("cloud-configuration.json")
        let baseline = fixture.first.directory.appendingPathComponent("cloud-baseline.json")
        XCTAssertEqual(try mode(at: config), 0o600)
        XCTAssertEqual(try mode(at: baseline), 0o600)
        let restarted = fixture.engine(for: fixture.first)
        let lastSync = try await restarted.lastSyncSummary()
        XCTAssertNotNil(lastSync)
        try await restarted.disconnect()

        let connection = try await restarted.configuration()
        XCTAssertNil(connection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseline.path))
        XCTAssertEqual(try fixture.first.load().servers, [original])
        _ = try await secondEngine.synchronize()
        XCTAssertEqual(try fixture.second.load().servers, [original])
    }

    private func mode(at url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func server(_ name: String, notes: String? = "entry note") -> MCPServer {
        MCPServer(
            id: name, transport: .http(url: "https://example.invalid/mcp", headers: ["Authorization": "secret"], bearerTokenEnvVar: nil),
            enabledTools: [.codex], notes: notes, tags: ["open"], updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            perToolOverrides: [.codex: ServerOverride(fields: ["timeout": .integer(10)])]
        )
    }

    private func registry(_ servers: [MCPServer]) -> Registry {
        var store = Registry()
        store.servers = servers
        return store
    }
}

private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = CloudEngineTestService()
    let configuration: CloudConfiguration

    var first: RegistryStore { RegistryStore(directory: directory.appendingPathComponent("first")) }
    var second: RegistryStore { RegistryStore(directory: directory.appendingPathComponent("second")) }

    init(useS3: Bool = false) throws {
        let target: CloudTarget
        if useS3 {
            target = .s3(S3CloudTarget(
                endpoint: "https://s3.example.invalid", region: "us-east-1", bucket: "panda-bucket", objectKey: "registry.json",
                accessKeyID: "example-access-key", secretAccessKey: "example-secret"
            ))
        } else {
            target = .webDAV(WebDAVCloudTarget(
                endpoint: "https://dav.example.invalid", objectKey: "registry.json", username: "name", password: "credential"
            ))
        }
        configuration = CloudConfiguration(target: target, encryption: .key(Data(repeating: 7, count: 32).base64EncodedString()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func engine(for store: RegistryStore) -> CloudSyncEngine {
        CloudSyncEngine(store: store) { [service] request in try await service.execute(request) }
    }

    func connect() async throws -> (CloudSyncEngine, CloudSyncEngine) {
        let firstEngine = engine(for: first)
        let secondEngine = engine(for: second)
        try await firstEngine.saveConfiguration(configuration)
        try await secondEngine.saveConfiguration(configuration)
        return (firstEngine, secondEngine)
    }
}

private actor CloudEngineTestService {
    private struct StoredObject {
        let data: Data
        let etag: String
    }

    private var objects = [String: StoredObject]()
    private var version = 0
    private var writeHook: (@Sendable () async throws -> Void)?
    private var unsupportedHook: (@Sendable () async throws -> Void)?
    private var mainReadsBeforeFailure: Int?
    private var ignoresWriteConditions = false
    private var readHook: (@Sendable () async throws -> Void)?

    func interceptNextMainWrite(_ hook: @escaping @Sendable () async throws -> Void) { writeHook = hook }

    func rejectNextConditionalWrite(_ hook: @escaping @Sendable () async throws -> Void) { unsupportedHook = hook }

    func failMainRead(after count: Int) { mainReadsBeforeFailure = count }

    func ignoreWriteConditionsAndInterceptRead(_ hook: @escaping @Sendable () async throws -> Void) {
        ignoresWriteConditions = true
        readHook = hook
    }

    func snapshotBytes() -> Data? { objects.first { $0.key.contains("/snapshots/") }?.value.data }

    func removeMain() { objects.removeValue(forKey: "/registry.json") }

    func damageMain() { objects["/registry.json"] = StoredObject(data: Data("damaged".utf8), etag: "\"damaged\"") }

    func oversizeMain() {
        objects["/registry.json"] = StoredObject(data: Data(count: 32 * 1024 * 1024 + 1), etag: "\"oversized\"")
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let path = url.path
        func response(_ status: Int, data: Data = Data(), headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
            (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)))
        }
        switch request.httpMethod {
        case "GET":
            if path.hasSuffix("/registry.json"), let count = mainReadsBeforeFailure {
                if count == 0 {
                    mainReadsBeforeFailure = nil
                    return try response(503)
                }
                mainReadsBeforeFailure = count - 1
            }
            guard let object = objects[path] else { return try response(404) }
            if path.hasSuffix("/registry.json"), let hook = readHook {
                readHook = nil
                try await hook()
            }
            return try response(200, data: object.data, headers: ["ETag": object.etag])
        case "HEAD":
            guard let object = objects[path] else { return try response(404) }
            return try response(200, headers: ["ETag": object.etag, "Content-Length": String(object.data.count)])
        case "PUT":
            if path.hasSuffix("/registry.json"), let hook = writeHook {
                writeHook = nil
                try await hook()
            }
            if path.hasSuffix("/registry.json"), request.value(forHTTPHeaderField: "If-Match") != nil,
               let hook = unsupportedHook {
                unsupportedHook = nil
                try await hook()
                return try response(501)
            }
            if !ignoresWriteConditions, request.value(forHTTPHeaderField: "If-None-Match") == "*", objects[path] != nil {
                return try response(412)
            }
            if !ignoresWriteConditions, let match = request.value(forHTTPHeaderField: "If-Match"), match != objects[path]?.etag {
                return try response(412)
            }
            version += 1
            let etag = "\"version-\(version)\""
            objects[path] = StoredObject(data: try XCTUnwrap(request.httpBody), etag: etag)
            return try response(201, headers: ["ETag": etag])
        case "DELETE":
            return try response(objects.removeValue(forKey: path) == nil ? 404 : 204)
        case "MKCOL":
            return try response(201)
        case "PROPFIND":
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let entries = objects.filter { $0.key.hasPrefix(prefix) }.keys.sorted()
            let elements = entries.map { "<d:response><d:href>\($0)</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" }
            return try response(207, data: Data(("<d:multistatus xmlns:d=\"DAV:\">" + elements.joined() + "</d:multistatus>").utf8))
        default:
            return try response(405)
        }
    }
}
