import Foundation
import XCTest
@testable import NanoPandaCore

final class CLIAuthStatusTests: XCTestCase {
    func testGitHubShowsAllAccountsAndDoesNotTreatNetworkErrorsAsSignedOut() {
        let output = result("""
            {"hosts":{
              "github.example.com":[
                {"state":"success","login":"example","active":true,"token":"test-value"},
                {"state":"error","login":"former","active":false,"error":"HTTP 401: Bad credentials"}],
              "github.com":[
                {"state":"timeout","login":"offline","active":true,"error":"operation timed out"}]
            }}
            """)

        XCTAssertEqual(CLIAuthProvider.github.parse(output), .accounts([
            CLIAuthAccount(host: "github.com", login: "offline", active: true, state: .unverified),
            CLIAuthAccount(host: "github.example.com", login: "example", active: true, state: .signedIn),
            CLIAuthAccount(host: "github.example.com", login: "former", active: false, state: .reauthenticationRequired)
        ]))
        XCTAssertTrue(CLIAuthProvider.github.arguments.contains("--no-refresh"))
    }

    func testGitLabKeepsPartialResultsOnNonzeroExit() {
        let output = result("""
            {"hosts":[
              {"host":"gitlab.com","state":"success","user":"example"},
              {"host":"private.example:8443","state":"error","error":"GET https://private.example/api/v4/user: 401 {message: 401 Unauthorized}","token_source":"keyring"},
              {"host":"empty.example","state":"error","token_source":"none"},
              {"host":"offline.example","state":"error","error":"dial tcp: no such host"}
            ]}
            """, exitCode: 1)

        XCTAssertEqual(CLIAuthProvider.gitlab.parse(output), .accounts([
            CLIAuthAccount(host: "empty.example", login: nil, active: false, state: .signedOut),
            CLIAuthAccount(host: "gitlab.com", login: "example", active: false, state: .signedIn),
            CLIAuthAccount(host: "offline.example", login: nil, active: false, state: .unverified),
            CLIAuthAccount(host: "private.example:8443", login: nil, active: false, state: .reauthenticationRequired)
        ]))
    }

    func testMissingCredentialsAndUnsupportedClientsStayDistinct() {
        XCTAssertEqual(CLIAuthProvider.github.parse(result(#"{"hosts":{}}"#)), .signedOut)
        XCTAssertEqual(CLIAuthProvider.gitlab.parse(result(
            "", stderr: "no GitLab instances have been authenticated with glab", exitCode: 1
        )), .signedOut)
        XCTAssertEqual(CLIAuthProvider.github.parse(result(
            "", stderr: "unknown flag: --no-refresh", exitCode: 1
        )), .unsupportedVersion)
        XCTAssertEqual(CLIAuthProvider.gitlab.parse(result(
            "", stderr: "permission denied", exitCode: 1
        )), .unverified)
        XCTAssertEqual(CLIAuthProvider.gitlab.parse(result("{}")), .unverified)
    }

    func testStatusRunnerCapturesBothStreamsAndTerminatesOnTimeout() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let output = try XCTUnwrap(CLIStatusCommand.run(
            executable: shell,
            arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"]
        ))
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "stdout")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "stderr")
        XCTAssertEqual(output.exitCode, 7)

        let clock = ContinuousClock()
        let started = clock.now
        XCTAssertNil(CLIStatusCommand.run(
            executable: shell, arguments: ["-c", "exec /bin/sleep 10"], timeout: .milliseconds(100)
        ))
        XCTAssertLessThan(clock.now - started, .seconds(3))
    }

    private func result(_ stdout: String, stderr: String = "", exitCode: Int32 = 0) -> CLIStatusCommand.Output {
        CLIStatusCommand.Output(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: exitCode)
    }
}
