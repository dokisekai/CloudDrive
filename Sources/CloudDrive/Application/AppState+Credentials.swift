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

    func getBaiduTokenPayloadString(for vaultId: String) -> String? {
        let tokenStore = BaiduPanTokenStore()
        var record = (try? tokenStore.readRecordPublic(vaultId)) ?? (try? tokenStore.readRecordPublic("default")) ?? BaiduPanTokenStore.getInMemoryToken(vaultID: vaultId) ?? BaiduPanTokenStore.getInMemoryToken(vaultID: "default")
        if record == nil || record?.accessToken.isEmpty == true {
            if let kcData = CredentialStore.shared.getBaiduPanToken(for: vaultId) ?? CredentialStore.shared.getBaiduPanToken(for: "default"),
               let kcPayload = try? JSONDecoder().decode(BaiduPanTokenStore.TokenPayload.self, from: kcData),
               !kcPayload.accessToken.isEmpty {
                record = BaiduPanTokenStore.Record(
                    vaultID: vaultId,
                    accessToken: kcPayload.accessToken,
                    refreshToken: kcPayload.refreshToken,
                    expiresAt: kcPayload.expiresAt,
                    generation: kcPayload.generation,
                    needsReauth: false
                )
            }
        }
        guard let validRecord = record, !validRecord.accessToken.isEmpty else {
            return nil
        }
        let vault = vaults.first(where: { $0.id == vaultId })
        let panConfig = (vault?.storageConfig.flatMap { cfg -> BaiduPanStorageConfig? in
            if case .baidupan(let c) = cfg { return c }
            return nil
        }) ?? BaiduPanStorageConfig()
        let payload = BaiduPanTokenStore.TokenPayload(
            vaultID: vaultId,
            appID: panConfig.appID,
            clientID: panConfig.appKey,
            accessToken: validRecord.accessToken,
            refreshToken: validRecord.refreshToken,
            expiresAt: validRecord.expiresAt,
            generation: validRecord.generation,
            needsReauth: false
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
