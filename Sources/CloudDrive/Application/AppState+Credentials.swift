import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func saveCredentialsToAppGroup(vaultId: String, webdavPassword: String?, vaultPassword: String?) {
        CredentialStore.shared.saveCredentialsToAppGroup(vaultId: vaultId,
            storagePassword: webdavPassword, vaultPassword: vaultPassword)
    }

    func saveWebDAVPassword(_ password: String, for vaultId: String) {
        CredentialStore.shared.saveStoragePassword(password, for: vaultId)
    }

    func saveVaultPassword(_ password: String, for vaultId: String) {
        CredentialStore.shared.saveVaultPassword(password, for: vaultId)
    }

    func getVaultPassword(for vaultId: String) -> String? {
        return CredentialStore.shared.getVaultPassword(for: vaultId)
    }

    func getWebDAVPassword(for vaultId: String) -> String? {
        return CredentialStore.shared.getStoragePassword(for: vaultId)
    }

    func deleteWebDAVPassword(for vaultId: String) {
        CredentialStore.shared.deleteStoragePassword(for: vaultId)
    }

    func deleteVaultPassword(for vaultId: String) {
        CredentialStore.shared.deleteVaultPassword(for: vaultId)
    }
}
