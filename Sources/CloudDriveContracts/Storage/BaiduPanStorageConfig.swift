//
//  BaiduPanStorageConfig.swift
//  CloudDriveContracts
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//

import Foundation

public struct BaiduPanStorageConfig: Codable, Hashable, Sendable {
    public var appID: String
    public var appKey: String
    public var clientSecret: String
    public var appFolderName: String
    public var rootPath: String
    public var refreshToken: String
    public var accessToken: String
    public var expiresAt: Date?
    public var maxRequestsPerMinute: Int
    public var maxRequestsPerDay: Int

    public init(
        appID: String = "",
        appKey: String = "",
        clientSecret: String = "",
        appFolderName: String = "CloudDrive",
        rootPath: String = "/",
        refreshToken: String = "",
        accessToken: String = "",
        expiresAt: Date? = nil,
        maxRequestsPerMinute: Int = 600,
        maxRequestsPerDay: Int = 50_000
    ) {
        self.appID = appID
        self.appKey = appKey
        self.clientSecret = clientSecret
        self.appFolderName = appFolderName
        self.rootPath = rootPath
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.maxRequestsPerMinute = maxRequestsPerMinute
        self.maxRequestsPerDay = maxRequestsPerDay
    }

    private enum CodingKeys: String, CodingKey {
        case appID, appKey, clientSecret, appFolderName, rootPath, refreshToken, accessToken, expiresAt, maxRequestsPerMinute, maxRequestsPerDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
        self.appKey = try container.decodeIfPresent(String.self, forKey: .appKey) ?? ""
        self.clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
        self.appFolderName = try container.decodeIfPresent(String.self, forKey: .appFolderName) ?? "CloudDrive"
        self.rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? "/"
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        self.accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.maxRequestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .maxRequestsPerMinute) ?? 600
        self.maxRequestsPerDay = try container.decodeIfPresent(Int.self, forKey: .maxRequestsPerDay) ?? 50_000
    }
}
