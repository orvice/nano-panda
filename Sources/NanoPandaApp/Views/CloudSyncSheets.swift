import NanoPandaCore
import SwiftUI

struct CloudConflictSheet: View {
    let state: AppState
    let preview: CloudConflictPreview
    @State private var choices: [String: CloudConflictChoice] = [:]
    @State private var selectionError: String?

    private var cloud: CloudWorkspaceState { state.cloud }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("解决云端同步冲突").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                    Text("\(preview.conflicts.count) 项冲突").font(WorkspaceStyle.small)
                        .foregroundStyle(WorkspaceStyle.amberInk)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(WorkspaceStyle.amberTint, in: Capsule())
                }
                Text("这些 MCP 条目在本地与远端均发生了变更。请选择每项应保留的版本。")
                    .foregroundStyle(WorkspaceStyle.secondary)
                HStack(spacing: 8) {
                    Text("批量选择").font(WorkspaceStyle.title)
                    Spacer()
                    Button("全部保留本地") { chooseAll(.local) }.buttonStyle(WorkspaceButton())
                    Button("全部采用远端") { chooseAll(.remote) }.buttonStyle(WorkspaceButton())
                }
                .workspaceCard(padding: 10)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider().overlay(WorkspaceStyle.border)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(preview.conflicts, id: \.id) { conflict in
                        conflictCard(conflict)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            }
            .background(WorkspaceStyle.inset)
            Divider().overlay(WorkspaceStyle.border)
            VStack(alignment: .leading, spacing: 8) {
                if let error = selectionError ?? cloud.syncError { CloudErrorLabel(message: error) }
                Label("应用后只更新中央配置库。要写入本机 Agent，请使用「同步变更」。",
                      systemImage: "info.circle")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
                HStack {
                    if cloud.isSyncing { CloudProgressLabel(title: "正在完成云端同步") }
                    Spacer()
                    Button("取消") { state.sheet = nil }
                        .buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                    Button("应用选择并完成同步", action: submit)
                        .buttonStyle(WorkspaceButton(kind: .primary)).keyboardShortcut(.defaultAction)
                        .disabled(choices.count != preview.conflicts.count)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 760, height: 640)
        .background(.white)
        .disabled(cloud.isWorking)
        .interactiveDismissDisabled(cloud.isWorking)
    }

    private func conflictCard(_ conflict: CloudConflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(conflict.id).font(WorkspaceStyle.title).textSelection(.enabled)
                if let server = conflict.local ?? conflict.remote { FormatBadge(label: server.transport.formatLabel) }
                Spacer()
                Text(conflictLabel(conflict)).font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
            }
            CloudEntryComparison(
                left: conflict.local, right: conflict.remote,
                leftTitle: "本地版本", rightTitle: "远端版本"
            )
            HStack {
                Text("保留版本").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
                Spacer()
                WorkspaceSegments(options: [CloudConflictChoice?.some(.local), .some(.remote)], selection: Binding(
                    get: { choices[conflict.id] },
                    set: { choices[conflict.id] = $0 }
                )) { (option: CloudConflictChoice?) in
                    option == .local ? (conflict.local == nil ? "保留本地删除" : "保留本地") :
                        (conflict.remote == nil ? "采用远端删除" : "采用远端")
                }
                .accessibilityLabel("为 \(conflict.id) 选择版本")
            }
        }
        .workspaceCard()
    }

    private func conflictLabel(_ conflict: CloudConflict) -> String {
        if conflict.local == nil { return "本地已删除" }
        if conflict.remote == nil { return "远端已删除" }
        return conflict.base == nil ? "新增同名条目" : "双方均有修改"
    }

    private func chooseAll(_ choice: CloudConflictChoice) {
        choices = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.id, choice) })
    }

    private func submit() {
        selectionError = nil
        do {
            let resolution = try preview.resolve(choices: choices)
            Task {
                await cloud.synchronize(resolution: resolution)
                if cloud.conflict == nil { state.sheet = nil }
            }
        } catch {
            selectionError = error.localizedDescription
        }
    }
}

struct CloudSnapshotRestoreSheet: View {
    private enum Mode: CaseIterable {
        case full, selected

        var title: String {
            switch self {
            case .full: return "恢复整份快照"
            case .selected: return "恢复勾选条目"
            }
        }
    }

    let state: AppState
    let preview: CloudSnapshotPreview
    @State private var mode = Mode.full
    @State private var selected: Set<String>

    init(state: AppState, preview: CloudSnapshotPreview) {
        self.state = state
        self.preview = preview
        _selected = State(initialValue: Set(preview.changes.filter {
            $0.target != nil && $0.kind != .unchanged
        }.map(\.id)))
    }

