import CloudDriveContracts
import CloudDriveSupport
//
//  DatabaseQueryFilter.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  数据库参数化查询条件构建器
//

import Foundation

public indirect enum DatabaseQueryFilter: Sendable {
    case equals(column: String, value: DatabaseValue)
    case notEquals(column: String, value: DatabaseValue)
    case `in`(column: String, values: [DatabaseValue])
    case like(column: String, pattern: String)
    case and(DatabaseQueryFilter, DatabaseQueryFilter)
    case or(DatabaseQueryFilter, DatabaseQueryFilter)
    case raw(sql: String, bindings: [DatabaseValue])
    
    public var parameterizedSQL: (sql: String, bindings: [DatabaseValue]) {
        switch self {
        case .equals(let col, let val):
            return ("\(col) = ?", [val])
        case .notEquals(let col, let val):
            return ("\(col) != ?", [val])
        case .in(let col, let vals):
            let placeholders = Array(repeating: "?", count: vals.count).joined(separator: ", ")
            return ("\(col) IN (\(placeholders))", vals)
        case .like(let col, let pattern):
            return ("\(col) LIKE ?", [.text(pattern)])
        case .and(let left, let right):
            let l = left.parameterizedSQL
            let r = right.parameterizedSQL
            return ("(\(l.sql) AND \(r.sql))", l.bindings + r.bindings)
        case .or(let left, let right):
            let l = left.parameterizedSQL
            let r = right.parameterizedSQL
            return ("(\(l.sql) OR \(r.sql))", l.bindings + r.bindings)
        case .raw(let sql, let bindings):
            return (sql, bindings)
        }
    }
}
