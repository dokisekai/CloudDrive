import Foundation

public struct SyncQueueItem: Codable {
    public let id: String
    public var operation: SyncOperation
    public let createdAt: Date
    public var retryCount: Int
    public var lastError: String?
    public var expectedETag: String?
    public var nextAttemptAt: Date?
    public var blockedByConflict: Bool?
    public var startedAt: Date?
    public var vaultId: String?
    public var isPermanentFailure: Bool?
    public var isAuthFailure: Bool?
    
    public init(
        id: String = UUID().uuidString,
        operation: SyncOperation,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        lastError: String? = nil,
        expectedETag: String? = nil,
        nextAttemptAt: Date? = nil,
        blockedByConflict: Bool? = nil,
        startedAt: Date? = nil,
        vaultId: String? = nil,
        isPermanentFailure: Bool? = nil,
        isAuthFailure: Bool? = nil
    ) {
        self.id = id
        self.operation = operation
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.lastError = lastError
        self.expectedETag = expectedETag
        self.nextAttemptAt = nextAttemptAt
        self.blockedByConflict = blockedByConflict
        self.startedAt = startedAt
        self.vaultId = vaultId ?? operation.vaultId
        self.isPermanentFailure = isPermanentFailure
        self.isAuthFailure = isAuthFailure
    }
    
    /// Whether this item can currently be processed by the worker
    public var isActionable: Bool {
        if blockedByConflict == true { return false }
        if isAuthFailure == true { return false }
        if isPermanentFailure == true { return false }
        if let next = nextAttemptAt, next > Date() { return false }
        return true
    }
}

// MARK: - 文件元数据

/// 文件元数据（用于同步状态跟踪）
