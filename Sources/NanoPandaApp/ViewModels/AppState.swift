import Foundation
import NanoPandaCore
import Observation

enum Destination: Hashable {
    case overview, server(String), matrix, tools
}

enum ActiveSheet: String, Identifiable {
    case new, paste, scan, sync, path, restore, inspect
    var id: Self { self }
}

@MainActor @Observable
final class AppState {
    let engine = SyncEngine()
    private(set) var registry = Registry()
    private(set) var plan: SyncPlan
    private(set) var snapshots: [BackupSnapshot] = []
    private(set) var canEdit = false
    var destination: Destination? = .overview
    var sheet: ActiveSheet?
    var discovery: DiscoveryResult?
    var restorePlan: RestorePlan?
    var editingTool: ToolID = .claudeCode
    var failure: String?
    var backupIssue: String?
    var matrixEdits: [ToolAssignment: Bool] = [:]
    var search = ""
    var searchRequest = 0
    var previewRegistry: Registry?

    init() {
        plan = engine.preview(Registry())
        do {
            registry = try engine.store.load()
            canEdit = true
            refresh()
            if let first = servers.first { destination = .server(first.id) }
        } catch {
            failure = "无法读取中央配置库。\n" + error.localizedDescription
        }
    }

    var servers: [MCPServer] { registry.servers.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending } }

    func refresh() {
        guard canEdit else { return }
        plan = engine.preview(registry)
        do {
            snapshots = try engine.backups()
            backupIssue = nil
        } catch {
            backupIssue = error.localizedDescription
        }
    }

    func newServer() { if canEdit { sheet = .new } }
    func paste() { if canEdit { sheet = .paste } }

    func scan() {
        guard canEdit else { return }
        discovery = engine.discover(registry)
        sheet = .scan
    }

    func focusSearch() {
        if destination == .matrix || destination == .tools { destination = .overview }
        searchRequest += 1
    }

    func inspect(_ tool: ToolID) {
        editingTool = tool
        refresh()
        sheet = .inspect
    }

    var pendingTools: [ToolID] {
        let planned = Set(plan.tools.filter { $0.hasChanges || $0.status == .drift || $0.status == .pending }.map(\.tool))
        let affected = planned.union(matrixEdits.keys.map(\.tool))
        return ToolID.workspaceOrder.filter(affected.contains)
    }

    func preview() {
        guard canEdit else { return }
        refresh()
        if matrixEdits.isEmpty {
            previewRegistry = nil
        } else {
            var draft = registry
            for (assignment, enabled) in matrixEdits { draft.set(assignment, enabled: enabled) }
            previewRegistry = draft
        }
        sheet = .sync
    }

    func preview(_ mode: SyncMode) -> SyncPlan {
        if let draft = previewRegistry {
            return engine.preview(draft, mode: mode, replacing: registry)
        }
        return mode == .managed ? plan : engine.preview(registry, mode: mode)
    }

    func enabled(_ server: MCPServer, in tool: ToolID) -> Bool {
        matrixEdits[ToolAssignment(serverID: server.id, tool: tool)] ?? server.enabledTools.contains(tool)
    }

    func stage(_ server: MCPServer, in tool: ToolID, enabled: Bool) {
        let assignment = ToolAssignment(serverID: server.id, tool: tool)
        matrixEdits[assignment] = enabled == server.enabledTools.contains(tool) ? nil : enabled
    }

    func hasPendingChanges(_ server: MCPServer) -> Bool {
        matrixEdits.keys.contains { $0.serverID == server.id } ||
            plan.tools.contains { $0.changedIDs.contains(server.id) || ($0.status == .drift && $0.configuredIDs.contains(server.id)) }
    }

    func apply(_ preview: SyncPlan) throws {
        registry = try engine.apply(preview)
        if previewRegistry != nil { matrixEdits.removeAll() }
        previewRegistry = nil
        sheet = nil
        refresh()
    }

    func restore(_ preview: RestorePlan) throws {
        registry = try engine.restore(preview)
        sheet = nil
        refresh()
    }

    func startRestore(_ snapshot: BackupSnapshot) {
        perform {
            restorePlan = try engine.previewRestore(snapshot)
            sheet = .restore
        }
    }

    func choosePath(_ tool: ToolID) {
        editingTool = tool
        sheet = .path
    }

    func savePath(_ input: String, for tool: ToolID) throws {
        var updated = registry
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            updated.customPaths.removeValue(forKey: tool)
        } else {
            guard path.hasPrefix("/") || path.hasPrefix("~/") else {
                throw PandaError.invalid("请输入绝对路径或以 ~/ 开头的路径。")
            }
            updated.customPaths[tool] = path
        }
        try save(updated)
        sheet = nil
    }

    func saveServer(_ server: MCPServer, replacing original: String?) throws {
        var updated = registry
        if server.id != original && updated.servers.contains(where: { $0.id == server.id }) {
            throw PandaError.invalid("中央配置库已存在「\(server.id)」。")
        }
        if let original, let index = updated.servers.firstIndex(where: { $0.id == original }) {
            updated.servers[index] = server
        } else {
            updated.servers.append(server)
        }
        try save(updated)
        sheet = nil
        destination = .server(server.id)
    }

    func savePasted(_ entries: [MCPServer], replacingExisting: Bool) throws {
        var updated = registry
        for var entry in entries {
            if let index = updated.servers.firstIndex(where: { $0.id == entry.id }) {
                guard replacingExisting else {
                    throw PandaError.invalid("中央配置库已存在「\(entry.id)」，请确认是否替换其传输配置。")
                }
                entry.enabledTools = updated.servers[index].enabledTools
                entry.tags = updated.servers[index].tags
                entry.notes = updated.servers[index].notes
                entry.perToolOverrides = updated.servers[index].perToolOverrides.merging(entry.perToolOverrides) { _, latest in latest }
                updated.servers[index] = entry
            } else {
                entry.enabledTools = []
                updated.servers.append(entry)
            }
        }
        try save(updated)
        sheet = nil
        if let first = entries.first { destination = .server(first.id) }
    }

    func importDiscovery(_ discovery: DiscoveryResult, choices: [String: ImportChoice]) throws {
        try save(discovery.importing(choices, into: registry))
        sheet = nil
    }

    func delete(_ id: String) {
        perform {
            var updated = registry
            updated.servers.removeAll { $0.id == id }
            try save(updated)
            destination = .overview
        }
    }

    private func save(_ updated: Registry) throws {
        guard canEdit else { throw PandaError.invalid("中央配置库无法编辑。") }
        try engine.store.save(updated, replacing: registry)
        registry = updated
        matrixEdits = matrixEdits.filter { assignment, enabled in
            updated.servers.contains { $0.id == assignment.serverID && $0.enabledTools.contains(assignment.tool) != enabled }
        }
        refresh()
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { failure = error.localizedDescription }
    }
}
