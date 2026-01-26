//
//  WebDAVClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  WebDAV 客户端实现
//

import Foundation

/// WebDAV 客户端
public class WebDAVClient {
    public static let shared = WebDAVClient()
    
    private let session: URLSession
    private var baseURL: URL?
    private var credentials: URLCredential?
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Configuration
    
    /// 配置 WebDAV 服务器
    public func configure(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.credentials = URLCredential(user: username, password: password, persistence: .forSession)
    }
    
    // MARK: - Connection Test
    
    /// 测试 WebDAV 连接
    public func testConnection() async throws -> Bool {
        guard let baseURL = baseURL else {
            throw WebDAVError.notConfigured
        }
        
        print("🔍 WebDAV: 测试连接...")
        print("📡 WebDAV: 服务器地址: \(baseURL.absoluteString)")
        
        // 使用 PROPFIND 测试根目录访问
        var request = URLRequest(url: baseURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10 // 10秒超时
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }
        
        do {
            let (_, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ WebDAV: 无效的响应")
                throw WebDAVError.invalidResponse
            }
            
            print("📡 WebDAV: 响应状态码: \(httpResponse.statusCode)")
            
            // 检查状态码
            switch httpResponse.statusCode {
            case 200...299:
                print("✅ WebDAV: 连接成功！")
                return true
            case 401, 403:
                print("❌ WebDAV: 认证失败（状态码: \(httpResponse.statusCode)）")
                throw WebDAVError.authenticationFailed
            case 404:
                print("❌ WebDAV: 服务器地址不存在（404）")
                throw WebDAVError.serverError(404)
            default:
                print("❌ WebDAV: 服务器错误（状态码: \(httpResponse.statusCode)）")
                throw WebDAVError.serverError(httpResponse.statusCode)
            }
        } catch let error as WebDAVError {
            throw error
        } catch {
            print("❌ WebDAV: 连接失败: \(error.localizedDescription)")
            throw WebDAVError.serverError(-1)
        }
    }
    
    // MARK: - WebDAV Operations
    
