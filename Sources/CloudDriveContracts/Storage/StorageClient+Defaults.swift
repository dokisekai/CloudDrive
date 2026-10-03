import Foundation

public extension StorageClient {
    var requiresETagForUpdate: Bool { false }

    @discardableResult
    func uploadFile(localURL: URL, to remotePath: String, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        if let etag = expectedETag {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .replace(expectedETag: etag), progress: progress)
        } else {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
        }
    }

    @discardableResult
    func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        switch mode {
        case .createIfAbsent:
            if try await exists(path: remotePath) {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
            try await uploadFile(localURL: localURL, to: remotePath, progress: progress)
            return nil
        case .replace:
            throw StorageError.notSupported("Conditional replacement is not supported by this storage provider")
        case .forceOverwrite:
            try await uploadFile(localURL: localURL, to: remotePath, progress: progress)
            return nil
        }
    }

    func delete(path: String, expectedETag: String?) async throws {
        guard expectedETag == nil else {
            throw StorageError.notSupported("Conditional delete is not supported by this storage provider")
        }
        try await delete(path: path)
    }

    func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        guard expectedETag == nil else {
            throw StorageError.notSupported("Conditional move is not supported by this storage provider")
        }
        try await move(from: sourcePath, to: destinationPath)
    }

    @discardableResult
    func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        // Providers without revision-aware reads retain their original download behavior.
        // A caller must not treat this nil result as a verified editing baseline.
        try await downloadFile(path: path, to: destinationURL, progress: progress)
        return nil
    }

    /// Copy file or directory. If the backend does not provide a native server-side copy,
    /// a download-then-upload streaming fallback is performed.
    func copy(from sourcePath: String, to destinationPath: String) async throws {
        guard try await exists(path: sourcePath) else {
            throw StorageError.notFound
        }
        
        if try await exists(path: destinationPath) {
            throw StorageError.serverError(statusCode: 412, message: "Target already exists")
        }
        
        // 尝试列举确认是否为目录
        do {
            let children = try await listDirectory(path: sourcePath)
            // 源为目录：创建目标目录并递归复制其下子项
            try await createDirectory(path: destinationPath)
            for child in children {
                let childSourcePath = child.path
                let childName = child.displayName
                let childDestPath = destinationPath.hasSuffix("/") ? "\(destinationPath)\(childName)" : "\(destinationPath)/\(childName)"
                try await copy(from: childSourcePath, to: childDestPath)
            }
            return
        } catch {
            // 非目录或无法列举，按单文件下载上传处理
        }
        
        // 文件复制：下载至临时文件，再采用 createIfAbsent 模式上传至目标
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("clouddrive_copy_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        try await downloadFile(path: sourcePath, to: tempURL) { _ in }
        try await uploadFile(localURL: tempURL, to: destinationPath, mode: .createIfAbsent) { _ in }
    }
    
    /// 默认连接测试实现（尝试列出根目录）
    func testConnection() async throws -> Bool {
        do {
            _ = try await listDirectory(path: "/")
            return true
        } catch {
            return false
        }
    }
}
