import NanoPandaCore
import SwiftUI

struct ServerListView: View {
    private enum Filter: String, CaseIterable {
        case all = "全部", stdio = "Stdio", remote = "远程"
    }

    let state: AppState
    @State private var filter = Filter.all

    private var visibleServers: [MCPServer] {
        let search = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.servers.filter { server in
            (filter == .all || server.transport.isRemote == (filter == .remote)) &&
                (search.isEmpty || server.id.localizedCaseInsensitiveContains(search) ||
                 server.tags.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("MCP 服务").font(WorkspaceStyle.section).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(state.servers.count) 个已配置").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
                }
                WorkspaceSegments(options: Filter.allCases, selection: $filter, equalWidth: true) { $0.rawValue }
            }
            .padding(16)
            Divider().overlay(WorkspaceStyle.border)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleServers) { server in row(server) }
                    if visibleServers.isEmpty && !state.servers.isEmpty {
                        Text("没有匹配的 MCP").font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted).padding(12)
                    }
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }

    private func row(_ server: MCPServer) -> some View {
        let selected = state.destination == .server(server.id)
        let pending = state.hasPendingChanges(server)
        return Button {
            state.destination = .server(server.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(pending ? WorkspaceStyle.amber : server.enabledTools.isEmpty ? WorkspaceStyle.strongBorder : WorkspaceStyle.green)
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(server.id).font(WorkspaceStyle.title).lineLimit(1)
                    Spacer(minLength: 0)
                    FormatBadge(label: server.transport.formatLabel)
                }
                HStack {
                    Text("\(server.enabledTools.count) 个工具").font(WorkspaceStyle.small)
                        .foregroundStyle(WorkspaceStyle.secondary)
                    Spacer(minLength: 0)
                    if pending { WorkspaceStatus(status: .pending) }
                }
                .padding(.leading, 15)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? WorkspaceStyle.blueTint : .white, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? WorkspaceStyle.blueBorder : .clear) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
