import XCTest
@testable import NanoPandaCore

final class AdapterTests: XCTestCase {
    private let command = Transport.stdio(command: "/opt/test app/run", args: ["", "a b", "#[text]"], env: ["KEY.X": "a\nb"])

    func testStdioRoundTripAndUntouchedConfigurationForAllAdapters() throws {
        for tool in ToolID.allCases {
            let adapter = AgentAdapter(tool)
            let sentinel = tool == .codex ? "model = 'example' # untouched\n" : #""ui": { "theme": "dark" }"#
            let input = Data((tool == .codex ? sentinel : "{\n  " + sentinel + "\n}\n").utf8)
            let entry = MCPServer(id: "demo.server", transport: command, enabledTools: [tool])
            let output = try XCTUnwrap(adapter.merge(input, servers: [entry], removing: []), tool.title)
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(sentinel), tool.title)
            let server = try XCTUnwrap(adapter.read(output).first, tool.title)
            XCTAssertEqual(server.id, entry.id, tool.title)
            XCTAssertEqual(server.transport, entry.transport, tool.title)
            XCTAssertEqual(server.enabledTools, entry.enabledTools, tool.title)
            XCTAssertEqual(try adapter.merge(output, servers: [entry], removing: []), output, tool.title)
            let removed = try XCTUnwrap(adapter.merge(output, servers: [], removing: [entry.id]))
            XCTAssertTrue(try adapter.read(removed).isEmpty, tool.title)
            XCTAssertTrue(String(decoding: removed, as: UTF8.self).contains(sentinel), tool.title)
        }
    }

    func testHTTPRoundTripForAllAdaptersAndSSEForTypedAdapters() throws {
        for tool in ToolID.allCases {
            let adapter = AgentAdapter(tool)
            let transport = Transport.http(url: "https://example.invalid/mcp", headers: ["X-Test": "token"],
                                           bearerTokenEnvVar: tool == .codex ? "MCP_AUTH" : nil)
            let server = MCPServer(id: "remote", transport: transport)
            let output = try XCTUnwrap(adapter.merge(nil, servers: [server], removing: []))
            XCTAssertEqual(try adapter.read(output).first?.transport, transport, tool.title)
        }
        for tool in [ToolID.claudeCode, .geminiCLI] {
            let adapter = AgentAdapter(tool)
            let transport = Transport.sse(url: "https://example.invalid/events", headers: ["X-Test": "token"])
            let output = try XCTUnwrap(adapter.merge(nil, servers: [MCPServer(id: "events", transport: transport)], removing: []))
            XCTAssertEqual(try adapter.read(output).first?.transport, transport, tool.title)
        }
    }

    func testSwitchTransportPreservesUnknownFieldsAndOtherServers() throws {
        let adapter = AgentAdapter(.claudeCode)
        let input = Data(#"{"mcpServers":{"local":{"type":"stdio","command":"node","env":{"A":"b"},"custom":99},"other":{"command":"a"}},"project":{"mcpServers":{"nested":true}}}"#.utf8)
        let entry = MCPServer(
            id: "local", transport: .http(url: "https://example.invalid/mcp", headers: [:], bearerTokenEnvVar: nil),
            perToolOverrides: [.claudeCode: ServerOverride(fields: ["custom": .integer(1)])]
        )
        let output = try XCTUnwrap(adapter.merge(input, servers: [entry], removing: []))
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains(#""custom":99"#))
        XCTAssertTrue(text.contains(#""other":{"command":"a"}"#))
        XCTAssertTrue(text.contains(#""project":{"mcpServers":{"nested":true}}"#))
        XCTAssertFalse(text.contains(#""env""#))
        let read = try adapter.read(output)
        XCTAssertEqual(read.first { $0.id == "local" }?.transport, entry.transport)
    }

    func testOpenCodeV1AndV2PreserveCommentsAndEnableFlags() throws {
        let adapter = AgentAdapter(.openCode)
        let v1 = """
        {
          // config note
          "mcp": {
            "old": { "type": "local", "command": ["node"], "enabled": false },
            "other": { "type": "local", "command": ["npm"] }, // retain note
          },
        }
        """
        let v2 = """
        {
          // config note
          "mcp": {
            "timeout": { "startup": 2000 },
            "servers": {
              "old": { "type": "local", "command": ["node"], "disabled": true },
              "other": { "type": "local", "command": ["npm"] }, // retain note
            },
          },
        }
        """
        for input in [v1, v2] {
            XCTAssertEqual(try adapter.read(Data(input.utf8)).first?.enabledTools, [])
            let servers = [MCPServer(id: "added", transport: command)]
            let output = try XCTUnwrap(adapter.merge(Data(input.utf8), servers: servers, removing: ["old"]))
            let text = String(decoding: output, as: UTF8.self)
            XCTAssertTrue(text.contains("// config note"))
            XCTAssertTrue(text.contains(#""other": { "type": "local", "command": ["npm"] }, // retain note"#))
            XCTAssertEqual(try adapter.read(output).first { $0.id == "added" }?.enabledTools, [.openCode])
            if input == v2 {
                XCTAssertTrue(text.contains(#""timeout": { "startup": 2000 }"#))
                XCTAssertFalse(text.contains(#""enabled""#))
            } else {
                XCTAssertTrue(text.contains(#""enabled""#))
                XCTAssertFalse(text.contains(#""servers""#))
            }
        }
    }

    func testJSONHandlesAddingAndRemovingAdjacentProperties() throws {
        let adapter = AgentAdapter(.cursor)
        let input = Data(#"{"mcpServers":{"first":{"command":"x"},"second":{"command":"x"},"third":{"command":"x"}}}"#.utf8)
        for removed: Set<String> in [["first"], ["third"], ["first", "third"], ["first", "second", "third"]] {
            let add = MCPServer(id: "added", transport: command)
            for additions in [[add], []] {
                let output = try adapter.merge(input, servers: additions, removing: removed)
                let ids = Set(try adapter.read(output).map(\.id))
                XCTAssertEqual(ids, Set(["first", "second", "third"]).subtracting(removed).union(additions.map(\.id)))
            }
        }
    }

    func testPasteAcceptsWrapperFragmentAndSingleEntry() throws {
        for text in [
            #"{"mcpServers": {"pasted": {"command": "node"}}}"#,
            #""pasted": {"command": "node"},"#,
            #"{"command": "node"}"#
        ] {
            let entries = try AgentAdapter.paste(text, defaultID: "pasted")
            XCTAssertEqual(entries.first?.id, "pasted")
            XCTAssertEqual(entries.first?.transport, .stdio(command: "node", args: [], env: [:]))
        }
    }

    func testStrictJSONAndMalformedContentsCannotBeOverwritten() throws {
        let adapter = AgentAdapter(.cursor)
        let server = MCPServer(id: "x", transport: command)
        for text in [#"{"mcpServers":null}"#, #"{"mcpServers":{},"mcpServers":{}}"#, #"{"mcpServers":{},}"#, "{"] {
            XCTAssertThrowsError(try adapter.merge(Data(text.utf8), servers: [server], removing: []))
        }
    }
}
