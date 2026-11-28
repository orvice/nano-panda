import Foundation

public enum ToolID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case claudeCode, codex, antigravity, claudeDesktop, cursor, windsurf, geminiCLI, openCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .geminiCLI: return "Gemini CLI"
        case .openCode: return "OpenCode"
        }
    }

    public var relativePath: String {
        switch self {
        case .claudeCode: return ".claude.json"
        case .codex: return ".codex/config.toml"
        case .antigravity: return ".gemini/antigravity/mcp_config.json"
        case .claudeDesktop: return "Library/Application Support/Claude/claude_desktop_config.json"
        case .cursor: return ".cursor/mcp.json"
        case .windsurf: return ".codeium/windsurf/mcp_config.json"
        case .geminiCLI: return ".gemini/settings.json"
        case .openCode: return ".config/opencode/opencode.json"
        }
    }
}

public struct ToolAssignment: Hashable {
    public let serverID: String
    public let tool: ToolID

    public init(serverID: String, tool: ToolID) {
        self.serverID = serverID
        self.tool = tool
    }
}

public enum Transport: Codable, Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: String, headers: [String: String], bearerTokenEnvVar: String?)
    case sse(url: String, headers: [String: String])

    public var isRemote: Bool {
        if case .stdio = self { return false }
        return true
    }

    public func validate() throws {
        switch self {
        case let .stdio(command, _, _):
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PandaError.invalid("请输入启动命令。")
            }
        case let .http(url, _, _), let .sse(url, _):
            guard let address = URLComponents(string: url),
                  let scheme = address.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = address.host, !host.isEmpty else {
                throw PandaError.invalid("请输入有效的 HTTP 或 HTTPS URL。")
            }
        }
    }
}

public enum ConfigValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), number(Double), bool(Bool)
    case array([ConfigValue]), object([String: ConfigValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([ConfigValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: ConfigValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .integer(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var object: [String: ConfigValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var strings: [String]? {
        guard case let .array(values) = self else { return nil }
        let strings = values.compactMap(\.string)
        return strings.count == values.count ? strings : nil
    }

    var stringMap: [String: String]? {
        guard let object else { return nil }
        let strings = object.compactMapValues(\.string)
        return strings.count == object.count ? strings : nil
    }
}

public struct ServerOverride: Codable, Equatable, Sendable {
    public var fields: [String: ConfigValue]

    public init(fields: [String: ConfigValue] = [:]) { self.fields = fields }
}

public struct MCPServer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var transport: Transport
    public var enabledTools: Set<ToolID>
    public var notes: String?
    public var tags: [String]
    public var updatedAt: Date
    public var perToolOverrides: [ToolID: ServerOverride]

    public init(
        id: String, transport: Transport, enabledTools: Set<ToolID> = [],
        notes: String? = nil, tags: [String] = [], updatedAt: Date = Date(),
        perToolOverrides: [ToolID: ServerOverride] = [:]
    ) {
        self.id = id
        self.transport = transport
        self.enabledTools = enabledTools
        self.notes = notes
        self.tags = tags
        self.updatedAt = updatedAt
        self.perToolOverrides = perToolOverrides
    }

    public func validate() throws {
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              id.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PandaError.invalid("MCP 名称不能为空，也不能含有控制字符或首尾空白。")
        }
        try transport.validate()
    }
}

public struct SyncReceipt: Codable, Equatable {
    public let path: String
    public let digest: String?
    public let managedIDs: Set<String>
}

public struct Registry: Codable, Equatable {
    public var servers: [MCPServer] = []
    public var customPaths: [ToolID: String] = [:]
    public var receipts: [ToolID: SyncReceipt] = [:]
    var cloudRestorationID: UUID?
    public init() {}

    public mutating func set(_ assignment: ToolAssignment, enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == assignment.serverID }) else { return }
        if enabled {
            servers[index].enabledTools.insert(assignment.tool)
        } else {
            servers[index].enabledTools.remove(assignment.tool)
        }
        servers[index].updatedAt = Date()
    }
}

public enum PandaError: LocalizedError {
    case invalid(String)
    case stale(String)
    case transaction(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message), let .stale(message), let .transaction(message): return message
        }
    }
}
