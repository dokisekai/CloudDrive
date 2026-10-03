import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
    }
    
    /// 上传文件（支持条件模式与版本比对，严密检查 10GB 大小上限、非法字符与分片上传）
    @discardableResult
    public func uploadFile(
        localURL: URL,
        to remotePath: String,
        mode: StorageWriteMode,
        progress: @escaping (Double) -> Void
    ) async throws -> String? {
        let canonical = normalizePath(remotePath)
        let parentPath = (canonical as NSString).deletingLastPathComponent
        let filename = (canonical as NSString).lastPathComponent
        try Self.validateFilename(filename)
        
        // 条件模式检查
        let existingNode = try? await resolveNode(for: canonical)
        switch mode {
        case .createIfAbsent:
            if existingNode != nil {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
        case .replace(let expectedETag):
            guard let node = existingNode else {
                throw StorageError.notFound
            }
            if let remoteETag = node.etag, !remoteETag.isEmpty, remoteETag != expectedETag {
                throw StorageError.serverError(statusCode: 412, message: "Remote revision changed: expected \(expectedETag), got \(remoteETag)")
            }
        case .forceOverwrite:
            break
        }
        
        // 校验本地文件大小（10GB 限制前置拦截）
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= Self.maxUploadFileSize else {
            throw StorageError.notSupported("单文件大小超出 123云盘开放平台 10GB 上限 (当前大小: \(fileSize) 字节)")
        }
        
        // 确保目标父目录存在
        if parentPath != "/" {
            let parentExists = try await exists(path: parentPath)
            if !parentExists {
                try await createDirectory(path: parentPath)
            }
        }
        
        let parentNode = try await resolveNode(for: parentPath)
        guard parentNode.isDirectory else {
            throw StorageError.invalidOperation
        }
        
        let fileMD5 = try computeFileMD5(localURL: localURL)
        
        // 1. 调用 V2 创建文件
        let createReq = Pan123CreateFileRequest(
            parentFileID: parentNode.fileId,
            filename: filename,
            etag: fileMD5,
            size: fileSize,
            duplicate: 2 // 覆盖模式
        )
        
        let createData: Pan123CreateFileData = try await apiClient.sendRequest(
            path: "upload/v2/file/create",
            method: "POST",
            body: createReq
        )
        
        // 2. 判断是否秒传成功
        if createData.reuse == true, let fileID = createData.fileID {
            progress(1.0)
            let uploadedItem = Pan123FileItem(
                fileId: fileID,
                filename: filename,
                parentFileId: parentNode.fileId,
                type: 0,
                etag: fileMD5,
                size: fileSize
            )
            cache.setNode(for: canonical, item: uploadedItem)
            cache.invalidateChildren(for: parentNode.fileId)
            return fileMD5
        }
        
        // 3. 非秒传，分片上传
        guard let preuploadID = createData.preuploadID, !preuploadID.isEmpty else {
            throw StorageError.serverError(statusCode: 500, message: "Missing preuploadID in create file response")
        }
        
        let sliceSize = createData.sliceSize ?? (16 * 1024 * 1024) // 默认 16MB
        let uploadServer = createData.servers?.first ?? "https://open-api.123pan.com"
        
        if fileSize > 0 {
            try await uploadSlices(
                localURL: localURL,
                fileSize: fileSize,
                sliceSize: sliceSize,
                preuploadID: preuploadID,
                uploadServer: uploadServer,
                progress: progress
            )
        }
        
        // 4. 调用上传完毕接口 (若 completed 为 false 则轮询，最多 30 次，每次 1 秒)
        let completeReq = Pan123UploadCompleteRequest(preuploadID: preuploadID)
        var finalFileID: Int64 = 0
        var isCompleted = false
        
        for _ in 0..<30 {
            let completeData: Pan123UploadCompleteData = try await apiClient.sendRequest(
                path: "upload/v2/file/upload_complete",
                method: "POST",
                body: completeReq
            )
            if completeData.completed {
                isCompleted = true
                finalFileID = completeData.fileID
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000) // 等待 1 秒
        }
        
        guard isCompleted else {
            throw StorageError.networkError("123云盘合成分片超时(30秒)，预上传ID: \(preuploadID)")
        }
        
        progress(1.0)
        let finalItem = Pan123FileItem(
            fileId: finalFileID,
            filename: filename,
            parentFileId: parentNode.fileId,
            type: 0,
            etag: fileMD5,
            size: fileSize
        )
        cache.setNode(for: canonical, item: finalItem)
        cache.invalidateChildren(for: parentNode.fileId)
        
        return fileMD5
    }
    
    /// 分片上传数据流
    func uploadSlices(
        localURL: URL,
        fileSize: Int64,
        sliceSize: Int,
        preuploadID: String,
        uploadServer: String,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let fileHandle = FileHandle(forReadingAtPath: localURL.path) else {
            throw StorageError.fileSystemError("Cannot open file for reading at \(localURL.path)")
        }
        defer { try? fileHandle.close() }
        
        var uploadedBytes: Int64 = 0
        var sliceNo = 1
        
        while uploadedBytes < fileSize {
            let currentSliceSize = min(Int64(sliceSize), fileSize - uploadedBytes)
            let sliceData = fileHandle.readData(ofLength: Int(currentSliceSize))
            if sliceData.isEmpty { break }
            
            let sliceMD5 = Insecure.MD5.hash(data: sliceData).map { String(format: "%02hhx", $0) }.joined()
            try await apiClient.uploadSlice(
                serverURLString: uploadServer,
                preuploadID: preuploadID,
                sliceNo: sliceNo,
                sliceMD5: sliceMD5,
                sliceData: sliceData
            )
            
            uploadedBytes += Int64(sliceData.count)
            sliceNo += 1
            
            if fileSize > 0 {
                let currentProgress = Double(uploadedBytes) / Double(fileSize)
                progress(min(0.99, currentProgress))
            }
        }
    }
    
    /// 下载文件
}
