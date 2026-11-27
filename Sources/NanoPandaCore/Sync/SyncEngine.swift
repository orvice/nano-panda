import CryptoKit
import Foundation

public enum SyncMode: String, CaseIterable, Identifiable {
    case managed, full
    public var id: Self { self }
    public var title: String { self == .managed ? "仅同步托管条目" : "完全同步" }
}

public enum SyncStatus: String {
    case synced = "已同步"
    case pending = "待同步"
    case drift = "外部有修改"
    case missing = "未创建"
    case unavailable = "无法读取"
}

public struct ToolChange: Identifiable {
    public let tool: ToolID
    public let path: URL
    public let status: SyncStatus
    public let diff: String
    public let removedIDs: [String]
    public let configuredIDs: Set<String>
    public let changedIDs: Set<String>
    public let warnings: [String]
    public let error: String?
    public var id: ToolID { tool }
    public var hasChanges: Bool { error == nil && before != after }

    fileprivate let before: Data?
    fileprivate let after: Data?
    fileprivate let managedIDs: Set<String>

    fileprivate func receipt(for registry: Registry) -> SyncReceipt? {
        guard hasChanges || !managedIDs.isEmpty || registry.receipts[tool]?.path == path.path else { return nil }
        return SyncReceipt(path: path.path, digest: SyncEngine.digest(after), managedIDs: managedIDs)
    }
}

public struct SyncPlan {
    public let mode: SyncMode
    public let tools: [ToolChange]
    public var changeCount: Int { tools.filter(\.hasChanges).count }
    public var canApply: Bool {
        registry != expectedRegistry || tools.contains { change in
            guard change.error == nil else { return false }
            return change.hasChanges || change.receipt(for: registry).map { $0 != registry.receipts[change.tool] } == true
        }
    }
    fileprivate let registry: Registry
    fileprivate let expectedRegistry: Registry
}

public enum BackupTrigger: String, Codable {
    case sync, restore
}

public struct BackupSnapshot: Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let tool: ToolID
    public let originalPath: String
    public let existed: Bool
    public let trigger: BackupTrigger?
    fileprivate let batch: String
    fileprivate let digest: String?
    fileprivate let permissions: Int?
    fileprivate let managedIDs: Set<String>
}

public struct RestorePlan {
    public let snapshot: BackupSnapshot
    public let diff: String
    public var hasChanges: Bool { before != after }
    fileprivate let before: Data?
    fileprivate let after: Data?
}

public struct SyncEngine {
    public let store: RegistryStore
    public let home: URL
    private let environment: [String: String]

