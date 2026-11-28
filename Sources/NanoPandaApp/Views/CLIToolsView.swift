import AppKit
import NanoPandaCore
import SwiftUI

private struct DeveloperCLI: Identifiable {
    enum Category: String, CaseIterable {
        case sourceControl = "版本控制"
        case runtime = "语言与构建"
        case cloud = "容器与云"
        case utilities = "命令行工具"
    }

    let command: String
    let name: String
    let category: Category
    var id: String { command }

    init(_ command: String, _ name: String, _ category: Category) {
        self.command = command
        self.name = name
        self.category = category
    }

    static let catalog: [Self] = [
        .init("gh", "GitHub CLI", .sourceControl),
        .init("glab", "GitLab CLI", .sourceControl),
        .init("git", "Git", .sourceControl),
        .init("jj", "Jujutsu", .sourceControl),
        .init("swift", "Swift", .runtime),
        .init("node", "Node.js", .runtime),
        .init("npm", "npm", .runtime),
        .init("pnpm", "pnpm", .runtime),
        .init("bun", "Bun", .runtime),
        .init("python3", "Python 3", .runtime),
        .init("uv", "uv", .runtime),
        .init("go", "Go", .runtime),
        .init("cargo", "Cargo", .runtime),
        .init("docker", "Docker CLI", .cloud),
        .init("kubectl", "Kubernetes CLI", .cloud),
        .init("helm", "Helm", .cloud),
        .init("aws", "AWS CLI", .cloud),
        .init("gcloud", "Google Cloud CLI", .cloud),
        .init("terraform", "Terraform", .cloud),
        .init("wrangler", "Cloudflare Wrangler", .cloud),
        .init("brew", "Homebrew", .utilities),
        .init("rg", "ripgrep", .utilities),
        .init("jq", "jq", .utilities),
        .init("curl", "curl", .utilities)
    ]
}

struct CLIToolsView: View {
    private enum Filter: String, CaseIterable {
        case all = "全部"
        case installed = "已检测到"
        case missing = "未检测到"
    }

    let home: URL
    let query: String
    @State private var filter = Filter.all
    @State private var matches: [String: CLIExecutableLookup.Match]?
    @State private var refreshRequest = 0
    @State private var authRequest = 0
    @State private var checkingAuth = false
    @State private var loginStatuses: [CLIAuthProvider: CLIAuthStatus] = [:]

