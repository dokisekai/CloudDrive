import Foundation
import CloudDriveCore
import CloudDriveStorage
import CloudDriveContracts

private enum DirectoryDeleteFailure: Error { case assertion(String) }
private final class DirectoryDeleteProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Int)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let code = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
func runDirectoryDeleteRegressionTests() async throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw DirectoryDeleteFailure.assertion(message) }
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DirectoryDeleteProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel(); DirectoryDeleteProtocol.handler = nil }
    let client = WebDAVClient(baseURL: URL(string: "https://fixture.invalid/dav")!, username: "fixture", password: "fixture", session: session)
    var requests: [URLRequest] = []
    DirectoryDeleteProtocol.handler = { request in requests.append(request); return 204 }
    try await client.delete(path: "/collection", expectedETag: "\"collection-version\"")
    try require(requests.count == 1 && requests[0].httpMethod == "DELETE" && requests[0].value(forHTTPHeaderField: "If-Match") == "\"collection-version\"", "Collection deletion must issue exactly one conditional DELETE")
    let format = CryptomatorFormat(masterkey: try VFSEncryption().generateMasterKey(password: "fixture").0, storageClient: WebDAVStorageClient(webDAVClient: client), basePath: "/vault")
    requests = []
    try await format.deleteItem(remotePath: "/vault/d/parent/entry.c9r", dirIdData: Data("child-id".utf8), expectedETag: "W/\"weak\"")
    try require(requests.count == 1 && requests[0].httpMethod == "DELETE" && requests[0].url?.path == "/dav/vault/d/parent/entry.c9r" && requests[0].value(forHTTPHeaderField: "If-Match") == nil, "Encrypted directory deletion must unlink only the parent entry, without listing or descending into ciphertext")
    requests = []
    DirectoryDeleteProtocol.handler = { request in requests.append(request); throw URLError(.networkConnectionLost) }
    var uncertain = false
    do { try await client.delete(path: "/collection", expectedETag: nil) }
    catch StorageError.indeterminateMutation { uncertain = true }
    try require(uncertain && requests.count == 1, "An unknown collection DELETE outcome must be surfaced without network retry")
    print("✅ Single-request collection deletion and encrypted unlink regressions passed")
}
