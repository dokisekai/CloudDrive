//
//  DomainConfiguration.swift
//  CloudDriveFileProvider
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  FileProvider 扩展域配置与凭据解析器 (优先 userInfo，回退 App Group 与 Keychain)
//

import Foundation
import FileProvider
import CloudDriveCore

/// 域配置解析结果
public struct ResolvedDomainConfig: Sendable {
    public let vault: VaultInfo?
    public let webdavPassword: String?
    public let vaultPassword: String?
    public let bookmarkData: Data?
    
    public init(
        vault: VaultInfo?,
        webdavPassword: String?,
        vaultPassword: String?,
        bookmarkData: Data?
    ) {
        self.vault = vault
        self.webdavPassword = webdavPassword
        self.vaultPassword = vaultPassword
        self.bookmarkData = bookmarkData
    }
}

public struct DomainConfiguration: Sendable {
    
    /// 解析指定 FileProviderDomain 的配置及凭据
    public static func resolve(domain: NSFileProviderDomain) -> ResolvedDomainConfig {
        let domainId = domain.identifier.rawValue
        let vaultId = domainId.hasPrefix("vault-") ? String(domainId.dropFirst("vault-".count)) : domainId
        var resolvedVault: VaultInfo? = VaultRegistry.shared.loadVaultConfig(for: vaultId)
        var resolvedBookmarkData: Data?
        if #available(macOS 15.0, *), let info = domain.userInfo,
           let json = info["vaultConfig"] as? String, let data = json.data(using: .utf8),
           let vault = try? JSONDecoder().decode(VaultInfo.self, from: data), vault.id == vaultId {
            resolvedVault = resolvedVault ?? vault
            resolvedBookmarkData = resolvedVault?.bookmarkData ?? (info["bookmarkData"] as? String).flatMap { Data(base64Encoded: $0) }
            // One-time, domain-matched migration. Credentials are subsequently read only by vault ID.
            if CredentialStore.shared.getStoragePassword(for: vaultId) == nil, let password = info["webdavPassword"] as? String {
                CredentialStore.shared.saveStoragePassword(password, for: vaultId)
            }
            if CredentialStore.shared.getVaultPassword(for: vaultId) == nil, let password = info["vaultPassword"] as? String {
                CredentialStore.shared.saveVaultPassword(password, for: vaultId)
            }
        }
        let defaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        if resolvedVault == nil, let data = defaults?.data(forKey: "vault_config_\(vaultId)"),
           let vault = try? JSONDecoder().decode(VaultInfo.self, from: data), vault.id == vaultId {
            resolvedVault = vault
        }
        resolvedBookmarkData = resolvedBookmarkData ?? defaults?.data(forKey: "vault_bookmark_\(vaultId)") ?? resolvedVault?.bookmarkData
        let resolvedWebDAVPassword = CredentialStore.shared.getStoragePassword(for: vaultId)
        let resolvedVaultPassword = CredentialStore.shared.getVaultPassword(for: vaultId)

        if let secret = resolvedWebDAVPassword, !secret.isEmpty {
            if let config = resolvedVault?.storageConfig, (config.secret ?? "").isEmpty {
                resolvedVault?.storageConfig = config.replacingSecret(secret)
            }
        }

        return ResolvedDomainConfig(
            vault: resolvedVault,
            webdavPassword: resolvedWebDAVPassword,
            vaultPassword: resolvedVaultPassword,
            bookmarkData: resolvedBookmarkData
        )
    }
}
