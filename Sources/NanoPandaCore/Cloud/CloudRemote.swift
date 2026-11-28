import Foundation

public typealias CloudHTTPExecutor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public struct CloudRemoteObject: Equatable, Sendable {
    public let data: Data
    public let etag: String?
}

public struct CloudRemoteMetadata: Equatable, Sendable {
    public let etag: String?
    public let lastModified: String?
    public let size: Int64?
}

public enum CloudWriteCondition: Equatable, Sendable {
    case none
    case missing
    case matches(String)

    fileprivate var headers: [String: String] {
        switch self {
        case .none: return [:]
        case .missing: return ["If-None-Match": "*"]
        case let .matches(tag): return ["If-Match": tag]
        }
    }
}

public enum CloudRemoteError: LocalizedError {
    case preconditionFailed
    case conditionalWriteUnsupported
    case http(Int)
    case invalidResponse
    case objectTooLarge

    public var errorDescription: String? {
        switch self {
        case .preconditionFailed:
            return "远端对象已改变，请重新读取后再同步。"
        case .conditionalWriteUnsupported:
            return "远端服务不支持条件写入。"
        case .objectTooLarge:
            return "远端云端数据超过 32 MB。"
        case .invalidResponse:
            return "远端服务返回了无法识别的响应。"
        case let .http(status):
            let reason: String
            switch status {
            case 300...399: reason = "请使用服务的最终地址。云端同步不会跟随重定向。"
            case 401, 403: reason = "远端认证失败或账号缺少权限。"
            case 404: reason = "远端 Bucket 或路径不存在。"
            case 405: reason = "远端服务不允许此操作。"
            case 409: reason = "远端路径有冲突，请检查目录和远端文件名。"
            case 423: reason = "远端路径已被锁定。"
            case 429: reason = "远端服务请求过多，请稍后重试。"
            case 507: reason = "远端存储空间不足。"
            case 500...599: reason = "远端服务暂时无法处理请求。"
            default: reason = "远端服务拒绝了请求，请检查连接和路径设置。"
            }
            return "\(reason)（HTTP \(status)）"
        }
    }
}

public struct CloudRemote: Sendable {
    private let backend: any CloudRemoteBackend
    private let httpExecutor: CloudHTTPExecutor

    public init(target: CloudTarget, execute: @escaping CloudHTTPExecutor = { try await CloudRemote.execute($0) }) throws {
        try target.validate()
        switch target {
        case let .s3(config): backend = try S3CloudClient(target: config)
        case let .webDAV(config): backend = try WebDAVCloudClient(target: config)
        }
        httpExecutor = execute
    }

    public func read(_ key: String) async throws -> CloudRemoteObject? {
        try CloudAddress.validateKey(key)
        let result = try await send(backend.request("GET", key: key, headers: [:], body: nil))
        if result.status == 404 { return nil }
        try result.requireSuccess()
        return CloudRemoteObject(data: result.data, etag: result.response.value(forHTTPHeaderField: "ETag"))
    }

    public func metadata(_ key: String) async throws -> CloudRemoteMetadata? {
        try CloudAddress.validateKey(key)
        let result = try await send(backend.request("HEAD", key: key, headers: [:], body: nil))
        if result.status == 404 { return nil }
        try result.requireSuccess()
        return CloudRemoteMetadata(
            etag: result.response.value(forHTTPHeaderField: "ETag"),
            lastModified: result.response.value(forHTTPHeaderField: "Last-Modified"),
            size: result.response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        )
    }

    @discardableResult
    public func write(_ data: Data, to key: String, condition: CloudWriteCondition) async throws -> String? {
        try CloudAddress.validateKey(key)
        guard data.count <= CloudEnvelope.fileLimit else { throw CloudEnvelope.fileTooLarge }
        if case let .matches(etag) = condition, etag.rangeOfCharacter(from: .controlCharacters) != nil {
            throw CloudRemoteError.invalidResponse
        }
        var headers = condition.headers
        headers["Content-Type"] = "application/json"
        let request = try backend.request("PUT", key: key, headers: headers, body: data)
        let result = try await backend.write(request, key: key, send: send)
        if condition != .none {
            if result.status == 412 {
                throw CloudRemoteError.preconditionFailed
            }
            if [400, 501].contains(result.status) { throw CloudRemoteError.conditionalWriteUnsupported }
        }
        try result.requireSuccess()
        return result.response.value(forHTTPHeaderField: "ETag")
    }

    public func list(prefix: String) async throws -> [String] {
        guard prefix.hasSuffix("/") else { throw PandaError.invalid("远端快照目录必须以 / 结尾。") }
        try CloudAddress.validateKey(String(prefix.dropLast()))
        return try await backend.list(prefix: prefix, send: send)
    }

    public func delete(_ key: String) async throws {
        try CloudAddress.validateKey(key)
        let result = try await send(backend.request("DELETE", key: key, headers: [:], body: nil))
        if result.status != 404 { try result.requireSuccess() }
    }

    public func testConnection() async throws {
        try await backend.testConnection(send: send)
    }

    private func send(_ request: URLRequest) async throws -> CloudHTTPResult {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await httpExecutor(request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw PandaError.invalid("连接远端服务超时。")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                    .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw PandaError.invalid("无法验证远端服务的 TLS 连接。")
            default: throw PandaError.invalid("无法连接远端服务，请检查地址和网络连接。")
            }
        }
        guard result.0.count <= CloudEnvelope.fileLimit else { throw CloudRemoteError.objectTooLarge }
        return CloudHTTPResult(data: result.0, response: result.1)
    }

    public static func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw CloudRemoteError.invalidResponse }
        // Failure bodies are not consumed by either client. A HEAD Content-Length describes a GET.
        guard (200..<300).contains(response.statusCode), request.httpMethod != "HEAD" else {
            return (Data(), response)
        }
        let size = response.expectedContentLength
        guard size <= Int64(CloudEnvelope.fileLimit) else { throw CloudRemoteError.objectTooLarge }
        var data = Data()
        if size > 0 { data.reserveCapacity(Int(size)) }
        for try await byte in bytes {
            guard data.count < CloudEnvelope.fileLimit else { throw CloudRemoteError.objectTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: RejectCloudRedirects(), delegateQueue: nil)
    }()
}

private final class RejectCloudRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct CloudHTTPResult {
    let data: Data
    let response: HTTPURLResponse

    var status: Int { response.statusCode }

    func requireSuccess() throws {
        guard (200..<300).contains(status) else { throw CloudRemoteError.http(status) }
    }
}

typealias SendCloudRequest = (URLRequest) async throws -> CloudHTTPResult

protocol CloudRemoteBackend: Sendable {
    func request(_ method: String, key: String?, headers: [String: String], body: Data?) throws -> URLRequest
    func write(_ request: URLRequest, key: String, send: SendCloudRequest) async throws -> CloudHTTPResult
    func list(prefix: String, send: SendCloudRequest) async throws -> [String]
    func testConnection(send: SendCloudRequest) async throws
}
