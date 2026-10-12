import Foundation
import CloudDriveStorage
import CloudDriveContracts

private enum DAVBoundaryFailure: Error { case assertion(String) }
private final class DAVBoundaryProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, bytes) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
func runWebDAVBoundaryRegressionTests() async throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw DAVBoundaryFailure.assertion(message) } }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DAVBoundaryProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel(); DAVBoundaryProtocol.handler = nil }
    let client = WebDAVClient(baseURL: URL(string: "https://fixture.invalid/root/dav")!, username: "fixture", password: "fixture", session: session)
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: local) }
    try Data("existing bytes".utf8).write(to: local)
    DAVBoundaryProtocol.handler = { _ in (206, ["Content-Range": "bytes 0-1/10"], Data("xx".utf8)) }
    var rejected = false
    do { try await client.downloadFile(path: "/a", to: local) { _ in } } catch { rejected = true }
    try require(rejected && (try Data(contentsOf: local)) == Data("existing bytes".utf8), "A partial HTTP response must not replace a complete local file")
    rejected = false
    do { _ = try await client.downloadRange(path: "/a", range: 0...3) } catch { rejected = true }
    try require(rejected, "Short non-EOF Content-Range must not be accepted as a complete selection")
    DAVBoundaryProtocol.handler = { _ in (200, ["ETag": "\"different\""], Data("other".utf8)) }
    rejected = false
    do { _ = try await client.downloadFile(path: "/a", to: local, expectedETag: "\"requested\"") { _ in } } catch { rejected = true }
    try require(rejected && (try Data(contentsOf: local)) == Data("existing bytes".utf8), "A server ignoring If-Match must not publish the wrong revision")
    DAVBoundaryProtocol.handler = { _ in (200, [:], Data(repeating: 1, count: 4096)) }
    rejected = false
    do { _ = try await client.downloadFile(path: "/a", to: local, expectedETag: nil, maximumBytes: 16) { _ in } } catch { rejected = true }
    try require(rejected, "Verification downloads must enforce their payload limit")
    let entityXML = "<?xml version=\"1.0\" encoding=\"UTF-32\"?><!DOCTYPE D:multistatus [<!ENTITY x \"expanded\">]><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/root/dav/a</D:href><D:propstat><D:prop><D:displayname>&x;</D:displayname></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"
    DAVBoundaryProtocol.handler = { _ in (207, [:], entityXML.data(using: .utf32BigEndian)!) }
    rejected = false
    do { _ = try await client.listDirectory(path: "/") } catch { rejected = true }
    try require(rejected, "UTF-32 DTD/entity declarations must be rejected before expansion")
    for fakeMutation in ["<multistatus><response><status>HTTP/1.1 200 OK</status></response></multistatus>", "<D:multistatus xmlns:D=\"DAV:\"><D:status>HTTP/1.1 200 OK</D:status></D:multistatus>"] {
        DAVBoundaryProtocol.handler = { _ in (207, [:], Data(fakeMutation.utf8)) }
        rejected = false
        do { try await client.delete(path: "/a", expectedETag: "\"baseline\"") } catch { rejected = true }
        try require(rejected, "Mutation acknowledgements must have DAV response structure")
    }
    var created: [String] = []
    DAVBoundaryProtocol.handler = { request in
        try require(request.httpMethod == "MKCOL", "Unexpected recursive mkdir request")
        created.append(request.url!.path)
        return (201, [:], Data())
    }
    try await client.createDirectory(path: "/root/dav/child/grand")
    try require(created == ["/root/dav/child", "/root/dav/child/grand"], "Recursive mkdir must not recreate configured root prefixes as child folders")
    created = []
    rejected = false
    do { try await client.createDirectory(path: "/valid/../outside") } catch { rejected = true }
    try require(rejected && created.isEmpty, "Validate the complete mkdir path before making any remote changes")
    DAVBoundaryProtocol.handler = { request in
        if request.httpMethod == "MKCOL" { return (405, [:], Data()) }
        let xml = "<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/root/dav/file</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"
        return (207, [:], Data(xml.utf8))
    }
    rejected = false
    do { try await client.createDirectory(path: "/file") } catch { rejected = true }
    try require(rejected, "MKCOL 405 must not label an existing file as a directory")
    let invalidRoot = WebDAVClient(baseURL: URL(string: "https://fixture.invalid/dav/%2e%2e/private")!, username: "fixture", password: "fixture", session: session)
    rejected = false
    do { _ = try invalidRoot.buildURL(for: "/a") } catch { rejected = true }
    try require(rejected, "Configured root must reject encoded traversal components")
    for advertisedLength in [true, false] {
        DAVBoundaryProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                try require(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true, "Streamed upload must retain authentication")
                let headers = advertisedLength ? ["Content-Length": String(2 * 1024 * 1024)] : [:]
                return (201, headers, Data(repeating: 7, count: 2 * 1024 * 1024))
            }
            return (403, [:], Data()) // Prevent content proof from hiding a rejected response.
        }
        rejected = false
        do { _ = try await client.uploadFile(localURL: local, to: "/a", mode: .createIfAbsent) { _ in } }
        catch let error as StorageError {
            if case .serverError(let status, _) = error { rejected = status == 502 }
        }
        try require(rejected, "PUT responses must be bounded with and without Content-Length")
    }
    let cancelledUpload = Task {
        try await client.uploadFile(localURL: local, to: "/a", mode: .createIfAbsent) { _ in }
    }
    cancelledUpload.cancel()
    var cancelled = false
    do { _ = try await cancelledUpload.value } catch is CancellationError { cancelled = true }
    try require(cancelled, "Upload cancellation must propagate and must not trigger commit proof")
    print("✅ WebDAV response, XML encoding, mkdir and path boundary regressions passed")
}
