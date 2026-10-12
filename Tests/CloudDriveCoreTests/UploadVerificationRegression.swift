import Foundation
import CloudDriveContracts
import CloudDriveStorage
import CloudDriveCore

private enum UploadVerificationFailure: Error { case assertion(String) }
private final class UploadVerificationStorage: StorageClient {
    var requiresETagForUpdate: Bool { true }
    var files: [String: Data] = [:]
    var tags: [String: String] = [:]
    var loseNextReply = false
    var replaceBeforeVerification = false
    var verificationDownloads = 0
    func listDirectory(path: String) async throws -> [StorageResource] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.compactMap { key, bytes in
            guard key.hasPrefix(prefix), !key.dropFirst(prefix.count).contains("/") else { return nil }
            return StorageResource(path: key, displayName: (key as NSString).lastPathComponent, isDirectory: false, contentLength: Int64(bytes.count), etag: tags[key])
        }
    }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        _ = try await downloadFile(path: path, to: destinationURL, expectedETag: nil, progress: progress)
    }
    func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        verificationDownloads += 1
        if replaceBeforeVerification {
            replaceBeforeVerification = false
            tags[path] = "\"other-device\""
        }
        if let expectedETag, tags[path] != expectedETag { throw StorageError.serverError(statusCode: 412, message: "Revision changed") }
        guard let bytes = files[path] else { throw StorageError.notFound }
        try bytes.write(to: destinationURL)
        return tags[path]
    }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        _ = try await uploadFile(localURL: localURL, to: remotePath, mode: .createIfAbsent, progress: progress)
    }
    func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        switch mode {
        case .createIfAbsent: if files[remotePath] != nil { throw StorageError.serverError(statusCode: 412, message: "Exists") }
        case .replace(let expected): if tags[remotePath] != expected { throw StorageError.serverError(statusCode: 412, message: "Changed") }
        case .forceOverwrite: throw UploadVerificationFailure.assertion("Unexpected unconditional overwrite")
        }
        files[remotePath] = try Data(contentsOf: localURL)
        tags[remotePath] = "\"committed\""
        if loseNextReply { loseNextReply = false; throw URLError(.networkConnectionLost) }
        return tags[remotePath]
    }
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws {}
    func move(from sourcePath: String, to destinationPath: String) async throws {}
    func exists(path: String) async throws -> Bool { files[path] != nil }
}

func runUploadVerificationRegressionTests() async throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw UploadVerificationFailure.assertion(message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("upload-proof-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("source")
    try Data(repeating: 42, count: 100000).write(to: local)
    let storage = UploadVerificationStorage()
    let key = try VFSEncryption().generateMasterKey(password: "fixture").0
    let format = CryptomatorFormat(masterkey: key, storageClient: storage, basePath: "/vault")
    storage.loseNextReply = true
    let committed = try await format.uploadFile(localURL: local, name: "a.txt", parentDirId: Data(), mode: .createIfAbsent)
    try require(committed.etag == "\"committed\"" && storage.verificationDownloads == 1, "Lost encrypted PUT reply must recover only through decrypted content proof")
    let remotePath = committed.remotePath!
    let initialCiphertext = storage.files[remotePath]!
    let replayed = try await format.uploadFile(localURL: local, name: "a.txt", parentDirId: Data(), mode: .createIfAbsent)
    try require(replayed.etag == committed.etag && storage.files[remotePath] == initialCiphertext, "Crash replay with freshly randomized ciphertext must recognize identical remote plaintext without overwriting")
    try Data(repeating: 43, count: 100000).write(to: local)
    var conflict = false
    do { _ = try await format.uploadFile(localURL: local, name: "a.txt", parentDirId: Data(), mode: .createIfAbsent) }
    catch let error as StorageError { conflict = error.isPreconditionFailure }
    try require(conflict && storage.files[remotePath] == initialCiphertext, "Equal-size different bytes must remain a conflict")
    try Data(repeating: 42, count: 100000).write(to: local)
    storage.replaceBeforeVerification = true
    conflict = false
    do { _ = try await format.uploadFile(localURL: local, name: "a.txt", parentDirId: Data(), mode: .createIfAbsent) }
    catch let error as StorageError { conflict = error.isPreconditionFailure }
    try require(conflict, "A verification GET must reject an intervening remote revision")
    print("✅ Encrypted upload proof: lost replies, randomized replay, different bytes and revision races passed")
}
