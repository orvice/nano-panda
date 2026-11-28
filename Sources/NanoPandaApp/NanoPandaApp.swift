import AppKit
import SwiftUI

@main
struct NanoPandaApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("Nano Panda", id: "main") {
            MainSplitView(state: state)
                .frame(minWidth: 980, minHeight: 620)
                .task { await state.cloud.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.refresh()
                    state.cloud.scheduleAutomaticSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                    if let window = notification.object as? NSWindow, window.canBecomeMain, window.sheetParent == nil {
                        state.cloud.scheduleAutomaticSync()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 MCP", systemImage: "plus", action: state.newServer)
                    .keyboardShortcut("n")
            }
            CommandMenu("云端同步") {
                Button("打开云端同步", action: state.openCloud)
                Button("立即同步", action: state.syncCloudNow)
                    .disabled(!state.cloud.canSync || !state.canEdit)
            }
            CommandMenu("MCP") {
                Button("搜索工作区", action: state.focusSearch).keyboardShortcut("k")
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
