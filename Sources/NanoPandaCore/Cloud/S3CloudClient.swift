import Foundation

struct S3CloudClient: CloudRemoteBackend {
    private let endpoint: URLComponents
    private let bucketPath: String?
    private let target: S3CloudTarget

    init(target: S3CloudTarget) throws {
        self.target = target
        var address = try CloudAddress.endpoint(target.endpoint, allowHTTP: target.allowHTTP)
        if target.pathStyle {
            bucketPath = target.bucket
        } else {
            guard let host = address.host else { throw CloudRemoteError.invalidResponse }
            address.host = "\(target.bucket).\(host)"
            bucketPath = nil
        }
        address.percentEncodedPath = address.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { CloudAddress.encode(String($0).removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
        endpoint = address
    }

    func request(_ method: String, key: String?, headers: [String: String], body: Data?) throws -> URLRequest {
        try request(method, key: key, query: [:], headers: headers, body: body)
    }

    private func request(
        _ method: String, key: String?, query: [String: String],
        headers: [String: String] = [:], body: Data? = nil
    ) throws -> URLRequest {
        let path = [bucketPath, key].compactMap { $0 }.joined(separator: "/")
        var address = CloudAddress.append(path.isEmpty ? nil : path, to: endpoint)
        if address.percentEncodedPath.isEmpty { address.percentEncodedPath = "/" }
        let canonicalQuery = query.map { "\(CloudAddress.encode($0.key))=\(CloudAddress.encode($0.value))" }
            .sorted().joined(separator: "&")
        if !canonicalQuery.isEmpty { address.percentEncodedQuery = canonicalQuery }
        guard let url = address.url else { throw PandaError.invalid("无法生成 S3 请求地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try S3RequestSigner.sign(
            request, region: target.region, accessKeyID: target.accessKeyID, secretAccessKey: target.secretAccessKey,
            at: Date()
        )
    }

    func write(_ request: URLRequest, key: String, send: SendCloudRequest) async throws -> CloudHTTPResult {
        let result = try await send(request)
        if result.status == 409, request.value(forHTTPHeaderField: "If-Match") != nil ||
            request.value(forHTTPHeaderField: "If-None-Match") != nil {
            throw CloudRemoteError.preconditionFailed
        }
        return result
    }

    func list(prefix: String, send: SendCloudRequest) async throws -> [String] {
        var keys = Set<String>()
        var cursor: String?
        var used = Set<String>()
        repeat {
            var query = ["list-type": "2", "prefix": prefix]
            query["continuation-token"] = cursor
            let result = try await send(request("GET", key: nil, query: query))
            try result.requireSuccess()
            let page = try CloudXML.parse(result.data, expecting: "ListBucketResult")
            for item in page.children(named: "Contents") {
                guard let value = item.child(named: "Key")?.text else { throw CloudRemoteError.invalidResponse }
                let key = page.child(named: "EncodingType")?.text == "url" ? value.removingPercentEncoding : value
                if let key, key.hasPrefix(prefix), (try? CloudAddress.validateKey(key)) != nil {
                    keys.insert(key)
                }
            }
            let truncated = page.child(named: "IsTruncated")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = nil
            if truncated == "true" {
                guard let next = page.child(named: "NextContinuationToken")?.text, !next.isEmpty,
                      used.insert(next).inserted else { throw CloudRemoteError.invalidResponse }
                cursor = next
            }
        } while cursor != nil
        return keys.sorted()
    }

    func testConnection(send: SendCloudRequest) async throws {
        let result = try await send(request("HEAD", key: nil, headers: [:], body: nil))
        try result.requireSuccess()
    }

}
