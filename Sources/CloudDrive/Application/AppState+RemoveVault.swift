import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func deleteVault(_ vault: VaultInfo) {
        print("🗑️ AppState: Deleting vault: \(vault.name)")
        
        // 如果当前处于挂载状态，先执行优雅卸载
        if vault.isMounted {
            unmountVault(vault)
        }
        
        // 清理相关资源 (Keychain密码、MasterKey、Domain与共享配置)
        deleteVaultResources(vault: vault)
        
        // 从列表中移除
        vaults.removeAll { $0.id == vault.id }
        saveVaults()
        
        if currentVault?.id == vault.id {
            lockVault()
        }
        
        print("✅ AppState: Vault deleted")
    }

    func deleteVaultResources(vault: VaultInfo) {
        print("🧹 AppState: Cleaning vault resources: \(vault.name)")
        
        // 1. 从 Keychain 中删除密码与主密钥
        deleteWebDAVPassword(for: vault.id)
        deleteVaultPassword(for: vault.id)
        try? CredentialStore.shared.deleteMasterKey(forVault: vault.id)
        
        // 2. 清理共享文件
        cleanupSharedFiles()
        
        // 3. 停止同步队列与活跃进度
        SyncManager.forVault(vault.id).pauseSyncQueue()
        FileProgressPublisher.shared.cancelTransfers(for: vault.id)
        
        // 4. 移除 File Provider Domain
        Task {
            await removeFileProviderDomain(for: vault)
        }
    }

    func cleanupSharedFiles() {
        VaultRegistry.shared.clearActiveVaultConfig()
    }

    func removeFileProviderDomain(for vault: VaultInfo) async {
        do {
            try await FileProviderDomainService.shared.unregisterDomain(for: vault)
            print("✅ AppState: File Provider domain removed: vault-\(vault.id)")
        } catch {
            print("⚠️ AppState: Failed to remove File Provider domain: \(error.localizedDescription)")
        }
    }
    
    func unmountVault(_ vault: VaultInfo) {
        print("📤 AppState: Unmounting vault: \(vault.name)")
        
        // 1. 暂停同步队列，防止正在传输的任务发生循环报错或损坏
        SyncManager.forVault(vault.id).pauseSyncQueue()
        
        // 2. 取消该保险库的所有活跃进度指示与系统圆环
        FileProgressPublisher.shared.cancelTransfers(for: vault.id)
        
        if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = false
            updatedVault.isUnlocked = false
            updatedVault.isAutoMount = false
            vaults[index] = updatedVault
            saveVaults()
        }
        
        if currentVault?.id == vault.id {
            vfs.lock()
            currentVault = nil
            isVaultUnlocked = false
        }
        
        // 关键：真正注销并移除系统 File Provider Domain，并在 Finder 侧边栏移除该挂载点
        Task {
            await removeFileProviderDomain(for: vault)
        }
        
        // 向 FileProvider Extension 发送锁定通知，进入安全锁定状态
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        sharedDefaults?.set(vault.id, forKey: "lockedVaultId")
        sharedDefaults?.removeObject(forKey: "unlockedVaultId")
        sharedDefaults?.synchronize()
        
        FileProviderSync.shared.notifyVaultLocked(vaultId: vault.id)
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("net.aabg.CloudDrive.vaultLocked"),
            object: nil,
            userInfo: ["vaultId": vault.id],
            deliverImmediately: true
        )
        
        postSystemNotification(title: "CloudDrive", body: "存储库「\(vault.name)」已成功卸载")
        print("✅ AppState: Vault unmounted (Domain removed)")
    }
}
