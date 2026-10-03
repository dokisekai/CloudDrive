//
//  CloudDrivePaths.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  Unified Shared Path Resolver
//

import Foundation
import CryptoKit

public enum CloudDrivePaths {
    /// Unified retrieval of base directory (.CloudDrive) shared between Main App and FileProvider Extension
    public static var sharedDirectory: URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive") {
            let appDir = groupURL.appendingPathComponent(".CloudDrive", isDirectory: true)
            if !FileManager.default.fileExists(atPath: appDir.path) {
                try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            }
            // Real write probe to avoid false negative from FileManager.isWritableFile in sandbox Group Container
            let testFile = appDir.appendingPathComponent(".probe_\(UUID().uuidString)")
            if (try? "probe".write(to: testFile, atomically: true, encoding: .utf8)) != nil {
                try? FileManager.default.removeItem(at: testFile)
                return appDir
            }
        }
        
        // Fallback to standard Application Support directory in sandbox environment
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fallback = appSupport.appendingPathComponent(".CloudDrive", isDirectory: true)
        if !FileManager.default.fileExists(atPath: fallback.path) {
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        }
        return fallback
    }
    
    /// Stable namespace; never infer ownership of old global cache entries.
    public static func vaultDirectory(for vaultId: String) -> URL {
        let digest = SHA256.hash(data: Data(vaultId.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = sharedDirectory.appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Persistent thumbnail cache directory
    public static var thumbnailsDirectory: URL {
        let dir = sharedDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Real user home directory (escaping sandbox container home)
    public static var realUserHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Real user ~/Library/CloudStorage directory
    public static var cloudStorageDirectory: URL {
        return realUserHomeDirectory.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }
}
