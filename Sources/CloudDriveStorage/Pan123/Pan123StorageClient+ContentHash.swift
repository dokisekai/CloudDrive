import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    // MARK: - Helper Methods
    
    /// 计算本地文件 MD5
    func computeFileMD5(localURL: URL) throws -> String {
        guard let stream = InputStream(url: localURL) else {
            throw StorageError.fileSystemError("Cannot open stream for \(localURL.path)")
        }
        stream.open()
        defer { stream.close() }
        
        var hasher = Insecure.MD5()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw StorageError.fileSystemError(stream.streamError?.localizedDescription ?? "Read error")
            }
            if read == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
