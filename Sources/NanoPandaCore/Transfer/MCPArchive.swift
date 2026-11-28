import CryptoKit
import Darwin
import Foundation

public struct MCPArchive: Sendable {
    public enum Protection: String, Codable, CaseIterable, Sendable {
        case password, key, plaintext
    }

    public enum ConflictPolicy: Sendable {
        case skip, replace
    }

    private struct Header: Codable, Sendable {
        let format: String
        let version: Int
        let protection: Protection

        init(protection: Protection) {
            format = MCPArchive.formatID
            version = MCPArchive.formatVersion
            self.protection = protection
        }

        func authenticatedData(salt: Data?) -> Data {
            Data("\(format):\(version):\(protection.rawValue):".utf8) + (salt ?? Data())
        }
    }

    private struct Envelope: Codable, Sendable {
        let header: Header
        let salt: Data?
        let sealed: Data?
        let servers: [MCPServer]?
    }

    private static let formatID = "nano-panda.mcp"
    private static let formatVersion = 1
    private static let fileLimit = 32 * 1024 * 1024
    private let envelope: Envelope

    public var protection: Protection { envelope.header.protection }

    public init(data: Data) throws {
        guard data.count <= Self.fileLimit else { throw Self.fileTooLarge }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(HeaderOnly.self, from: data).header,
              header.format == Self.formatID else {
            throw PandaError.invalid("请选择 Nano Panda 导出的 MCP 归档。")
        }
        guard header.version == Self.formatVersion else { throw PandaError.invalid("此 MCP 归档版本不受支持。") }
        let decoded: Envelope
        do {
            decoded = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw Self.invalidArchive
        }
        switch decoded.header.protection {
        case .plaintext:
            guard let servers = decoded.servers, decoded.salt == nil, decoded.sealed == nil else {
                throw Self.invalidArchive
            }
            try Self.validate(servers)
        case .password:
            guard decoded.servers == nil, decoded.salt?.count == ConfigurationCipher.saltSize,
                  let sealed = decoded.sealed, sealed.count >= 28 else { throw Self.invalidArchive }
        case .key:
            guard decoded.servers == nil, decoded.salt == nil,
                  let sealed = decoded.sealed, sealed.count >= 28 else { throw Self.invalidArchive }
        }
        envelope = decoded
    }

    private struct HeaderOnly: Decodable {
        struct Identity: Decodable {
            let format: String
            let version: Int
        }

        let header: Identity
    }

    public static func read(from url: URL) throws -> Self {
        let url = url.resolvingSymlinksInPath()
        guard url.isFileURL else { throw Self.invalidArchive }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalFile.posixError(url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LocalFile.posixError(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Self.invalidArchive }
        guard info.st_size <= Self.fileLimit else { throw Self.fileTooLarge }

        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, Self.fileLimit - data.count + 1)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.fileLimit else { throw Self.fileTooLarge }
        }
        return try Self(data: data)
    }

    public static func generateKey() throws -> String {
        try ConfigurationCipher.generateKey()
    }

    public static func export(
        _ servers: [MCPServer], protection: Protection, credential: String = "", to url: URL
    ) throws {
        let data = try encode(servers, protection: protection, credential: credential)
        guard url.isFileURL else { throw PandaError.invalid("请选择本地文件路径。") }
        try LocalFile.write(data, to: url, permissions: 0o600)
    }

    public static func encode(
        _ servers: [MCPServer], protection: Protection, credential: String = ""
    ) throws -> Data {
        try validate(servers)
        let header = Header(protection: protection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let envelope: Envelope
        if protection == .plaintext {
            encoder.outputFormatting.insert(.prettyPrinted)
            envelope = Envelope(header: header, salt: nil, sealed: nil, servers: servers)
        } else {
            if protection == .password && credential.precomposedStringWithCanonicalMapping.count < 12 {
                throw PandaError.invalid("导出密码至少需要 12 个字符。")
            }
            let salt = protection == .password ? try ConfigurationCipher.randomBytes(count: ConfigurationCipher.saltSize) : nil
            let key = try encryptionKey(protection: protection, credential: credential, salt: salt)
            let payload = try encoder.encode(servers)
            guard payload.count <= fileLimit else { throw fileTooLarge }
            let sealed = try ConfigurationCipher.seal(payload, with: key, authenticating: header.authenticatedData(salt: salt))
            envelope = Envelope(header: header, salt: salt, sealed: sealed, servers: nil)
        }
        let data = try encoder.encode(envelope)
        guard data.count <= fileLimit else { throw fileTooLarge }
        return data
    }

    public func unlock(credential: String = "") throws -> [MCPServer] {
        if let servers = envelope.servers { return servers }
        guard let sealed = envelope.sealed else { throw Self.invalidArchive }
        let key = try Self.encryptionKey(protection: protection, credential: credential, salt: envelope.salt)
        let payload: Data
        do {
            payload = try ConfigurationCipher.open(
                sealed, with: key, authenticating: envelope.header.authenticatedData(salt: envelope.salt)
            )
        } catch {
            throw PandaError.invalid("密码或密钥不正确，或归档内容已损坏。")
        }
        guard let servers = try? JSONDecoder().decode([MCPServer].self, from: payload) else {
            throw Self.invalidArchive
        }
        try Self.validate(servers)
        return servers
    }

    public static func merging(
        _ entries: [MCPServer], into registry: Registry, conflicts: ConflictPolicy
    ) throws -> Registry {
        try validate(entries)
        var updated = registry
        let positions = Dictionary(
            registry.servers.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first }
        )
        guard positions.count == registry.servers.count else {
            throw PandaError.invalid("中央配置库含有重复的 MCP 名称。")
        }
        for entry in entries {
            if let position = positions[entry.id] {
                if conflicts == .replace { updated.servers[position] = entry }
            } else {
                updated.servers.append(entry)
            }
        }
        return updated
    }

    private static func validate(_ servers: [MCPServer]) throws {
        guard !servers.isEmpty else { throw PandaError.invalid("归档至少需要包含一个 MCP 条目。") }
        guard Set(servers.map(\.id)).count == servers.count else {
            throw PandaError.invalid("归档含有重复的 MCP 名称。")
        }
        for server in servers { try server.validate() }
    }

    private static func encryptionKey(protection: Protection, credential: String, salt: Data?) throws -> SymmetricKey {
        switch protection {
        case .key:
            return try ConfigurationCipher.rawKey(credential)
        case .password:
            guard let salt else { throw invalidArchive }
            return try ConfigurationCipher.passwordKey(credential, salt: salt)
        case .plaintext:
            throw invalidArchive
        }
    }

    private static var invalidArchive: PandaError { .invalid("MCP 归档无效或已损坏。") }
    private static var fileTooLarge: PandaError { .invalid("MCP 归档最大支持 32 MB。") }
}
