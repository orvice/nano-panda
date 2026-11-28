import CryptoKit
import Darwin
import Foundation

public struct CloudConfiguration: Codable, Equatable, Sendable {
    public var target: CloudTarget
    public var encryption: CloudEncryption
    public var automaticSync: Bool

    public init(target: CloudTarget, encryption: CloudEncryption, automaticSync: Bool = false) {
        self.target = target
        self.encryption = encryption
        self.automaticSync = automaticSync
    }

    public func validate() throws {
        try target.validate()
        try encryption.validate()
    }
}

public enum CloudTarget: Codable, Equatable, Sendable {
    case s3(S3CloudTarget)
    case webDAV(WebDAVCloudTarget)

    public var objectKey: String {
        switch self {
        case let .s3(target): return target.objectKey
        case let .webDAV(target): return target.objectKey
        }
    }

    public var snapshotPrefix: String {
        let directories = objectKey.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        // Keep each main object’s history in its own collection, even in a shared parent directory.
        let digest = SHA256.hash(data: Data(objectKey.utf8))
        let namespace = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return (directories.map(String.init) + ["snapshots", namespace, ""]).joined(separator: "/")
    }

    func validate() throws {
        try CloudAddress.validateKey(objectKey)
        switch self {
        case let .s3(target):
            let address = try CloudAddress.endpoint(target.endpoint, allowHTTP: target.allowHTTP)
            let bucketPattern = #"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"#
            guard target.bucket.range(of: bucketPattern, options: .regularExpression) != nil,
                  !target.bucket.contains(".."), !target.bucket.contains(".-"), !target.bucket.contains("-."),
                  target.pathStyle || CloudAddress.canPrefixBucket(to: address),
                  target.region.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
                throw PandaError.invalid("请输入有效的 S3 Bucket、Region 和寻址方式。")
            }
            guard target.accessKeyID.range(of: #"^[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil,
                  !target.secretAccessKey.isEmpty,
                  target.secretAccessKey.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw PandaError.invalid("请输入有效的 S3 访问凭据。")
            }
        case let .webDAV(target):
            _ = try CloudAddress.endpoint(target.endpoint, allowHTTP: target.allowHTTP)
            guard !target.username.isEmpty, !target.username.contains(":"),
                  target.username.rangeOfCharacter(from: .controlCharacters) == nil,
                  !target.password.isEmpty, target.password.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw PandaError.invalid("请输入有效的 WebDAV 用户名和密码。")
            }
        }
    }
}

public struct S3CloudTarget: Codable, Equatable, Sendable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var objectKey: String
    public var accessKeyID: String
    public var secretAccessKey: String
    public var pathStyle: Bool
    public var allowHTTP: Bool

    public init(
        endpoint: String, region: String, bucket: String, objectKey: String,
        accessKeyID: String, secretAccessKey: String, pathStyle: Bool = true, allowHTTP: Bool = false
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.objectKey = objectKey
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.pathStyle = pathStyle
        self.allowHTTP = allowHTTP
    }
}

public struct WebDAVCloudTarget: Codable, Equatable, Sendable {
    public var endpoint: String
    public var objectKey: String
    public var username: String
    public var password: String
    public var allowHTTP: Bool

    public init(endpoint: String, objectKey: String, username: String, password: String, allowHTTP: Bool = false) {
        self.endpoint = endpoint
        self.objectKey = objectKey
        self.username = username
        self.password = password
        self.allowHTTP = allowHTTP
    }
}

enum CloudAddress {
    static func endpoint(_ input: String, allowHTTP: Bool) throws -> URLComponents {
        guard input.rangeOfCharacter(from: .controlCharacters) == nil,
              var address = URLComponents(string: input),
              let scheme = address.scheme?.lowercased(),
              let host = address.host?.lowercased(), !host.isEmpty,
              address.user == nil, address.password == nil, address.query == nil, address.fragment == nil,
              address.path.rangeOfCharacter(from: .controlCharacters) == nil, !address.path.contains("\\"),
              (address.port.map { (1...65535).contains($0) } ?? true),
              !address.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let encodedHost = address.percentEncodedHost, isValidHost(encodedHost),
              address.url != nil else {
            throw PandaError.invalid("请输入有效的云端服务地址。")
        }
        guard scheme == "https" || (scheme == "http" && allowHTTP && isLocal(host)) else {
            throw PandaError.invalid("云端同步需要 HTTPS。内网地址可显式启用 HTTP。")
        }
        address.scheme = scheme
        address.host = host
        return address
    }

    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 1024,
              key.rangeOfCharacter(from: .controlCharacters) == nil, !key.contains("\\"),
              !key.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PandaError.invalid("请输入有效的远端文件路径（最多 1024 UTF-8 字节）。")
        }
    }

    static func encode(_ value: String, keepSlashes: Bool = false) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                encoded.append(byte)
            case 47 where keepSlashes:
                encoded.append(byte)
            default:
                encoded.append(37)
                encoded.append(hex[Int(byte >> 4)])
                encoded.append(hex[Int(byte & 15)])
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func append(_ path: String?, to endpoint: URLComponents, collection: Bool = false) -> URLComponents {
        var address = endpoint
        var base = endpoint.percentEncodedPath
        while base.last == "/" { base.removeLast() }
        if let path { base += "/" + encode(path, keepSlashes: true) }
        if collection { base += "/" }
        address.percentEncodedPath = base
        return address
    }

    static func canPrefixBucket(to endpoint: URLComponents) -> Bool {
        guard let host = endpoint.host, !host.contains(":") else { return false }
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) != 1
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let address = host.dropFirst().dropLast().split(separator: "%", maxSplits: 1).first
            var ipv6 = in6_addr()
            return address.map { inet_pton(AF_INET6, String($0), &ipv6) == 1 } ?? false
        }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            $0.range(of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"#, options: .regularExpression) != nil
        }
    }

    private static func isLocal(_ host: String) -> Bool {
        let bareHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let numericHost = String(bareHost.prefix { $0 != "%" })
        var ipv4 = in_addr()
        if inet_pton(AF_INET, bareHost, &ipv4) == 1 {
            let number = UInt32(bigEndian: ipv4.s_addr)
            return number >> 24 == 10 || number >> 24 == 127 || number >> 20 == 0xac1 ||
                number >> 16 == 0xc0a8 || number >> 16 == 0xa9fe
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, numericHost, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) ||
                    (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            }
        }
        let localName = bareHost.hasSuffix(".") ? String(bareHost.dropLast()) : bareHost
        return localName.hasSuffix(".local") || localName.hasSuffix(".lan") || localName.hasSuffix(".internal") ||
            localName.hasSuffix(".localhost") ||
            localName.range(of: #"^[a-z](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
    }
}
