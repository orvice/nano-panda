import AppKit
import NanoPandaCore
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveExportSheet: View {
    let state: AppState
    @State private var selected: Set<String>
    @State private var protection = MCPArchive.Protection.password
    @State private var credential = ""
    @State private var repeatedPassword = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    init(state: AppState) {
        self.state = state
        _selected = State(initialValue: Set(state.servers.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出 MCP 配置").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
            ArchiveServerList(servers: state.servers, selected: $selected)
            Picker("文件保护", selection: $protection) {
                Text("密码").tag(MCPArchive.Protection.password)
                Text("密钥").tag(MCPArchive.Protection.key)
                Text("明文").tag(MCPArchive.Protection.plaintext)
            }
            .pickerStyle(.segmented)
            .onChange(of: protection) { _, _ in
                credential = ""
                repeatedPassword = ""
                copied = false
                error = nil
            }

            switch protection {
            case .password:
                SecureField("导出密码（至少 12 个字符）", text: $credential)
                    .textFieldStyle(.plain).workspaceField()
                SecureField("再次输入密码", text: $repeatedPassword)
                    .textFieldStyle(.plain).workspaceField()
            case .key:
                SecureField("32 字节 Base64 密钥", text: $credential)
                    .textFieldStyle(.plain).workspaceField()
                    .onChange(of: credential) { _, _ in copied = false }
                HStack {
                    Button("生成密钥", action: generateKey).buttonStyle(WorkspaceButton())
                    Button("复制密钥", action: copyKey).buttonStyle(WorkspaceButton())
                        .disabled(credential.isEmpty)
                    if copied {
                        Text("已复制").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
                    }
                }
                Text("请单独保存密钥，导入时需要同一把密钥。")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
            case .plaintext:
                Label("明文文件可直接读取其中的环境变量和请求头。", systemImage: "exclamationmark.triangle")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
            }

            if let error { ArchiveErrorLabel(message: error) }
            HStack {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("正在导出") }
                Spacer()
                Button("取消") { state.sheet = nil }
                    .buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                Button("导出…", action: export)
                    .buttonStyle(WorkspaceButton(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || (protection != .plaintext && credential.isEmpty))
            }
        }
        .padding(24).frame(width: 560)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
    }

    private func generateKey() {
        do {
            credential = try MCPArchive.generateKey()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copyKey() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(credential, forType: .string)
    }

    private func export() {
        error = nil
        if protection == .password {
            guard credential.count >= 12 else {
                error = "导出密码至少需要 12 个字符。"
                return
            }
            guard credential == repeatedPassword else {
                error = "两次输入的密码不同。"
                return
            }
        }
        let entries = state.servers.filter { selected.contains($0.id) }
        let mode = protection
        let secret = credential
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = mode == .plaintext ? "NanoPanda-MCP.json" : "NanoPanda-MCP.encrypted.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try state.validateArchiveDestination(url) }
        catch {
            self.error = error.localizedDescription
            return
        }

        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MCPArchive.export(entries, protection: mode, credential: secret, to: url)
                }.value
                credential = ""
                repeatedPassword = ""
                state.sheet = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ArchiveImportSheet: View {
    let state: AppState
    @State private var choosingFile = false
    @State private var archive: MCPArchive?
    @State private var filename: String?
    @State private var credential = ""
    @State private var servers: [MCPServer] = []
    @State private var selected: Set<String> = []
    @State private var conflicts = MCPArchive.ConflictPolicy.skip
    @State private var busy = false
    @State private var error: String?

    private var duplicateIDs: Set<String> {
        Set(state.registry.servers.map(\.id)).intersection(servers.map(\.id))
    }

    private var importCount: Int {
        conflicts == .replace ? selected.count : selected.subtracting(duplicateIDs).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入 MCP 配置").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
            HStack {
                if let filename {
                    Label(filename, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("选择从 Nano Panda 导出的配置文件。").foregroundStyle(WorkspaceStyle.secondary)
                }
                Spacer()
                Button(filename == nil ? "选择文件…" : "更换文件…") { choosingFile = true }
                    .buttonStyle(WorkspaceButton())
            }

            if let archive, archive.protection != .plaintext && servers.isEmpty {
                SecureField(archive.protection == .password ? "归档密码" : "Base64 密钥", text: $credential)
                    .textFieldStyle(.plain).workspaceField()
            }

            if !servers.isEmpty {
                ArchiveServerList(servers: servers, selected: $selected, duplicateIDs: duplicateIDs)
                if !duplicateIDs.isEmpty {
                    Picker("同名条目", selection: $conflicts) {
                        Text("保留现有条目").tag(MCPArchive.ConflictPolicy.skip)
                        Text("用归档替换").tag(MCPArchive.ConflictPolicy.replace)
                    }
                    .pickerStyle(.segmented)
                    if conflicts == .replace {
                        Text("替换时会使用归档里的内容和工具分配。")
                            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
                    }
                }
                Text("导入后，可在同步预览中审核将写入 Agent 工具的变更。")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
            }

            if let error { ArchiveErrorLabel(message: error) }
            HStack {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("正在读取归档") }
                Spacer()
                Button("取消") { state.sheet = nil }
                    .buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                if !servers.isEmpty {
                    Button("导入 \(importCount) 项", action: commit)
                        .buttonStyle(WorkspaceButton(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(importCount == 0)
                } else if archive != nil {
                    Button("解密并预览", action: unlock)
                        .buttonStyle(WorkspaceButton(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(credential.isEmpty)
                }
            }
        }
        .padding(24).frame(width: 560)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): read(url)
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }

    private func read(_ url: URL) {
        archive = nil
        filename = url.lastPathComponent
        credential = ""
        servers = []
        selected = []
        conflicts = .skip
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    return try MCPArchive.read(from: url)
                }.value
                archive = loaded
                if loaded.protection == .plaintext { show(try loaded.unlock()) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func unlock() {
        guard let archive else { return }
        let secret = credential
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try archive.unlock(credential: secret)
                }.value
                credential = ""
                show(entries)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func show(_ entries: [MCPServer]) {
        servers = entries.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        selected = Set(entries.map(\.id))
    }

    private func commit() {
        do { try state.importArchive(servers.filter { selected.contains($0.id) }, conflicts: conflicts) }
        catch { self.error = error.localizedDescription }
    }
}

private struct ArchiveServerList: View {
    let servers: [MCPServer]
    @Binding var selected: Set<String>
    var duplicateIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已选 \(selected.count) / \(servers.count) 项")
                    .font(WorkspaceStyle.small).monospacedDigit()
                Spacer()
                let allSelected = selected.count == servers.count
                Button(allSelected ? "取消全选" : "全选") {
                    selected = allSelected ? [] : Set(servers.map(\.id))
                }
                .buttonStyle(WorkspaceButton(kind: .quiet))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(servers) { server in
                        HStack {
                            Toggle(server.id, isOn: Binding(
                                get: { selected.contains(server.id) },
                                set: { enabled in
                                    if enabled { selected.insert(server.id) }
                                    else { selected.remove(server.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            Spacer()
                            if duplicateIDs.contains(server.id) {
                                Text("同名").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
                            }
                            FormatBadge(label: server.transport.formatLabel)
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: min(180, CGFloat(servers.count * 31 + 20)))
            .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceStyle.border) }
        }
    }
}

private struct ArchiveErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.red)
    }
}
