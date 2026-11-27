import NanoPandaCore
import SwiftUI

struct ImportWizardSheet: View {
    let state: AppState
    let discovery: DiscoveryResult
    @State private var choices: [String: ImportChoice] = [:]
    @State private var error: String?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描本机导入").font(.title2.bold())
            if discovery.groups.isEmpty && discovery.issues.isEmpty {
                ContentUnavailableView("未发现 MCP", systemImage: "magnifyingglass",
                                       description: Text("可以在「工具与备份」中检查配置路径。"))
            } else {
                List(selection: $selection) {
                    ForEach(discovery.groups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(group.id).font(.headline)
                                Spacer()
                                if group.isConflict {
                                    Label("同名冲突", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                            }
                            Text(group.sources.map { source in
                                source.tool.title + (source.server.enabledTools.contains(source.tool) ? "" : "（停用）")
                            }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            if group.isConflict {
                                if let existing = group.existing {
                                    transport("中央配置库", server: existing)
                                }
                                ForEach(group.sources) { source in
                                    transport(source.tool.title, server: source.server)
                                }
                            }
                            Picker("导入方式", selection: Binding(
                                get: { choices[group.id] },
                                set: { choices[group.id] = $0 }
                            )) {
                                Text(group.isConflict ? "请选择" : "合并工具分配").tag(Optional<ImportChoice>.none)
                                if group.existing != nil {
                                    Text("使用中央配置库版本").tag(ImportChoice.existing as ImportChoice?)
                                }
                                ForEach(group.sources) { source in
                                    Text("使用 \(source.tool.title) 版本").tag(ImportChoice.source(source.tool) as ImportChoice?)
                                }
                                if group.isConflict {
                                    Text("另存为独立条目").tag(ImportChoice.separate as ImportChoice?)
                                }
                                Text("跳过").tag(ImportChoice.skip as ImportChoice?)
                            }
                        }.padding(.vertical, 4).tag(group.id)
                    }
                    if !discovery.issues.isEmpty {
                        Section("读取问题") {
                            ForEach(ToolID.allCases) { tool in
                                if let issues = discovery.issues[tool] {
                                    Text(tool.title + " · " + issues.joined(separator: "\n"))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }.border(.quaternary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { state.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    do { try state.importDiscovery(discovery, choices: choices) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(discovery.groups.isEmpty || discovery.groups.contains { $0.isConflict && choices[$0.id] == nil })
            }
        }.padding(20).frame(width: 700, height: 600)
    }

    private func transport(_ title: String, server: MCPServer) -> some View {
        DisclosureGroup(title) {
            Text(transportSummary(server.transport))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tool = server.enabledTools.first, let extra = server.perToolOverrides[tool] {
                Text("工具专用字段 · " + extra.fields.keys.sorted().joined(separator: "、"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transportSummary(_ transport: Transport) -> String {
        switch transport {
        case let .stdio(command, args, env):
            return (["stdio", "命令：\(command)", "参数：\(args.debugDescription)"] +
                env.keys.sorted().map { "\($0)=\(env[$0]!)" }).joined(separator: "\n")
        case let .http(url, headers, token):
            return (["http", url] + headers.keys.sorted().map { "\($0): \(headers[$0]!)" } +
                (token.map { ["Bearer Token 环境变量：\($0)"] } ?? [])).joined(separator: "\n")
        case let .sse(url, headers):
            return (["sse", url] + headers.keys.sorted().map { "\($0): \(headers[$0]!)" }).joined(separator: "\n")
        }
    }
}