    private var cloud: CloudWorkspaceState { state.cloud }
    private var selectable: Set<String> {
        Set(preview.changes.filter { $0.target != nil && $0.kind != .unchanged }.map(\.id))
    }
    private var hasFullRestoreChanges: Bool {
        preview.changes.contains { $0.kind != .unchanged } || !preview.remoteChanges.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WorkspaceStyle.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if mode == .full && !preview.remoteChanges.isEmpty {
                        restoreSectionTitle("本机中央配置库")
                    }
                    ForEach(preview.changes, id: \.id) { change in
                        changeRow(change)
                        Divider().overlay(WorkspaceStyle.border)
                    }
                    if mode == .full && !preview.remoteChanges.isEmpty {
                        restoreSectionTitle("远端中央配置库")
                        ForEach(preview.remoteChanges, id: \.id) { change in
                            changeRow(change, remote: true)
                            Divider().overlay(WorkspaceStyle.border)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .background(.white)
            Divider().overlay(WorkspaceStyle.border)
            footer
        }
        .frame(width: 680, height: 560)
        .background(.white)
        .disabled(cloud.isWorking)
        .interactiveDismissDisabled(cloud.isWorking)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预览与恢复远端版本快照").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 8) {
                Label(preview.snapshot.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if let note = preview.snapshot.note { Text(note).lineLimit(2) }
                Text("\(preview.snapshot.serverCount) 项")
                Spacer(minLength: 0)
            }
            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
            WorkspaceSegments(options: Mode.allCases, selection: $mode, equalWidth: true, title: \.title)
                .accessibilityLabel("恢复范围")
            HStack(spacing: 8) {
                countBadge("+\(preview.changes.filter { $0.kind == .added }.count) 新增", background: WorkspaceStyle.greenTint, ink: WorkspaceStyle.greenInk)
                countBadge("~\(preview.changes.filter { $0.kind == .modified }.count) 修改", background: WorkspaceStyle.blueTint, ink: WorkspaceStyle.blue)
                if mode == .full {
                    countBadge("−\(preview.changes.filter { $0.kind == .deleted }.count) 移除", background: WorkspaceStyle.redTint, ink: WorkspaceStyle.red)
                }
                Spacer()
                if mode == .selected {
                    Button(selected == selectable ? "取消全选" : "全选") {
                        selected = selected == selectable ? [] : selectable
                    }
                    .buttonStyle(WorkspaceButton())
                    .disabled(selectable.isEmpty)
                }
            }
            .frame(minHeight: 32)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func restoreSectionTitle(_ title: String) -> some View {
        Text(title).font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
            .padding(.top, 12).padding(.bottom, 4)
    }

    private func changeRow(_ change: CloudSnapshotChange, remote: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if mode == .selected {
                Toggle(isOn: Binding(
                    get: { selected.contains(change.id) },
                    set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } }
                )) {
                    Text("恢复 \(change.id)")
                }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!selectable.contains(change.id))
                .padding(.top, 2)
            }
            DisclosureGroup {
                CloudEntryComparison(
                    left: change.current, right: change.target,
                    leftTitle: remote ? "当前远端中央配置库" : "当前本机中央配置库", rightTitle: "快照版本"
                )
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text(change.id).font(WorkspaceStyle.title)
                    if let entry = change.target ?? change.current { FormatBadge(label: entry.transport.formatLabel) }
                    Spacer()
                    switch change.kind {
                    case .added: countBadge("新增", background: WorkspaceStyle.greenTint, ink: WorkspaceStyle.greenInk)
                    case .modified: countBadge("配置不同", background: WorkspaceStyle.blueTint, ink: WorkspaceStyle.blue)
                    case .deleted:
                        if mode == .full {
                            countBadge("将移除", background: WorkspaceStyle.redTint, ink: WorkspaceStyle.red)
                        } else {
                            countBadge("快照中无此项", background: WorkspaceStyle.neutral, ink: WorkspaceStyle.secondary)
                        }
                    case .unchanged: countBadge("一致", background: WorkspaceStyle.neutral, ink: WorkspaceStyle.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = cloud.snapshotError { CloudErrorLabel(message: error) }
            Label("恢复前会备份本机中央配置库。恢复结果会作为新变更同步到远端，写入 Agent 需经同步预览确认。",
                  systemImage: "shield")
                .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
            HStack {
                if cloud.isSyncing { CloudProgressLabel(title: "正在恢复并同步") }
                Spacer()
                Button("取消") { state.sheet = nil }
                    .buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                Button(mode == .full ? "恢复整份快照" : "恢复所选 \(selected.count) 项", action: submit)
                    .buttonStyle(WorkspaceButton(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(mode == .full ? !hasFullRestoreChanges : selected.isEmpty)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func countBadge(_ label: String, background: Color, ink: Color) -> some View {
        Text(label).font(WorkspaceStyle.small).monospacedDigit().foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(background, in: Capsule())
    }

    private func submit() {
        let ids = mode == .full ? nil : selected
        Task {
            if await cloud.restoreSnapshot(preview, selectedIDs: ids) {
                state.sheet = nil
            }
        }
    }
}

struct CloudSnapshotCreateSheet: View {
    let state: AppState
    @State private var note = ""
    @State private var submitted = false

    private var cloud: CloudWorkspaceState { state.cloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("创建远端版本快照").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
            Text("加密备份当前中央配置库中的 \(state.servers.count) 个 MCP 条目。")
                .foregroundStyle(WorkspaceStyle.secondary)
            TextField("备注（可选）", text: $note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.plain).workspaceField()
            if submitted, let message = cloud.snapshotError { CloudErrorLabel(message: message) }
            HStack {
                if cloud.operation == .snapshots { CloudProgressLabel(title: "正在创建快照") }
                Spacer()
                Button("取消") { state.sheet = nil }
                    .buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                Button("创建快照", action: create)
                    .buttonStyle(WorkspaceButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
        .background(.white)
        .disabled(cloud.isWorking)
        .interactiveDismissDisabled(cloud.isWorking)
    }

    private func create() {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = true
        Task {
            if await cloud.createSnapshot(note: value.isEmpty ? nil : value) {
                state.sheet = nil
            }
        }
    }
}

private struct CloudEntryComparison: View {
    let left: MCPServer?
    let right: MCPServer?
    let leftTitle: String
    let rightTitle: String
    @State private var revealSecrets = false

    private struct Field {
        var title: String
        var value: String
        var masked: String?
    }

    var body: some View {
        let leftFields = fields(left)
        let rightFields = fields(right)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                panel(leftTitle, entry: left, fields: leftFields, otherFields: rightFields)
                panel(rightTitle, entry: right, fields: rightFields, otherFields: leftFields)
            }
            if (leftFields + rightFields).contains(where: { $0.masked != nil }) {
                Toggle("显示凭据与工具覆盖值", isOn: $revealSecrets)
                    .toggleStyle(.checkbox).font(WorkspaceStyle.small)
            }
        }
    }

    private func panel(_ title: String, entry: MCPServer?, fields: [Field], otherFields: [Field]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(WorkspaceStyle.title)
            if let entry {
                Text(entry.updatedAt, format: .dateTime.month().day().hour().minute())
                    .font(WorkspaceStyle.small).monospacedDigit().foregroundStyle(WorkspaceStyle.muted)
                ForEach(fields, id: \.title) { field in
                    let changed = otherFields.first { $0.title == field.title }?.value != field.value
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.title).font(WorkspaceStyle.small)
                            .foregroundStyle(changed ? WorkspaceStyle.blue : WorkspaceStyle.muted)
                        Text(revealSecrets ? field.value : field.masked ?? field.value)
                            .font(WorkspaceStyle.mono)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Label("无此条目", systemImage: "minus.circle")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceStyle.border) }
    }

    private func fields(_ entry: MCPServer?) -> [Field] {
        guard let entry else { return [] }
        var fields = [Field(title: "传输", value: entry.transport.formatLabel)]
        switch entry.transport {
        case let .stdio(command, args, environment):
            fields.append(Field(title: "命令", value: command))
            if !args.isEmpty { fields.append(secretField("参数", value: json(args), masked: "\(args.count) 个参数")) }
            if !environment.isEmpty { fields.append(secretMap("环境变量", environment)) }
        case let .http(url, headers, token):
            fields.append(Field(title: "URL", value: url))
            if !headers.isEmpty { fields.append(secretMap("请求头", headers)) }
            if let token { fields.append(Field(title: "Bearer Token 环境变量", value: token)) }
        case let .sse(url, headers):
            fields.append(Field(title: "URL", value: url))
            if !headers.isEmpty { fields.append(secretMap("请求头", headers)) }
        }
        let toolNames = ToolID.workspaceOrder.filter(entry.enabledTools.contains).map(\.title)
        fields.append(Field(title: "工具分配", value: toolNames.isEmpty ? "无" : toolNames.joined(separator: "、")))
        if !entry.tags.isEmpty { fields.append(Field(title: "标签", value: entry.tags.joined(separator: "、"))) }
        if let notes = entry.notes { fields.append(Field(title: "备注", value: notes)) }
        for tool in ToolID.workspaceOrder {
            if let override = entry.perToolOverrides[tool] {
                let names = override.fields.keys.sorted().joined(separator: "、")
                fields.append(secretField("\(tool.title) 工具覆盖", value: json(override.fields), masked: names))
            }
        }
        return fields
    }

    private func secretMap(_ title: String, _ values: [String: String]) -> Field {
        let masked = values.keys.sorted().map { "\($0) = ••••••" }.joined(separator: "\n")
        return secretField(title, value: json(values), masked: masked)
    }

    private func secretField(_ title: String, value: String, masked: String) -> Field {
        Field(title: title, value: value, masked: masked)
    }

    private func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "无法显示值" }
        return String(decoding: data, as: UTF8.self)
    }
}
