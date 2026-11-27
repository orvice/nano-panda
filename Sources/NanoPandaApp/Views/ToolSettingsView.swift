import AppKit
import NanoPandaCore
import SwiftUI

struct ToolSettingsView: View {
    let state: AppState

    private var installed: Set<ToolID> {
        Set(ToolID.workspaceOrder.filter { ToolInstallation.detected($0, home: state.engine.home) })
    }

    var body: some View {
        let installed = installed
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Agent 工具与备份").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                        Text("查看本机配置、同步状态与写入前的自动备份。")
                            .foregroundStyle(WorkspaceStyle.muted)
                    }
                    Spacer()
                    Button("重新扫描配置", systemImage: "arrow.clockwise", action: state.refresh)
                        .buttonStyle(WorkspaceButton())
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("检测到的工具").font(WorkspaceStyle.section).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(installed.count) / \(ToolID.allCases.count) 已安装")
                            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted).monospacedDigit()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 2), spacing: 16) {
                        ForEach(ToolID.workspaceOrder) { tool in
                            if let change = state.plan.tools.first(where: { $0.tool == tool }) {
                                toolCard(change, isInstalled: installed.contains(tool))
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("最近的自动备份").font(WorkspaceStyle.section).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text(shortPath(state.engine.store.directory.appendingPathComponent("backups").path))
                            .font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let issue = state.backupIssue {
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(WorkspaceStyle.amberInk)
                    }
                    backupTable
                }
            }
            .padding(32).frame(maxWidth: 1260)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolCard(_ change: ToolChange, isInstalled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text(change.tool.title).font(WorkspaceStyle.title).lineLimit(1)
                FormatBadge(label: change.tool.formatLabel)
                Spacer(minLength: 0)
                WorkspaceStatus(status: change.status)
            }
            HStack(spacing: 8) {
                Text(shortPath(change.path.path))
                    .font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.secondary)
                    .lineLimit(1).truncationMode(.middle).help(change.path.path)
                Spacer(minLength: 0)
                Button("在访达显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([change.path])
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .foregroundStyle(WorkspaceStyle.muted)
                .disabled(!FileManager.default.fileExists(atPath: change.path.path))
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceStyle.border) }
            HStack(spacing: 5) {
                Text("\(change.configuredIDs.count) 个 MCP")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
                    .help(isInstalled ? "已找到应用或命令" : "未在常用位置找到应用或命令")
                Spacer(minLength: 0)
                Button("更改路径") { state.choosePath(change.tool) }
                    .buttonStyle(WorkspaceButton(kind: .quiet))
                Button("检查") { state.inspect(change.tool) }
                    .buttonStyle(WorkspaceButton())
            }
        }
        .workspaceCard()
    }

    private var backupTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("时间")
                Text("工具")
                Text("文件")
                Text("触发原因")
                Text("操作").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkspaceStyle.muted)
            .padding(10).background(WorkspaceStyle.inset)
            Divider().overlay(WorkspaceStyle.border).gridCellUnsizedAxes(.horizontal)
            if state.snapshots.isEmpty {
                Text("暂无备份").foregroundStyle(WorkspaceStyle.muted).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridCellColumns(5)
            }
            ForEach(state.snapshots) { snapshot in
                GridRow {
                    Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit().lineLimit(1)
                    Text(snapshot.tool.title).lineLimit(1)
                    Text(URL(fileURLWithPath: snapshot.originalPath).lastPathComponent)
                        .font(WorkspaceStyle.mono).lineLimit(1).truncationMode(.middle).help(snapshot.originalPath)
                    Text(trigger(snapshot))
                        .foregroundStyle(WorkspaceStyle.secondary)
                    Button("预览与恢复") { state.startRestore(snapshot) }
                        .buttonStyle(WorkspaceButton())
                }
                .font(WorkspaceStyle.small)
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider().overlay(WorkspaceStyle.border).gridCellUnsizedAxes(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border) }
    }

    private func shortPath(_ path: String) -> String {
        let home = state.engine.home.path
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    private func trigger(_ snapshot: BackupSnapshot) -> String {
        switch snapshot.trigger {
        case .sync: return "同步前"
        case .restore: return "恢复前"
        case nil: return "写入前"
        }
    }
}

struct ToolInspectSheet: View {
    let state: AppState
    let tool: ToolID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tool.title).font(WorkspaceStyle.headline)
                FormatBadge(label: tool.formatLabel)
                Spacer()
                if let change { WorkspaceStatus(status: change.status) }
            }
            if let change {
                Text(change.path.path).textSelection(.enabled).workspaceField()
                if let error = change.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(WorkspaceStyle.red)
                }
                ForEach(Array(change.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(WorkspaceStyle.amberInk)
                }
                Text("已配置的 MCP").font(WorkspaceStyle.title)
                if change.configuredIDs.isEmpty {
                    Text("此配置没有可列出的 MCP。").foregroundStyle(WorkspaceStyle.muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(change.configuredIDs.sorted(), id: \.self) { name in
                                Text(name).font(WorkspaceStyle.mono).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("完成") { state.sheet = nil }.buttonStyle(WorkspaceButton(kind: .primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 530, height: 340)
    }

    private var change: ToolChange? { state.plan.tools.first { $0.tool == tool } }
}

struct ToolPathSheet: View {
    let state: AppState
    let tool: ToolID
    @State private var path: String

    init(state: AppState, tool: ToolID) {
        self.state = state
        self.tool = tool
        _path = State(initialValue: state.registry.customPaths[tool] ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("\(tool.title) 配置路径").font(.title2.bold())
            TextField("自定义路径", text: $path, prompt: Text("留空使用默认路径"))
            HStack {
                Button("选择文件…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
                Spacer()
                Button("取消") { state.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("保存") { state.savePath(path, for: tool) }
                    .buttonStyle(WorkspaceButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 510)
    }
}

struct RestoreSheet: View {
    let state: AppState
    let preview: RestorePlan
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("恢复 \(preview.snapshot.tool.title) 配置").font(.title2.bold())
            Text(preview.snapshot.originalPath).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            if !preview.snapshot.existed {
                Label("此快照记录的是文件尚未创建，恢复将移除当前文件。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            DiffView(diff: preview.diff).border(.quaternary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { state.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("恢复此备份") {
                    do { try state.restore(preview) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(WorkspaceButton(kind: .primary)).disabled(!preview.hasChanges)
            }
        }.padding(20).frame(width: 690, height: 480)
    }
}
