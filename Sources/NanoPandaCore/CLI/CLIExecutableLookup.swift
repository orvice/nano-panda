import Foundation

public struct CLIExecutableLookup {
    public struct Match: Equatable, Sendable {
        public enum Source: Sendable {
            case path, commonDirectory
        }

        public let url: URL
        public let source: Source
    }

    private let pathDirectories: [URL]
    private let commonDirectories: [URL]

    public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]
        let userDirectories = [
            ".local/bin", ".bun/bin", ".cargo/bin", ".opencode/bin", "go/bin",
            ".volta/bin", ".npm-global/bin", "Library/pnpm", ".local/share/pnpm"
        ].map { home.appendingPathComponent($0, isDirectory: true) }
        let configuredDirectories = ["PNPM_HOME", "NVM_BIN"].compactMap { environment[$0] }
            .compactMap(Self.absoluteDirectory)
        let toolHomes = ["BUN_INSTALL", "CARGO_HOME", "GOPATH", "VOLTA_HOME", "NPM_CONFIG_PREFIX"]
            .compactMap { environment[$0] }.compactMap(Self.absoluteDirectory)
            .map { $0.appendingPathComponent("bin", isDirectory: true) }

        self.init(
            path: environment["PATH"] ?? "",
            commonDirectories: userDirectories + configuredDirectories + toolHomes
                + systemDirectories.compactMap(Self.absoluteDirectory)
        )
    }

    init(path: String, commonDirectories: [URL]) {
        pathDirectories = Self.unique(path.split(separator: ":").compactMap { Self.absoluteDirectory(String($0)) })
        let onPath = Set(pathDirectories)
        self.commonDirectories = Self.unique(commonDirectories).filter { !onPath.contains($0) }
    }

    public func find(_ command: String) -> Match? {
        guard !command.isEmpty, command != ".", command != "..", !command.contains("/"), !command.utf8.contains(0) else {
            return nil
        }
        if let url = firstExecutable(command, in: pathDirectories) { return Match(url: url, source: .path) }
        if let url = firstExecutable(command, in: commonDirectories) { return Match(url: url, source: .commonDirectory) }
        return nil
    }

    private func firstExecutable(_ command: String, in directories: [URL]) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(command, isDirectory: false)
            let target = candidate.resolvingSymlinksInPath()
            let values = try? target.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func absoluteDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func unique(_ directories: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return directories.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }
}
