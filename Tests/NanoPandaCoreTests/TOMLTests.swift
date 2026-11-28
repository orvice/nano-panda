import XCTest
@testable import NanoPandaCore

final class TOMLTests: XCTestCase {
    func testMultilineStringsNestedTablesQuotedKeysAndComments() throws {
        let input = #"""
        model = "example"
        description = '''
        [mcp_servers.fake]
        # inside a literal
        '''
        [[unrelated.entries]]
        name = "leave me alone"
        [mcp_servers."a.b"] # keep
        command = 'node'
        args = [
          "-y", # argument note
          "pkg",
        ] # inline note
        startup_timeout_sec = 10
        [mcp_servers."a.b".env]
        "ENV.KEY" = "secret # value"
        [mcp_servers."a.b".future]
        timestamp = 2026-01-02T00:00:00Z
        [other]
        setting = { foo = [1, 2] }
        """#
        let adapter = AgentAdapter(.codex)
        let original = try adapter.read(Data(input.utf8))
        XCTAssertEqual(original.map(\.id), ["a.b"])
        XCTAssertEqual(original.first?.transport, .stdio(command: "node", args: ["-y", "pkg"], env: ["ENV.KEY": "secret # value"]))
        let desired = MCPServer(id: "a.b", transport: .http(url: "https://example.invalid/mcp", headers: ["X.Y": "a"], bearerTokenEnvVar: "TOKEN"))
        let output = try XCTUnwrap(adapter.merge(Data(input.utf8), servers: [desired], removing: []))
        let text = String(decoding: output, as: UTF8.self)
        for unchanged in ["model = \"example\"", "[[unrelated.entries]]", "# argument note", "# inline note", "startup_timeout_sec = 10",
                          "timestamp = 2026-01-02T00:00:00Z", "[other]\nsetting = { foo = [1, 2] }"] {
            XCTAssertTrue(text.contains(unchanged), unchanged)
        }
        XCTAssertFalse(text.contains("ENV.KEY"))
        XCTAssertEqual(try adapter.read(output).first?.transport, desired.transport)
    }

    func testDottedAssignmentsStayInTheirOriginalScope() throws {
        let input = #"""
        [mcp_servers]
        "a.b".command = "node"
        "a.b".startup_timeout_sec = 20
        [projects."/tmp"]
        trust_level = "trusted"
        """#
        let adapter = AgentAdapter(.codex)
        let desired = MCPServer(id: "a.b", transport: .stdio(command: "node", args: ["test"], env: [:]))
        let output = try XCTUnwrap(adapter.merge(Data(input.utf8), servers: [desired], removing: []))
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains(#""a.b"."args" = ["test"]"#))
        XCTAssertTrue(text.contains(#"[projects."/tmp"]"#))
        XCTAssertEqual(try adapter.read(output).first?.transport, desired.transport)
    }

    func testUnsupportedManagedFormsFailSafely() throws {
        let adapter = AgentAdapter(.codex)
        let desired = MCPServer(id: "x", transport: .stdio(command: "node", args: [], env: [:]))
        for input in [#"mcp_servers = { x = { command = "node" } }"#, "[[mcp_servers.x]]\ncommand = 'node'", "[mcp_servers.x]\nargs = ["] {
            XCTAssertThrowsError(try adapter.merge(Data(input.utf8), servers: [desired], removing: []))
        }
    }
}
