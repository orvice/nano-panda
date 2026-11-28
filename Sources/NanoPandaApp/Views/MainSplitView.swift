import NanoPandaCore
import SwiftUI

struct MainSplitView: View {
    @Bindable var state: AppState
    @AppStorage("sidebarExpanded") private var sidebarExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searching: Bool
    @State private var sidebarButtonHovered = false
    @State private var lastServerWorkspace = Destination.overview

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(WorkspaceStyle.border)
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarExpanded ? 200 : 52)
                    .clipped()
                Divider().overlay(WorkspaceStyle.border)
                switch state.destination {
                case .matrix: ToolMatrixView(state: state)
                case .tools: ToolSettingsView(state: state)
                default: serverWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.white)
        .foregroundStyle(WorkspaceStyle.ink)
        .font(WorkspaceStyle.body)
        .tint(WorkspaceStyle.blue)
        .preferredColorScheme(.light)
        .onChange(of: state.searchRequest) { _, _ in searching = true }
        .onChange(of: state.destination, initial: true) { _, destination in
            switch destination {
            case .server, .overview: lastServerWorkspace = destination ?? .overview
            default: break
            }
        }
        .sheet(item: $state.sheet) { sheet in
            switch sheet {
            case .new: ServerEditorView(state: state, server: nil).frame(width: 720, height: 680)
            case .paste: PasteSheet(state: state)
            case .scan:
                if let discovery = state.discovery { ImportWizardSheet(state: state, discovery: discovery) }
            case .sync: SyncPreviewSheet(state: state, initialPlan: state.preview(.managed))
            case .path: ToolPathSheet(state: state, tool: state.editingTool)
            case .restore:
                if let preview = state.restorePlan { RestoreSheet(state: state, preview: preview) }
            case .inspect: ToolInspectSheet(state: state, tool: state.editingTool)
            case .importArchive: ArchiveImportSheet(state: state)
            case .exportArchive: ArchiveExportSheet(state: state)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { state.failure != nil }, set: { if !$0 { state.failure = nil } }
        )) {
            Button("好") { state.failure = nil }
        } message: {
            Text(state.failure ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    sidebarExpanded.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(sidebarExpanded ? WorkspaceStyle.secondary : WorkspaceStyle.blue)
                    .frame(width: 32, height: 32)
                    .background(
                        sidebarExpanded ? (sidebarButtonHovered ? WorkspaceStyle.neutral : .clear) : WorkspaceStyle.blueTint,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { sidebarButtonHovered = $0 }
            .help(sidebarExpanded ? "折叠侧栏" : "展开侧栏")
            .accessibilityLabel(sidebarExpanded ? "折叠侧栏" : "展开侧栏")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceStyle.muted)
                TextField("搜索 MCP 或标签", text: $state.search)
                    .textFieldStyle(.plain).focused($searching)
                    .onChange(of: state.search) { _, search in
                        guard !search.isEmpty else { return }
                        if state.destination == .matrix || state.destination == .tools { state.destination = .overview }
                    }
                if state.search.isEmpty {
                    FormatBadge(label: "⌘K").accessibilityHidden(true)
                } else {
                    Button("清除搜索", systemImage: "xmark.circle.fill") { state.search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(WorkspaceStyle.muted)
                }
            }
            .padding(.horizontal, 9).frame(height: 32).frame(maxWidth: 380)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(searching ? WorkspaceStyle.blue : WorkspaceStyle.border) }
            Spacer(minLength: 12)
            Button("扫描导入", systemImage: "dot.radiowaves.left.and.right", action: state.scan)
                .buttonStyle(WorkspaceButton())
            Button("新建 MCP", systemImage: "plus", action: state.newServer)
                .buttonStyle(WorkspaceButton())
            Menu {
                Button("导入配置文件…", action: state.showArchiveImport)
                Button("导出 MCP 配置…", action: state.showArchiveExport)
                    .disabled(state.servers.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .frame(width: 28, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("导入或导出 MCP 配置")
            .accessibilityLabel("导入和导出")
            .disabled(!state.canEdit)
            Button(action: state.preview) {
                HStack(spacing: 7) {
                    Label("同步变更", systemImage: "arrow.triangle.2.circlepath")
                    if !state.pendingTools.isEmpty {
                        Text(state.pendingTools.count, format: .number)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(WorkspaceStyle.blue)
                            .frame(minWidth: 19, minHeight: 19)
                            .background(.white, in: Capsule())
                    }
                }
            }
            .buttonStyle(WorkspaceButton(kind: .primary))
        }
        .padding(.leading, 90)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(WorkspaceStyle.sidebar)
    }

    private var sidebar: some View {
        VStack(alignment: sidebarExpanded ? .leading : .center, spacing: 16) {
            HStack(spacing: 9) {
                PandaMark()
                if sidebarExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nano Panda").font(WorkspaceStyle.title)
                        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                            Text("v" + version).font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.muted)
                        }
                    }
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, sidebarExpanded ? 6 : 0)
            .frame(height: 36)
            VStack(alignment: .leading, spacing: 4) {
                if sidebarExpanded { sidebarHeading("工作区").transition(.opacity) }
                navigation("MCP 服务", icon: "server.rack", active: state.destination != .matrix && state.destination != .tools,
                           count: state.servers.count, action: showServerWorkspace)
                navigation("工具矩阵", icon: "square.grid.2x2", active: state.destination == .matrix) {
                    state.destination = .matrix
                }
                navigation("Agent 工具", icon: "cable.connector", active: state.destination == .tools,
                           count: ToolID.allCases.count) { state.destination = .tools }
            }
            if sidebarExpanded {
                sidebarStatus.transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, sidebarExpanded ? 12 : 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sidebarExpanded ? .topLeading : .top)
        .background(WorkspaceStyle.sidebar)
    }

    private var sidebarStatus: some View {
        Group {
            Divider().overlay(WorkspaceStyle.border)
            VStack(alignment: .leading, spacing: 9) {
                sidebarHeading("同步状态")
                ForEach(ToolID.workspaceOrder) { tool in
                    if let change = state.plan.tools.first(where: { $0.tool == tool }),
                       change.status != .missing || change.hasChanges {
                        Button {
                            state.inspect(tool)
                        } label: {
                            HStack {
                                Text(tool.title).lineLimit(1)
                                Spacer(minLength: 4)
                                WorkspaceStatus(status: change.hasChanges && change.status == .missing ? .pending : change.status, filled: false)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
                if state.plan.tools.allSatisfy({ $0.status == .missing && !$0.hasChanges }) {
                    Text("尚无配置文件").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
            Divider().overlay(WorkspaceStyle.border)
            Label("自动备份已启用", systemImage: "checkmark.shield")
                .font(WorkspaceStyle.small)
                .foregroundStyle(WorkspaceStyle.greenInk)
                .padding(.horizontal, 8)
        }
    }

    private func showServerWorkspace() {
        guard state.destination == .matrix || state.destination == .tools else { return }
        if case let .server(id) = lastServerWorkspace, state.servers.contains(where: { $0.id == id }) {
            state.destination = lastServerWorkspace
        } else {
            state.destination = state.servers.first.map { .server($0.id) } ?? .overview
        }
    }

    private func sidebarHeading(_ label: String) -> some View {
        Text(label).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 8).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func navigation(
        _ label: String, icon: String, active: Bool, count: Int? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: sidebarExpanded ? 13 : 15, weight: active ? .semibold : .medium))
                    .frame(width: 16)
                if sidebarExpanded {
                    Text(label).lineLimit(1)
                    Spacer(minLength: 0)
                    if let count {
                        Text(count, format: .number)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(active ? .white : WorkspaceStyle.neutral, in: Capsule())
                    }
                }
            }
            .font(.system(size: 13, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? WorkspaceStyle.blue : WorkspaceStyle.secondary)
            .padding(.horizontal, sidebarExpanded ? 8 : 0)
            .frame(width: sidebarExpanded ? nil : 36, height: 36)
            .background(active ? WorkspaceStyle.blueTint : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(count.map { String($0) } ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(label)
    }

    private var serverWorkspace: some View {
        HStack(spacing: 0) {
            ServerListView(state: state).frame(width: 280)
            Divider().overlay(WorkspaceStyle.border)
            if case let .server(id) = state.destination,
               let server = state.servers.first(where: { $0.id == id }) {
                ServerEditorView(state: state, server: server).id(server.updatedAt).id(id)
            } else {
                ContentUnavailableView {
                    Label(state.servers.isEmpty ? "添加第一个 MCP" : "选择一个 MCP", systemImage: "server.rack")
                } description: {
                    Text(state.servers.isEmpty ? "扫描现有配置，或手动新建 MCP。" : "从列表选择条目以编辑配置。")
                } actions: {
                    if state.servers.isEmpty {
                        Button("扫描导入", action: state.scan).buttonStyle(WorkspaceButton(kind: .primary))
                        Button("粘贴 JSON", action: state.paste).buttonStyle(WorkspaceButton())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
