import AppKit
import SwiftUI

@main
struct NanoPandaApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("Nano Panda", id: "main") {
            MainSplitView(state: state)
                .frame(minWidth: 980, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.refresh()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 MCP", systemImage: "plus", action: state.newServer)
                    .keyboardShortcut("n")
            }
            CommandMenu("MCP") {
                Button("搜索 MCP", action: state.focusSearch).keyboardShortcut("k")
                Button("从 JSON 粘贴", action: state.paste)
                Button("导入配置文件…", action: state.showArchiveImport)
                    .disabled(!state.canEdit)
                Button("导出 MCP 配置…", action: state.showArchiveExport)
                    .disabled(!state.canEdit || state.servers.isEmpty)
                Divider()
                Button("扫描本机导入", action: state.scan)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("同步预览", action: state.preview)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("刷新工具状态", action: state.refresh)
                    .keyboardShortcut("r")
            }
        }
    }
}
