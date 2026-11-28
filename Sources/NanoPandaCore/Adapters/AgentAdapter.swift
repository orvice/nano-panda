import Foundation

public struct AgentAdapter {
    public let tool: ToolID

    public init(_ tool: ToolID) { self.tool = tool }

    static let codexFields: Set<String> = [
        "command", "args", "env", "url", "http_headers", "bearer_token_env_var", "enabled"
    ]

    private var jsonFields: Set<String> {
        switch tool {
        case .openCode: return ["type", "command", "environment", "url", "headers", "enabled", "disabled"]
        case .geminiCLI: return ["command", "args", "env", "httpUrl", "url", "headers"]
        case .antigravity, .windsurf: return ["command", "args", "env", "serverUrl", "url", "headers"]
        case .claudeCode: return ["type", "command", "args", "env", "url", "headers"]
        default: return ["command", "args", "env", "url", "headers"]
        }
    }

    struct Inventory {
        var ids: Set<String> = []
        var servers: [MCPServer] = []
        var issues: [String] = []
    }

    func inventory(_ data: Data?) throws -> Inventory {
        guard let data else { return Inventory() }
        let text = try ConfigEncoding.text(data)
        var result = Inventory()
        if tool == .codex {
            let document = try TOMLDocument(text)
            result.ids = document.serverIDs
            for id in result.ids.sorted() {
                do {
                    result.servers.append(try decode(id: id, fields: document.fields(for: id), nestedOpenCode: false))
                } catch {
                    result.issues.append("\(id)：\(error.localizedDescription)")
                }
            }
        } else {
            let config = try jsonConfig(text)
            for member in config.servers?.members ?? [] {
                result.ids.insert(member.name)
                do {
                    guard let fields = member.value.value.object else {
                        throw PandaError.invalid("MCP 条目必须为对象。")
                    }
                    result.servers.append(try decode(id: member.name, fields: fields, nestedOpenCode: config.nested))
                } catch {
                    result.issues.append("\(member.name)：\(error.localizedDescription)")
                }
            }
        }
        return result
    }

    public func read(_ data: Data?) throws -> [MCPServer] {
        let result = try inventory(data)
        guard result.issues.isEmpty else { throw PandaError.invalid(result.issues.joined(separator: "\n")) }
        return result.servers
    }

    public static func paste(_ text: String, defaultID: String) throws -> [MCPServer] {
        let adapter = AgentAdapter(.claudeCode)
        let document: JSONDocument
        do {
            document = try JSONDocument(text, allowsComments: true)
        } catch {
            document = try JSONDocument("{\n" + text + "\n}", allowsComments: true)
        }
        var root = document.root
        if let wrapped = root["mcpServers"] { root = wrapped }
        guard let members = root.members, !members.isEmpty else {
            throw PandaError.invalid("请粘贴至少一个 MCP JSON 条目。")
        }
        if root["command"]?.value.string != nil || root["url"]?.value.string != nil {
            return [try adapter.decode(id: defaultID, fields: root.value.object!, nestedOpenCode: false)]
        }
        return try members.map { member in
            guard let fields = member.value.value.object else {
                throw PandaError.invalid("MCP 条目「\(member.name)」必须为对象。")
            }
            return try adapter.decode(id: member.name, fields: fields, nestedOpenCode: false)
        }
    }

    func merge(_ data: Data?, servers: [MCPServer], removing: Set<String>) throws -> Data? {
        guard !servers.isEmpty || !removing.isEmpty else { return data }
        let text = try ConfigEncoding.text(data)
        if tool == .codex {
            let document = try TOMLDocument(text)
            let fields = try Dictionary(uniqueKeysWithValues: servers.map { ($0.id, try encode($0, nestedOpenCode: false)) })
            let output = try document.merging(remove: removing, replace: fields, owned: Self.codexFields)
            return Data(output.utf8)
        }

        let config = try jsonConfig(data == nil ? "{}\n" : text)
        var edits: [JSONDocument.Edit] = []
        var additions: [String: ConfigValue] = [:]
        for server in servers {
            let desired = try encode(server, nestedOpenCode: config.nested)
            if let node = config.servers?[server.id], let members = node.members {
                let original = Set(members.map(\.name))
                let fields = desired.filter { jsonFields.contains($0.key) || !original.contains($0.key) }
                let remove = original.intersection(jsonFields).subtracting(desired.keys)
                edits += try config.document.editObject(node, remove: remove, replace: fields)
            } else {
                additions[server.id] = .object(desired)
            }
        }

        if let node = config.servers {
            edits += try config.document.editObject(node, remove: removing, replace: additions)
        } else if !additions.isEmpty {
            if config.nested, let mcp = config.document.root[config.key] {
                edits += try config.document.editObject(mcp, remove: [], replace: ["servers": .object(additions)])
            } else {
                let fields = config.nested ? ["servers": ConfigValue.object(additions)] : additions
                edits += try config.document.editObject(config.document.root, remove: [], replace: [config.key: .object(fields)])
            }
        }
        let output = config.document.applying(edits)
        _ = try jsonConfig(output)
        return Data(output.utf8)
    }

    func warnings(for server: MCPServer) -> [String] {
        var warnings: [String] = []
        if tool == .claudeDesktop && server.transport.isRemote {
            warnings.append("Claude Desktop 的本地配置可能无法启动远程 MCP「\(server.id)」。")
        }
        if case .sse = server.transport, [.codex, .openCode, .cursor, .windsurf, .antigravity, .claudeDesktop].contains(tool) {
            warnings.append("\(tool.title) 的映射无法保留「\(server.id)」的 SSE 类型。")
        }
        if case let .http(_, _, token?) = server.transport, !token.isEmpty, tool != .codex {
            warnings.append("\(tool.title) 的映射不会写入「\(server.id)」的 Bearer Token 环境变量。")
        }
        return warnings
    }

