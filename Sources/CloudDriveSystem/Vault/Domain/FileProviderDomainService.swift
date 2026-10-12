import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSecurity
import CloudDriveStorage
//
//  FileProviderDomainService.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  NSFileProviderManager 域管理服务 (负责 Domain 注册、注销、凭据封装及信号通知)
//

import Foundation
import FileProvider

public final class FileProviderDomainService: @unchecked Sendable {
    public static let shared = FileProviderDomainService()
    
    private init() {}
    
    public func makeDomainIdentifier(for vaultId: String) -> NSFileProviderDomainIdentifier {
        return NSFileProviderDomainIdentifier(rawValue: "vault-\(vaultId)")
    }
    
    public func makeDomain(for vault: VaultInfo) -> NSFileProviderDomain {
        let domainIdentifier = makeDomainIdentifier(for: vault.id)
        return NSFileProviderDomain(identifier: domainIdentifier, displayName: vault.name)
    }
    
    public func getManager(for vault: VaultInfo) -> NSFileProviderManager? {
        let domain = makeDomain(for: vault)
        return NSFileProviderManager(for: domain)
    }
    
    /// 注册 File Provider Domain。共享配置不包含凭据。
    public func registerDomain(
        for vault: VaultInfo,
        storagePassword: String? = nil,
        vaultPassword: String? = nil
    ) async throws {
        let domainIdentifier = makeDomainIdentifier(for: vault.id)
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: vault.name)
        
        var userInfo = [AnyHashable: Any]()
        // 传递完整保险库配置给自身扩展 (包含已配置的协议参数)，避免脱敏后导致扩展进程丢失云端通信能力
        if let data = try? JSONEncoder().encode(vault), let jsonStr = String(data: data, encoding: .utf8) {
            userInfo["vaultConfig"] = jsonStr
        }
        
        let sp = storagePassword ?? CredentialStore.shared.getStoragePassword(for: vault.id)
        let vp = vaultPassword ?? CredentialStore.shared.getVaultPassword(for: vault.id)
        if let bookmark = vault.bookmarkData {
            userInfo["bookmarkData"] = bookmark.base64EncodedString()
        }
        if let sp = sp {
            userInfo["webdavPassword"] = sp
            userInfo["storagePassword"] = sp
        }
        if vault.storageType == .baidupan || vault.storageConfig?.type == .baidupan {
            let panConfig = (vault.storageConfig.flatMap { cfg -> BaiduPanStorageConfig? in
                if case .baidupan(let c) = cfg { return c }
                return nil
            }) ?? BaiduPanStorageConfig()
            if !panConfig.clientSecret.isEmpty {
                userInfo["clientSecret"] = panConfig.clientSecret
            }
            let tokenStore = BaiduPanTokenStore()
            var foundRecord = (try? tokenStore.readRecordPublic(vault.id)) ?? (try? tokenStore.readRecordPublic("default")) ?? BaiduPanTokenStore.getInMemoryToken(vaultID: vault.id) ?? BaiduPanTokenStore.getInMemoryToken(vaultID: "default")
            if foundRecord == nil || foundRecord?.accessToken.isEmpty == true {
                if let kcData = CredentialStore.shared.getBaiduPanToken(for: vault.id) ?? CredentialStore.shared.getBaiduPanToken(for: "default"),
                   let kcPayload = try? JSONDecoder().decode(BaiduPanTokenStore.TokenPayload.self, from: kcData),
                   !kcPayload.accessToken.isEmpty {
                    foundRecord = BaiduPanTokenStore.Record(
                        vaultID: vault.id,
                        accessToken: kcPayload.accessToken,
                        refreshToken: kcPayload.refreshToken,
                        expiresAt: kcPayload.expiresAt,
                        generation: kcPayload.generation,
                        needsReauth: kcPayload.needsReauth
                    )
                }
            }
            if (foundRecord == nil || foundRecord?.accessToken.isEmpty == true) && !panConfig.accessToken.isEmpty {
                foundRecord = BaiduPanTokenStore.Record(
                    vaultID: vault.id,
                    accessToken: panConfig.accessToken,
                    refreshToken: panConfig.refreshToken,
                    expiresAt: panConfig.expiresAt ?? Date().addingTimeInterval(25 * 86400),
                    generation: 0,
                    needsReauth: false
                )
            }
            if let record = foundRecord, !record.accessToken.isEmpty {
                let payload = BaiduPanTokenStore.TokenPayload(
                    vaultID: vault.id,
                    appID: panConfig.appID,
                    clientID: panConfig.appKey,
                    accessToken: record.accessToken,
                    refreshToken: record.refreshToken,
                    expiresAt: record.expiresAt,
                    generation: record.generation,
                    needsReauth: false
                )
                if let tokenData = try? JSONEncoder().encode(payload),
                   let tokenStr = String(data: tokenData, encoding: .utf8) {
                    userInfo["baiduToken"] = tokenStr
                    Logger.shared.info(.system, "🔑 [FileProviderDomainService] Injected baiduToken into domain userInfo for \(vault.id), len: \(record.accessToken.count)")
                }
            } else {
                Logger.shared.warning(.system, "⚠️ [FileProviderDomainService] No valid token found to inject for vault \(vault.id)")
            }
        }
        if let vp = vp {
            userInfo["vaultPassword"] = vp
        }
        
        #if os(macOS)
        if #available(macOS 15.0, *) {
            domain.userInfo = userInfo
        }
        #endif
        
        if let sp = sp {
            _ = CredentialStore.shared.saveStoragePassword(sp, for: vault.id)
        }
        if let vp = vp {
            _ = CredentialStore.shared.saveVaultPassword(vp, for: vault.id)
        }
        
        VaultRegistry.shared.saveVaultConfig(vault)
        VaultRegistry.shared.saveActiveVaultConfig(vault)
        Logger.shared.info(.system, "FileProviderDomainService: Registering domain \(domainIdentifier.rawValue)")
        
        do {
            try await NSFileProviderManager.add(domain)
            Logger.shared.info(.system, "FileProviderDomainService: Domain registered successfully")
        } catch let error as NSError where error.code == 516 {
            Logger.shared.info(.system, "FileProviderDomainService: Domain already exists (516), replacing to update credentials...")
            try? await NSFileProviderManager.remove(domain)
            try await NSFileProviderManager.add(domain)
            Logger.shared.info(.system, "FileProviderDomainService: Domain re-registered successfully with updated credentials")
            await EnumeratorSignaler.shared.signalImmediately(for: domain)
        } catch {
            Logger.shared.error(.system, "FileProviderDomainService: Failed to register domain: \(error)")
            throw error
        }
    }
    
    /// 移除已注销的 Domain
    public func unregisterDomain(for vault: VaultInfo) async throws {
        FileProgressPublisher.shared.cancelTransfers(for: vault.id)
        let domain = makeDomain(for: vault)
        try await NSFileProviderManager.remove(domain)
        Logger.shared.info(.system, "FileProviderDomainService: Domain removed: \(domain.identifier.rawValue)")
    }
    
    /// 触发刷新信号
    public func signalRefresh(for vault: VaultInfo, immediate: Bool = false) async {
        let domain = makeDomain(for: vault)
        if immediate {
            await EnumeratorSignaler.shared.signalImmediately(for: domain)
        } else {
            await EnumeratorSignaler.shared.signal(for: domain)
        }
    }
}
