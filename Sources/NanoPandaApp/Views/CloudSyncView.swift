import AppKit
import NanoPandaCore
import SwiftUI

private struct CloudConfigurationDraft: Equatable {
    enum Provider: String, CaseIterable {
        case s3 = "S3 兼容服务"
        case webDAV = "WebDAV"
    }

    enum Protection: String, CaseIterable {
        case password = "同步密码"
        case key = "32 字节密钥"
    }

    enum Addressing: String, CaseIterable {
        case path = "Path-Style"
        case virtualHosted = "Virtual-Hosted"
    }

    var provider = Provider.s3
    var protection = Protection.password
    var addressing = Addressing.path
    var endpoint = ""
    var region = "auto"
    var bucket = ""
    var objectKey = "nano-panda.json"
    var account = ""
    var secret = ""
    var credential = ""
    var allowHTTP = false

    init(_ configuration: CloudConfiguration? = nil) {
        guard let configuration else { return }
        switch configuration.target {
        case let .s3(target):
            provider = .s3
            endpoint = target.endpoint
            region = target.region
            bucket = target.bucket
            objectKey = target.objectKey
            account = target.accessKeyID
            secret = target.secretAccessKey
            addressing = target.pathStyle ? .path : .virtualHosted
            allowHTTP = target.allowHTTP
        case let .webDAV(target):
            provider = .webDAV
            endpoint = target.endpoint
            objectKey = target.objectKey
            account = target.username
            secret = target.password
            allowHTTP = target.allowHTTP
        }
        switch configuration.encryption {
        case let .password(value):
            protection = .password
            credential = value
        case let .key(value):
            protection = .key
            credential = value
        }
    }

    func configuration(automaticSync: Bool) -> CloudConfiguration {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: CloudTarget
        switch provider {
        case .s3:
            target = .s3(S3CloudTarget(
                endpoint: endpoint, region: region, bucket: bucket, objectKey: objectKey,
                accessKeyID: account, secretAccessKey: secret, pathStyle: addressing == .path, allowHTTP: allowHTTP
            ))
        case .webDAV:
            target = .webDAV(WebDAVCloudTarget(
                endpoint: endpoint, objectKey: objectKey, username: account, password: secret, allowHTTP: allowHTTP
            ))
        }
        return CloudConfiguration(
            target: target,
            encryption: protection == .password ? .password(credential) : .key(credential),
            automaticSync: automaticSync
        )
    }
}

struct CloudSyncView: View {
    let state: AppState
    @State private var draft = CloudConfigurationDraft()
    @State private var copied = false
    @State private var keyError: String?
    @State private var confirmation: Confirmation?

    private enum Confirmation {
        case forceLocal, forceRemote, disconnect, deleteSnapshot(CloudSnapshotSummary)

        var title: String {
            switch self {
            case .forceLocal: return "强制本地覆盖远端"
            case .forceRemote: return "强制远端覆盖本地"
            case .disconnect: return "断开云端同步"
            case .deleteSnapshot: return "删除远端版本快照"
            }
        }

        var message: String {
            switch self {
            case .forceLocal: return "远端中央配置库会被本机当前条目替换。其他设备下次同步时会收到这次变更。"
            case .forceRemote: return "本机中央配置库会被远端条目替换，应用会先保留一份本机中央配置库备份。"
            case .disconnect: return "将清除本机云端配置、凭据与同步基线。本机中央配置库和远端文件会保留。"
            case let .deleteSnapshot(snapshot):
                return "将永久删除此远端版本快照（\(snapshot.date.formatted(date: .abbreviated, time: .shortened))）。"
            }
        }
    }

