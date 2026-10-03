//
//  VaultIgnoreManager.swift
//  CloudDriveVFS
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  加密库级别 .clouddriveignore 规则持久化与同步管理器
//  （脱离 CloudDrive 软件，使用官方 Cryptomator 解密挂载仍可直接读取与编辑）
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence

public final class VaultIgnoreManager {
    public static let shared = VaultIgnoreManager()
    
    /// 加密库内隐藏规则文件名
    public static let ignoreFileName = ".clouddriveignore"
    
    private let engine = IgnoreRuleEngine.shared
    
    private init() {}
    
    /// 加密库解锁后异步调用：从加密库根目录加载专属忽略规则
    public func loadIgnoreRules(vaultId: String, vfs: (any VaultIgnoreVFSDelegate)? = nil) async {
        // 1. 先加载该库的访达手动排除列表
        engine.loadUserExclusions(vaultId: vaultId)
        
        // 2. 优先从加密库本地数据库中极速加载忽略规则（离线即刻生效）
        let db = VFSDatabase(vaultId: vaultId)
        if let cachedRules = db.getIgnoreRules(), !cachedRules.isEmpty {
            engine.setVaultRules(vaultId: vaultId, content: cachedRules)
            Logger.shared.info(.sync, "Vault \(vaultId): Loaded ignore rules from vault database")
        }
        
        guard let vfs = vfs else { return }
        
        do {
            // 列出根目录寻找 .clouddriveignore
            let rootItems = try await vfs.listDirectoryFromWebDAVAsync(directoryId: "ROOT")
            if let ignoreItem = rootItems.first(where: { $0.name == Self.ignoreFileName }) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ignore_\(UUID().uuidString).txt")
                
                try await vfs.downloadFile(fileId: ignoreItem.id, to: tempURL, progress: nil)
                let content = try String(contentsOf: tempURL, encoding: .utf8)
                try? FileManager.default.removeItem(at: tempURL)
                
                engine.setVaultRules(vaultId: vaultId, content: content)
                try? db.setIgnoreRules(content)
                Logger.shared.info(.sync, "Vault \(vaultId): Successfully loaded .clouddriveignore (\(content.components(separatedBy: .newlines).count) lines) and updated vault database")
            } else {
                // 首次未找到规则文件，创建默认模板并上传至加密库根目录
                await createDefaultIgnoreFileIfNeeded(vaultId: vaultId, vfs: vfs)
            }
        } catch {
            Logger.shared.warning(.sync, "Vault \(vaultId): Failed to load .clouddriveignore: \(error.localizedDescription)")
        }
    }
    
    /// 保存并加密同步规则到该 Vault 根目录及库数据库中
    public func saveIgnoreRules(vaultId: String, vfs: any VaultIgnoreVFSDelegate, content: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload_\(Self.ignoreFileName)")
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        
        // 上传到根目录（若已有则覆盖/新版本）
        _ = try await vfs.uploadFile(localURL: tempURL, name: Self.ignoreFileName, parentId: "ROOT")
        try? FileManager.default.removeItem(at: tempURL)
        
        // 更新内存规则引擎与加密库本地数据库
        engine.setVaultRules(vaultId: vaultId, content: content)
        let db = VFSDatabase(vaultId: vaultId)
        try? db.setIgnoreRules(content)
        Logger.shared.info(.sync, "Vault \(vaultId): Saved and encrypted .clouddriveignore to vault and database")
    }
    
    /// 生成并上传默认的 .clouddriveignore 模板
    public func createDefaultIgnoreFileIfNeeded(vaultId: String, vfs: any VaultIgnoreVFSDelegate) async {
        let defaultContent = """
        # CloudDrive Vault Ignore Rules
        # 语法完全兼容 .gitignore 标准
        # 此文件存储在加密库内部根目录下，并由客户端自动端到端加密
        # 脱离 CloudDrive 软件，使用官方 Cryptomator 客户端挂载后，此文件依然在根目录可见并可修改！
        
        # === 编译产物与构建缓存 ===
        target/
        build/
        out/
        dist/
        .gradle/
        
        # === 依赖项缓存 ===
        node_modules/
        .pnpm-store/
        __pycache__/
        *.pyc
        .venv/
        venv/
        
        # === IDE 配置与临时文件 ===
        .idea/
        .vscode/
        DerivedData/
        *.tmp
        *.log
        .cache/
        
        # === 反向放行示例 (以 ! 开头表示绝不忽略) ===
        # !important.log
        """
        
        do {
            try await saveIgnoreRules(vaultId: vaultId, vfs: vfs, content: defaultContent)
            Logger.shared.info(.sync, "Vault \(vaultId): Created default .clouddriveignore")
        } catch {
            Logger.shared.warning(.sync, "Vault \(vaultId): Failed to create default .clouddriveignore: \(error.localizedDescription)")
        }
    }
}