    /// 列出目录内容（PROPFIND）
    public func listDirectory(path: String) async throws -> [WebDAVResource] {
        guard let baseURL = baseURL else {
            throw WebDAVError.notConfigured
        }
        
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        
        // PROPFIND XML body
        let propfindXML = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
            <D:prop>
                <D:displayname/>
                <D:getcontentlength/>
                <D:getcontenttype/>
                <D:creationdate/>
                <D:getlastmodified/>
                <D:resourcetype/>
                <D:getetag/>
            </D:prop>
        </D:propfind>
        """
        request.httpBody = propfindXML.data(using: .utf8)
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDAVError.serverError(httpResponse.statusCode)
        }
        
        // 解析 XML 响应
        return try parseMultiStatusResponse(data: data, basePath: path)
    }
    
    /// 下载文件（GET）
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        logInfo(.webdav, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.webdav, "开始下载文件")
        logInfo(.webdav, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let baseURL = baseURL else {
            logError(.webdav, "客户端未配置")
            throw WebDAVError.notConfigured
        }
        
        logInfo(.webdav, "配置信息 - Base URL: \(baseURL.absoluteString)")
        logInfo(.webdav, "请求路径: \(path)")
        
        // 构建完整 URL
        let url = baseURL.appendingPathComponent(path)
        logInfo(.webdav, "完整 URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                logInfo(.webdav, "认证: Basic (用户名: \(credentials.user!))")
            }
        } else {
            logWarning(.webdav, "认证: 无")
        }
        
        logInfo(.webdav, "发送 HTTP GET 请求...")
        let (tempURL, response) = try await session.download(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logError(.webdav, "无效的响应")
            throw WebDAVError.invalidResponse
        }
        
        logInfo(.webdav, "收到响应 - 状态码: \(httpResponse.statusCode)")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            logError(.webdav, "HTTP 错误 - 状态码: \(httpResponse.statusCode)")
            logError(.webdav, "请求 URL: \(url.absoluteString)")
            if httpResponse.statusCode == 404 {
                logError(.webdav, "404 Not Found - 文件不存在")
                logError(.webdav, "可能原因: 1.文件路径不正确 2.文件已被删除 3.URL编码问题")
            }
            logInfo(.webdav, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw WebDAVError.serverError(httpResponse.statusCode)
        }
        
        logSuccess(.webdav, "下载成功")
        logInfo(.fileOps, "临时文件: \(tempURL.path)")
        logInfo(.fileOps, "临时文件存在: \(FileManager.default.fileExists(atPath: tempURL.path))")
        logInfo(.fileOps, "目标文件: \(destinationURL.path)")
        
        // 确保目标目录存在
        let destinationDir = destinationURL.deletingLastPathComponent()
        logInfo(.fileOps, "目标目录: \(destinationDir.path)")
        
        if !FileManager.default.fileExists(atPath: destinationDir.path) {
            logInfo(.fileOps, "创建目标目录...")
            do {
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
                logSuccess(.fileOps, "目标目录创建成功")
            } catch {
                logError(.fileOps, "创建目标目录失败: \(error)")
                throw error
            }
        }
        
        // 删除已存在的目标文件
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            logInfo(.fileOps, "删除已存在的目标文件...")
            do {
                try FileManager.default.removeItem(at: destinationURL)
                logSuccess(.fileOps, "已删除旧文件")
            } catch {
                logError(.fileOps, "删除旧文件失败: \(error)")
                throw error
            }
        }
        
        // 移动文件
        logInfo(.fileOps, "移动文件: \(tempURL.path) -> \(destinationURL.path)")
        do {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            logSuccess(.fileOps, "文件移动成功")
        } catch {
            logError(.fileOps, "文件移动失败: \(error)")
            
            // 尝试复制而不是移动
            logInfo(.fileOps, "尝试复制文件...")
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                logSuccess(.fileOps, "文件复制成功")
                // 删除临时文件
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                logError(.fileOps, "文件复制也失败: \(error)")
                throw error
            }
        }
        
        // 验证文件是否存在
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let fileSize = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64
            logSuccess(.fileOps, "文件已保存 - 大小: \(fileSize ?? 0) 字节")
        } else {
            logError(.fileOps, "文件保存失败 - 目标文件不存在")
        }
        
        logInfo(.webdav, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// 上传文件（PUT）
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        guard let baseURL = baseURL else {
            throw WebDAVError.notConfigured
        }
        
        let url = baseURL.appendingPathComponent(remotePath)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let data = try Data(contentsOf: localURL)
        request.httpBody = data
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WebDAVError.serverError(statusCode)
        }
    }
    
    /// 创建目录（MKCOL）- 支持递归创建父目录
    public func createDirectory(path: String) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📁 WebDAV.createDirectory: 开始创建目录")
        print("   原始路径: \(path)")
        print("   当前时间: \(Date())")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let baseURL = baseURL else {
            print("❌ WebDAV: 客户端未配置，无法创建目录")
            throw WebDAVError.notConfigured
        }
        
        print("✅ WebDAV: 客户端已配置")
        print("   Base URL: \(baseURL.absoluteString)")
        
        // 确保路径格式正确，避免双斜杠问题
        var cleanPath = path
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        
        print("🧹 WebDAV: 路径清理")
        print("   原始路径: \(path)")
        print("   清理后路径: \(cleanPath)")
        
        // 递归创建父目录
        let pathComponents = cleanPath.split(separator: "/").map(String.init)
        print("📂 WebDAV: 路径组件分析")
        print("   组件数量: \(pathComponents.count)")
        for (index, component) in pathComponents.enumerated() {
            print("   [\(index)]: \(component)")
        }
        
        var currentPath = ""
        
        for (index, component) in pathComponents.enumerated() {
            if !currentPath.isEmpty {
                currentPath += "/"
            }
            currentPath += component
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📁 WebDAV: 处理路径组件 [\(index)/\(pathComponents.count-1)]")
            print("   组件: \(component)")
            print("   当前路径: \(currentPath)")
            
            // 检查目录是否已存在
            let checkURL = baseURL.appendingPathComponent(currentPath)
            print("🔍 WebDAV: 检查目录是否存在")
            print("   检查URL: \(checkURL.absoluteString)")
            
            var checkRequest = URLRequest(url: checkURL)
            checkRequest.httpMethod = "PROPFIND"
            checkRequest.setValue("0", forHTTPHeaderField: "Depth")
            checkRequest.timeoutInterval = 15
            
            // 添加认证
            if let credentials = credentials {
                let authString = "\(credentials.user!):\(credentials.password!)"
                if let authData = authString.data(using: .utf8) {
                    let base64Auth = authData.base64EncodedString()
                    checkRequest.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                    print("🔑 WebDAV: 已添加认证")
                }
            }
            
            do {
                print("📤 WebDAV: 发送PROPFIND检查请求...")
                let (_, checkResponse) = try await session.data(for: checkRequest)
                if let httpResponse = checkResponse as? HTTPURLResponse {
                    print("📥 WebDAV: 检查响应状态码: \(httpResponse.statusCode)")
                    if (200...299).contains(httpResponse.statusCode) {
                        print("✅ WebDAV: 目录已存在，跳过创建: \(currentPath)")
                        continue // 目录已存在，跳过创建
                    } else {
                        print("ℹ️ WebDAV: 目录不存在（状态码: \(httpResponse.statusCode)），需要创建")
                    }
                } else {
                    print("⚠️ WebDAV: 检查响应无效，尝试创建目录")
                }
            } catch {
                print("⚠️ WebDAV: 检查目录失败: \(error)，尝试创建目录")
            }
            
            // 创建目录
            let url = baseURL.appendingPathComponent(currentPath)
            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            request.timeoutInterval = 30
            
            print("📁 WebDAV: 创建目录")
            print("   目录路径: \(currentPath)")
            print("   请求URL: \(url.absoluteString)")
            print("   HTTP方法: MKCOL")
            
            // 添加认证
            if let credentials = credentials {
                let authString = "\(credentials.user!):\(credentials.password!)"
                if let authData = authString.data(using: .utf8) {
                    let base64Auth = authData.base64EncodedString()
                    request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                    print("🔑 WebDAV: 已添加认证")
                }
            }
            
            do {
                print("📤 WebDAV: 发送MKCOL创建请求...")
                let (data, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    print("📥 WebDAV: 创建响应")
                    print("   状态码: \(httpResponse.statusCode)")
                    print("   响应头: \(httpResponse.allHeaderFields)")
                    
                    if !data.isEmpty {
                        if let responseBody = String(data: data, encoding: .utf8) {
                            print("   响应体: \(responseBody)")
                        } else {
                            print("   响应体大小: \(data.count) 字节")
                        }
                    }
                    
                    // 405 表示目录已存在（某些服务器会返回这个）
                    if httpResponse.statusCode == 405 {
                        print("ℹ️ WebDAV: 目录已存在（405）: \(currentPath)")
                        continue
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        print("❌ WebDAV: 目录创建失败")
                        print("   路径: \(currentPath)")
                        print("   状态码: \(httpResponse.statusCode)")
                        print("   URL: \(url.absoluteString)")
                        throw WebDAVError.serverError(httpResponse.statusCode)
                    }
                    
                    print("✅ WebDAV: 目录创建成功: \(currentPath)")
                } else {
                    print("❌ WebDAV: 无效的创建响应")
                    throw WebDAVError.invalidResponse
                }
            } catch {
                print("❌ WebDAV: 创建目录请求异常")
                print("   路径: \(currentPath)")
                print("   错误: \(error)")
                print("   错误类型: \(type(of: error))")
                throw error
            }
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ WebDAV.createDirectory: 完整路径创建成功")
        print("   最终路径: \(path)")
        print("   完成时间: \(Date())")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// 删除文件或目录（DELETE）
    public func delete(path: String) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🗑️ WebDAV.delete: 开始删除操作")
        print("   路径: \(path)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let baseURL = baseURL else {
            print("❌ WebDAV: 客户端未配置")
            throw WebDAVError.notConfigured
        }
        
        let url = baseURL.appendingPathComponent(path)
        print("📡 WebDAV: 完整删除URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30  // 30秒超时
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                print("🔑 WebDAV: 已添加认证 (用户: \(credentials.user!))")
            }
        } else {
            print("⚠️ WebDAV: 无认证信息")
        }
        
        print("📤 WebDAV: 发送 DELETE 请求...")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ WebDAV: 无效响应")
                throw WebDAVError.invalidResponse
            }
            
            print("📥 WebDAV: 收到响应")
            print("   状态码: \(httpResponse.statusCode)")
            print("   响应头: \(httpResponse.allHeaderFields)")
            
            if !data.isEmpty {
                if let responseBody = String(data: data, encoding: .utf8) {
                    print("   响应体: \(responseBody)")
                } else {
                    print("   响应体大小: \(data.count) 字节")
                }
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ WebDAV: 删除失败 - HTTP \(httpResponse.statusCode)")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                throw WebDAVError.serverError(httpResponse.statusCode)
            }
            
            print("✅ WebDAV: 删除成功")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
        } catch {
            print("❌ WebDAV: 删除请求异常: \(error)")
            print("   错误类型: \(type(of: error))")
            if let urlError = error as? URLError {
                print("   URL错误码: \(urlError.code.rawValue)")
                print("   URL错误描述: \(urlError.localizedDescription)")
            }
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw error
        }
    }
    
    /// 移动/重命名（MOVE）
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        guard let baseURL = baseURL else {
            throw WebDAVError.notConfigured
        }
        
        let sourceURL = baseURL.appendingPathComponent(sourcePath)
        let destinationURL = baseURL.appendingPathComponent(destinationPath)
        
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "MOVE"
        request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WebDAVError.serverError(statusCode)
        }
    }
    
    // MARK: - Helper Methods
    
    private func parseMultiStatusResponse(data: Data, basePath: String) throws -> [WebDAVResource] {
        let parser = WebDAVXMLParser()
        return try parser.parse(data: data, basePath: basePath)
    }
}

// MARK: - Models

/// WebDAV 资源
public struct WebDAVResource {
    public let path: String
    public let displayName: String
    public let isDirectory: Bool
    public let contentLength: Int64
    public let contentType: String?
    public let creationDate: Date?
    public let lastModified: Date?
    public let etag: String?
    
    public init(path: String, displayName: String, isDirectory: Bool, contentLength: Int64,
                contentType: String?, creationDate: Date?, lastModified: Date?, etag: String?) {
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.contentType = contentType
        self.creationDate = creationDate
        self.lastModified = lastModified
        self.etag = etag
    }
}

// MARK: - Errors

public enum WebDAVError: Error, CustomNSError {
    case notConfigured
    case invalidResponse
    case serverError(Int)
    case parseError
    case authenticationFailed
    
    public static var errorDomain: String {
        return "com.clouddrive.webdav"
    }
    
    public var errorCode: Int {
        switch self {
        case .notConfigured:
            return 1001
        case .invalidResponse:
            return 1002
        case .serverError(let statusCode):
            return statusCode  // 使用实际的HTTP状态码
        case .parseError:
            return 1003
        case .authenticationFailed:
            return 1004
        }
    }
    
    public var errorUserInfo: [String : Any] {
        switch self {
        case .notConfigured:
            return [NSLocalizedDescriptionKey: "WebDAV客户端未配置"]
        case .invalidResponse:
            return [NSLocalizedDescriptionKey: "无效的WebDAV响应"]
        case .serverError(let statusCode):
            return [NSLocalizedDescriptionKey: "服务器错误 (\(statusCode))"]
        case .parseError:
            return [NSLocalizedDescriptionKey: "解析WebDAV响应失败"]
        case .authenticationFailed:
            return [NSLocalizedDescriptionKey: "WebDAV认证失败"]
        }
    }
}

// MARK: - XML Parser

private class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var resources: [WebDAVResource] = []
    private var currentResource: [String: String] = [:]
    private var currentElement: String = ""
    private var currentValue: String = ""
    
    func parse(data: Data, basePath: String) throws -> [WebDAVResource] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        
        guard parser.parse() else {
            throw WebDAVError.parseError
        }
        
        // 过滤掉基础路径本身
        return resources.filter { !$0.path.hasSuffix(basePath) || $0.path != basePath }
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentValue = ""
        
        if elementName == "D:response" || elementName == "response" {
            currentResource = [:]
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        
        switch elementName {
        case "D:href", "href":
            currentResource["href"] = currentValue
        case "D:displayname", "displayname":
            currentResource["displayname"] = currentValue
        case "D:getcontentlength", "getcontentlength":
            currentResource["contentlength"] = currentValue
        case "D:getcontenttype", "getcontenttype":
            currentResource["contenttype"] = currentValue
        case "D:creationdate", "creationdate":
            currentResource["creationdate"] = currentValue
        case "D:getlastmodified", "getlastmodified":
            currentResource["lastmodified"] = currentValue
        case "D:getetag", "getetag":
            currentResource["etag"] = currentValue
        case "D:collection", "collection":
            currentResource["isdirectory"] = "true"
        case "D:response", "response":
            if let href = currentResource["href"] {
                let resource = WebDAVResource(
                    path: href,
                    displayName: currentResource["displayname"] ?? href.components(separatedBy: "/").last ?? "",
                    isDirectory: currentResource["isdirectory"] == "true",
                    contentLength: Int64(currentResource["contentlength"] ?? "0") ?? 0,
                    contentType: currentResource["contenttype"],
                    creationDate: parseDate(currentResource["creationdate"]),
                    lastModified: parseDate(currentResource["lastmodified"]),
                    etag: currentResource["etag"]
                )
                resources.append(resource)
            }
        default:
            break
        }
        
        currentValue = ""
    }
    
    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        let rfc1123Formatter = DateFormatter()
        rfc1123Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        rfc1123Formatter.locale = Locale(identifier: "en_US_POSIX")
        return rfc1123Formatter.date(from: dateString)
    }
}