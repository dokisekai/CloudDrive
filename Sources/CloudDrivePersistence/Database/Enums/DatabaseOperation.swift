import CloudDriveContracts
import CloudDriveSupport
//
//  DatabaseOperation.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  数据库强类型操作指令与参数值抽象
//

import Foundation

public enum DatabaseValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null
}

public enum DatabaseOperation: Sendable {
    case insert(table: DatabaseTable, values: [String: DatabaseValue])
    case update(table: DatabaseTable, values: [String: DatabaseValue], where: DatabaseQueryFilter)
    case delete(table: DatabaseTable, where: DatabaseQueryFilter)
    case rawExecute(sql: String, bindings: [DatabaseValue])
}
