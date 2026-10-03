//
//  VaultCreationMode.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  保险库创建模式枚举
//

import Foundation

public enum VaultCreationMode: String, Codable, CaseIterable, Sendable {
    /// 新建加密保险库 (基于 Cryptomator Format 7/8)
    case createEncrypted
    
    /// 打开/导入已有的加密保险库
    case openEncrypted
    
    /// 直接映射 (透明映射云端已有目录或本地路径，不加密)
    case directMapping
    
    public var displayName: String {
        switch self {
        case .createEncrypted:
            return "新建加密保险库"
        case .openEncrypted:
            return "打开已有加密库"
        case .directMapping:
            return "直接透明映射"
        }
    }
}