    private var cloud: CloudWorkspaceState { state.cloud }
    private var currentDraft: CloudConfiguration { draft.configuration(automaticSync: cloud.configuration?.automaticSync ?? false) }
    private var canOperate: Bool { cloud.canSync && state.canEdit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statusCard
                HStack(alignment: .top, spacing: 16) {
                    connectionCard
                    encryptionCard
                }
                snapshotsCard
                advancedCard
            }
            .frame(maxWidth: 1260)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { cloud.loadSnapshotsIfNeeded() }
        .onChange(of: cloud.configuration, initial: true) { old, new in
            if old == new || old?.target != new?.target || old?.encryption != new?.encryption {
                draft = CloudConfigurationDraft(new)
                cloud.loadSnapshotsIfNeeded()
            }
        }
        .onChange(of: draft) { _, _ in
            copied = false
            keyError = nil
            cloud.clearConnectionFeedback()
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { action in
            Button("取消", role: .cancel) {}
            Button(action.title, role: .destructive) { confirm(action) }
        } message: { action in
            Text(action.message)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端同步").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                Text("通过 S3 兼容服务或 WebDAV 加密同步中央配置库，并管理远端版本快照。")
                    .foregroundStyle(WorkspaceStyle.secondary)
            }
            Spacer(minLength: 0)
            Button("创建版本快照", systemImage: "archivebox") { state.sheet = .cloudCreateSnapshot }
                .buttonStyle(WorkspaceButton())
                .disabled(!canOperate)
            Button("立即同步", systemImage: "arrow.triangle.2.circlepath", action: state.syncCloudNow)
                .buttonStyle(WorkspaceButton(kind: .primary))
                .disabled(!canOperate)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                CloudStatusBadge(cloud: cloud)
                if let target = cloud.configuration?.target {
                    FormatBadge(label: providerName(target))
                    Label("AES-256-GCM", systemImage: "lock")
                        .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.blue)
                }
                Spacer(minLength: 0)
                Toggle("自动同步", isOn: Binding(
                    get: { cloud.configuration?.automaticSync ?? false },
                    set: { enabled in Task { await cloud.setAutomaticSync(enabled) } }
                ))
                .toggleStyle(.switch)
                .disabled(!canOperate)
            }
            if let summary = cloud.summary {
                Label {
                    Text("上次同步：\(summary.date.formatted(date: .abbreviated, time: .shortened)) · 新增 \(summary.added)、修改 \(summary.modified)、删除 \(summary.deleted) · \(summary.uploaded ? "已上传远端修订" : "远端无须写入")")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(WorkspaceStyle.greenInk)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            } else if cloud.configuration == nil {
                Text("保存远端连接与加密凭据后，即可开始同步。")
                    .foregroundStyle(WorkspaceStyle.secondary)
            }
            if let conflict = cloud.conflict {
                HStack {
                    Label("有 \(conflict.conflicts.count) 项冲突。自动同步已暂停，等待选择版本。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(WorkspaceStyle.amberInk)
                    Spacer()
                    Button("解决冲突", action: state.presentCloudConflicts)
                        .buttonStyle(WorkspaceButton())
                        .disabled(cloud.isWorking)
                }
                .padding(8)
                .background(WorkspaceStyle.amberTint, in: RoundedRectangle(cornerRadius: 6))
            }
            if let message = cloud.syncError { CloudErrorLabel(message: message) }
            Text("自动同步在启动、窗口回到前台和保存 MCP 条目后运行。拉取只更新中央配置库。要写入本机 Agent，请使用「同步变更」。")
                .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
        }
        .workspaceCard()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("远端存储连接").font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
            WorkspaceSegments(options: CloudConfigurationDraft.Provider.allCases, selection: Binding(
                get: { draft.provider },
                set: { provider in
                    guard draft.provider != provider else { return }
                    var replacement = CloudConfigurationDraft(cloud.configuration)
                    if replacement.provider != provider { replacement = CloudConfigurationDraft() }
                    replacement.provider = provider
                    replacement.protection = draft.protection
                    replacement.credential = draft.credential
                    draft = replacement
                }
            ), equalWidth: true) { $0.rawValue }
                .accessibilityLabel("远端存储类型")
            field(draft.provider == .s3 ? "Endpoint URL" : "WebDAV URL", text: $draft.endpoint, prompt: "https://")
            if draft.provider == .s3 {
                HStack(spacing: 12) {
                    field("Region", text: $draft.region)
                    field("Bucket", text: $draft.bucket)
                }
            }
            field(draft.provider == .s3 ? "Object Key" : "远端文件名", text: $draft.objectKey)
            field(draft.provider == .s3 ? "Access Key ID" : "用户名", text: $draft.account)
            field(draft.provider == .s3 ? "Secret Access Key" : "密码", text: $draft.secret, secure: true)
            if draft.provider == .s3 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("寻址模式").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
                    WorkspaceSegments(
                        options: CloudConfigurationDraft.Addressing.allCases, selection: $draft.addressing, equalWidth: true
                    ) { $0.rawValue }
                    .accessibilityLabel("S3 寻址模式")
                }
            }
            Toggle("允许局域网 HTTP 连接", isOn: $draft.allowHTTP)
                .help("仅在可信的局域网内开启。")
            HStack(spacing: 8) {
                Button("测试连接") { Task { await cloud.testConnection(currentDraft) } }
                    .buttonStyle(WorkspaceButton())
                Spacer(minLength: 0)
                Button("保存配置") { Task { await cloud.saveConfiguration(currentDraft) } }
                    .buttonStyle(WorkspaceButton(kind: .primary))
                    .disabled(currentDraft == cloud.configuration)
            }
            switch cloud.connectionFeedback {
            case let .passed(milliseconds):
                Label("连接正常 · \(milliseconds) ms", systemImage: "checkmark.circle.fill")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.greenInk)
                    .monospacedDigit()
            case let .failed(message): CloudErrorLabel(message: message)
            case nil: if cloud.operation == .testing { CloudProgressLabel(title: "正在测试连接") }
            }
            if let error = cloud.configurationError { CloudErrorLabel(message: error) }
        }
        .workspaceCard()
        .disabled(cloud.isWorking)
    }

    private var encryptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("端到端加密与本地安全").font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
            WorkspaceSegments(
                options: CloudConfigurationDraft.Protection.allCases,
                selection: Binding(
                    get: { draft.protection },
                    set: { protection in
                        guard draft.protection != protection else { return }
                        draft.protection = protection
                        let saved = CloudConfigurationDraft(cloud.configuration)
                        draft.credential = saved.protection == protection ? saved.credential : ""
                    }
                ), equalWidth: true
            ) { $0.rawValue }
            .accessibilityLabel("端到端加密方式")
            Text("环境变量和请求头在本机加密后上传。在其他设备上使用相同的同步密码或密钥。")
                .foregroundStyle(WorkspaceStyle.secondary)
            switch draft.protection {
            case .password:
                field("端到端加密密码（至少 12 个字符）", text: $draft.credential, secure: true)
                Text("PBKDF2-HMAC-SHA256 · 600,000 次迭代")
                    .font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.muted)
            case .key:
                field("32 字节 Base64 密钥", text: $draft.credential, secure: true)
                HStack(spacing: 8) {
                    Button("生成密钥", action: generateKey).buttonStyle(WorkspaceButton())
                    Button("复制密钥", action: copyKey).buttonStyle(WorkspaceButton())
                        .disabled(Data(base64Encoded: draft.credential)?.count != 32)
                    if copied {
                        Text("已复制").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.greenInk)
                    }
                }
                if let keyError { CloudErrorLabel(message: keyError) }
            }
            Label("认证与加密凭据仅保存在本机私有文件中，权限为 0600。", systemImage: "lock.shield")
                .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 6))
        }
        .workspaceCard()
        .disabled(cloud.isWorking)
    }

    private var snapshotsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("远端版本快照").font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
                if cloud.loadedSnapshots {
                    Text("\(cloud.snapshots.count) 个").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
                }
                if cloud.configuration != nil { FormatBadge(label: "snapshots/") }
                Spacer(minLength: 0)
                Button("刷新列表", systemImage: "arrow.clockwise") {
                    Task { await cloud.refreshSnapshots() }
                }
                .buttonStyle(WorkspaceButton())
                .disabled(!cloud.canSync)
            }
            if let error = cloud.snapshotError { CloudErrorLabel(message: error) }
            if cloud.operation == .snapshots {
                CloudProgressLabel(title: "正在访问远端版本快照")
            }
            if !cloud.snapshots.isEmpty {
                snapshotsTable
            } else if cloud.loadedSnapshots {
                Text("暂无远端版本快照。").foregroundStyle(WorkspaceStyle.secondary)
            } else if cloud.configuration == nil {
                Text("连接远端后可手动创建加密版本快照。").foregroundStyle(WorkspaceStyle.secondary)
            }
        }
        .workspaceCard()
    }

    private var snapshotsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("创建时间").frame(width: 132, alignment: .leading)
                Text("备注").frame(maxWidth: .infinity, alignment: .leading)
                Text("MCP 数量").frame(width: 62, alignment: .leading)
                Text("来源设备").frame(width: 112, alignment: .leading)
                Text("操作").frame(width: 144, alignment: .leading)
            }
            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(WorkspaceStyle.inset)
            ForEach(cloud.snapshots, id: \.id) { snapshot in
                Divider().overlay(WorkspaceStyle.border)
                snapshotRow(snapshot)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceStyle.border) }
    }

    private func snapshotRow(_ snapshot: CloudSnapshotSummary) -> some View {
        HStack(spacing: 12) {
            Text(snapshot.date, format: .dateTime.year().month().day().hour().minute())
                .monospacedDigit().lineLimit(2).frame(width: 132, alignment: .leading)
            Text(snapshot.note ?? "—").lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(snapshot.note ?? "")
            Text("\(snapshot.serverCount) 项").monospacedDigit().frame(width: 62, alignment: .leading)
            Text(snapshot.sourceDevice).lineLimit(2).frame(width: 112, alignment: .leading)
                .help(snapshot.sourceDevice)
            HStack(spacing: 4) {
                Button("预览与恢复") {
                    Task {
                        if await cloud.previewSnapshot(snapshot.id), state.sheet == nil { state.sheet = .cloudRestore }
                    }
                }
                .buttonStyle(WorkspaceButton())
                .disabled(!canOperate)
                Button("删除远端版本快照", systemImage: "trash") { confirmation = .deleteSnapshot(snapshot) }
                    .labelStyle(.iconOnly).buttonStyle(WorkspaceButton(kind: .danger))
                    .disabled(!cloud.canSync)
                    .help("删除远端版本快照")
            }
            .frame(width: 144, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("高级操作").font(WorkspaceStyle.title).accessibilityAddTraits(.isHeader)
            Text("强制覆盖会用一端的中央配置库完整替换另一端。")
                .foregroundStyle(WorkspaceStyle.secondary)
            HStack(spacing: 8) {
                Button("强制本地覆盖远端") { confirmation = .forceLocal }
                    .disabled(!canOperate)
                Button("强制远端覆盖本地") { confirmation = .forceRemote }
                    .disabled(!canOperate)
                Spacer(minLength: 0)
                Button("断开云端同步") { confirmation = .disconnect }
                    .disabled((cloud.configuration == nil && cloud.configurationError == nil) || cloud.isWorking)
            }
            .buttonStyle(WorkspaceButton(kind: .danger))
        }
        .workspaceCard()
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "", secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
                .accessibilityHidden(true)
            Group {
                if secure { SecureField(title, text: text, prompt: Text(prompt)) }
                else { TextField(title, text: text, prompt: Text(prompt)) }
            }
            .textFieldStyle(.plain).workspaceField()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerName(_ target: CloudTarget) -> String {
        switch target {
        case .s3: return "S3 兼容服务"
        case .webDAV: return "WebDAV"
        }
    }

    private func generateKey() {
        do { draft.credential = try CloudEncryption.generateKey() }
        catch { keyError = error.localizedDescription }
    }

    private func copyKey() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(draft.credential, forType: .string)
    }

    private func confirm(_ action: Confirmation) {
        Task {
            switch action {
            case .forceLocal: await cloud.synchronize(mode: .forceLocal)
            case .forceRemote: await cloud.synchronize(mode: .forceRemote)
            case .disconnect: await cloud.disconnect()
            case let .deleteSnapshot(snapshot): await cloud.deleteSnapshot(snapshot.id)
            }
        }
    }
}

struct CloudStatusBadge: View {
    let cloud: CloudWorkspaceState
    var filled = true

    private var color: Color {
        if cloud.isSyncing { return WorkspaceStyle.blue }
        if cloud.conflict != nil { return WorkspaceStyle.amber }
        if cloud.syncError != nil || (cloud.configuration == nil && cloud.configurationError != nil) {
            return WorkspaceStyle.red
        }
        if cloud.localChangesPending, cloud.configuration != nil { return WorkspaceStyle.amber }
        return cloud.summary != nil ? WorkspaceStyle.green : WorkspaceStyle.muted
    }

    var body: some View {
        HStack(spacing: 5) {
            if cloud.isSyncing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            } else {
                Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(cloud.status).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, filled ? 7 : 0)
        .padding(.vertical, filled ? 3 : 0)
        .foregroundStyle(WorkspaceStyle.secondary)
        .background(filled ? color.opacity(0.12) : .clear, in: Capsule())
    }
}

struct CloudErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.red)
            .textSelection(.enabled)
    }
}

struct CloudProgressLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title).font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.secondary)
        }
    }
}
