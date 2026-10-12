import Foundation
import CloudDriveCore
import CloudDriveStorage
import CryptomatorCryptoLib

private enum WebDAVRegressionError: Error {
    case assertion(String)
}

private func verifyDAV(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw WebDAVRegressionError.assertion(message) }
}

private final class DAVFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.1)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.2)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// An isolated storage tree; no App Group, account, or real remote endpoint is used.
private final class DAVMemoryStorage: StorageClient {
    var files: [String: Data] = [:]
    var directories: Set<String> = ["/"]
    var failListing = false
    func listDirectory(path: String) async throws -> [StorageResource] {
        if failListing { throw StorageError.serverError(statusCode: 403, message: "Fixture denies listing") }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return (directories.union(files.keys)).compactMap { child in
            guard child.hasPrefix(prefix), child != path else { return nil }
            let name = String(child.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return StorageResource(path: child, displayName: name, isDirectory: directories.contains(child), contentLength: Int64(files[child]?.count ?? 0))
        }
    }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard let data = files[path] else { throw StorageError.notFound }
        try data.write(to: destinationURL)
        progress(1)
    }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        files[remotePath] = try Data(contentsOf: localURL)
        progress(1)
    }
    func createDirectory(path: String) async throws { directories.insert(path) }
    func delete(path: String) async throws {
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        directories = directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }
    func move(from sourcePath: String, to destinationPath: String) async throws { throw StorageError.notSupported("fixture move") }
    func exists(path: String) async throws -> Bool { files[path] != nil || directories.contains(path) }
}

