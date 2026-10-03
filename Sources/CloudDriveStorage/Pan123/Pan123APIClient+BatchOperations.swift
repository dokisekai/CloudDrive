import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

extension Pan123APIClient {
    // MARK: - Batch Operations (批量上限 100 自动切分)
    
    /// 批量移动文件（单次最多 100 条，超出自动分页批量处理）
    public func batchMove(fileIDs: [Int64], toParentFileID: Int64) async throws {
        guard !fileIDs.isEmpty else { return }
        let chunkSize = 100
        for i in stride(from: 0, to: fileIDs.count, by: chunkSize) {
            let chunk = Array(fileIDs[i..<min(i + chunkSize, fileIDs.count)])
            let moveReq = Pan123MoveRequest(fileIDs: chunk, toParentFileID: toParentFileID)
            try await sendEmptyResponseRequest(
                path: "api/v1/file/move",
                method: "POST",
                body: moveReq
            )
        }
    }
    
    /// 批量移入回收站（单次最多 100 条，超出自动分页批量处理）
    public func batchTrash(fileIDs: [Int64]) async throws {
        guard !fileIDs.isEmpty else { return }
        let chunkSize = 100
        for i in stride(from: 0, to: fileIDs.count, by: chunkSize) {
            let chunk = Array(fileIDs[i..<min(i + chunkSize, fileIDs.count)])
            let trashReq = Pan123TrashRequest(fileIDs: chunk)
            try await sendEmptyResponseRequest(
                path: "api/v1/file/trash",
                method: "POST",
                body: trashReq
            )
        }
    }
}