    private var visibleTools: [DeveloperCLI] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeveloperCLI.catalog.filter { tool in
            let match = matches?[tool.id]
            let installed = match != nil
            guard filter == .all || installed == (filter == .installed) else { return false }
            return term.isEmpty || [tool.name, tool.command, tool.category.rawValue, match?.url.path ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider().overlay(WorkspaceStyle.border)
            if matches == nil {
                ProgressView("正在检测 CLI…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleTools.isEmpty {
                ContentUnavailableView("没有匹配的 CLI", systemImage: "magnifyingglass",
                                       description: Text("可以修改搜索词或切换筛选。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(DeveloperCLI.Category.allCases, id: \.self) { category in
                            let tools = visibleTools.filter { $0.category == category }
                            if !tools.isEmpty {
                                section(category, tools: tools)
                            }
                        }
                    }
                    .frame(maxWidth: 1100)
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: refreshRequest) { await detectTools() }
        .task(id: authRequest) {
            if authRequest > 0 { await checkLogin() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshRequest += 1
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CLI 工具").font(WorkspaceStyle.headline).accessibilityAddTraits(.isHeader)
                    Text("查看 GitHub、GitLab 登录账号和本机命令。PATH 以 Nano Panda 进程为准。")
                        .foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("重新检测", systemImage: "arrow.clockwise") { refreshRequest += 1 }
                        .buttonStyle(WorkspaceButton())
                    Button("检查登录", systemImage: "person.crop.circle.badge.checkmark") { authRequest += 1 }
                        .buttonStyle(WorkspaceButton(kind: .primary))
                        .disabled(checkingAuth || !CLIAuthProvider.allCases.contains { matches?[$0.rawValue] != nil })
                        .help("使用 gh 和 glab 向已配置的服务验证账号")
                }
            }
            HStack {
                WorkspaceSegments(options: Filter.allCases, selection: $filter) { $0.rawValue }
                Spacer()
                if let matches {
                    Text("\(matches.count) / \(DeveloperCLI.catalog.count) 已检测到")
                        .font(WorkspaceStyle.small).monospacedDigit().foregroundStyle(WorkspaceStyle.muted)
                }
            }
        }
        .frame(maxWidth: 1100)
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }

    private func section(_ category: DeveloperCLI.Category, tools: [DeveloperCLI]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(category.rawValue).font(WorkspaceStyle.section).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(tools) { tool in
                    row(tool, match: matches?[tool.id])
                    if tool.id != tools.last?.id { Divider().overlay(WorkspaceStyle.border) }
                }
            }
            .workspaceCard(padding: 0)
        }
    }

    private func row(_ tool: DeveloperCLI, match: CLIExecutableLookup.Match?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name).font(WorkspaceStyle.title)
                    Text(tool.command).font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.muted)
                }
                .frame(width: 145, alignment: .leading)

                if let match {
                    Text(match.url.path)
                        .font(WorkspaceStyle.mono).foregroundStyle(WorkspaceStyle.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(match.url.path)
                }
                Spacer(minLength: 0)
                status(match?.source)
                if let match {
                    Button("显示 \(tool.command) 的位置", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([match.url])
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .help("在访达显示")
                    .frame(width: 24)
                } else {
                    Color.clear.frame(width: 24).accessibilityHidden(true)
                }
            }
            if let provider = CLIAuthProvider(rawValue: tool.command), match != nil {
                loginStatus(for: provider)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 50)
    }

    @ViewBuilder
    private func loginStatus(for provider: CLIAuthProvider) -> some View {
        switch loginStatuses[provider] {
        case let .accounts(accounts):
            ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                HStack(spacing: 8) {
                    loginBadge(account.state)
                    Text([account.login, account.host].compactMap { $0 }.joined(separator: " · "))
                        .font(WorkspaceStyle.mono).textSelection(.enabled)
                    if account.active {
                        Text("当前账号")
                            .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.blue)
                    }
                }
            }
        case .signedOut:
            loginBadge(.signedOut)
        case .unverified:
            loginBadge(.unverified)
        case .unsupportedVersion:
            Label("当前 CLI 版本不支持状态检查", systemImage: "exclamationmark.circle")
                .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.amberInk)
        case nil:
            Label(checkingAuth ? "正在检查登录…" : "登录状态待检查", systemImage: "person.crop.circle")
                .font(WorkspaceStyle.small).foregroundStyle(WorkspaceStyle.muted)
        }
    }

    private func loginBadge(_ state: CLIAuthAccount.State) -> some View {
        let title: String
        let icon: String
        let color: Color
        switch state {
        case .signedIn: (title, icon, color) = ("已登录", "checkmark.circle", WorkspaceStyle.greenInk)
        case .signedOut: (title, icon, color) = ("未登录", "person.crop.circle", WorkspaceStyle.muted)
        case .reauthenticationRequired: (title, icon, color) = ("需要重新登录", "exclamationmark.circle", WorkspaceStyle.amberInk)
        case .unverified: (title, icon, color) = ("暂时无法验证", "questionmark.circle", WorkspaceStyle.muted)
        }
        return Label(title, systemImage: icon).font(WorkspaceStyle.small).foregroundStyle(color).fixedSize()
    }

    private func status(_ source: CLIExecutableLookup.Match.Source?) -> some View {
        let label: String
        let fill: Color
        let foreground: Color
        switch source {
        case .path:
            (label, fill, foreground) = ("在 PATH 中", WorkspaceStyle.greenTint, WorkspaceStyle.greenInk)
        case .commonDirectory:
            (label, fill, foreground) = ("不在 PATH 中", WorkspaceStyle.amberTint, WorkspaceStyle.amberInk)
        case nil:
            (label, fill, foreground) = ("未检测到", WorkspaceStyle.neutral, WorkspaceStyle.secondary)
        }
        return Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(fill, in: Capsule())
            .fixedSize()
    }

    private func detectTools() async {
        let commands = DeveloperCLI.catalog.map(\.command)
        let home = home
        let found = await Task.detached(priority: .userInitiated) {
            let lookup = CLIExecutableLookup(home: home)
            return Dictionary(uniqueKeysWithValues: commands.compactMap { command in
                lookup.find(command).map { (command, $0) }
            })
        }.value
        guard !Task.isCancelled else { return }
        for provider in CLIAuthProvider.allCases where matches?[provider.rawValue] != found[provider.rawValue] {
            loginStatuses[provider] = nil
        }
        matches = found
    }

    private func checkLogin() async {
        let commands = CLIAuthProvider.allCases.compactMap { provider in
            matches?[provider.rawValue].map { (provider, $0.url) }
        }
        checkingAuth = true
        loginStatuses = [:]
        defer { checkingAuth = false }
        await withTaskGroup(of: (CLIAuthProvider, URL, CLIAuthStatus).self) { group in
            for (provider, url) in commands {
                group.addTask { (provider, url, provider.check(executable: url)) }
            }
            for await (provider, url, status) in group where !Task.isCancelled {
                if matches?[provider.rawValue]?.url == url { loginStatuses[provider] = status }
            }
        }
    }
}
