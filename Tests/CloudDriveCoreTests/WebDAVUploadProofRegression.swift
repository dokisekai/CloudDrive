import Foundation
import CloudDriveStorage
import CloudDriveContracts

private enum DAVUploadProofFailure: Error { case assertion(String) }
private final class DAVUploadProofProtocol: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handle!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
func runWebDAVUploadProofRegressionTests() async throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw DAVUploadProofFailure.assertion(message) } }
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("dav-proof-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: local); DAVUploadProofProtocol.handle = nil }
    let bytes = Data("accepted bytes".utf8)
    try bytes.write(to: local)
    var commits = 0
    var remote: Data?
    var revision = "\"committed\""
    var changeDuringRead = false
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DAVUploadProofProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let client = WebDAVClient(baseURL: URL(string: "https://fixture.invalid/dav")!, username: "fixture", password: "fixture", session: session)
    DAVUploadProofProtocol.handle = { request in
        switch request.httpMethod {
        case "PUT":
            if remote != nil { return (412, [:], Data()) }
            commits += 1
            remote = bytes
            throw URLError(.networkConnectionLost)
        case "PROPFIND":
            let xml = "<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response><D:response><D:href>/dav/a</D:href><D:propstat><D:prop><D:getetag>\(revision)</D:getetag><D:getcontentlength>\(remote?.count ?? 0)</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"
            return (207, [:], Data(xml.utf8))
        case "GET":
            if changeDuringRead { revision = "\"newer\""; changeDuringRead = false }
            guard request.value(forHTTPHeaderField: "If-Match") == revision else { return (412, [:], Data()) }
            guard let remote else { return (404, [:], Data()) }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return (206, ["ETag": revision, "Content-Range": "bytes 0-3/\(remote.count)"], remote.prefix(4))
            }
            return (200, ["ETag": revision], remote)
        default: throw DAVUploadProofFailure.assertion("Unexpected request")
        }
    }
    let proven = try await client.uploadFile(localURL: local, to: "/a", mode: .createIfAbsent) { _ in }
    try require(proven == revision && commits == 1, "Lost PUT response must be proved by complete same-revision bytes")
    _ = try await client.uploadFile(localURL: local, to: "/a", mode: .createIfAbsent) { _ in }
    try require(commits == 1, "Replay must not issue an unconditional overwrite")
    try Data("different byte".utf8).write(to: local)
    var conflict = false
    do { _ = try await client.uploadFile(localURL: local, to: "/a", mode: .createIfAbsent) { _ in } }
    catch let error as StorageError { conflict = error.isPreconditionFailure }
    try require(conflict && remote == bytes, "Same-size different content must retain remote conflict")
    try bytes.write(to: local)
    changeDuringRead = true
    conflict = false
    do { _ = try await client.uploadFile(localURL: local, to: "/a", mode: .createIfAbsent) { _ in } }
    catch let error as StorageError { conflict = error.isPreconditionFailure }
    try require(conflict, "Verification must not cross remote revisions")
    let range = try await client.downloadRange(path: "/a", range: 0...3, expectedETag: revision)
    try require(range == bytes.prefix(4), "Range reads must send the selected revision")
    var staleRejected = false
    do { _ = try await client.downloadRange(path: "/a", range: 0...3, expectedETag: "\"old\"") }
    catch { staleRejected = true }
    try require(staleRejected, "Stale range reads must reject mixed-revision bytes")
    print("✅ WebDAV upload proof and revision-bound Range regressions passed")
}
