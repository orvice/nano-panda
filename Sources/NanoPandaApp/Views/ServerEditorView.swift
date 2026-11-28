import AppKit
import NanoPandaCore
import SwiftUI

private enum TransportKind: String, CaseIterable, Identifiable {
    case stdio, http, sse
    var id: Self { self }
    var title: String {
        switch self {
        case .stdio: return "Stdio"
        case .http: return "Streamable HTTP"
        case .sse: return "SSE"
        }
    }
}

private struct EditorRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}

struct ServerEditorView: View {
    let state: AppState
    let server: MCPServer?
    @State private var name: String
    @State private var kind = TransportKind.stdio
    @State private var command = ""
    @State private var arguments: [EditorRow] = []
    @State private var environment: [EditorRow] = []
    @State private var url = ""
    @State private var headers: [EditorRow] = []
    @State private var bearer = ""
    @State private var notes: String
    @State private var tags: String
    @State private var tools: Set<ToolID>
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var revealed: Set<UUID> = []

    init(state: AppState, server: MCPServer?) {
        self.state = state
        self.server = server
        _name = State(initialValue: server?.id ?? "")
        _notes = State(initialValue: server?.notes ?? "")
        _tags = State(initialValue: server?.tags.joined(separator: ", ") ?? "")
        _tools = State(initialValue: server?.enabledTools ?? [])
        switch server?.transport {
        case let .stdio(program, args, env):
            _command = State(initialValue: program)
            _arguments = State(initialValue: args.map { EditorRow(value: $0) })
            _environment = State(initialValue: Self.rows(env))
        case let .http(address, values, token):
            _kind = State(initialValue: .http)
            _url = State(initialValue: address)
            _headers = State(initialValue: Self.rows(values))
            _bearer = State(initialValue: token ?? "")
        case let .sse(address, values):
            _kind = State(initialValue: .sse)
            _url = State(initialValue: address)
            _headers = State(initialValue: Self.rows(values))
        case nil: break
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    editorHeader
                    Divider().overlay(WorkspaceStyle.border)
                    toolCard
                    connectionCard
                    if kind == .stdio {
                        valuesCard("环境变量", entries: $environment, add: "添加变量")
                    } else {
                        valuesCard("请求头", entries: $headers, add: "添加请求头")
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            field("标签", text: $tags, prompt: "用逗号分隔")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("备注").font(WorkspaceStyle.small)
                                TextField("备注", text: $notes, axis: .vertical)
                                    .textFieldStyle(.plain).lineLimit(2...5).workspaceField()
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("标签与备注").font(WorkspaceStyle.title)
                    }
                    .workspaceCard()
                }
                .frame(maxWidth: 896)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            Divider().overlay(WorkspaceStyle.border)
            HStack(spacing: 10) {
                if server == nil {
                    Button("取消") { state.sheet = nil }
                        .buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                } else {
                    Label("安全合并：仅更新托管的 MCP 配置。", systemImage: "shield")
                        .font(WorkspaceStyle.small)
                        .foregroundStyle(WorkspaceStyle.secondary)
                }
                Spacer()
                if let error { Text(error).font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.red) }
                Button("保存", action: save)
                    .buttonStyle(WorkspaceButton(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canEdit)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(WorkspaceStyle.sidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }

    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if server == nil {
                        Text("新建 MCP").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                    } else {
                        TextField("MCP 名称", text: $name)
                            .font(WorkspaceStyle.headline)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 2)
                    }
                    Text("全局")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WorkspaceStyle.greenInk)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(WorkspaceStyle.greenTint, in: Capsule())
                }
                if let server {
                    Text("最近编辑于 \(server.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
                } else {
                    field("MCP 名称", text: $name, prompt: "例如 filesystem")
                }
            }
            if let server {
                Button("粘贴 JSON", systemImage: "doc.on.clipboard", action: state.paste)
                    .buttonStyle(WorkspaceButton())
                Button("删除 MCP", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(WorkspaceButton(kind: .danger))
                    .help("删除 MCP")
                    .confirmationDialog("删除「\(server.id)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("删除 MCP", role: .destructive) { state.delete(server.id) }
                    } message: {
                        Text("已托管的工具配置将在下一次确认同步时移除。")
                    }
            }
        }
    }

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("启用的 Agent 工具").font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(tools.count) / \(ToolID.allCases.count) 已启用")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
                    .monospacedDigit()
            }
            ViewThatFits(in: .horizontal) {
                toolChips(columns: 4).frame(minWidth: 490)
                toolChips(columns: 2)
            }
            if kind != .stdio && tools.contains(.claudeDesktop) {
                Label("Claude Desktop 的本地配置可能无法启动远程 MCP。", systemImage: "exclamationmark.triangle")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
            }
        }
        .workspaceCard()
    }

    private func toolChips(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(ToolID.workspaceOrder) { tool in
                let active = tools.contains(tool)
                Button {
                    if active { tools.remove(tool) } else { tools.insert(tool) }
                } label: {
                    HStack(spacing: 5) {
                        Text(tool.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(active ? WorkspaceStyle.greenInk : WorkspaceStyle.muted)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(active ? WorkspaceStyle.greenInk : WorkspaceStyle.secondary)
                    .padding(.horizontal, 9).frame(height: 34)
                    .background(active ? WorkspaceStyle.greenTint : WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(active ? WorkspaceStyle.green.opacity(0.32) : WorkspaceStyle.border) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("连接与传输").font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
                Spacer()
                WorkspaceSegments(options: TransportKind.allCases, selection: $kind) { $0.title }
            }
            if kind == .stdio {
                HStack(alignment: .top, spacing: 16) {
                    field("启动命令", text: $command, prompt: "例如 npx")
                        .frame(maxWidth: 180, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("参数").font(WorkspaceStyle.small)
                        ForEach($arguments) { $argument in
                            HStack(spacing: 6) {
                                TextField("参数", text: $argument.value).textFieldStyle(.plain).workspaceField()
                                removeButton("移除参数") { arguments.removeAll { $0.id == argument.id } }
                            }
                        }
                        Button("添加参数", systemImage: "plus") { arguments.append(EditorRow()) }
                            .buttonStyle(WorkspaceButton(kind: .quiet))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                field("URL", text: $url, prompt: "https://example.com/mcp")
                if kind == .http {
                    field("Bearer Token 环境变量", text: $bearer, prompt: "仅用于 Codex")
                }
            }
        }
        .workspaceCard()
    }

    private func valuesCard(_ label: String, entries: Binding<[EditorRow]>, add: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(label).font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(entries.wrappedValue.count) 项").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
            }
            if !entries.wrappedValue.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                    GridRow {
                        Text("键").padding(.leading, 8)
                        Text("值")
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkspaceStyle.muted)
                    .padding(.vertical, 8)
                    ForEach(entries) { $entry in
                        Divider().overlay(WorkspaceStyle.border).gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            TextField("键", text: $entry.key).textFieldStyle(.plain)
                                .font(WorkspaceStyle.mono).padding(.leading, 8)
                            HStack(spacing: 7) {
                                if revealed.contains(entry.id) {
                                    TextField("值", text: $entry.value).textFieldStyle(.plain).font(WorkspaceStyle.mono)
                                } else {
                                    SecureField("值", text: $entry.value).textFieldStyle(.plain).font(WorkspaceStyle.mono)
                                }
                                Button(revealed.contains(entry.id) ? "隐藏值" : "显示值",
                                       systemImage: revealed.contains(entry.id) ? "eye.slash" : "eye") {
                                    if revealed.contains(entry.id) { revealed.remove(entry.id) } else { revealed.insert(entry.id) }
                                }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(WorkspaceStyle.muted)
                                Button("复制值", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.value, forType: .string)
                                }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(WorkspaceStyle.muted)
                                removeButton("移除此项") {
                                    entries.wrappedValue.removeAll { $0.id == entry.id }
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceStyle.border) }
            }
            Button(add, systemImage: "plus") { entries.wrappedValue.append(EditorRow()) }
                .buttonStyle(WorkspaceButton(kind: .quiet))
        }
        .workspaceCard()
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(WorkspaceButton(kind: .quiet))
            .foregroundStyle(WorkspaceStyle.muted)
            .help(label)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(WorkspaceStyle.small)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .workspaceField()
        }
    }

    private func save() {
        do {
            let transport: Transport
            switch kind {
            case .stdio:
                transport = .stdio(command: command, args: arguments.map(\.value), env: try map(environment))
            case .http:
                transport = .http(url: url, headers: try map(headers), bearerTokenEnvVar: bearer.isEmpty ? nil : bearer)
            case .sse:
                transport = .sse(url: url, headers: try map(headers))
            }
            let entry = MCPServer(
                id: name.trimmingCharacters(in: .whitespacesAndNewlines), transport: transport, enabledTools: tools,
                notes: notes.isEmpty ? nil : notes,
                tags: tags.split(whereSeparator: { $0 == "," || $0 == "，" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                perToolOverrides: server?.perToolOverrides ?? [:]
            )
            try state.saveServer(entry, replacing: server?.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func rows(_ values: [String: String]) -> [EditorRow] {
        values.keys.sorted().map { EditorRow(key: $0, value: values[$0]!) }
    }

    private func map(_ rows: [EditorRow]) throws -> [String: String] {
        var values: [String: String] = [:]
        for row in rows {
            guard !row.key.isEmpty, values.updateValue(row.value, forKey: row.key) == nil else {
                throw PandaError.invalid("环境变量和请求头的键不能为空或重复。")
            }
        }
        return values
    }
}

struct PasteSheet: View {
    let state: AppState
    @State private var input = ""
    @State private var defaultName = "new-mcp"
    @State private var replace = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从 JSON 粘贴导入").font(.title2.bold())
            Text("支持 Claude Code 或 Cursor 的 mcpServers 配置和单个 MCP JSON 片段。")
                .foregroundStyle(.secondary)
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .border(.quaternary)
                .accessibilityLabel("MCP JSON")
            TextField("单条配置的默认名称", text: $defaultName)
            Toggle("同名时替换中央配置库中的传输配置", isOn: $replace)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { state.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    do {
                        let entries = try AgentAdapter.paste(input, defaultID: defaultName)
                        try state.savePasted(entries, replacingExisting: replace)
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 620, height: 425)
    }
}
