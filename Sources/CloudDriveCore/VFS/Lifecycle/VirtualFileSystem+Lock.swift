import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func lock() {
        print("🔒 [VFS] Locking vault...")
        
        // 从密钥链删除主密钥
        if let vaultId = currentVaultId {
            try? CredentialStore.shared.deleteMasterKey(forVault: vaultId)
            currentVaultId = nil
        }
        
        // 清除内存中的主密钥
        encryption.clearMasterKey()
        cryptomatorFormat = nil
        isEncryptedVault = false
        isDirectMappingVault = false
        activeProvider = nil
        print("✅ [VFS] Master key cleared")
        
        // 关闭数据库（通过deinit自动调用，但显式调用更安全）
        database = VFSDatabase()
        print("✅ [VFS] Database reset")
    }
}
