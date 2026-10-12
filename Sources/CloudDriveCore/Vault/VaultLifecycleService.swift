//
//  VaultLifecycleService.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  保险库生命周期总控服务 (创建/挂载/解锁/锁定/注销)
//

import Foundation
import CloudDriveStorage

public final class VaultLifecycleService: @unchecked Sendable {
    public static let shared = VaultLifecycleService()
    
    private let vfs = VirtualFileSystem.shared
    private let domainService = FileProviderDomainService.shared
    private let credentialStore = CredentialStore.shared
    private let registry = VaultRegistry.shared
    
    private init() {}
    
    /// 创建并挂载新加密保险库
    public func createEncryptedVault(
        name: String,
        storageConfig: StorageConfiguration,
        storagePassword: String,
        vaultPassword: String
    ) async throws -> VaultInfo {
        guard storageConfig.type.isAvailable else { throw StorageError.notSupported("Only WebDAV is enabled") }
        vfs.configureStorage(configuration: storageConfig)
        
        let vaultId = try await vfs.initializeVault(name: name, password: vaultPassword, storagePath: "/")
        
        credentialStore.saveStoragePassword(storagePassword, for: vaultId)
        credentialStore.saveVaultPassword(vaultPassword, for: vaultId)
        credentialStore.saveCredentialsToAppGroup(vaultId: vaultId, storagePassword: storagePassword, vaultPassword: vaultPassword)
        
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: "/",
            createdAt: Date(),
            storageType: storageConfig.type,
            storageConfig: storageConfig,
            webdavURL: storageConfig.url?.absoluteString,
            webdavUsername: storageConfig.username,
            isMounted: true,
            isEncrypted: true
        )
        
        registry.saveActiveVaultConfig(vaultInfo)
        var allVaults = registry.loadVaults()
        allVaults.append(vaultInfo)
        registry.saveVaults(allVaults)
        
        try? await domainService.registerDomain(for: vaultInfo, storagePassword: storagePassword, vaultPassword: vaultPassword)
        return vaultInfo
    }
    
    /// 打开并导入已有加密保险库
    public func openExistingEncryptedVault(
        name: String,
        storageConfig: StorageConfiguration,
        storagePassword: String,
        remotePath: String,
        vaultPassword: String
    ) async throws -> VaultInfo {
        guard storageConfig.type.isAvailable else { throw StorageError.notSupported("Only WebDAV is enabled") }
        vfs.configureStorage(configuration: storageConfig)
        
        var cleanPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPath.isEmpty || cleanPath == "/" {
            cleanPath = "/"
        } else {
            if !cleanPath.hasPrefix("/") {
                cleanPath = "/" + cleanPath
            }
            while cleanPath.hasSuffix("/") && cleanPath.count > 1 {
                cleanPath = String(cleanPath.dropLast())
            }
        }
        
        let folderName = cleanPath == "/" ? "root" : (URL(fileURLWithPath: cleanPath).lastPathComponent)
        let sanitizedFolderName = folderName.filter { $0.isLetter || $0.isNumber }
        let vaultId = "vault_\(sanitizedFolderName.isEmpty ? "v" : sanitizedFolderName)_\(UUID().uuidString.prefix(6).lowercased())"
        
        try await vfs.unlockVault(password: vaultPassword, storagePath: cleanPath, vaultId: vaultId)
        
        credentialStore.saveStoragePassword(storagePassword, for: vaultId)
        credentialStore.saveVaultPassword(vaultPassword, for: vaultId)
        credentialStore.saveCredentialsToAppGroup(vaultId: vaultId, storagePassword: storagePassword, vaultPassword: vaultPassword)
        
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: cleanPath,
            createdAt: Date(),
            storageType: storageConfig.type,
            storageConfig: storageConfig,
            webdavURL: storageConfig.url?.absoluteString,
            webdavUsername: storageConfig.username,
            isMounted: true,
            isEncrypted: true
        )
        
        registry.saveActiveVaultConfig(vaultInfo)
        var allVaults = registry.loadVaults()
        allVaults.append(vaultInfo)
        registry.saveVaults(allVaults)
        
        try? await domainService.registerDomain(for: vaultInfo, storagePassword: storagePassword, vaultPassword: vaultPassword)
        return vaultInfo
    }
    
    /// 解锁已配置的保险库
    public func unlockVault(vault: VaultInfo, vaultPassword: String) async throws {
        guard vault.isStorageEnabled else { throw StorageError.notSupported("Only WebDAV is enabled") }
        let storagePassword = credentialStore.getStoragePassword(for: vault.id) ?? ""
        let storageConfig = StorageClientFactory.createConfiguration(from: vault, password: storagePassword)
        guard storageConfig.type.isAvailable else { throw StorageError.notSupported("Only WebDAV is enabled") }
        vfs.configureStorage(configuration: storageConfig)
        
        try await vfs.unlockVault(password: vaultPassword, storagePath: vault.storagePath, vaultId: vault.id)
        credentialStore.saveVaultPassword(vaultPassword, for: vault.id)
    }
    
    /// 修改加密保险库主密码 (重加密云端 masterkey.cryptomator 并更新本地钥匙串)
    public func changeVaultPassword(vault: VaultInfo, oldPassword: String, newPassword: String) async throws {
        guard vault.isStorageEnabled else { throw StorageError.notSupported("Only WebDAV is enabled") }
        let storagePassword = credentialStore.getStoragePassword(for: vault.id) ?? ""
        let storageConfig = StorageClientFactory.createConfiguration(from: vault, password: storagePassword)
        let client = StorageClientFactory.createClient(configuration: storageConfig)
        
        let targetVFS = (vfs.currentVaultId == vault.id) ? vfs : VirtualFileSystem(vaultId: vault.id)
        targetVFS.configureStorage(client: client)
        
        let effectiveStoragePath = vault.storagePath
        
        try await targetVFS.changeVaultPassword(oldPassword: oldPassword, newPassword: newPassword, storagePath: effectiveStoragePath, vaultId: vault.id)
        
        // 更新本地钥匙串
        _ = credentialStore.saveVaultPassword(newPassword, for: vault.id)
    }
    
    /// 锁定当前保险库
    public func lockCurrentVault() {
        vfs.lock()
    }
}
