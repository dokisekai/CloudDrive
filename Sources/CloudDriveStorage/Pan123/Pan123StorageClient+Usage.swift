import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func getTodayUsageStats() throws -> Pan123UsageStats {
        let maxQuota = config.maxDailyDownloadBytes ?? (1024 * 1024 * 1024)
        return try apiClient.databaseStore.getUsageStats(clientID: config.clientID, maxDailyDownloadBytes: maxQuota)
    }
}
