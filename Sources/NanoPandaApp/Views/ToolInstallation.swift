import Foundation
import NanoPandaCore

enum ToolInstallation {
    static func detected(_ tool: ToolID, home: URL) -> Bool {
        let appName: String?
        let command: String?
        switch tool {
        case .claudeCode: (appName, command) = (nil, "claude")
        case .codex: (appName, command) = ("Codex", "codex")
        case .antigravity: (appName, command) = ("Antigravity", "antigravity")
        case .claudeDesktop: (appName, command) = ("Claude", nil)
        case .cursor: (appName, command) = ("Cursor", "cursor")
        case .windsurf: (appName, command) = ("Windsurf", "windsurf")
        case .geminiCLI: (appName, command) = (nil, "gemini")
        case .openCode: (appName, command) = ("OpenCode", "opencode")
        }

        let files = FileManager.default
        if let appName {
            let locations = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            if locations.contains(where: { files.fileExists(atPath: $0.appendingPathComponent(appName + ".app").path) }) {
                return true
            }
        }
        guard let command else { return false }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let locations = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
            + [".local/bin", ".opencode/bin", ".bun/bin"].map { home.appendingPathComponent($0).path }
        return locations.contains { files.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(command).path) }
    }
}
