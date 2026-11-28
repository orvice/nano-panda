import Foundation
import XCTest
@testable import NanoPandaCore

final class CLIExecutableLookupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testPathOrderTakesPrecedenceOverCommonDirectories() throws {
        let first = try directory("first")
        let second = try directory("second")
        let common = try directory("common")
        let expected = try file("gh", in: first)
        _ = try file("gh", in: second)
        _ = try file("gh", in: common)
        let lookup = CLIExecutableLookup(path: "\(first.path):\(second.path)", commonDirectories: [common])

        XCTAssertEqual(lookup.find("gh")?.url, expected)
        XCTAssertEqual(lookup.find("gh")?.source, .path)
    }

    func testMissingAndNonExecutableCommandsFallBackToCommonDirectories() throws {
        let path = try directory("path")
        let common = try directory("common")
        _ = try file("glab", in: path, permissions: 0o644)
        let expected = try file("glab", in: common)
        let lookup = CLIExecutableLookup(path: "relative::\(path.path)", commonDirectories: [common])

        XCTAssertEqual(lookup.find("glab")?.url, expected)
        XCTAssertEqual(lookup.find("glab")?.source, .commonDirectory)
        XCTAssertNil(lookup.find("missing"))
        XCTAssertNil(lookup.find("../glab"))
    }

    func testExecutableSymlinksWorkButDirectoriesAndBrokenLinksDoNot() throws {
        let bin = try directory("bin")
        let install = try directory("install")
        let executable = try file("gh", in: install)
        let link = bin.appendingPathComponent("gh", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let broken = bin.appendingPathComponent("glab", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: install.appendingPathComponent("missing"))
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("docker"), withIntermediateDirectories: false)
        let lookup = CLIExecutableLookup(path: bin.path, commonDirectories: [])

        XCTAssertEqual(lookup.find("gh")?.url, link)
        XCTAssertNil(lookup.find("glab"))
        XCTAssertNil(lookup.find("docker"))
    }

    func testDefaultLookupChecksUserBinWhenLaunchedWithoutAShellPath() throws {
        let local = try directory(".local/bin")
        let expected = try file("fixture-cli", in: local)
        let lookup = CLIExecutableLookup(home: root, environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(lookup.find("fixture-cli")?.url, expected)
        XCTAssertEqual(lookup.find("fixture-cli")?.source, .commonDirectory)
    }

    private func directory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func file(_ name: String, in directory: URL, permissions: Int = 0o755) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }
}
