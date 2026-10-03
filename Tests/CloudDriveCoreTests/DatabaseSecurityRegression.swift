import Foundation
import CryptoKit
import CloudDriveCore
import CloudDriveStorage
import CryptomatorCryptoLib

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

public func runDatabaseSecurityRegressionTests() async throws {
    var checks = 0
    func expect(_ value: Bool, _ description: String) throws {
        guard value else { throw RegressionFailure(description: description) }
        checks += 1
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDrive-db-regression-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = VFSDatabase(vaultId: "vault-a", directory: root.appendingPathComponent("a"))
    let other = VFSDatabase(vaultId: "vault-b", directory: root.appendingPathComponent("b"))
    defer { db.close(); other.close() }
    try db.initialize(vaultId: "vault-a", basePath: "/dav")
    try other.initialize(vaultId: "vault-b", basePath: "/other")
    let date = Date(timeIntervalSince1970: 1_650_000_000)
    try db.insertDirectory(id: "ROOT", name: "Root", parentId: nil, encryptedId: "", remotePath: "/dav")
    try db.insertDirectory(id: "/dav/目录", name: "目录", parentId: "ROOT", encryptedId: "", remotePath: "/dav/目录", modifiedAt: date)
    try db.insertDirectory(id: "/dav/目录/sub", name: "sub", parentId: "/dav/目录", encryptedId: "", remotePath: "/dav/目录/sub", modifiedAt: date)
    try db.insertDirectory(id: "/dav/目录-other", name: "sibling", parentId: "ROOT", encryptedId: "", remotePath: "/dav/目录-other")
    try db.insertFile(id: "/dav/目录/sub/a.txt", name: "a.txt", parentId: "/dav/目录/sub", size: 7, encryptedName: "", remotePath: "/dav/目录/sub/a.txt", modifiedAt: date)
    let children = try db.listChildren(parentId: "ROOT")
    try expect(!children.contains { $0.id == "ROOT" }, "Root must not enumerate itself")
    try expect(children.first { $0.id == "/dav/目录" }?.remotePath == "/dav/目录", "Cached enumeration preserves remote path")
    try db.moveDirectory(oldId: "/dav/目录", newId: "/dav/新目录", newName: "新目录", newParentId: "ROOT", newRemotePath: "/dav/新目录")
    let moved = try db.getFile(id: "/dav/新目录/sub/a.txt")
    try expect(moved?.parentId == "/dav/新目录/sub" && moved?.remotePath == "/dav/新目录/sub/a.txt", "Directory move rewrites descendant identities and paths")
    try expect(try db.getDirectory(id: "/dav/目录-other") != nil, "Directory move does not rewrite a sibling sharing a prefix")
    try expect(try db.getFile(id: "/dav/目录/sub/a.txt") == nil, "Directory move removes old descendant identities")
    try db.insertFile(id: "/dav/新目录/sub/a.txt", name: "a.txt", parentId: "/dav/新目录/sub", size: 8, encryptedName: "", remotePath: "/dav/新目录/sub/a.txt")
    try expect(try db.getFile(id: "/dav/新目录/sub/a.txt")?.modifiedAt == date, "Metadata refresh without a new mtime preserves remote mtime")
    try other.insertFile(id: "/dav/新目录/sub/a.txt", name: "other.txt", parentId: "ROOT", size: 42, encryptedName: "", remotePath: "/other/a.txt")
    try expect(try db.getFile(id: "/dav/新目录/sub/a.txt")?.size == 8, "Identical file IDs in separate vault databases do not collide")
    try db.deleteDirectory(id: "/dav/新目录")
    try expect(try db.getFile(id: "/dav/新目录/sub/a.txt") == nil, "Recursive deletion removes descendant files")
    try expect(try db.getDirectory(id: "/dav/新目录/sub") == nil, "Recursive deletion removes descendant directories")
    try expect(try other.getFile(id: "/dav/新目录/sub/a.txt") != nil, "Recursive deletion remains vault scoped")
    do {
        try db.connection.withTransaction {
            try db.insertFile(id: "rolled-back", name: "temporary", parentId: "ROOT", size: 1, encryptedName: "", remotePath: "/dav/temporary")
            throw RegressionFailure(description: "rollback")
        }
    } catch {}
    try expect(try db.getFile(id: "rolled-back") == nil, "Failed transaction rolls back changes")
    let lock = NSLock()
    var failures: [String] = []
    DispatchQueue.concurrentPerform(iterations: 40) { index in
        do {
            let name = String(repeating: "文件-\(index)-", count: 100)
            try db.connection.withTransaction {
                try db.insertFile(id: "concurrent-\(index)", name: name, parentId: "ROOT", size: Int64(index), encryptedName: "encrypted-\(index)", remotePath: "/dav/\(index)")
                guard try db.getFile(id: "concurrent-\(index)")?.name == name else { throw RegressionFailure(description: "Bound text corrupted") }
            }
        } catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
    }
    try expect(failures.isEmpty, "Concurrent transactions preserve bound text and commit independently")
    try expect(try db.listChildren(parentId: "ROOT").filter { $0.id.hasPrefix("concurrent-") }.count == 40, "All concurrent transactions survive")

    let sentinel = "do-not-serialize-this-secret"
    for configuration: StorageConfiguration in [
        .webdav(WebDAVStorageConfig(baseURL: "https://dav.example.test", username: "user", password: sentinel)),
        .s3(S3StorageConfig(endpoint: "https://s3.example.test", bucket: "bucket", accessKey: "access", secretKey: sentinel))
    ] {
        let vault = VaultInfo(id: UUID().uuidString, name: "test", storagePath: "/dav", createdAt: date, storageConfig: configuration, isEncrypted: false)
        let encoded = try JSONEncoder().encode(vault)
        try expect(!String(decoding: encoded, as: UTF8.self).contains(sentinel), "Serialized vault configuration excludes storage secrets")
        try expect(try JSONDecoder().decode(VaultInfo.self, from: encoded).storageConfig?.secret == "", "Serialized configuration retains a usable password-free shape")
    }
    let key = try Masterkey.createNew()
    let (config, _) = try CryptomatorVaultConfig.create(masterKey: key)
    try expect(config.verifySignature(masterKey: key), "Valid vault signature is accepted")
    let parts = config.rawJWT.split(separator: ".").map(String.init)
    let tampered = try CryptomatorVaultConfig.decodeUnverified(jwtString: parts[0] + "." + parts[1] + "." + CryptomatorVaultConfig.base64UrlEncode(Data(repeating: 0, count: 32)))
    try expect(!tampered.verifySignature(masterKey: key), "Invalid vault signature is rejected")
    let unknownHeader = CryptomatorVaultConfig.Header(alg: "none")
    let invalid = CryptomatorVaultConfig.base64UrlEncode(try JSONEncoder().encode(unknownHeader)) + "." + parts[1] + "." + parts[2]
    var rejected = false
    do { _ = try CryptomatorVaultConfig.decodeUnverified(jwtString: invalid) } catch { rejected = true }
    try expect(rejected, "Unsupported JWT algorithm is rejected")
    let unsafeHeader = CryptomatorVaultConfig.Header(kid: "masterkeyfile:../outside")
    let unsafeJWT = CryptomatorVaultConfig.base64UrlEncode(try JSONEncoder().encode(unsafeHeader)) + "." + parts[1] + "." + parts[2]
    rejected = false
    do { _ = try CryptomatorVaultConfig.decodeUnverified(jwtString: unsafeJWT) } catch { rejected = true }
    try expect(rejected, "Masterkey path traversal is rejected")
    print("✅ Database/security regressions: \(checks) checks passed")
}