    public init(
        store: RegistryStore = RegistryStore(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.home = home
        self.environment = environment
    }

    public func path(for tool: ToolID, in registry: Registry) -> URL {
        if let override = registry.customPaths[tool], !override.isEmpty {
            let path = override.hasPrefix("~/") ? home.appendingPathComponent(String(override.dropFirst(2))).path : override
            return URL(fileURLWithPath: path, isDirectory: false, relativeTo: home).standardizedFileURL
        }
        if tool == .codex, let codexHome = environment["CODEX_HOME"], codexHome.hasPrefix("/") {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml")
        }
        if tool == .openCode, let override = environment["OPENCODE_CONFIG"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        if tool == .openCode {
            let configured = environment["XDG_CONFIG_HOME"]
            let config = configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? home.appendingPathComponent(".config")
            let json = config.appendingPathComponent("opencode/opencode.json")
            let alternative = config.appendingPathComponent("opencode/opencode.jsonc")
            if FileManager.default.fileExists(atPath: alternative.path) { return alternative }
            return json
        }
        return home.appendingPathComponent(tool.relativePath)
    }

    public func discover(_ registry: Registry) -> DiscoveryResult {
        var files: [ToolID: DiscoveryResult.DiscoveredFile] = [:]
        var sources: [ImportSource] = []
        var issues: [ToolID: [String]] = [:]
        for tool in ToolID.allCases {
            do {
                let url = try target(for: tool, in: registry)
                let data = try LocalFile.read(url)
                let inventory = try AgentAdapter(tool).inventory(data)
                files[tool] = .init(url: url, data: data)
                sources += inventory.servers.map { ImportSource(tool: tool, server: $0) }
                if !inventory.issues.isEmpty { issues[tool] = inventory.issues }
            } catch {
                issues[tool] = [error.localizedDescription]
            }
        }
        return DiscoveryResult(engine: self, registry: registry, files: files, sources: sources, issues: issues)
    }

    public func preview(_ registry: Registry, mode: SyncMode = .managed, replacing expected: Registry? = nil) -> SyncPlan {
        let tools = ToolID.allCases.map { tool -> ToolChange in
            let configured = path(for: tool, in: registry)
            do {
                let url = try target(for: tool, in: registry)
                let before = try LocalFile.read(url)
                let adapter = AgentAdapter(tool)
                let inventory = try adapter.inventory(before)
                let desired = registry.servers.filter { $0.enabledTools.contains(tool) }
                let ids = Set(desired.map(\.id))
                let receipt = registry.receipts[tool].flatMap { $0.path == url.path ? $0 : nil }
                let previouslyManaged = receipt?.managedIDs ?? []
                let removed = (mode == .full ? inventory.ids : previouslyManaged.intersection(inventory.ids)).subtracting(ids)
                let after = try adapter.merge(before, servers: desired, removing: removed)
                let status: SyncStatus
                if let receipt, receipt.digest != Self.digest(before) { status = .drift }
                else if before == nil { status = .missing }
                else if before != after { status = .pending }
                else { status = .synced }
                let diff = try UnifiedDiff.make(
                    before: ConfigEncoding.text(before), after: ConfigEncoding.text(after),
                    path: url.path, existed: before != nil, exists: after != nil
                )
                let configured = Dictionary(uniqueKeysWithValues: inventory.servers.map { ($0.id, $0) })
                let changedIDs = Set(removed).union(desired.compactMap { server -> String? in
                    guard before != after else { return nil }
                    guard let current = configured[server.id],
                          current.transport == server.transport, current.enabledTools.contains(tool) else { return server.id }
                    return nil
                })
                return ToolChange(
                    tool: tool, path: url, status: status, diff: diff, removedIDs: removed.sorted(),
                    configuredIDs: inventory.ids, changedIDs: changedIDs,
                    warnings: inventory.issues + desired.flatMap(adapter.warnings),
                    error: nil, before: before, after: after, managedIDs: ids
                )
            } catch {
                return ToolChange(tool: tool, path: configured, status: .unavailable, diff: "", removedIDs: [],
                                  configuredIDs: [], changedIDs: [], warnings: [], error: error.localizedDescription, before: nil, after: nil, managedIDs: [])
            }
        }
        return SyncPlan(mode: mode, tools: tools, registry: registry, expectedRegistry: expected ?? registry)
    }

    @discardableResult
    public func apply(_ plan: SyncPlan) throws -> Registry {
        try store.locked {
            guard try store.load() == plan.expectedRegistry else {
                throw PandaError.stale("中央配置库已更改，请重新预览同步。")
            }
            let inspected = plan.tools.filter { change in
                guard change.error == nil else { return false }
                return change.receipt(for: plan.registry) != nil
            }
            var result = plan.registry
            let mutations = try inspected.compactMap { change -> Mutation? in
                guard try target(for: change.tool, in: plan.registry) == change.path,
                      try LocalFile.read(change.path) == change.before else {
                    throw PandaError.stale("\(change.tool.title) 的配置已更改，请重新预览同步。")
                }
                result.receipts[change.tool] = change.receipt(for: plan.registry)
                guard change.hasChanges else { return nil }
                return try mutation(tool: change.tool, url: change.path, before: change.before,
                                    after: change.after, registry: plan.registry)
            }
            try commit(mutations, registry: result, trigger: .sync)
            return result
        }
    }

    public func backups() throws -> [BackupSnapshot] {
        let root = store.directory.appendingPathComponent("backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> [BackupSnapshot]? in
                guard let manifest = try LocalFile.read(url.appendingPathComponent("manifest.json")) else { return nil }
                return try JSONDecoder().decode([BackupSnapshot].self, from: manifest)
            }
            .flatMap { $0 }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func previewRestore(_ snapshot: BackupSnapshot) throws -> RestorePlan {
        let url = try restoreTarget(snapshot)
        let before = try LocalFile.read(url)
        let after = try snapshotContents(snapshot)
        return RestorePlan(
            snapshot: snapshot,
            diff: UnifiedDiff.make(before: restoreText(before), after: restoreText(after),
                                   path: url.path, existed: before != nil, exists: after != nil),
            before: before, after: after
        )
    }

    @discardableResult
    public func restore(_ plan: RestorePlan) throws -> Registry {
        try store.locked {
            let url = try restoreTarget(plan.snapshot)
            guard try LocalFile.read(url) == plan.before,
                  try snapshotContents(plan.snapshot) == plan.after else {
                throw PandaError.stale("配置或备份已更改，请重新预览恢复。")
            }
            var registry = try store.load()
            guard plan.hasChanges else { return registry }
            var change = try mutation(tool: plan.snapshot.tool, url: url, before: plan.before,
                                      after: plan.after, registry: registry)
            change.afterPermissions = plan.snapshot.permissions
            if let receipt = registry.receipts[plan.snapshot.tool], receipt.path == url.path {
                registry.receipts[plan.snapshot.tool] = SyncReceipt(
                    path: receipt.path, digest: receipt.digest,
                    managedIDs: receipt.managedIDs.union(plan.snapshot.managedIDs)
                )
            }
            try commit([change], registry: registry, trigger: .restore)
            return registry
        }
    }

    static func digest(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    private struct Mutation {
        let tool: ToolID
        let url: URL
        let before: Data?
        let after: Data?
        let beforePermissions: Int?
        let managedIDs: Set<String>
        var afterPermissions: Int?
    }

    private func mutation(tool: ToolID, url: URL, before: Data?, after: Data?, registry: Registry) throws -> Mutation {
        let permissions = (try LocalFile.attributes(url)?[.posixPermissions] as? NSNumber)?.intValue
        let receipt = registry.receipts[tool].flatMap { $0.path == url.path ? $0 : nil }
        return Mutation(tool: tool, url: url, before: before, after: after, beforePermissions: permissions,
                        managedIDs: receipt?.managedIDs ?? [], afterPermissions: permissions)
    }

    private func commit(_ changes: [Mutation], registry: Registry, trigger: BackupTrigger) throws {
        if !changes.isEmpty { try saveBackups(changes, trigger: trigger) }
        var applied: [Mutation] = []
        do {
            for change in changes {
                guard try LocalFile.read(change.url) == change.before else {
                    throw PandaError.stale("\(change.tool.title) 的配置已更改，请重新预览。")
                }
                try LocalFile.restore(change.after, to: change.url, permissions: change.afterPermissions)
                applied.append(change)
            }
            try store.write(registry)
        } catch {
            let originalError = error
            var failures: [String] = []
            for change in applied.reversed() {
                do {
                    guard try LocalFile.read(change.url) == change.after else {
                        throw PandaError.stale("检测到外部修改")
                    }
                    try LocalFile.restore(change.before, to: change.url, permissions: change.beforePermissions)
                } catch {
                    failures.append("\(change.tool.title)：\(error.localizedDescription)")
                }
            }
            if failures.isEmpty { throw originalError }
            throw PandaError.transaction(originalError.localizedDescription + "\n请从备份检查：" + failures.joined(separator: "、"))
        }
    }

    func target(for tool: ToolID, in registry: Registry) throws -> URL {
        let url = path(for: tool, in: registry).resolvingSymlinksInPath()
        try validateTarget(url)
        let collisions = ToolID.allCases.filter {
            $0 != tool && path(for: $0, in: registry).resolvingSymlinksInPath() == url
        }
        if let other = collisions.first {
            throw PandaError.invalid("\(tool.title) 与 \(other.title) 指向同一个配置文件。")
        }
        return url
    }

    private func validateTarget(_ url: URL) throws {
        let privatePath = store.directory.path
        guard url.path != privatePath, !url.path.hasPrefix(privatePath + "/") else {
            throw PandaError.invalid("工具配置路径不能位于 Nano Panda 数据目录中。")
        }
    }

    private func restoreTarget(_ snapshot: BackupSnapshot) throws -> URL {
        let url = URL(fileURLWithPath: snapshot.originalPath)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == resolved.path else { throw PandaError.stale("备份的原配置路径已重定向。") }
        try validateTarget(resolved)
        return resolved
    }

    private func snapshotContents(_ snapshot: BackupSnapshot) throws -> Data? {
        guard snapshot.existed else { return nil }
        let url = store.directory.appendingPathComponent("backups").appendingPathComponent(snapshot.batch)
            .appendingPathComponent(snapshot.tool.rawValue).appendingPathComponent("config")
        guard let contents = try LocalFile.read(url), Self.digest(contents) == snapshot.digest else {
            throw PandaError.invalid("备份文件缺失或内容校验失败。")
        }
        return contents
    }

    private func restoreText(_ data: Data?) -> String {
        guard let data else { return "" }
        return String(data: data, encoding: .utf8) ?? "［非 UTF-8 数据，\(data.count) 字节］\n"
    }

    private func saveBackups(_ changes: [Mutation], trigger: BackupTrigger) throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let batch = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        let root = store.directory.appendingPathComponent("backups", isDirectory: true)
        let staging = root.appendingPathComponent("." + batch, isDirectory: true)
        try LocalFile.privateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        var snapshots: [BackupSnapshot] = []
        for change in changes {
            let directory = staging.appendingPathComponent(change.tool.rawValue, isDirectory: true)
            try LocalFile.privateDirectory(directory)
            if let contents = change.before {
                try LocalFile.write(contents, to: directory.appendingPathComponent("config"), permissions: 0o600)
            }
            snapshots.append(BackupSnapshot(
                id: UUID(), createdAt: now, tool: change.tool, originalPath: change.url.path,
                existed: change.before != nil, trigger: trigger, batch: batch, digest: Self.digest(change.before),
                permissions: change.beforePermissions, managedIDs: change.managedIDs
            ))
        }
        let data = Data(try ConfigEncoding.json(snapshots, pretty: true).utf8)
        try LocalFile.write(data, to: staging.appendingPathComponent("manifest.json"), permissions: 0o600)
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(batch))
    }
}
