import Foundation

public enum StorageContentVerification {
    /// Compare every byte with bounded memory; metadata equality is not proof.
    public static func identical(_ left: URL, _ right: URL) throws -> Bool {
        let lhs = try FileHandle(forReadingFrom: left)
        let rhs = try FileHandle(forReadingFrom: right)
        defer { try? lhs.close(); try? rhs.close() }
        while true {
            try Task.checkCancellation()
            let a = try lhs.read(upToCount: 1024 * 1024) ?? Data()
            let b = try rhs.read(upToCount: 1024 * 1024) ?? Data()
            if a != b { return false }
            if a.isEmpty { return true }
        }
    }
    /// A collection deletion is an explicit whole-directory intent. Use a
    /// verified strong collection tag when available, without substituting a
    /// child pointer's tag or fabricating a strong tag from a weak one.
    public static func collectionDeletionETag(_ value: String?) -> String? {
        try? mutationETag(value, required: false)
    }

    public static func mutationETag(_ value: String?, required: Bool) throws -> String? {
        guard let value else {
            if required { throw StorageError.serverError(statusCode: 412, message: "Mutation has no verified remote revision") }
            return nil
        }
        let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag.count >= 2, tag.first == "\"", tag.last == "\"",
              !tag.dropFirst().dropLast().contains("\""),
              !tag.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }) else {
            throw StorageError.serverError(statusCode: 412, message: "Mutation requires a strong remote revision")
        }
        return tag
    }

    public static func deletionOutcomeIsUncertain(_ error: Error) -> Bool {
        if error is URLError || error is CancellationError { return true }
        if let storage = error as? StorageError {
            switch storage {
            case .networkError, .indeterminateMutation: return true
            case .serverError(let code, _): return code >= 500
            default: return false
            }
        }
        if let dav = error as? WebDAVError {
            switch dav {
            case .invalidResponse, .parseError: return true
            case .serverError(let code): return code >= 500
            default: return false
            }
        }
        return false
    }

    public static func mayHaveCommitted(_ error: Error) -> Bool {
        if Task.isCancelled { return false }
        if let error = error as? URLError { return error.code != .cancelled }
        if let error = error as? StorageError, case .serverError(let code, _) = error { return code == 412 || code >= 500 }
        if let error = error as? WebDAVError, case .serverError(let code) = error { return code == 412 || code >= 500 }
        return false
    }
}

public extension StorageClient {
    func currentResource(path: String) async throws -> StorageResource? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let resources = try await listDirectory(path: parent.isEmpty ? "/" : parent)
        let matches = resources.filter { $0.displayName == name }
        guard matches.count <= 1 else { throw StorageError.serverError(statusCode: 502, message: "Ambiguous revision snapshot") }
        return matches.first
    }
}
