import Foundation
import NanoPandaCore
import XCTest

final class CloudTransportTests: XCTestCase {
    func testWebDAVCreatesParentCollectionsAndConditionallyWrites() async throws {
        let service = DAVFixture()
        let target = CloudTarget.webDAV(WebDAVCloudTarget(
            endpoint: "https://dav.example.test/root", objectKey: "alpha/beta/config.json",
            username: "fixture", password: "pass:word"
        ))
        let remote = try CloudRemote(target: target, execute: { try await service.execute($0) })
        let payload = Data("encrypted fixture".utf8)
        let etag = try await remote.write(payload, to: target.objectKey, condition: .missing)
        XCTAssertEqual(etag, "\"r1\"")
        let object = try await remote.read(target.objectKey)
        XCTAssertEqual(object?.data, payload)
        XCTAssertEqual(object?.etag, etag)
        do {
            _ = try await remote.write(payload, to: target.objectKey, condition: .missing)
            XCTFail("A conditional write must preserve an existing remote file.")
        } catch CloudRemoteError.preconditionFailed {}
    }

    func testWebDAVListIncludesOnlyFilesInsideSnapshotCollection() async throws {
        let target = CloudTarget.webDAV(WebDAVCloudTarget(
            endpoint: "https://dav.example.test/root/", objectKey: "projects/live.json",
            username: "fixture", password: "test"
        ))
        let namespace = "ac5c61369f0a508715ba0cc2921e173e"
        let prefix = "projects/snapshots/\(namespace)/"
        let remote = try CloudRemote(target: target, execute: { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            XCTAssertEqual(url.absoluteString, "https://dav.example.test/root/\(prefix)")
            let xml = """
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/root/\(prefix)</D:href>
                    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
                    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
                  </D:response>
                  <D:response><D:href>/root/\(prefix)first%20copy.json</D:href></D:response>
                  <D:response><D:href>second.json</D:href></D:response>
                  <D:response><D:href>child/private.json</D:href></D:response>
                  <D:response><D:href>/elsewhere/example.json</D:href></D:response>
                  <D:response><D:href>https://foreign.test/root/\(prefix)private.json</D:href></D:response>
                </D:multistatus>
                """
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 207, httpVersion: nil, headerFields: nil))
            return (Data(xml.utf8), response)
        })
        let contents = try await remote.list(prefix: target.snapshotPrefix)
        XCTAssertEqual(contents, ["\(prefix)first copy.json", "\(prefix)second.json"])
    }

    func testHTTPRequiresExplicitOptInAndLocalAddress() async throws {
        func target(_ endpoint: String, allowHTTP: Bool) -> CloudTarget {
            .webDAV(WebDAVCloudTarget(
                endpoint: endpoint, objectKey: "live.json", username: "fixture", password: "test", allowHTTP: allowHTTP
            ))
        }
        XCTAssertThrowsError(try CloudRemote(target: target("http://127.0.0.1", allowHTTP: false)))
        XCTAssertThrowsError(try CloudRemote(target: target("http://dav.example.test", allowHTTP: true)))
        XCTAssertThrowsError(try CloudRemote(target: target("http://0x08080808", allowHTTP: true)))
        XCTAssertThrowsError(try CloudRemote(target: target("http://8.8.8.8", allowHTTP: true)))
        XCTAssertThrowsError(try CloudRemote(target: target("ftp://127.0.0.1", allowHTTP: true)))
        XCTAssertThrowsError(try CloudRemote(target: target("https://not valid.test", allowHTTP: false)))
        for host in ["127.0.0.1", "[::1]", "10.1.2.3", "172.31.1.10", "192.168.0.1", "nas.local"] {
            let destination = target("http://\(host):8080", allowHTTP: true)
            let remote = try CloudRemote(target: destination, execute: { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(url.scheme, "http")
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
                return (Data(), response)
            })
            let value = try await remote.read(destination.objectKey)
            XCTAssertNil(value)
        }
    }

    func testPasswordEnvelopeRejectsTamperingAndPlaintext() throws {
        let password = CloudEncryption.password("a strong password fixture")
        let secret = "private snapshot note"
        let sealed = try CloudEnvelope.encode(secret, kind: .snapshot, encryption: password)
        let decoded = try CloudEnvelope.decode(String.self, from: sealed, kind: .snapshot, encryption: password)
        XCTAssertEqual(decoded, secret)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains(secret))
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: sealed, kind: .snapshot, encryption: .password("different valid password")
        ))
        XCTAssertThrowsError(try CloudEnvelope.encode(secret, kind: .snapshot, encryption: .password("too short")))

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        var wrongVersion = envelope
        var header = try XCTUnwrap(wrongVersion["header"] as? [String: Any])
        header["version"] = 999
        wrongVersion["header"] = header
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: JSONSerialization.data(withJSONObject: wrongVersion), kind: .snapshot, encryption: password
        ))
        var changedSalt = envelope
        changedSalt["salt"] = Data(repeating: 0xaa, count: 16).base64EncodedString()
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: JSONSerialization.data(withJSONObject: changedSalt), kind: .snapshot, encryption: password
        ))
        var mixed = envelope
        mixed["payload"] = secret
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: JSONSerialization.data(withJSONObject: mixed), kind: .snapshot, encryption: password
        ))
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: JSONEncoder().encode(secret), kind: .snapshot, encryption: password
        ))
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: Data(count: 32 * 1024 * 1024 + 1), kind: .snapshot, encryption: password
        ))
    }

    func testEnvelopeAuthenticatesPayloadAndKind() throws {
        let encryption = CloudEncryption.key(try CloudEncryption.generateKey())
        let secret = "this value must stay private"
        let data = try CloudEnvelope.encode(secret, kind: .snapshot, encryption: encryption)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertEqual(try CloudEnvelope.decode(String.self, from: data, kind: .snapshot, encryption: encryption), secret)
        XCTAssertThrowsError(try CloudEnvelope.decode(String.self, from: data, kind: .sync, encryption: encryption))
        XCTAssertThrowsError(try CloudEnvelope.decode(
            String.self, from: data, kind: .snapshot,
            encryption: .key(CloudEncryption.generateKey())
        ))
    }
}

private actor DAVFixture {
    var directories: Set<String> = ["/root"]
    var contents: Data?

    func execute(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let path = url.path
        let parent = (path as NSString).deletingLastPathComponent
        var status = 500
        var headers: [String: String] = [:]
        var body = Data()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic Zml4dHVyZTpwYXNzOndvcmQ=")
        switch request.httpMethod {
        case "MKCOL":
            if directories.contains(path) { status = 405 }
            else if directories.contains(parent) {
                directories.insert(path)
                status = 201
            } else { status = 409 }
        case "PUT":
            XCTAssertEqual(path, "/root/alpha/beta/config.json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            if !directories.contains(parent) { status = 409 }
            else if contents != nil { status = 412 }
            else {
                contents = request.httpBody
                status = 201
                headers["ETag"] = "\"r1\""
            }
        case "GET":
            if let contents {
                status = 200
                headers["ETag"] = "\"r1\""
                body = contents
            } else { status = 404 }
        default:
            XCTFail("Unexpected request method")
        }
        return (body, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
    }
}
