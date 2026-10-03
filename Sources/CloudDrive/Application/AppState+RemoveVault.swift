import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func deleteVault(_ vault: VaultInfo) {
        print("🗑️ AppState: Deleting vault: \(vault.name)")
        
        // 检查是否已挂载
        if vault.isMounted {
            print("⚠️ AppState: Vault is mounted, cannot delete")
            return
        }
        
        // 清理相关资源
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
        
        // 1. 从 Keychain 中删除密码
        deleteWebDAVPassword(for: vault.id)
        deleteVaultPassword(for: vault.id)
        
        // 2. 清理共享文件
        cleanupSharedFiles()
        
        // 3. 级联清理该保险库的回收站记录与磁盘快照
        RecycleBinManager.shared.purgeVaultData(vaultId: vault.id)
        
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
        
        if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = false
            vaults[index] = updatedVault
            saveVaults()
        }
        
        if currentVault?.id == vault.id {
            lockVault()
        }
        
        Task {
            await removeFileProviderDomain(for: vault)
        }
        
        postSystemNotification(title: "CloudDrive", body: "存储库「\(vault.name)」已成功卸载")
        print("✅ AppState: Vault unmounted")
    }
}
