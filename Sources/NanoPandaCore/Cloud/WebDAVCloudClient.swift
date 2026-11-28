import Foundation

struct WebDAVCloudClient: CloudRemoteBackend {
    private static let resourceTypeQuery = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>
        """.utf8)

    private let endpoint: URLComponents
    private let authorization: String
    private let objectKey: String

    init(target: WebDAVCloudTarget) throws {
        endpoint = try CloudAddress.endpoint(target.endpoint, allowHTTP: target.allowHTTP)
        authorization = "Basic " + Data("\(target.username):\(target.password)".utf8).base64EncodedString()
        objectKey = target.objectKey
    }

    func request(_ method: String, key: String?, headers: [String: String], body: Data?) throws -> URLRequest {
        try request(method, key: key, collection: false, headers: headers, body: body)
    }

    private func request(
        _ method: String, key: String?, collection: Bool,
        headers: [String: String] = [:], body: Data? = nil
    ) throws -> URLRequest {
        let components = CloudAddress.append(key, to: endpoint, collection: collection)
        guard let url = components.url else { throw PandaError.invalid("无法生成 WebDAV 请求地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func write(_ request: URLRequest, key: String, send: SendCloudRequest) async throws -> CloudHTTPResult {
        let result = try await send(request)
        let directories = key.split(separator: "/").dropLast()
        guard [404, 409].contains(result.status), !directories.isEmpty else { return result }

        var path: [Substring] = []
        for directory in directories {
            path.append(directory)
            let collection = try self.request("MKCOL", key: path.joined(separator: "/"), collection: true)
            let creation = try await send(collection)
            if creation.status != 405 { try creation.requireSuccess() }
        }
        return try await send(request)
    }

    func list(prefix: String, send: SendCloudRequest) async throws -> [String] {
        let request = try propertyRequest(String(prefix.dropLast()), depth: 1)
        let result = try await send(request)
        if result.status == 404 { return [] }
        try result.requireSuccess()

        let document = try CloudXML.parse(result.data, expecting: "multistatus")
        guard let collectionURL = request.url else { throw CloudRemoteError.invalidResponse }
        let collectionPath = collectionURL.path(percentEncoded: false)
        let prefixPath = collectionPath.hasSuffix("/") ? collectionPath : collectionPath + "/"
        let keys = document.children(named: "response").compactMap { response -> String? in
            guard let href = response.child(named: "href")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: href, relativeTo: collectionURL)?.absoluteURL,
                  url.scheme == collectionURL.scheme, url.host == collectionURL.host,
                  effectivePort(url) == effectivePort(collectionURL), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            let path = url.path(percentEncoded: false)
            guard path.hasPrefix(prefixPath), !url.path(percentEncoded: true).hasSuffix("/"),
                  resourceType(response)?.child(named: "collection") == nil else { return nil }
            let name = path.dropFirst(prefixPath.count)
            guard !name.isEmpty, !name.contains("/") else { return nil }
            let key = prefix + name
            return (try? CloudAddress.validateKey(key)) == nil ? nil : key
        }
        return Set(keys).sorted()
    }

    func testConnection(send: SendCloudRequest) async throws {
        // The configured WebDAV endpoint must already exist. Missing object parents can be created on write.
        let result = try await send(propertyRequest(nil, depth: 0))
        try result.requireSuccess()
        let root = try CloudXML.parse(result.data, expecting: "multistatus")
        guard root.children(named: "response").contains(where: { resourceType($0)?.child(named: "collection") != nil }) else {
            throw PandaError.invalid("WebDAV 地址必须指向可访问的目录。")
        }

        var parents = objectKey.split(separator: "/").dropLast()
        while !parents.isEmpty {
            let result = try await send(propertyRequest(parents.joined(separator: "/"), depth: 0))
            if result.status == 404 {
                parents = parents.dropLast()
                continue
            }
            try result.requireSuccess()
            let document = try CloudXML.parse(result.data, expecting: "multistatus")
            guard document.children(named: "response").contains(where: {
                resourceType($0)?.child(named: "collection") != nil
            }) else {
                throw PandaError.invalid("WebDAV 文件的父路径中包含普通文件。")
            }
            break
        }
    }

    private func propertyRequest(_ key: String?, depth: Int) throws -> URLRequest {
        try request(
            "PROPFIND", key: key, collection: true,
            headers: ["Depth": String(depth), "Content-Type": "application/xml; charset=utf-8"],
            body: Self.resourceTypeQuery
        )
    }

    private func resourceType(_ response: CloudXMLNode) -> CloudXMLNode? {
        for propertyStatus in response.children(named: "propstat") {
            let status = propertyStatus.child(named: "status")?.text.split(whereSeparator: \.isWhitespace)
            if status?.dropFirst().first == "200",
               let resourceType = propertyStatus.child(named: "prop")?.child(named: "resourcetype") {
                return resourceType
            }
        }
        return nil
    }

    private func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme == "https" ? 443 : 80)
    }
}
