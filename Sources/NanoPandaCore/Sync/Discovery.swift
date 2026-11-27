import Foundation

public struct ImportSource: Identifiable {
    public let tool: ToolID
    public let server: MCPServer
    public var id: ToolID { tool }
}

public struct ImportGroup: Identifiable {
    public let id: String
    public let sources: [ImportSource]
    public let existing: MCPServer?

    public var isConflict: Bool {
        guard let baseline = existing ?? sources.first?.server else { return false }
        return sources.contains {
            $0.server.transport != baseline.transport ||
                (baseline.perToolOverrides[$0.tool] != nil &&
                 $0.server.perToolOverrides[$0.tool] != baseline.perToolOverrides[$0.tool])
        }
    }
}

public enum ImportChoice: Hashable {
    case existing, source(ToolID), skip, separate
}

public struct DiscoveryResult {
    public let groups: [ImportGroup]
    public let issues: [ToolID: [String]]
    private let engine: SyncEngine
    fileprivate let registry: Registry
    fileprivate let files: [ToolID: DiscoveredFile]

    struct DiscoveredFile {
        let url: URL
        let data: Data?
    }

    init(
        engine: SyncEngine, registry: Registry, files: [ToolID: DiscoveredFile],
        sources: [ImportSource], issues: [ToolID: [String]]
    ) {
        self.engine = engine
        self.registry = registry
        self.files = files
        self.issues = issues
        let grouped = Dictionary(grouping: sources, by: { $0.server.id })
        let existing = Dictionary(grouping: registry.servers, by: \.id)
        self.groups = grouped.keys.sorted().map { id in
            ImportGroup(id: id, sources: grouped[id]!, existing: existing[id]?.first)
        }
    }

    public func importing(_ choices: [String: ImportChoice], into registry: Registry) throws -> Registry {
        guard registry == self.registry else {
            throw PandaError.stale("中央配置库已更改，请重新扫描。")
        }
        var result = registry
        var used = Set(registry.servers.map(\.id)).union(groups.map(\.id))
        var checkedTools: Set<ToolID> = []
        for group in groups {
            let fallback = group.existing == nil ? ImportChoice.source(group.sources[0].tool) : .existing
            if group.isConflict && choices[group.id] == nil {
                throw PandaError.invalid("请选择如何处理「\(group.id)」的导入冲突。")
            }
            let choice = choices[group.id] ?? fallback
            if choice == .skip { continue }
            for source in group.sources where checkedTools.insert(source.tool).inserted {
                guard let file = files[source.tool], try engine.target(for: source.tool, in: registry) == file.url,
                      try LocalFile.read(file.url) == file.data else {
                    throw PandaError.stale("\(source.tool.title) 配置已更改，请重新扫描。")
                }
            }
            if choice == .separate {
                var hasOriginal = group.existing != nil
                for source in group.sources {
                    var server = source.server
                    if hasOriginal {
                        let base = "\(group.id)-\(source.tool.rawValue)"
                        var newID = base
                        var suffix = 2
                        while !used.insert(newID).inserted {
                            newID = "\(base)-\(suffix)"
                            suffix += 1
                        }
                        server.id = newID
                    }
                    hasOriginal = true
                    result.servers.append(server)
                    if server.id == group.id || group.existing?.enabledTools.contains(source.tool) != true {
                        adopt(source, into: &result)
                    }
                }
                continue
            }

            let selected: MCPServer
            switch choice {
            case .existing:
                guard let existing = group.existing else { throw PandaError.invalid("没有同名的库内版本。") }
                selected = existing
            case let .source(tool):
                guard let source = group.sources.first(where: { $0.tool == tool }) else {
                    throw PandaError.invalid("找不到选择的导入来源。")
                }
                selected = source.server
            default: continue
            }

            var server = group.existing ?? selected
            server.transport = selected.transport
            for source in group.sources {
                server.enabledTools.formUnion(source.server.enabledTools)
                if choice != .existing || server.perToolOverrides[source.tool] == nil {
                    server.perToolOverrides[source.tool] = source.server.perToolOverrides[source.tool]
                }
                adopt(source, into: &result)
            }
            server.updatedAt = Date()
            if let index = result.servers.firstIndex(where: { $0.id == server.id }) {
                result.servers[index] = server
            } else {
                result.servers.append(server)
            }
        }
        return result
    }

    private func adopt(_ source: ImportSource, into registry: inout Registry) {
        guard source.server.enabledTools.contains(source.tool), let file = files[source.tool] else { return }
        let previous = registry.receipts[source.tool]
        let isSamePath = previous?.path == file.url.path
        var ids = isSamePath ? previous?.managedIDs ?? [] : []
        ids.insert(source.server.id)
        registry.receipts[source.tool] = SyncReceipt(
            path: file.url.path,
            digest: isSamePath ? previous?.digest : SyncEngine.digest(file.data),
            managedIDs: ids
        )
    }
}
