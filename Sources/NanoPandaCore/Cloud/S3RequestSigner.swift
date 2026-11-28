import CryptoKit
import Foundation

enum S3RequestSigner {
    static func sign(
        _ request: URLRequest, region: String, accessKeyID: String, secretAccessKey: String, at date: Date
    ) throws -> URLRequest {
        guard let url = request.url, let address = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = address.percentEncodedHost, let method = request.httpMethod else {
            throw PandaError.invalid("无法生成 S3 请求地址。")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let payloadHash = Self.sha256(request.httpBody ?? Data())
        let defaultPort = address.scheme == "https" ? 443 : 80
        let hostHeader = address.port.flatMap { $0 == defaultPort ? nil : "\(host):\($0)" } ?? host
        var signedHeaders = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
        signedHeaders["host"] = hostHeader
        signedHeaders["x-amz-date"] = timestamp
        signedHeaders["x-amz-content-sha256"] = payloadHash

        let names = signedHeaders.keys.sorted()
        let canonicalHeaders = names.compactMap { name in
            signedHeaders[name].map { value in
                let normalized = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                return "\(name):\(normalized)\n"
            }
        }.joined()
        let signedHeaderNames = names.joined(separator: ";")
        let canonicalRequest = [
            method, address.percentEncodedPath, address.percentEncodedQuery ?? "", canonicalHeaders, signedHeaderNames, payloadHash
        ].joined(separator: "\n")

        let day = String(timestamp.prefix(8))
        let scope = "\(day)/\(region)/s3/aws4_request"
        let algorithm = "AWS4-HMAC-SHA256"
        let signingKey = [day, region, "s3", "aws4_request"].reduce(Data("AWS4\(secretAccessKey)".utf8)) {
            Self.hmac($1, key: $0)
        }
        let stringToSign = [algorithm, timestamp, scope, Self.sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = Self.hex(Self.hmac(stringToSign, key: signingKey))
        let authorization =
            "\(algorithm) Credential=\(accessKeyID)/\(scope),SignedHeaders=\(signedHeaderNames),Signature=\(signature)"

        var request = request
        for (name, value) in signedHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hmac(_ value: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
