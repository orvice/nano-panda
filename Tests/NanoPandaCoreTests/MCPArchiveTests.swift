import Foundation
import XCTest
@testable import NanoPandaCore

final class MCPArchiveTests: XCTestCase {
    private let password = "测试-password-🔐-2026"
    private let entries = [
        MCPServer(
            id: "stdio-server",
            transport: .stdio(command: "/opt/bin/mcp", args: ["--flag"], env: ["API_KEY": "sensitive-fixture"]),
            enabledTools: [.claudeCode, .codex], notes: "Portable note", tags: ["测试"],
            updatedAt: Date(timeIntervalSinceReferenceDate: 456),
            perToolOverrides: [.codex: ServerOverride(fields: ["timeout": .integer(7)])]
        ),
        MCPServer(
            id: "remote-server",
            transport: .http(url: "https://example.invalid/mcp", headers: ["Authorization": "fixture-token"], bearerTokenEnvVar: "TOKEN"),
            enabledTools: [.cursor], updatedAt: Date(timeIntervalSinceReferenceDate: 123)
        )
    ]

    func testPasswordRoundTripAndWrongPassword() throws {
        let first = try MCPArchive.encode(entries, protection: .password, credential: password)
        let second = try MCPArchive.encode(entries, protection: .password, credential: password)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("sensitive-fixture"))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("remote-server"))
        let archive = try MCPArchive(data: first)
        XCTAssertEqual(archive.protection, .password)
        XCTAssertEqual(try archive.unlock(credential: password), entries)
        XCTAssertThrowsError(try archive.unlock(credential: "unrelated-password"))
        XCTAssertThrowsError(try MCPArchive.encode(entries, protection: .password, credential: "short"))
    }

    func testKeyRoundTripAndAlteredCiphertext() throws {
        let key = try MCPArchive.generateKey()
        let other = try MCPArchive.generateKey()
        XCTAssertNotEqual(key, other)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        let data = try MCPArchive.encode(entries, protection: .key, credential: key)
        let archive = try MCPArchive(data: data)
        XCTAssertEqual(archive.protection, .key)
        XCTAssertEqual(try archive.unlock(credential: " \(key)\n"), entries)
        XCTAssertThrowsError(try archive.unlock(credential: other))
        XCTAssertThrowsError(try MCPArchive.encode(entries, protection: .key, credential: "invalid-key"))

        var envelope = try object(data)
        let encoded = try XCTUnwrap(envelope["sealed"] as? String)
        var sealed = try XCTUnwrap(Data(base64Encoded: encoded))
        sealed[sealed.startIndex + 16] ^= 1
        envelope["sealed"] = sealed.base64EncodedString()
        let tampered = try MCPArchive(data: JSONSerialization.data(withJSONObject: envelope))
        XCTAssertThrowsError(try tampered.unlock(credential: key))
    }

    func testPlaintextIsReadableAndRejectsUnsupportedVersionsAndDuplicates() throws {
        let data = try MCPArchive.encode(entries, protection: .plaintext)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("sensitive-fixture"))
        XCTAssertEqual(try MCPArchive(data: data).unlock(), entries)

        var envelope = try object(data)
        var header = try XCTUnwrap(envelope["header"] as? [String: Any])
        header["version"] = 2
        header["protection"] = "future-cipher"
        envelope["header"] = header
        XCTAssertThrowsError(try MCPArchive(data: JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0.localizedDescription, "此 MCP 归档版本不受支持。")
        }

        XCTAssertThrowsError(try MCPArchive.encode([entries[0], entries[0]], protection: .plaintext))
        XCTAssertThrowsError(try MCPArchive.encode([], protection: .plaintext))
    }

    func testEncryptedArchiveRejectsPlaintextFieldsAndInvalidSalt() throws {
        let data = try MCPArchive.encode(entries, protection: .password, credential: password)
        var envelope = try object(data)
        envelope["servers"] = []
        XCTAssertThrowsError(try MCPArchive(data: JSONSerialization.data(withJSONObject: envelope)))
        envelope.removeValue(forKey: "servers")
        envelope["salt"] = Data(repeating: 0, count: 15).base64EncodedString()
        XCTAssertThrowsError(try MCPArchive(data: JSONSerialization.data(withJSONObject: envelope)))
    }

    func testFilesArePrivateAndOversizedFilesAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.json")
        let key = try MCPArchive.generateKey()
        try MCPArchive.export(entries, protection: .key, credential: key, to: url)
        XCTAssertEqual(try MCPArchive.read(from: url).unlock(credential: key), entries)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 32 * 1024 * 1024 + 1)
        try file.close()
        XCTAssertThrowsError(try MCPArchive.read(from: url))
    }

    func testMergeSkipsOrReplacesWithoutChangingLocalToolState() throws {
        var registry = Registry()
        var saved = entries[0]
        saved.notes = "Local note"
        saved.enabledTools = [.windsurf]
        registry.servers = [saved]
        registry.customPaths[.codex] = "/tmp/local-only.toml"
        registry.receipts[.codex] = SyncReceipt(path: "/tmp/local-only.toml", digest: "fixture", managedIDs: [saved.id])

        let skipped = try MCPArchive.merging(entries, into: registry, conflicts: .skip)
        let replaced = try MCPArchive.merging(entries, into: registry, conflicts: .replace)
        XCTAssertEqual(skipped.servers, [saved, entries[1]])
        XCTAssertEqual(replaced.servers, entries)
        XCTAssertEqual(replaced.customPaths, registry.customPaths)
        XCTAssertEqual(replaced.receipts, registry.receipts)
        XCTAssertEqual(registry.servers, [saved])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
