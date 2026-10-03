import CloudDriveContracts
import CloudDriveSupport
//
//  VaultRegistry.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  保险库持久化注册中心 (UserDefaults + App Group + 共享配置文件)
//

import Foundation

public final class VaultRegistry: @unchecked Sendable {
    public static let shared = VaultRegistry()
    
    private let vaultsKey = "saved_vaults"
    private let sharedGroup = "group.net.aabg.CloudDrive"
    private let userDefaults: UserDefaults
    private let sharedDefaults: UserDefaults?
    
    public init(
        userDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
    ) {
        self.userDefaults = userDefaults
        self.sharedDefaults = sharedDefaults
    }
    
    private func hydrate(_ vault: VaultInfo) -> VaultInfo {
        var value = vault
        if CredentialStore.shared.getStoragePassword(for: vault.id) == nil, let secret = vault.storageConfig?.secret, !secret.isEmpty {
            _ = CredentialStore.shared.saveStoragePassword(secret, for: vault.id)
        }
        if let secret = CredentialStore.shared.getStoragePassword(for: vault.id) {
            value.storageConfig = value.storageConfig?.replacingSecret(secret)
        }
        return value
    }

    private func persistSecrets(_ vault: VaultInfo) -> Bool {
        guard let secret = vault.storageConfig?.secret, !secret.isEmpty else { return true }
        return CredentialStore.shared.saveStoragePassword(secret, for: vault.id)
    }

    // MARK: - 保险库列表持久化
    
    public func loadVaults() -> [VaultInfo] {
        if let data = userDefaults.data(forKey: vaultsKey),
           let decoded = try? JSONDecoder().decode([VaultInfo].self, from: data) {
            let hydrated = decoded.map { hydrate($0) }
            // Re-encode only after every legacy secret has a durable Keychain copy.
            if decoded.contains(where: { !($0.storageConfig?.secret ?? "").isEmpty }),
               decoded.allSatisfy({ persistSecrets($0) }) { saveVaults(hydrated) }
            return hydrated
        }
        if let shared = sharedDefaults,
           let data = shared.data(forKey: vaultsKey),
           let decoded = try? JSONDecoder().decode([VaultInfo].self, from: data) {
            let hydrated = decoded.map { hydrate($0) }
            // Re-encode only after every legacy secret has a durable Keychain copy.
            if decoded.contains(where: { !($0.storageConfig?.secret ?? "").isEmpty }),
               decoded.allSatisfy({ persistSecrets($0) }) { saveVaults(hydrated) }
            return hydrated
        }
        return []
    }
    
    public func saveVaults(_ vaults: [VaultInfo]) {
        guard vaults.allSatisfy({ persistSecrets($0) }) else { return }
        let sanitized = vaults.map { v -> VaultInfo in
            var copy = v
            copy.storageConfig = copy.storageConfig?.withoutSecrets
            return copy
        }
        guard let encoded = try? JSONEncoder().encode(sanitized) else { return }
        userDefaults.set(encoded, forKey: vaultsKey)
        sharedDefaults?.set(encoded, forKey: vaultsKey)
        for vault in sanitized {
            if let data = try? JSONEncoder().encode(vault) {
                sharedDefaults?.set(data, forKey: "vault_config_\(vault.id)")
            }
        }
    }
    
    // MARK: - 单一/活跃保险库配置持久化
    
    public func saveVaultConfig(_ vault: VaultInfo) {
        guard persistSecrets(vault) else { return }
        var sanitized = vault
        sanitized.storageConfig = sanitized.storageConfig?.withoutSecrets
        do {
            let data = try JSONEncoder().encode(sanitized)
            sharedDefaults?.set(data, forKey: "vault_config_\(vault.id)")
        } catch {
            Logger.shared.error(.system, "VaultRegistry: Failed to encode config for vault \(vault.id): \(error)")
        }
    }
    
    public func saveActiveVaultConfig(_ vault: VaultInfo) {
        saveVaultConfig(vault)
        guard persistSecrets(vault) else { return }
        var sanitized = vault
        sanitized.storageConfig = sanitized.storageConfig?.withoutSecrets
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clouddrive_config.json")
        do {
            let data = try JSONEncoder().encode(sanitized)
            try data.write(to: configURL, options: [.atomic])
            
            sharedDefaults?.set(data, forKey: "vault_config")
            sharedDefaults?.set(data, forKey: "active_vault_config")
            sharedDefaults?.set(vault.id, forKey: "active_vault_id")
        } catch {
            Logger.shared.error(.system, "VaultRegistry: Failed to write active config file: \(error)")
        }
    }
    
    public func loadActiveVaultConfig() -> VaultInfo? {
        if let shared = sharedDefaults {
            if let data = shared.data(forKey: "active_vault_config"),
               let vault = try? JSONDecoder().decode(VaultInfo.self, from: data) {
                return hydrate(vault)
            }
            if let data = shared.data(forKey: "vault_config"),
               let vault = try? JSONDecoder().decode(VaultInfo.self, from: data) {
                return hydrate(vault)
            }
        }
        
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clouddrive_config.json")
        if let data = try? Data(contentsOf: configURL),
           let vault = try? JSONDecoder().decode(VaultInfo.self, from: data) {
            return hydrate(vault)
        }
        
        return nil
    }
    
    public func loadVaultConfig(for vaultId: String) -> VaultInfo? {
        if let shared = sharedDefaults,
           let data = shared.data(forKey: "vault_config_\(vaultId)"),
           let vault = try? JSONDecoder().decode(VaultInfo.self, from: data) {
            return hydrate(vault)
        }
        return loadVaults().first { $0.id == vaultId }
    }
    
    public func getActiveVaultId() -> String? {
        return sharedDefaults?.string(forKey: "active_vault_id")
    }
    
    public func setActiveVaultId(_ vaultId: String) {
        sharedDefaults?.set(vaultId, forKey: "active_vault_id")
    }
    
    public func clearActiveVaultConfig() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clouddrive_config.json")
        try? FileManager.default.removeItem(at: configURL)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) {
            let sharedConfigURL = containerURL.appendingPathComponent("vault_config.json")
            try? FileManager.default.removeItem(at: sharedConfigURL)
        }
        sharedDefaults?.removeObject(forKey: "vault_config")
        sharedDefaults?.removeObject(forKey: "active_vault_config")
        sharedDefaults?.removeObject(forKey: "active_vault_id")
    }
}
