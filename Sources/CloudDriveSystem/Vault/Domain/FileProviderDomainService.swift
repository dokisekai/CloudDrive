import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSecurity
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
        var sanitized = vault
        sanitized.storageConfig = sanitized.storageConfig?.withoutSecrets
        if let data = try? JSONEncoder().encode(sanitized), let jsonStr = String(data: data, encoding: .utf8) {
            userInfo["vaultConfig"] = jsonStr
        }
        
        let sp = storagePassword ?? CredentialStore.shared.getStoragePassword(for: vault.id)
        if let bookmark = vault.bookmarkData {
            userInfo["bookmarkData"] = bookmark.base64EncodedString()
        }
        
        #if os(macOS)
        if #available(macOS 15.0, *) {
            domain.userInfo = userInfo
        }
        #endif
        
        if let sp = sp {
            guard CredentialStore.shared.saveStoragePassword(sp, for: vault.id) else { throw VFSError.authenticationFailed }
        }
        if let vp = vaultPassword {
            guard CredentialStore.shared.saveVaultPassword(vp, for: vault.id) else { throw VFSError.authenticationFailed }
        }
        
        VaultRegistry.shared.saveVaultConfig(vault)
        VaultRegistry.shared.saveActiveVaultConfig(vault)
        Logger.shared.info(.system, "FileProviderDomainService: Registering domain \(domainIdentifier.rawValue)")
        
        do {
            try await NSFileProviderManager.add(domain)
            Logger.shared.info(.system, "FileProviderDomainService: Domain registered successfully")
        } catch let error as NSError where error.code == 516 {
            // Re-registering must not remove a domain with materialized or dirty files.
            Logger.shared.info(.system, "FileProviderDomainService: Reconnecting existing domain")
            if let manager = NSFileProviderManager(for: domain) {
                try await manager.reconnect()
                await EnumeratorSignaler.shared.signalImmediately(for: domain)
            }
        } catch {
            Logger.shared.error(.system, "FileProviderDomainService: Failed to register domain: \(error)")
            throw error
        }
    }
    
    /// 移除已注销的 Domain
    public func unregisterDomain(for vault: VaultInfo) async throws {
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
