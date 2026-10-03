import Foundation
import CloudDriveCore

enum SharedVaultConfigurationWriter {
    static func write(_ vault: VaultInfo) {
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clouddrive_config.json")
        print("📁 AppState: Config file path (Unsandboxed): \(configURL.path)")
        
        do {
            let data = try JSONEncoder().encode(vault)
            try data.write(to: configURL, options: [.atomic])
            print("✅ AppState: Config file written successfully, size: \(data.count) bytes")
            
            // 另外也尝试写入 UserDefaults (如果需要)
            if let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive") {
                sharedDefaults.set(data, forKey: "vault_config_\(vault.id)")
                sharedDefaults.set(data, forKey: "vault_config")
                sharedDefaults.set(data, forKey: "active_vault_config")
                sharedDefaults.set(vault.id, forKey: "active_vault_id")
            }
        } catch {
            print("❌ AppState: Failed to write config file: \(error)")
        }
    }
}
