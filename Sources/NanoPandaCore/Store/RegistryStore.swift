import Darwin
import Foundation

public struct RegistryStore {
    public let directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NanoPanda", isDirectory: true)) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    var registryURL: URL { directory.appendingPathComponent("registry.json") }

    public func load() throws -> Registry {
        guard let data = try LocalFile.read(registryURL) else { return Registry() }
        let registry = try JSONDecoder().decode(Registry.self, from: data)
        try validate(registry)
        return registry
    }

    public func save(_ registry: Registry, replacing expected: Registry) throws {
        try locked {
            guard try load() == expected else {
                throw PandaError.stale("中央配置库已被其他进程修改，请重新启动 Nano Panda 后再编辑。")
            }
            var updated = registry
            updated.cloudRestorationID = expected.cloudRestorationID
            try write(updated)
        }
    }

    func write(_ registry: Registry) throws {
        try validate(registry)
        let data = Data(try ConfigEncoding.json(registry, pretty: true).utf8)
        try LocalFile.write(data, to: registryURL, permissions: 0o600)
    }

    func locked<Result>(_ action: () throws -> Result) throws -> Result {
        try LocalFile.privateDirectory(directory)
        let path = directory.appendingPathComponent(".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalFile.posixError(path) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw LocalFile.posixError(path) }
        }
        return try action()
    }

    private func validate(_ registry: Registry) throws {
        guard Set(registry.servers.map(\.id)).count == registry.servers.count else {
            throw PandaError.invalid("中央配置库含有重复的 MCP 名称。")
        }
        for server in registry.servers { try server.validate() }
    }
}

enum LocalFile {
    static func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }

    static func read(_ url: URL) throws -> Data? {
        guard try attributes(url) != nil else { return nil }
        return try Data(contentsOf: url)
    }

    static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PandaError.invalid("目标路径不是普通文件：\(url.path)")
        }
        return attributes
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    static func write(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let parent = url.deletingLastPathComponent()
        try privateDirectory(parent)
        let existing = try attributes(url)
        let mode = permissions ?? (existing?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let temporary = parent.appendingPathComponent(".nanopanda-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw posixError(temporary.path) }
        defer {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fchmod(descriptor, mode_t(mode)) == 0 else { throw posixError(temporary.path) }
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw posixError(url.path) }
    }

    static func restore(_ data: Data?, to url: URL, permissions: Int? = nil) throws {
        if let data {
            try write(data, to: url, permissions: permissions)
        } else if try attributes(url) != nil {
            try FileManager.default.removeItem(at: url)
        }
    }
}
