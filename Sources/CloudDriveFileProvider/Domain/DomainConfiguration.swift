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
        if #available(macOS 15.0, *) {
            let keys = domain.userInfo?.keys.map { String(describing: $0) } ?? []
            Logger.shared.info(.system, "🔍 [DomainConfiguration] Resolving domain \(domainId), hasUserInfo: \(domain.userInfo != nil), keys: \(keys)")
            NSLog("🔍 [DomainConfiguration] Resolving domain %@, hasUserInfo: %d, keys: %@", domainId, domain.userInfo != nil, keys)
            if let info = domain.userInfo {
            if let json = info["vaultConfig"] as? String, let data = json.data(using: .utf8),
               let vault = try? JSONDecoder().decode(VaultInfo.self, from: data), vault.id == vaultId {
                resolvedVault = resolvedVault ?? vault
            }
            if resolvedBookmarkData == nil, let b64 = (info["bookmarkData"] as? String) {
                resolvedBookmarkData = Data(base64Encoded: b64)
            }
            if let password = (info["storagePassword"] as? String) ?? (info["webdavPassword"] as? String) {
                CredentialStore.shared.saveStoragePassword(password, for: vaultId)
            }
            if let vp = info["vaultPassword"] as? String {
                CredentialStore.shared.saveVaultPassword(vp, for: vaultId)
            }
            if let tokenStr = info["baiduToken"] as? String,
               let tokenData = tokenStr.data(using: .utf8),
               let payload = try? JSONDecoder().decode(BaiduPanTokenStore.TokenPayload.self, from: tokenData),
               !payload.accessToken.isEmpty {
                Logger.shared.info(.system, "🔑 [DomainConfiguration] Received baiduToken from domain userInfo for vault \(vaultId), len: \(payload.accessToken.count), expiresAt: \(payload.expiresAt)")
                BaiduPanTokenStore.setInMemoryToken(
                    vaultID: vaultId,
                    appID: payload.appID,
                    clientID: payload.clientID,
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken,
                    expiresAt: payload.expiresAt,
                    generation: payload.generation,
                    needsReauth: false
                )
                BaiduPanTokenStore.setInMemoryToken(
                    vaultID: "default",
                    appID: payload.appID,
                    clientID: payload.clientID,
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken,
                    expiresAt: payload.expiresAt,
                    generation: payload.generation,
                    needsReauth: false
                )
                try? BaiduPanTokenStore().saveAuthorized(
                    vaultID: vaultId,
                    appID: payload.appID,
                    clientID: payload.clientID,
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken,
                    expiresIn: Int(max(60, payload.expiresAt.timeIntervalSinceNow))
                )
                try? BaiduPanTokenStore().saveAuthorized(
                    vaultID: "default",
                    appID: payload.appID,
                    clientID: payload.clientID,
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken,
                    expiresIn: Int(max(60, payload.expiresAt.timeIntervalSinceNow))
                )
                _ = CredentialStore.shared.saveBaiduPanToken(data: tokenData, for: vaultId)
                _ = CredentialStore.shared.saveBaiduPanToken(data: tokenData, for: "default")
            }
            }
        }
        let defaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        if resolvedVault == nil, let data = defaults?.data(forKey: "vault_config_\(vaultId)"),
           let vault = try? JSONDecoder().decode(VaultInfo.self, from: data), vault.id == vaultId {
            resolvedVault = vault
        }
        resolvedBookmarkData = resolvedBookmarkData ?? defaults?.data(forKey: "vault_bookmark_\(vaultId)") ?? resolvedVault?.bookmarkData
        var resolvedWebDAVPassword = CredentialStore.shared.getStoragePassword(for: vaultId)
        var resolvedVaultPassword = CredentialStore.shared.getVaultPassword(for: vaultId)
        if #available(macOS 15.0, *), let info = domain.userInfo {
            if resolvedWebDAVPassword == nil {
                resolvedWebDAVPassword = (info["storagePassword"] as? String) ?? (info["webdavPassword"] as? String)
            }
            if resolvedVaultPassword == nil {
                resolvedVaultPassword = info["vaultPassword"] as? String
            }
        }

        if let secret = resolvedWebDAVPassword, !secret.isEmpty {
            if let config = resolvedVault?.storageConfig, (config.secret ?? "").isEmpty {
                resolvedVault?.storageConfig = config.replacingSecret(secret)
            }
        }

        if #available(macOS 15.0, *), let info = domain.userInfo {
            if let clientSecret = info["clientSecret"] as? String, !clientSecret.isEmpty {
                if case .baidupan(var panConfig) = resolvedVault?.storageConfig, panConfig.clientSecret.isEmpty {
                    panConfig.clientSecret = clientSecret
                    resolvedVault?.storageConfig = .baidupan(panConfig)
                }
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
