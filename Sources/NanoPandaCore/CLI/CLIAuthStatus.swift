import Foundation

public enum CLIAuthProvider: String, CaseIterable, Sendable {
    case github = "gh"
    case gitlab = "glab"

    var arguments: [String] {
        switch self {
        case .github: return ["auth", "status", "--json", "hosts", "--no-refresh"]
        case .gitlab: return ["auth", "status", "--all", "--output", "json"]
        }
    }

    public func check(executable: URL) -> CLIAuthStatus {
        guard let output = CLIStatusCommand.run(executable: executable, arguments: arguments) else {
            return .unverified
        }
        return parse(output)
    }

    func parse(_ output: CLIStatusCommand.Output) -> CLIAuthStatus {
        let decoder = JSONDecoder()
        let accounts: [CLIAuthAccount]
        switch self {
        case .github:
            guard let result = try? decoder.decode(GitHubStatus.self, from: output.stdout) else {
                return unsupported(output.stderr, flags: ["--json", "--no-refresh"])
            }
            accounts = result.hosts.keys.sorted().flatMap { host in
                result.hosts[host, default: []].map {
                    Self.account(host: host, login: $0.login, active: $0.active,
                                 state: $0.state, error: $0.error, tokenSource: nil)
                }
            }
        case .gitlab:
            guard let result = try? decoder.decode(GitLabStatus.self, from: output.stdout) else {
                let stderr = String(decoding: output.stderr, as: UTF8.self)
                if stderr.localizedCaseInsensitiveContains("no GitLab instances have been authenticated with glab") {
                    return .signedOut
                }
                return unsupported(output.stderr, flags: ["--all", "--output"])
            }
            accounts = result.hosts.sorted { $0.host < $1.host }.map {
                Self.account(host: $0.host, login: $0.user, active: nil,
                             state: $0.state, error: $0.error, tokenSource: $0.tokenSource)
            }
        }
        if accounts.isEmpty { return output.exitCode == 0 ? .signedOut : .unverified }
        return .accounts(accounts)
    }

    private func unsupported(_ data: Data, flags: [String]) -> CLIAuthStatus {
        let message = String(decoding: data, as: UTF8.self)
        return flags.contains { message.contains("unknown flag: \($0)") } ? .unsupportedVersion : .unverified
    }

    private static func account(
        host: String, login: String?, active: Bool?, state: String, error: String?, tokenSource: String?
    ) -> CLIAuthAccount {
        let status: CLIAuthAccount.State
        switch state {
        case "success":
            status = .signedIn
        case "refresh_expired":
            status = .reauthenticationRequired
        case "error":
            let detail = error ?? ""
            if tokenSource == "none" {
                status = .signedOut
            } else if detail.range(of: #"(?i)(?:\bHTTP\s+401\b|:\s*401\s+(?:unauthorized|\{)|\binvalid_grant\b)"#,
                                   options: .regularExpression) != nil {
                status = .reauthenticationRequired
            } else {
                status = .unverified
            }
        default:
            status = .unverified
        }

        return CLIAuthAccount(
            host: safeLabel(host, punctuation: ".-:[]"),
            login: login.flatMap { safeLabel($0, punctuation: ".-_[]") },
            active: active == true,
            state: status
        )
    }

    private static func safeLabel(_ value: String, punctuation: String) -> String? {
        guard (1...253).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || punctuation.utf8.contains(byte)
              }) else { return nil }
        return value
    }

    private struct GitHubStatus: Decodable {
        let hosts: [String: [Entry]]

        struct Entry: Decodable {
            let state: String
            let login: String?
            let active: Bool?
            let error: String?
        }
    }

    private struct GitLabStatus: Decodable {
        let hosts: [Entry]

        struct Entry: Decodable {
            let host: String
            let state: String
            let user: String?
            let error: String?
            let tokenSource: String?

            enum CodingKeys: String, CodingKey {
                case host, state, user, error
                case tokenSource = "token_source"
            }
        }
    }
}

public enum CLIAuthStatus: Equatable, Sendable {
    case accounts([CLIAuthAccount])
    case signedOut
    case unverified
    case unsupportedVersion
}

public struct CLIAuthAccount: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case signedIn
        case signedOut
        case reauthenticationRequired
        case unverified
    }

    public let host: String?
    public let login: String?
    public let active: Bool
    public let state: State
}
