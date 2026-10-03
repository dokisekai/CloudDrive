import Foundation

/// Stable cache naming shared by metadata and content storage; no file mutations.
public enum CachePathLayout {
    public static func directory(vaultId: String?) -> URL {
        guard let vaultId else {
            return CloudDrivePaths.sharedDirectory.appendingPathComponent("Cache", isDirectory: true)
        }
        return CloudDrivePaths.vaultDirectory(for: vaultId)
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("Files", isDirectory: true)
    }

    public static func localPath(fileId: String, cacheDirectory: URL) -> URL {
        var cleanPath = fileId
        if cleanPath.hasPrefix("/") { cleanPath = String(cleanPath.dropFirst()) }
        let components = cleanPath.split(separator: "/", omittingEmptySubsequences: true).map { component -> String in
            if component == "." || component == ".." {
                return "__" + component.utf8.map { String(format: "%02x", $0) }.joined()
            }
            return String(component)
        }
        return cacheDirectory.appendingPathComponent(components.joined(separator: "/"))
    }
}
