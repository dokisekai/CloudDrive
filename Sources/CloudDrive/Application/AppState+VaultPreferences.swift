import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func toggleAutoMount(for vaultId: String) {
        if let index = vaults.firstIndex(where: { $0.id == vaultId }) {
            var updated = vaults[index]
            updated.isAutoMount.toggle()
            vaults[index] = updated
            saveVaults()
            VaultRegistry.shared.saveVaults(vaults)
        }
    }

    func updateVault(_ updatedVault: VaultInfo, newStoragePassword: String? = nil, newVaultPassword: String? = nil) {
        if let index = vaults.firstIndex(where: { $0.id == updatedVault.id }) {
            vaults[index] = updatedVault
            saveVaults()
            VaultRegistry.shared.saveVaults(vaults)
            
            if let sp = newStoragePassword, !sp.isEmpty {
                _ = CredentialStore.shared.saveStoragePassword(sp, for: updatedVault.id)
            }
            if let vp = newVaultPassword, !vp.isEmpty {
                _ = CredentialStore.shared.saveVaultPassword(vp, for: updatedVault.id)
            }
            if currentVault?.id == updatedVault.id {
                currentVault = updatedVault
                VaultRegistry.shared.saveActiveVaultConfig(updatedVault)
            }
        }
    }

    func changeVaultPassword(vault: VaultInfo, oldPassword: String, newPassword: String) async throws {
        try await VaultLifecycleService.shared.changeVaultPassword(vault: vault, oldPassword: oldPassword, newPassword: newPassword)
        saveVaultPassword(newPassword, for: vault.id)
    }

    func updateBookmark(for vaultId: String, bookmark: Data) {
        if let index = vaults.firstIndex(where: { $0.id == vaultId }) {
            var updated = vaults[index]
            updated.bookmarkData = bookmark
            vaults[index] = updated
            saveVaults()
            if let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive") {
                sharedDefaults.set(bookmark, forKey: "vault_bookmark_\(vaultId)")
                sharedDefaults.set(bookmark, forKey: "active_vault_bookmark")
            }
        }
    }
}