    private func jsonConfig(_ text: String) throws -> (
        document: JSONDocument, key: String, servers: JSONDocument.Node?, nested: Bool
    ) {
        let document = try JSONDocument(text, allowsComments: tool == .openCode)
        guard document.root.members != nil else { throw PandaError.invalid("配置根节点必须为 JSON 对象。") }
        let key = tool == .openCode ? "mcp" : "mcpServers"
        let section = document.root[key]
        if let section, section.members == nil { throw PandaError.invalid("「\(key)」必须为对象。") }
        let v2Keys: Set<String> = ["timeout", "codemode", "auth_server_metadata_url", "pool"]
        let nested = tool == .openCode && (
            section == nil ||
            (section?["servers"] != nil && section?["servers"]?["type"]?.value.string == nil) ||
            (section?.members?.contains { v2Keys.contains($0.name) && $0.value["type"]?.value.string == nil } ?? false)
        )
        let servers = nested ? section?["servers"] : section
        if let servers, servers.members == nil { throw PandaError.invalid("MCP 列表必须为对象。") }
        return (document, key, servers, nested)
    }

    private func decode(id: String, fields: [String: ConfigValue], nestedOpenCode: Bool) throws -> MCPServer {
        func string(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value.string else { throw PandaError.invalid("「\(key)」必须为字符串。") }
            return text
        }

        func map(_ key: String) throws -> [String: String] {
            guard let value = fields[key] else { return [:] }
            guard let map = value.stringMap else { throw PandaError.invalid("「\(key)」必须为字符串键值表。") }
            return map
        }

        let mode = tool == .claudeCode || tool == .openCode ? try string("type") : nil
        let transport: Transport
        let remote = mode == "remote" || mode == "http" || mode == "sse"
        if !remote, let command = fields["command"] {
            if tool == .openCode {
                guard let parts = command.strings, let program = parts.first else {
                    throw PandaError.invalid("OpenCode 的 command 必须为非空字符串列表。")
                }
                transport = .stdio(command: program, args: Array(parts.dropFirst()), env: try map("environment"))
            } else {
                guard let program = command.string else { throw PandaError.invalid("command 必须为字符串。") }
                let args = fields["args"]?.strings
                if fields["args"] != nil && args == nil { throw PandaError.invalid("args 必须为字符串列表。") }
                transport = .stdio(command: program, args: args ?? [], env: try map("env"))
            }
        } else {
            let urlKey: String
            switch tool {
            case .geminiCLI: urlKey = fields["httpUrl"] != nil ? "httpUrl" : "url"
            case .antigravity, .windsurf: urlKey = fields["serverUrl"] != nil ? "serverUrl" : "url"
            default: urlKey = "url"
            }
            guard let url = try string(urlKey) else { throw PandaError.invalid("缺少 command 或远程 URL。") }
            let headers = try map(tool == .codex ? "http_headers" : "headers")
            if mode == "sse" || (tool == .geminiCLI && urlKey == "url") {
                transport = .sse(url: url, headers: headers)
            } else {
                let token = tool == .codex ? try string("bearer_token_env_var") : nil
                transport = .http(url: url, headers: headers, bearerTokenEnvVar: token)
            }
        }

        let enabled = nestedOpenCode ? fields["disabled"] != .bool(true)
            : (tool == .codex || tool == .openCode ? fields["enabled"] != .bool(false) : true)
        let known = tool == .codex ? Self.codexFields : jsonFields
        let extra = fields.filter { !known.contains($0.key) }
        let overrides = extra.isEmpty ? [:] : [tool: ServerOverride(fields: extra)]
        let server = MCPServer(id: id, transport: transport, enabledTools: enabled ? [tool] : [], perToolOverrides: overrides)
        try server.validate()
        return server
    }

    private func encode(_ server: MCPServer, nestedOpenCode: Bool) throws -> [String: ConfigValue] {
        try server.validate()
        let owned = tool == .codex ? Self.codexFields : jsonFields
        var result = server.perToolOverrides[tool]?.fields.filter { !owned.contains($0.key) } ?? [:]
        switch server.transport {
        case let .stdio(command, args, env):
            if tool == .openCode {
                result["type"] = .string("local")
                result["command"] = .array(([command] + args).map(ConfigValue.string))
            } else {
                result["command"] = .string(command)
                if !args.isEmpty { result["args"] = .array(args.map(ConfigValue.string)) }
                if tool == .claudeCode { result["type"] = .string("stdio") }
            }
            if !env.isEmpty { result[tool == .openCode ? "environment" : "env"] = .object(env.mapValues(ConfigValue.string)) }
        case let .http(url, headers, bearer):
            addRemote(url, headers: headers, sse: false, into: &result)
            if tool == .codex, let bearer, !bearer.isEmpty { result["bearer_token_env_var"] = .string(bearer) }
        case let .sse(url, headers):
            addRemote(url, headers: headers, sse: true, into: &result)
        }
        if tool == .openCode && !nestedOpenCode { result["enabled"] = .bool(true) }
        return result
    }

    private func addRemote(_ url: String, headers: [String: String], sse: Bool, into fields: inout [String: ConfigValue]) {
        let key: String
        switch tool {
        case .antigravity, .windsurf: key = "serverUrl"
        case .geminiCLI: key = sse ? "url" : "httpUrl"
        default: key = "url"
        }
        if tool == .openCode { fields["type"] = .string("remote") }
        if tool == .claudeCode { fields["type"] = .string(sse ? "sse" : "http") }
        fields[key] = .string(url)
        if !headers.isEmpty {
            fields[tool == .codex ? "http_headers" : "headers"] = .object(headers.mapValues(ConfigValue.string))
        }
    }
}
