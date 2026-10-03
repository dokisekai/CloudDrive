import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func loadVaults() {
        var result: [VaultInfo] = []
        let loaded = VaultRegistry.shared.loadVaults()
        if !loaded.isEmpty {
            result = loaded
            print("📂 AppState: Loaded \(loaded.count) vaults via VaultRegistry (hydrated)")
        } else if let data = userDefaults.data(forKey: vaultsKey),
                  let decoded = try? JSONDecoder().decode([VaultInfo].self, from: data) {
            result = decoded
            print("📂 AppState: Loaded \(decoded.count) vaults from userDefaults")
        }
        
        // Also check if there are any vaults in App Group sharedDefaults that weren't in result
        if let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive"),
           let data = sharedDefaults.data(forKey: "saved_vaults"),
           let decoded = try? JSONDecoder().decode([VaultInfo].self, from: data) {
            for v in decoded where !result.contains(where: { $0.id == v.id }) {
                result.append(v)
            }
        }
        
        vaults = result
        if !vaults.isEmpty {
            VaultRegistry.shared.saveVaults(vaults)
        }
    }

    func saveVaults() {
        VaultRegistry.shared.saveVaults(vaults)
        if let encoded = try? JSONEncoder().encode(vaults) {
            userDefaults.set(encoded, forKey: vaultsKey)
            print("💾 AppState: Saved \(vaults.count) vaults")
        }
    }

    func saveVaultConfigToSharedFile(_ vault: VaultInfo) {
        SharedVaultConfigurationWriter.write(vault)
    }
}
