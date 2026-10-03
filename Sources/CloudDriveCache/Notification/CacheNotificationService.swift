import Foundation
import CloudDriveContracts

public final class CacheNotificationService: Sendable {
    public static let shared = CacheNotificationService()
    public let vaultId: String?
    public init(vaultId: String? = nil) { self.vaultId = vaultId }

    public func postEvictionNotification(fileId: String?) { post(fileId: fileId, kind: "eviction") }
    public func postPolicyNotification(fileId: String) { post(fileId: fileId, kind: "policy") }

    private func post(fileId: String?, kind: String) {
        var info: [String: String] = ["kind": kind]
        if let fileId { info["fileId"] = fileId }
        if let vaultId { info["vaultId"] = vaultId }
        NotificationCenter.default.post(name: NSNotification.Name("CloudDriveCacheDidEvictItem"), object: nil, userInfo: info)
        // Distributed notifications carry each event, avoiding the former shared "last ID" race.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("net.aabg.CloudDrive.cacheChanged"), object: vaultId, userInfo: info, deliverImmediately: true
        )
    }
}
