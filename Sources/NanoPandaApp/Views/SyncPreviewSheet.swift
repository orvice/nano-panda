import NanoPandaCore
import SwiftUI

struct SyncPreviewSheet: View {
    let state: AppState
    @State private var preview: SyncPlan
    @State private var mode = SyncMode.managed
    @State private var selected: ToolID?
    @State private var error: String?

    init(state: AppState, initialPlan: SyncPlan) {
        self.state = state
        _preview = State(initialValue: initialPlan)
        _selected = State(initialValue: Self.reviewItems(initialPlan).first?.tool)
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider().overlay(WorkspaceStyle.border)
            Group {
                if Self.reviewItems(preview).isEmpty {
                    ContentUnavailableView(
                        "没有待审查的文件差异", systemImage: "doc.text.magnifyingglass",
                        description: Text(preview.canApply ? "可以确认保存当前工具分配。" : "保存 MCP 或调整工具分配后，可在这里查看差异。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        changes.frame(width: 248)
                        Divider().overlay(WorkspaceStyle.border)
                        if let change = preview.tools.first(where: { $0.tool == selected }) {
                            changeDetail(change)
                        } else {
                            DiffView(diff: "")
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(WorkspaceStyle.border)
            footer
        }
        .background(.white)
        .frame(minWidth: 850, idealWidth: 1040, minHeight: 510, idealHeight: 680)
        .onChange(of: mode) { _, _ in
            recalculate()
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("审查同步变更").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                    Text(preview.changeCount > 0
                         ? "将更新 \(preview.changeCount) 个配置文件，并在写入前自动备份。"
                         : "当前没有需要写入的配置文件。")
                        .foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 4)
                WorkspaceSegments(options: SyncMode.allCases, selection: $mode) {
                    $0 == .managed ? "安全合并" : "完全同步"
                }
            }
            if mode == .full {
                Label("完全同步会移除未分配的 MCP，请核对删除清单。", systemImage: "exclamationmark.triangle")
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
            }
            if preview.tools.contains(where: { $0.error != nil }) {
                Text("无法读取的工具将跳过 · " + preview.tools.filter { $0.error != nil }.map { $0.tool.title }.joined(separator: "、"))
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("变更与异常").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.muted)
                Spacer()
                Text(preview.changeCount, format: .number).monospacedDigit()
                    .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Self.reviewItems(preview)) { item in
                        toolRow(item)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkspaceStyle.sidebar)
    }

    private func toolRow(_ change: ToolChange) -> some View {
        let active = selected == change.tool
        let diff = DiffDocument(change.diff)
        return Button {
            selected = change.tool
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(WorkspaceStyle.dot(change.hasChanges ? .pending : change.status))
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(change.tool.title).font(WorkspaceStyle.title)
                    Spacer(minLength: 0)
                    FormatBadge(label: change.tool.formatLabel)
                }
                Text(change.path.path).font(WorkspaceStyle.mono).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(WorkspaceStyle.muted)
                if change.hasChanges {
                    HStack(spacing: 8) {
                        Text("+\(diff.insertions)").foregroundStyle(WorkspaceStyle.greenInk)
                        Text("−\(diff.deletions)").foregroundStyle(WorkspaceStyle.red)
                    }
                    .font(WorkspaceStyle.mono)
                } else {
                    WorkspaceStatus(status: change.status)
                }
            }
            .padding(10)
            .background(active ? WorkspaceStyle.blueTint : .white, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(active ? WorkspaceStyle.blueBorder : WorkspaceStyle.border) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func changeDetail(_ change: ToolChange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Label(change.path.path, systemImage: "doc.text")
                    .font(WorkspaceStyle.mono).textSelection(.enabled)
                if change.status == .pending && !change.hasChanges {
                    Text("文件已符合工具分配，确认后会记录托管状态。")
                        .foregroundStyle(WorkspaceStyle.muted)
                }
                if let error = change.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(WorkspaceStyle.red)
                }
                if !change.removedIDs.isEmpty {
                    Text("将移除 · " + change.removedIDs.joined(separator: "、"))
                        .foregroundStyle(WorkspaceStyle.red)
                }
                ForEach(Array(change.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(WorkspaceStyle.amberInk)
                }
            }
            .font(WorkspaceStyle.small)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(WorkspaceStyle.border)
            DiffView(diff: change.diff)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).foregroundStyle(WorkspaceStyle.red).font(WorkspaceStyle.small) }
            HStack(spacing: 8) {
                Label("备份至 ~/Library/Application Support/NanoPanda/backups/", systemImage: "archivebox")
                    .font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("重新计算", action: recalculate).buttonStyle(WorkspaceButton(kind: .quiet))
                Button("取消") { state.sheet = nil }.buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                Button(preview.changeCount > 0 ? "备份并应用到 \(preview.changeCount) 个工具" : "确认当前状态",
                       systemImage: "checkmark.shield") {
                    do { try state.apply(preview) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(WorkspaceButton(kind: .primary))
                .disabled(!preview.canApply)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(WorkspaceStyle.sidebar)
    }

    private func recalculate() {
        state.refresh()
        preview = state.preview(mode)
        let items = Self.reviewItems(preview)
        if !items.contains(where: { $0.tool == selected }) { selected = items.first?.tool }
        error = nil
    }

    private static func reviewItems(_ preview: SyncPlan) -> [ToolChange] {
        let choices = preview.tools.filter {
            $0.hasChanges || $0.status == .pending || $0.status == .drift || $0.error != nil
        }
        return choices.sorted { left, right in
            if left.hasChanges != right.hasChanges { return left.hasChanges }
            return left.tool.title < right.tool.title
        }
    }
}

private struct DiffDocument {
    enum Kind { case header, addition, deletion, context, marker }

    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let number: Int?
        let content: String
    }

    let lines: [Line]
    var insertions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    init(_ text: String) {
        var old = 0
        var new = 0
        lines = text.components(separatedBy: "\n").dropLast().enumerated().map { index, line in
            if line.hasPrefix("@@ ") {
                let positions = line.split(separator: " ")
                if positions.count >= 3 {
                    old = Self.start(positions[1])
                    new = Self.start(positions[2])
                }
                return Line(id: index, kind: .header, number: nil, content: line)
            }
            if index < 2 { return Line(id: index, kind: .header, number: nil, content: line) }
            switch line.first {
            case "+":
                defer { new += 1 }
                return Line(id: index, kind: .addition, number: new, content: String(line.dropFirst()))
            case "-":
                defer { old += 1 }
                return Line(id: index, kind: .deletion, number: old, content: String(line.dropFirst()))
            case " ":
                defer { old += 1; new += 1 }
                return Line(id: index, kind: .context, number: new, content: String(line.dropFirst()))
            default:
                return Line(id: index, kind: .marker, number: nil, content: line)
            }
        }
    }

    private static func start(_ value: Substring) -> Int {
        value.dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0
    }
}

struct DiffView: View {
    let diff: String

    var body: some View {
        if diff.isEmpty {
            ContentUnavailableView("没有文件差异", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(DiffDocument(diff).lines) { line in
                            row(line, width: geometry.size.width)
                        }
                    }
                    .font(WorkspaceStyle.mono)
                    .textSelection(.enabled)
                }
            }
            .background(WorkspaceStyle.inset)
        }
    }

    private func row(_ line: DiffDocument.Line, width: CGFloat) -> some View {
        let fill: Color
        let ink: Color
        let sign: String
        switch line.kind {
        case .addition: (fill, ink, sign) = (WorkspaceStyle.greenTint, WorkspaceStyle.greenInk, "+")
        case .deletion: (fill, ink, sign) = (WorkspaceStyle.redTint, WorkspaceStyle.red, "−")
        case .header: (fill, ink, sign) = (WorkspaceStyle.neutral, WorkspaceStyle.secondary, "")
        case .marker: (fill, ink, sign) = (.white, WorkspaceStyle.muted, "")
        case .context: (fill, ink, sign) = (.white, WorkspaceStyle.ink, "")
        }
        return HStack(spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .foregroundStyle(WorkspaceStyle.muted).monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            Text(sign).frame(width: 25)
            Text(verbatim: line.content).fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(ink)
        .padding(.trailing, 12)
        .frame(minWidth: width, minHeight: 22, alignment: .leading)
        .background(fill)
    }
}
