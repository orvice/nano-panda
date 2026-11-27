import Foundation
import XCTest
@testable import NanoPandaCore

final class SyncTests: XCTestCase {
    private var temporary: URL!
    private var engine: SyncEngine!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        engine = SyncEngine(
            store: RegistryStore(directory: temporary.appendingPathComponent("state")),
            home: temporary.appendingPathComponent("home"), environment: [:]
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    func testBackupRestoreAndDriftWithOriginalBytesAndPermissions() throws {
        var registry = Registry()
        registry.servers = [server("managed", tools: [.cursor])]
        try engine.store.save(registry, replacing: Registry())
        let original = #"{"mcpServers":{"unmanaged":{"command":"node"}},"theme":"system"}"#
        let url = try write(original, to: .cursor)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        let plan = engine.preview(registry)
        let preview = try change(.cursor, in: plan)
        XCTAssertEqual(preview.status, .pending)
        XCTAssertEqual(plan.changeCount, 1)
        XCTAssertTrue(preview.diff.contains("@@"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        registry = try engine.apply(plan)
        XCTAssertEqual(try change(.cursor, in: engine.preview(registry)).status, .synced)
        XCTAssertEqual(try AgentAdapter(.cursor).read(Data(contentsOf: url)).map(\.id).sorted(), ["managed", "unmanaged"])
        let backup = try XCTUnwrap(engine.backups().first)

        try (Data(contentsOf: url) + Data("\n".utf8)).write(to: url)
        XCTAssertEqual(try change(.cursor, in: engine.preview(registry)).status, .drift)
        let restore = try engine.previewRestore(backup)
        XCTAssertTrue(restore.diff.contains("-"))
        registry = try engine.restore(restore)
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try engine.backups().count, 2)
        XCTAssertEqual(try change(.cursor, in: engine.preview(registry)).status, .drift)
    }

    func testStalePreviewLeavesAllFilesAndBackupsAlone() throws {
        var registry = Registry()
        registry.servers = [server("managed", tools: [.cursor, .claudeCode])]
        try engine.store.save(registry, replacing: Registry())
        let cursor = try write("{}", to: .cursor)
        let claude = try write("{}", to: .claudeCode)
        let plan = engine.preview(registry)
        _ = try write(#"{"updated":true}"#, to: .cursor)

        XCTAssertThrowsError(try engine.apply(plan))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), "{}")
        XCTAssertEqual(try String(contentsOf: cursor, encoding: .utf8), #"{"updated":true}"#)
        XCTAssertTrue(try engine.backups().isEmpty)
    }

    func testSwitchOffRemovesPreviouslyManagedIDOnlyAndFullSyncListsRemovals() throws {
        var registry = Registry()
        registry.servers = [server("managed", tools: [.cursor]), server("shared", tools: [.codex])]
        try engine.store.save(registry, replacing: Registry())
        let original = #"{"mcpServers":{"unmanaged":{"command":"node"},"shared":{"command":"node"}}}"#
        let url = try write(original, to: .cursor)
        registry = try engine.apply(engine.preview(registry))
        let originalRegistry = registry
        registry.set(ToolAssignment(serverID: "managed", tool: .cursor), enabled: false)
        try engine.store.save(registry, replacing: originalRegistry)

        let safe = engine.preview(registry)
        XCTAssertEqual(try change(.cursor, in: safe).removedIDs, ["managed"])
        let full = engine.preview(registry, mode: .full)
        XCTAssertEqual(try change(.cursor, in: full).removedIDs, ["managed", "shared", "unmanaged"])
        registry = try engine.apply(safe)
        XCTAssertEqual(try AgentAdapter(.cursor).read(Data(contentsOf: url)).map(\.id).sorted(), ["shared", "unmanaged"])
        XCTAssertThrowsError(try engine.apply(full))
        let updatedFull = engine.preview(registry, mode: .full)
        XCTAssertEqual(try change(.cursor, in: updatedFull).removedIDs, ["shared", "unmanaged"])
        _ = try engine.apply(updatedFull)
        XCTAssertTrue(try AgentAdapter(.cursor).read(Data(contentsOf: url)).isEmpty)
    }

    func testFirstWriteBackupCanRestoreFileAbsenceAndRejectStaleRestore() throws {
        var registry = Registry()
        registry.servers = [server("initial", tools: [.cursor])]
        try engine.store.save(registry, replacing: Registry())
        registry = try engine.apply(engine.preview(registry))
        let snap = try XCTUnwrap(engine.backups().first)
        XCTAssertFalse(snap.existed)

        let stale = try engine.previewRestore(snap)
        let file = try write(#"{"external":true}"#, to: .cursor)
        XCTAssertThrowsError(try engine.restore(stale))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        _ = try engine.restore(engine.previewRestore(snap))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try engine.backups().count, 2)
    }

    func testDiscoveryMergesIdenticalEntriesAndRequiresChoicesForConflicts() throws {
        _ = try write(#"{"mcpServers":{"shared":{"command":"node"},"collision":{"command":"a"}}}"#, to: .cursor)
        _ = try write(#"{"mcpServers":{"shared":{"command":"node"},"collision":{"command":"b"}}}"#, to: .claudeCode)
        _ = try write(#"{"mcpServers":{"invalid":{"x":true},"valid":{"command":"ok"}}}"#, to: .geminiCLI)
        let empty = Registry()
        let discovery = engine.discover(empty)
        XCTAssertEqual(discovery.groups.map(\.id), ["collision", "shared", "valid"])
        XCTAssertEqual(discovery.groups.filter(\.isConflict).map(\.id), ["collision"])
        XCTAssertEqual(discovery.issues[.geminiCLI]?.count, 1)
        XCTAssertThrowsError(try discovery.importing([:], into: empty))

        let merged = try discovery.importing(["collision": .source(.cursor)], into: empty)
        XCTAssertEqual(merged.servers.first { $0.id == "shared" }?.enabledTools, [.claudeCode, .cursor])
        XCTAssertEqual(merged.servers.first { $0.id == "collision" }?.transport, .stdio(command: "a", args: [], env: [:]))
        XCTAssertEqual(merged.receipts[.cursor]?.managedIDs, ["shared", "collision"])

        let split = try discovery.importing(["collision": .separate], into: empty)
        XCTAssertEqual(split.servers.first { $0.id == "collision-cursor" }?.enabledTools, [.cursor])
        XCTAssertEqual(try change(.cursor, in: engine.preview(split)).removedIDs, ["collision"])
        _ = try write("{}", to: .cursor)
        XCTAssertThrowsError(try discovery.importing(["collision": .skip], into: empty))
    }

    func testExistingConfigWithoutAssignmentsIsUnmanaged() throws {
        _ = try write(#"{"mcpServers":{"external":{"command":"node"}}}"#, to: .cursor)
        let registry = Registry()

        let managed = engine.preview(registry)
        XCTAssertEqual(try change(.cursor, in: managed).status.rawValue, "未托管")
        XCTAssertEqual(managed.changeCount, 0)
        XCTAssertFalse(managed.canApply)

        let full = try change(.cursor, in: engine.preview(registry, mode: .full))
        XCTAssertEqual(full.status, .pending)
        XCTAssertEqual(full.removedIDs, ["external"])
    }

    func testMatchingExistingConfigurationCanBeAdoptedWithoutFileChanges() throws {
        _ = try write(#"{"mcpServers":{"managed":{"command":"node"}}}"#, to: .cursor)
        var registry = Registry()
        registry.servers = [server("managed", tools: [.cursor])]
        try engine.store.save(registry, replacing: Registry())

        let preview = engine.preview(registry)
        XCTAssertEqual(preview.changeCount, 0)
        XCTAssertTrue(preview.canApply)
        registry = try engine.apply(preview)
        XCTAssertFalse(engine.preview(registry).canApply)
        XCTAssertEqual(registry.receipts[.cursor]?.managedIDs, ["managed"])
        XCTAssertTrue(try engine.backups().isEmpty)
    }

    func testMatrixPreviewKeepsAssignmentsStagedUntilConfirmedAndChecksSavedRegistry() throws {
        var saved = Registry()
        saved.servers = [server("managed", tools: [])]
        try engine.store.save(saved, replacing: Registry())
        let config = try write("{}", to: .cursor)
        var draft = saved
        draft.set(ToolAssignment(serverID: "managed", tool: .cursor), enabled: true)

        let preview = engine.preview(draft, replacing: saved)
        XCTAssertTrue(preview.canApply)
        let change = try change(.cursor, in: preview)
        XCTAssertEqual(change.changedIDs, ["managed"])
        XCTAssertTrue(change.configuredIDs.isEmpty)
        XCTAssertEqual(try engine.store.load(), saved)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{}")

        var edited = saved
        edited.servers[0].notes = "changed concurrently"
        try engine.store.save(edited, replacing: saved)
        XCTAssertThrowsError(try engine.apply(preview))
        XCTAssertTrue(try engine.backups().isEmpty)

        draft.servers[0].notes = edited.servers[0].notes
        let applied = try engine.apply(engine.preview(draft, replacing: edited))
        XCTAssertEqual(applied.servers[0].enabledTools, [.cursor])
        XCTAssertEqual(try engine.store.load(), applied)
        XCTAssertEqual(try engine.backups().first?.trigger, .sync)
        XCTAssertEqual(try AgentAdapter(.cursor).read(Data(contentsOf: config)).map(\.id), ["managed"])
    }

    func testPathCollisionsAndCustomPaths() throws {
        var registry = Registry()
        registry.customPaths[.cursor] = "~/custom.json"
        registry.customPaths[.claudeCode] = "~/custom.json"
        let plan = engine.preview(registry)
        XCTAssertEqual(try change(.cursor, in: plan).status, .unavailable)
        XCTAssertEqual(try change(.claudeCode, in: plan).status, .unavailable)
        XCTAssertEqual(plan.changeCount, 0)
        registry.customPaths.removeValue(forKey: .claudeCode)
        registry.servers = [server("custom", tools: [.cursor])]
        try engine.store.save(registry, replacing: Registry())
        _ = try engine.apply(engine.preview(registry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.home.appendingPathComponent("custom.json").path))
    }

    func testJointWriteRollsBackEarlierFileWhenLaterTargetCannotBeCreated() throws {
        let claude = try write("{}", to: .claudeCode)
        let readOnly = engine.home.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        var registry = Registry()
        registry.customPaths[.cursor] = readOnly.path + "/config.json"
        registry.servers = [server("test", tools: [.cursor, .claudeCode])]
        try engine.store.save(registry, replacing: Registry())

        let plan = engine.preview(registry)
        XCTAssertTrue(try change(.cursor, in: plan).hasChanges)
        XCTAssertThrowsError(try engine.apply(plan))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), "{}")
        XCTAssertEqual(try engine.store.load(), registry)
        XCTAssertEqual(try engine.backups().count, 2)
    }

    func testUnifiedDiffProducesMultipleHunksAndShowsMissingNewline() {
        let old = (1...30).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "2\n", with: "changed\n", range: old.startIndex..<old.index(old.startIndex, offsetBy: 4)) + "\n"
        let diff = UnifiedDiff.make(before: old, after: new, path: "test.json", existed: true)
        XCTAssertTrue(diff.contains("-2\n+changed"))
        XCTAssertTrue(diff.contains("\\ No newline at end of file"))
        XCTAssertEqual(diff.components(separatedBy: "\n@@ ").count - 1, 2)
    }

    private func server(_ id: String, tools: Set<ToolID>) -> MCPServer {
        MCPServer(id: id, transport: .stdio(command: "node", args: [], env: [:]), enabledTools: tools)
    }

    @discardableResult
    private func write(_ contents: String, to tool: ToolID) throws -> URL {
        let url = engine.path(for: tool, in: Registry())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func change(_ tool: ToolID, in plan: SyncPlan) throws -> ToolChange {
        try XCTUnwrap(plan.tools.first { $0.tool == tool })
    }
}