public func runWebDAVRegressionTests() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDrive-WebDAV-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DAVFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel(); DAVFixtureProtocol.handler = nil }
    let client = WebDAVClient(baseURL: URL(string: "https://fixture.invalid/dav")!, username: "fixture", password: "fixture", session: session)
    let storage = WebDAVStorageClient(webDAVClient: client)
    let upload = temporary.appendingPathComponent("edit.txt")
    try Data("local edit".utf8).write(to: upload)

    var remoteETag = "\"v1\""
    var commits = 0
    DAVFixtureProtocol.handler = { request in
        try verifyDAV(request.httpMethod == "PUT", "Expected a conditional PUT")
        guard request.value(forHTTPHeaderField: "If-Match") == remoteETag else { return (412, [:], Data()) }
        remoteETag = "\"v2\""
        commits += 1
        return (204, ["ETag": remoteETag], Data())
    }
    let committed = try await storage.uploadFile(localURL: upload, to: "/edit.txt", expectedETag: "\"v1\"") { _ in }
    try verifyDAV(committed == "\"v2\"", "The committed ETag comes from the PUT response")
    remoteETag = "\"other-device\""
    var rejected = false
    do { _ = try await storage.uploadFile(localURL: upload, to: "/edit.txt", expectedETag: committed) { _ in } }
    catch let error as StorageError { rejected = error.isPreconditionFailure }
    try verifyDAV(rejected && commits == 1 && remoteETag == "\"other-device\"", "A stale save must not overwrite another device")
    try verifyDAV(try Data(contentsOf: upload) == Data("local edit".utf8), "Rejected writes retain the local source")

    DAVFixtureProtocol.handler = { _ in (207, [:], Data("<not-a-directory/>".utf8)) }
    var malformedRejected = false
    do { _ = try await client.listDirectory(path: "/") } catch { malformedRejected = true }
    try verifyDAV(malformedRejected, "Non-DAV XML must not become an empty directory")
    let multistatus = """
    <D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>/dav/a.txt</D:href><D:propstat><D:prop><D:displayname>a.txt</D:displayname><D:getcontentlength>3</D:getcontentlength><D:getetag>"baseline"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:getetag/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
    </D:multistatus>
    """
    DAVFixtureProtocol.handler = { _ in (207, [:], Data(multistatus.utf8)) }
    let items = try await client.listDirectory(path: "/")
    try verifyDAV(items.count == 1 && items[0].etag == "\"baseline\"" && items[0].contentLength == 3, "Failed optional properties do not erase successful resource properties")
    DAVFixtureProtocol.handler = { _ in (403, [:], Data()) }
    var deniedExistsRejected = false
    do { _ = try await client.exists(path: "/a.txt") } catch { deniedExistsRejected = true }
    try verifyDAV(deniedExistsRejected, "Denied access must not be reported as absence")

    for malformedMutation in ["", "<not-dav/>", "<D:multistatus xmlns:D=\"DAV:\"><D:response><D:status>HTTP/1.1 403 Forbidden</D:status></D:response></D:multistatus>"] {
        DAVFixtureProtocol.handler = { _ in (207, [:], Data(malformedMutation.utf8)) }
        var rejected = false
        do { try await client.delete(path: "/a.txt", expectedETag: "\"v1\"") } catch { rejected = true }
        try verifyDAV(rejected, "Malformed or failed DELETE multistatus must not be confirmed as success")
    }

    for maliciousHref in ["/dav/../outside", "/dav/a%2fb", "https://other.invalid/dav/a", "/outside/a", "/dav/nested/a"] {
        let xml = "<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>\(maliciousHref)</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"
        DAVFixtureProtocol.handler = { _ in (207, [:], Data(xml.utf8)) }
        var rejected = false
        do { _ = try await client.listDirectory(path: "/") } catch { rejected = true }
        try verifyDAV(rejected, "Listing must reject an untrusted href: \(maliciousHref)")
    }
    DAVFixtureProtocol.handler = { _ in throw WebDAVRegressionError.assertion("Weak ETag must be rejected before network mutation") }
    var weakRejected = false
    do { _ = try await client.uploadFile(localURL: upload, to: "/edit.txt", mode: .replace(expectedETag: "W/\"v1\"")) { _ in } }
    catch let error as StorageError { weakRejected = error.isPreconditionFailure }
    try verifyDAV(weakRejected, "A weak ETag must never be promoted to a strong If-Match validator")
    for unsafePath in ["../outside", "a/../outside", "a\\b", "a\nheader"] {
        var rejected = false
        do { _ = try client.buildURL(for: unsafePath) } catch { rejected = true }
        try verifyDAV(rejected, "Unsafe request path must be rejected")
    }

    let tree = DAVMemoryStorage()
    let key = try VFSEncryption().generateMasterKey(password: "fixture only").0
    let format = CryptomatorFormat(masterkey: key, storageClient: tree, basePath: "/vault")
    let fixedId = UUID().uuidString
    let parent = try await format.createDirectory(name: "offline", parentDirId: Data(), directoryId: fixedId)
    let replay = try await format.createDirectory(name: "offline", parentDirId: Data(), directoryId: fixedId)
    try verifyDAV(parent.id == fixedId && replay.id == fixedId, "Offline mkdir replay preserves the directory ID")
    var duplicateRejected = false
    do { _ = try await format.createDirectory(name: "offline", parentDirId: Data(), directoryId: UUID().uuidString) } catch { duplicateRejected = true }
    try verifyDAV(duplicateRejected, "A replay must not replace another directory pointer")
    let child = try await format.createDirectory(name: "child", parentDirId: Data(fixedId.utf8))
    _ = try await format.uploadFile(localURL: upload, name: "a.txt", parentDirId: Data(child.id.utf8))
    tree.failListing = true
    var unavailableRejected = false
    do { _ = try await format.listDirectory(dirId: Data(fixedId.utf8)) } catch { unavailableRejected = true }
    try verifyDAV(unavailableRejected, "An encrypted listing failure must propagate")
    tree.failListing = false
    let originalDestination = temporary.appendingPathComponent("existing.txt")
    try Data("keep existing bytes".utf8).write(to: originalDestination)
    tree.files["/corrupt.c9r"] = Data("invalid ciphertext".utf8)
    var corruptRejected = false
    do { _ = try await format.downloadFile(remotePath: "/corrupt.c9r", to: originalDestination) } catch { corruptRejected = true }
    let retainedBytes = try Data(contentsOf: originalDestination)
    try verifyDAV(corruptRejected && retainedBytes == Data("keep existing bytes".utf8), "Failed decryption must retain the previous destination")
    let childContentPath = try format.getDirPath(dirId: Data(child.id.utf8))
    try await format.deleteItem(remotePath: parent.remotePath!, dirIdData: Data(fixedId.utf8))
    try verifyDAV(tree.directories.contains(childContentPath) && tree.files.keys.contains(where: { $0.hasPrefix(childContentPath + "/") }) && !tree.directories.contains(parent.remotePath!), "Deleting an encrypted directory unlinks its parent entry and preserves flattened ciphertext")
    print("  ✅ WebDAV conditional writes, complete snapshots, and encrypted replay regressions passed")
}
