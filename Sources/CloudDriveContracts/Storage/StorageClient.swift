import Foundation

public protocol StorageClient: AnyObject {
    /// 是否在替换更新已有文件时要求必须携带保存的 ETag（如 WebDAV 避免盲覆盖）
    var requiresETagForUpdate: Bool { get }

    /// 列出目录内容
    func listDirectory(path: String) async throws -> [StorageResource]
    
    /// 下载文件
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws
    
    /// 上传文件
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws

    /// Conditional replacement. The returned ETag belongs to the bytes committed by this request.
    @discardableResult
    func uploadFile(localURL: URL, to remotePath: String, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String?

    /// Upload file with explicit conditional mode.
    @discardableResult
    func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String?

    /// Fetch a specific remote revision and return the revision delivered by the response.
    @discardableResult
    func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String?
    
    /// 创建目录
    func createDirectory(path: String) async throws
    
    /// 删除文件或目录
    func delete(path: String) async throws

    /// 删除文件或目录（带版本约束）
    func delete(path: String, expectedETag: String?) async throws
    
    /// 移动/重命名
    func move(from sourcePath: String, to destinationPath: String) async throws

    /// 移动/重命名（带源版本约束）
    func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws
    
    /// Copy file or directory
    func copy(from sourcePath: String, to destinationPath: String) async throws
    
    /// 检查路径是否存在
    func exists(path: String) async throws -> Bool
    
    /// 测试连接有效性
    func testConnection() async throws -> Bool
}
