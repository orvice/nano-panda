import NanoPandaCore
import SwiftUI

struct ToolMatrixView: View {
    private enum Filter: String, CaseIterable {
        case all = "全部工具", installed = "仅已安装", pending = "有待同步变更"
    }

    let state: AppState
    @State private var filter = Filter.all

    private var tools: [ToolID] {
        switch filter {
        case .installed:
            return ToolID.workspaceOrder.filter { ToolInstallation.detected($0, home: state.engine.home) }
        case .all, .pending:
            return ToolID.workspaceOrder
        }
    }

    private var servers: [MCPServer] {
        filter == .pending ? state.servers.filter(state.hasPendingChanges) : state.servers
    }

    private var pendingTools: [ToolID] {
        let pending = Set(state.plan.tools.filter { $0.hasChanges || $0.status == .drift }.map(\.tool))
        return ToolID.workspaceOrder.filter { tool in
            pending.contains(tool) || state.matrixEdits.keys.contains { $0.tool == tool }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MCP × Agent 工具矩阵").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                    Text("选择每个 MCP 服务要同步到哪些工具的全局配置。")
                        .foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 0)
                WorkspaceSegments(options: Filter.allCases, selection: $filter) { $0.rawValue }
            }
            .padding(24)
            if tools.isEmpty {
                ContentUnavailableView("没有检测到已安装工具", systemImage: "cable.connector")
                    .frame(maxHeight: .infinity)
            } else if servers.isEmpty {
                ContentUnavailableView(
                    state.servers.isEmpty ? "暂无 MCP" : "没有待同步的 MCP",
                    systemImage: "square.grid.2x2"
                )
                .frame(maxHeight: .infinity)
            } else {
                matrix
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var matrix: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("MCP 服务").font(WorkspaceStyle.title)
                        .frame(width: 160, height: 57, alignment: .leading)
                        .padding(.horizontal, 14)
                    ForEach(tools) { tool in
                        Menu {
                            Button("为全部 MCP 启用") {
                                for server in servers { state.stage(server, in: tool, enabled: true) }
                            }
                            Button("为全部 MCP 停用") {
                                for server in servers { state.stage(server, in: tool, enabled: false) }
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(tool.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                FormatBadge(label: tool.formatLabel)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(minWidth: 88, maxWidth: .infinity, minHeight: 57)
                        .help("批量修改 \(tool.title) 的工具分配")
                    }
                }
                .background(WorkspaceStyle.inset)
                Divider().overlay(WorkspaceStyle.border).gridCellUnsizedAxes(.horizontal)
                ForEach(servers) { server in
                    GridRow {
                        HStack(spacing: 7) {
                            Text(server.id).font(WorkspaceStyle.title).lineLimit(1)
                            Spacer(minLength: 0)
                            FormatBadge(label: server.transport.formatLabel)
                            if state.hasPendingChanges(server) {
                                Circle().fill(WorkspaceStyle.amber).frame(width: 6, height: 6).accessibilityLabel("待同步")
                            }
                        }
                        .frame(width: 160)
                        .padding(.horizontal, 14)
                        ForEach(tools) { tool in
                            HStack(spacing: 4) {
                                Toggle(isOn: Binding(
                                    get: { state.enabled(server, in: tool) },
                                    set: { state.stage(server, in: tool, enabled: $0) }
                                )) { Text("\(server.id) · \(tool.title)") }
                                .toggleStyle(.checkbox).labelsHidden()
                                .disabled(!state.canEdit)
                                if server.transport.isRemote && tool == .claudeDesktop {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.amberInk)
                                        .help("Claude Desktop 的本地配置可能无法启动远程 MCP。")
                                }
                            }
                            .frame(minWidth: 88, maxWidth: .infinity, minHeight: 48)
                        }
                    }
                    .background(state.hasPendingChanges(server) ? WorkspaceStyle.amberTint.opacity(0.28) : .white)
                    Divider().overlay(WorkspaceStyle.border).gridCellUnsizedAxes(.horizontal)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border) }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Label { Text("待同步变更或外部修改") } icon: {
                    Circle().fill(WorkspaceStyle.amber).frame(width: 7, height: 7)
                }
                Label("Claude Desktop 的远程传输可能不受支持", systemImage: "exclamationmark.triangle")
            }
            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
            .padding(.horizontal, 24).padding(.bottom, 12)
            Divider().overlay(WorkspaceStyle.border)
            HStack(spacing: 8) {
                Text(pendingTools.isEmpty ? "没有待同步变更" : pendingTools.map(\.title).joined(separator: "、") + " 有待处理变更")
                    .lineLimit(1)
                    .foregroundStyle(WorkspaceStyle.secondary)
                Spacer()
                Button("丢弃") { state.matrixEdits.removeAll() }
                    .buttonStyle(WorkspaceButton()).disabled(state.matrixEdits.isEmpty)
                Button("查看差异并同步", systemImage: "doc.text.magnifyingglass", action: state.reviewMatrix)
                    .buttonStyle(WorkspaceButton(kind: .primary))
                    .disabled(!state.canEdit)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(WorkspaceStyle.sidebar)
        }
    }
}
