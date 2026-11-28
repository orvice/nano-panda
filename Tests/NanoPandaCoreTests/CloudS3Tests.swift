import Foundation
@testable import NanoPandaCore
import XCTest

final class CloudS3Tests: XCTestCase {
    func testS3AuthorizationMatchesAWSPublishedSignature() throws {
        // AWS S3 API Guide, Signature Calculations, GET Object example.
        let url = try XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        var request = URLRequest(url: url)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let signed = try S3RequestSigner.sign(
            request, region: "us-east-1", accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", at: date
        )
        let authorization = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," +
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," +
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Authorization"), authorization)
    }

    func testVirtualHostedRequestsEscapeObjectKey() async throws {
        let target = CloudTarget.s3(S3CloudTarget(
            endpoint: "https://s3.example.test:8443/s3", region: "us-east-1", bucket: "fixture-bucket",
            objectKey: "profiles/配置 + %.json", accessKeyID: "fixture", secretAccessKey: "fixture-secret",
            pathStyle: false
        ))
        let remote = try CloudRemote(target: target, execute: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://fixture-bucket.s3.example.test:8443/s3/profiles/%E9%85%8D%E7%BD%AE%20%2B%20%25.json"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "fixture-bucket.s3.example.test:8443")
            return try s3Response(request, status: 200, body: "encrypted fixture", headers: ["ETag": "\"fixture\""])
        })
        let result = try await remote.read(target.objectKey)
        XCTAssertEqual(result?.etag, "\"fixture\"")
        XCTAssertEqual(result?.data, Data("encrypted fixture".utf8))
    }

    func testPathStyleListFollowsEncodedContinuationTokens() async throws {
        let target = CloudTarget.s3(S3CloudTarget(
            endpoint: "https://s3.example.test/s3", region: "us-east-1", bucket: "fixture-bucket",
            objectKey: "profiles/config.json", accessKeyID: "fixture", secretAccessKey: "fixture-secret"
        ))
        let remote = try CloudRemote(target: target, execute: { request in
            XCTAssertEqual(request.url?.path, "/s3/fixture-bucket")
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.query {
            case "list-type=2&prefix=profiles%2Fsnapshots%2F":
                return try s3Response(request, status: 200, body: """
                    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                      <IsTruncated>true</IsTruncated><NextContinuationToken>token+=/&amp;</NextContinuationToken>
                      <Contents><Key>profiles/snapshots/a.json</Key></Contents>
                      <Contents><Key>unrelated.json</Key></Contents>
                    </ListBucketResult>
                    """)
            case "continuation-token=token%2B%3D%2F%26&list-type=2&prefix=profiles%2Fsnapshots%2F":
                return try s3Response(request, status: 200, body: """
                    <ListBucketResult><IsTruncated>false</IsTruncated>
                      <Contents><Key>profiles/snapshots/b.json</Key></Contents>
                    </ListBucketResult>
                    """)
            default:
                XCTFail("Invalid list request: \(request.url?.absoluteString ?? "")")
                return try s3Response(request, status: 400)
            }
        })
        let keys = try await remote.list(prefix: target.snapshotPrefix)
        XCTAssertEqual(keys, ["profiles/snapshots/a.json", "profiles/snapshots/b.json"])
    }

    func testConditionRejectionAndBucketConnectionAreObservable() async throws {
        let target = CloudTarget.s3(S3CloudTarget(
            endpoint: "https://s3.example.test", region: "us-east-1", bucket: "fixture-bucket",
            objectKey: "config.json", accessKeyID: "fixture", secretAccessKey: "fixture-secret"
        ))
        let remote = try CloudRemote(target: target, execute: { request in
            switch request.httpMethod {
            case "HEAD":
                XCTAssertEqual(request.url?.path, "/fixture-bucket")
                return try s3Response(request, status: 200)
            case "PUT":
                XCTAssertEqual(request.url?.path, "/fixture-bucket/config.json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                return try s3Response(request, status: request.value(forHTTPHeaderField: "If-Match") == "\"current\"" ? 501 : 409)
            case "DELETE":
                XCTAssertEqual(request.url?.path, "/fixture-bucket/config.json")
                return try s3Response(request, status: 204)
            default: return try s3Response(request, status: 500)
            }
        })
        try await remote.testConnection()
        do {
            _ = try await remote.write(Data("encrypted".utf8), to: target.objectKey, condition: .matches("\"current\""))
            XCTFail("Unsupported conditional write must be distinguished from a race.")
        } catch CloudRemoteError.conditionalWriteUnsupported {}
        do {
            _ = try await remote.write(Data("encrypted".utf8), to: target.objectKey, condition: .missing)
            XCTFail("S3 409 should cause the caller to read again.")
        } catch CloudRemoteError.preconditionFailed {}
        try await remote.delete(target.objectKey)
    }
}

private func s3Response(
    _ request: URLRequest, status: Int, body: String = "", headers: [String: String] = [:]
) throws -> (Data, HTTPURLResponse) {
    let url = try XCTUnwrap(request.url)
    return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
}
