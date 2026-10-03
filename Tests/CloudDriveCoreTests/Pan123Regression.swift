//
//  Pan123Regression.swift
//  CloudDriveCoreTests
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  123云盘存储模块单元测试与集成回归测试套件
//

import Foundation
import CryptoKit
import CloudDriveCore
import CloudDriveStorage

private struct Pan123TestFailure: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Mock URL Protocol for 123pan

final class Mock123PanURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = Mock123PanURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: Pan123TestFailure(description: "No handler registered"))
            return
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

private func extractBodyData(from request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var result = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            result.append(buffer, count: read)
        }
        return result
    }
    return Data()
}

// MARK: - Pan123 Regression Suite

public func runPan123Regressions() async throws {
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("☁️ Running 123 Cloud Drive Storage Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    func assert(_ condition: Bool, _ name: String) {
        if condition {
            print("  ✅ [123pan] PASSED: \(name)")
        } else {
            print("  ❌ [123pan] FAILED: \(name)")
            fatalError("Regression failed: \(name)")
        }
    }
    
    // 1. Model serialization & Deserialization
    do {
        print("  ▶ Verifying 123pan model serialization & response parsing...")
        let sampleListJSON = """
        {
          "code": 0,
          "message": "ok",
          "data": {
            "lastFileId": -1,
            "fileList": [
              {
                "fileId": 1001,
                "filename": "document.pdf",
                "parentFileId": 0,
                "type": 0,
                "etag": "d41d8cd98f00b204e9800998ecf8427e",
                "size": 1024,
                "trashed": 0,
                "createAt": "2026-10-01 12:00:00",
                "updateAt": "2026-10-02 15:30:00"
              },
              {
                "fileId": 1002,
                "filename": "TrashFile.txt",
                "parentFileId": 0,
                "type": 0,
                "etag": "e2fc714c4727ee9395f324cd2e7f331f",
                "size": 256,
                "trashed": 1
              },
              {
                "fileId": 2001,
                "filename": "Photos",
                "parentFileId": 0,
                "type": 1,
                "size": 0,
                "trashed": 0
              }
            ]
          }
        }
        """.data(using: .utf8)!
        
        let listResp = try JSONDecoder().decode(Pan123Response<Pan123FileListData>.self, from: sampleListJSON)
        assert(listResp.isSuccess, "Pan123Response isSuccess evaluates true when code == 0")
        assert(listResp.data?.lastFileId == -1, "lastFileId correctly parsed as -1 (end of page)")
        assert(listResp.data?.fileList?.count == 3, "fileList correctly contains 3 elements")
        
        let file = listResp.data!.fileList![0]
        assert(!file.isDirectory, "type 0 correctly recognized as not a directory")
        assert(!file.isTrashed, "trashed 0 correctly recognized as active")
        assert(file.size == 1024, "File size parsed accurately")
        
        let trashedFile = listResp.data!.fileList![1]
        assert(trashedFile.isTrashed, "trashed 1 correctly recognized as trashed")
        
        let folder = listResp.data!.fileList![2]
        assert(folder.isDirectory, "type 1 correctly recognized as directory")
    }
    
    // 2. StorageConfiguration & Security Desensitization
    do {
        print("  ▶ Verifying Pan123 StorageConfiguration & credentials security...")
        let panConfig = Pan123StorageConfig(
            clientID: "app_id_999",
            clientSecret: "secret_xyz_888",
            accessToken: "token_abc_123",
            rootFolderID: 14663228,
            rootPath: "/my_vault"
        )
        let configEnum = StorageConfiguration.pan123(panConfig)
        
        assert(configEnum.type == .pan123, "StorageConfiguration reports type .pan123")
        assert(configEnum.summaryDescription.contains("14663228"), "Summary contains rootFolderID")
        assert(configEnum.username == "app_id_999", "Username mapped to clientID")
        assert(configEnum.secret == "secret_xyz_888", "Secret mapped to clientSecret")
        
        let desensitized = configEnum.withoutSecrets
        assert(desensitized.secret == "", "Desensitized configuration clears secret")
        
        let restored = desensitized.replacingSecret("new_secret_key")
        assert(restored.secret == "new_secret_key", "Replacing secret restores credential properly")
        
        // Factory test
        let client = StorageClientFactory.createClient(configuration: configEnum)
        assert(client is Pan123StorageClient, "StorageClientFactory creates Pan123StorageClient")
    }
    
    // 3. Mock Network & Token Lifecycle
    do {
        print("  ▶ Verifying Pan123 API token acquisition & headers injection...")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        var tokenEndpointHit = false
        Mock123PanURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw Pan123TestFailure(description: "No URL") }
            
            if url.path.contains("api/v1/access_token") {
                tokenEndpointHit = true
                guard request.value(forHTTPHeaderField: "Platform") == "open_platform" else {
                    throw Pan123TestFailure(description: "Missing Platform header")
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {
                  "code": 0,
                  "message": "ok",
                  "data": {
                    "accessToken": "mocked_jwt_token_for_123pan",
                    "expiredAt": "2099-01-01T00:00:00Z"
                  }
                }
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            throw Pan123TestFailure(description: "Unhandled URL: \(url.absoluteString)")
        }
        
        let tempDBURL3 = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test3_\(UUID().uuidString).db")
        let dbStore3 = Pan123DatabaseStore(dbURL: tempDBURL3)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL3)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL3.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL3.path + "-shm"))
        }
        
        let panConfig = Pan123StorageConfig(clientID: "test_client_\(UUID().uuidString)", clientSecret: "test_secret")
        let apiClient = Pan123APIClient(config: panConfig, session: mockSession, databaseStore: dbStore3)
        
        let token = try await apiClient.getValidAccessToken()
        assert(token == "mocked_jwt_token_for_123pan", "Successfully acquired access token")
        assert(tokenEndpointHit, "Token endpoint correctly invoked with Platform header")
    }
    
    // 4. End-to-End Pan123StorageClient CRUD & Directory Traversal Mock
    do {
        print("  ▶ Verifying Pan123StorageClient full operations (list, mkdir, upload reuse, download, move, trash, copy)...")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        var remoteFiles: [Int64: (name: String, parentId: Int64, isDir: Bool, size: Int64, etag: String)] = [
            0: (name: "root", parentId: 0, isDir: true, size: 0, etag: "")
        ]
        var nextId: Int64 = 100
        
        Mock123PanURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw Pan123TestFailure(description: "No URL") }
            print("[Mock123Pan] Request: \(request.httpMethod ?? "") \(url.absoluteString)")
            
            // 1. Token acquisition
            if url.path.contains("api/v1/access_token") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {"code": 0, "message": "ok", "data": {"accessToken": "mock_valid_token", "expiredAt": "2099-12-31T23:59:59Z"}}
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            // 2. File list
            if url.path.contains("api/v2/file/list") {
                let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let parentIdStr = comp?.queryItems?.first(where: { $0.name == "parentFileId" })?.value ?? "0"
                let parentId = Int64(parentIdStr) ?? 0
                
                let children = remoteFiles.filter { $0.value.parentId == parentId && $0.key != parentId }
                let itemsJSON = children.map { (id, item) in
                    """
                    {
                      "fileId": \(id),
                      "filename": "\(item.name)",
                      "parentFileId": \(item.parentId),
                      "type": \(item.isDir ? 1 : 0),
                      "size": \(item.size),
                      "etag": "\(item.etag)",
                      "trashed": 0,
                      "createAt": "2026-10-01 10:00:00",
                      "updateAt": "2026-10-01 10:00:00"
                    }
                    """
                }.joined(separator: ",")
                
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {"code": 0, "message": "ok", "data": {"lastFileId": -1, "fileList": [\(itemsJSON)]}}
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            // 3. Mkdir
            if url.path.contains("upload/v1/file/mkdir") {
                let body = try JSONDecoder().decode(Pan123MkdirRequest.self, from: extractBodyData(from: request))
                nextId += 1
                let newDirId = nextId
                remoteFiles[newDirId] = (name: body.name, parentId: body.parentID, isDir: true, size: 0, etag: "")
                
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {"code": 0, "message": "ok", "data": {"dirID": \(newDirId)}}
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            // 4. Create File (Instant Upload Reuse test)
            if url.path.contains("upload/v2/file/create") {
                let body = try JSONDecoder().decode(Pan123CreateFileRequest.self, from: extractBodyData(from: request))
                nextId += 1
                let newFileId = nextId
                remoteFiles[newFileId] = (name: body.filename, parentId: body.parentFileID, isDir: false, size: body.size, etag: body.etag)
                
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {"code": 0, "message": "ok", "data": {"reuse": true, "fileID": \(newFileId)}}
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            // 5. Download Info
            if url.path.contains("api/v1/file/download_info") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {"code": 0, "message": "ok", "data": {"downloadUrl": "https://download.mock123.com/payload.bin"}}
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            // 6. Direct CDN download
            if url.host == "download.mock123.com" {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "12"])!
                let data = "HELLO_123PAN".data(using: .utf8)!
                return (resp, data)
            }
            
            // 7. Move
            if url.path.contains("api/v1/file/move") {
                let body = try JSONDecoder().decode(Pan123MoveRequest.self, from: extractBodyData(from: request))
                for fid in body.fileIDs {
                    if var item = remoteFiles[fid] {
                        item.parentId = body.toParentFileID
                        remoteFiles[fid] = item
                    }
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": null}".data(using: .utf8)!)
            }
            
            // 8. Rename
            if url.path.contains("api/v1/file/name") {
                let body = try JSONDecoder().decode(Pan123RenameRequest.self, from: extractBodyData(from: request))
                if var item = remoteFiles[body.fileId] {
                    item.name = body.fileName
                    remoteFiles[body.fileId] = item
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": null}".data(using: .utf8)!)
            }
            
            // 9. Trash (Delete)
            if url.path.contains("api/v1/file/trash") {
                let body = try JSONDecoder().decode(Pan123TrashRequest.self, from: extractBodyData(from: request))
                for fid in body.fileIDs {
                    remoteFiles.removeValue(forKey: fid)
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": null}".data(using: .utf8)!)
            }
            
            // 10. Copy
            if url.path.contains("api/v1/file/copy") {
                let body = try JSONDecoder().decode(Pan123CopyRequest.self, from: extractBodyData(from: request))
                guard let orig = remoteFiles[body.fileId] else {
                    throw Pan123TestFailure(description: "File not found for copy")
                }
                nextId += 1
                let targetId = nextId
                remoteFiles[targetId] = (name: orig.name, parentId: body.targetDirId, isDir: orig.isDir, size: orig.size, etag: orig.etag)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {"code": 0, "message": "ok", "data": {"sourceFileId": \(body.fileId), "targetFileId": \(targetId)}}
                """.data(using: .utf8)!
                return (resp, data)
            }
            
            throw Pan123TestFailure(description: "Unhandled request: \(url.absoluteString)")
        }
        
        let tempDBURL4 = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test4_\(UUID().uuidString).db")
        let dbStore4 = Pan123DatabaseStore(dbURL: tempDBURL4)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL4)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL4.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL4.path + "-shm"))
        }
        
        let panConfig = Pan123StorageConfig(clientID: "test_id_\(UUID().uuidString)", clientSecret: "test_secret", rootFolderID: 0)
        let client = Pan123StorageClient(config: panConfig, session: mockSession, databaseStore: dbStore4)
        
        // 4.1 Test connection
        let connected = try await client.testConnection()
        assert(connected, "testConnection succeeds on valid endpoint")
        
        // 4.2 Create directory
        try await client.createDirectory(path: "/Documents/Work")
        let docExists = try await client.exists(path: "/Documents")
        let workExists = try await client.exists(path: "/Documents/Work")
        assert(docExists && workExists, "createDirectory recursively creates parent and child folders")
        
        // 4.3 Upload file (Instant Reuse)
        let tempUploadURL = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_upload_\(UUID().uuidString).txt")
        try "HELLO_123PAN".data(using: .utf8)!.write(to: tempUploadURL)
        defer { try? FileManager.default.removeItem(at: tempUploadURL) }
        
        var reportedProgress = 0.0
        try await client.uploadFile(localURL: tempUploadURL, to: "/Documents/Work/notes.txt") { prog in
            reportedProgress = prog
        }
        assert(reportedProgress == 1.0, "Upload reaches 100% progress")
        
        let notesExist = try await client.exists(path: "/Documents/Work/notes.txt")
        assert(notesExist, "Uploaded file exists in remote storage")
        
        // 4.4 List Directory
        let items = try await client.listDirectory(path: "/Documents/Work")
        assert(items.count == 1 && items.first?.displayName == "notes.txt", "listDirectory retrieves uploaded notes.txt")
        assert(!items.first!.isDirectory, "notes.txt is marked as non-directory")
        
        // 4.5 Download File
        let tempDownloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_down_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempDownloadURL) }
        try await client.downloadFile(path: "/Documents/Work/notes.txt", to: tempDownloadURL) { _ in }
        let downloadedContent = try String(contentsOf: tempDownloadURL, encoding: .utf8)
        assert(downloadedContent == "HELLO_123PAN", "Downloaded file content matches uploaded bytes")
        
        // 4.6 Move / Rename
        try await client.move(from: "/Documents/Work/notes.txt", to: "/Documents/renamed_notes.txt")
        let oldExists = try await client.exists(path: "/Documents/Work/notes.txt")
        let newExists = try await client.exists(path: "/Documents/renamed_notes.txt")
        assert(!oldExists && newExists, "move successfully relocated and renamed file")
        
        // 4.7 Copy
        try await client.copy(from: "/Documents/renamed_notes.txt", to: "/Documents/Work/copied_notes.txt")
        let copiedExists = try await client.exists(path: "/Documents/Work/copied_notes.txt")
        assert(copiedExists, "copy successfully replicated file into target directory")
        
        // 4.8 Delete
        try await client.delete(path: "/Documents/Work/copied_notes.txt")
        let existsAfterTrash = try await client.exists(path: "/Documents/Work/copied_notes.txt")
        assert(!existsAfterTrash, "delete successfully removed file to trash")
        
        // 4.9 Precondition 412 collision guard on createIfAbsent
        var collisionBlocked = false
        do {
            try await client.uploadFile(localURL: tempUploadURL, to: "/Documents/renamed_notes.txt", mode: .createIfAbsent) { _ in }
        } catch let err as StorageError {
            if err.isPreconditionFailure {
                collisionBlocked = true
            }
        }
        assert(collisionBlocked, "uploadFile with .createIfAbsent throws 412 Precondition Failed when file already exists")
    }
    
    // 5. Filename & Character Restrictions Validation
    do {
        print("  ▶ Verifying 123pan filename constraints & character validation...")
        // 5.1 Valid filenames
        try Pan123StorageClient.validateFilename("valid_file-123.txt")
        try Pan123StorageClient.validateFilename("我的工作笔记.docx")
        assert(true, "Normal filenames pass validation")
        
        // 5.2 Illegal characters \\ / : * ? \" < > |
        let forbidden = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        for char in forbidden {
            var caught = false
            do {
                try Pan123StorageClient.validateFilename("bad\(char)name.txt")
            } catch {
                caught = true
            }
            assert(caught, "Filename with illegal character '\(char)' rejected")
        }
        
        // 5.3 Empty or whitespace names
        var emptyCaught = false
        do {
            try Pan123StorageClient.validateFilename("   ")
        } catch {
            emptyCaught = true
        }
        assert(emptyCaught, "Pure whitespace filename rejected")
        
        // 5.4 Leading / trailing whitespace
        var leadingSpaceCaught = false
        do {
            try Pan123StorageClient.validateFilename(" leading_space.txt")
        } catch {
            leadingSpaceCaught = true
        }
        assert(leadingSpaceCaught, "Leading space filename rejected")
        
        // 5.5 Max length >= 255 chars
        let longName = String(repeating: "a", count: 255)
        var longCaught = false
        do {
            try Pan123StorageClient.validateFilename(longName)
        } catch {
            longCaught = true
        }
        assert(longCaught, "Filename with >= 255 chars rejected")
    }

    // 6. Max File Size Limit (10GB) Check
    do {
        print("  ▶ Verifying 123pan 10GB single file upload limit...")
        assert(Pan123StorageClient.maxUploadFileSize == 10 * 1024 * 1024 * 1024, "maxUploadFileSize is 10GB")
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let client = Pan123StorageClient(config: Pan123StorageConfig(clientID: "id", clientSecret: "sec"), session: mockSession)
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_oversize_test.bin")
        let fileHandle = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        if fileHandle {
            let handle = try FileHandle(forWritingTo: tempURL)
            // Seek to 11GB to make a sparse file without consuming actual disk blocks
            try handle.seek(toOffset: 11 * 1024 * 1024 * 1024)
            try handle.write(contentsOf: Data([0x01]))
            try handle.close()
            
            var oversizeCaught = false
            do {
                try await client.uploadFile(localURL: tempURL, to: "/test_oversize.bin") { _ in }
            } catch let err as StorageError {
                if case .notSupported(let msg) = err, msg.contains("10GB") {
                    oversizeCaught = true
                }
            }
            try? FileManager.default.removeItem(at: tempURL)
            assert(oversizeCaught, "uploadFile intercepts >10GB file before network transmission")
        }
    }

    // 7. QPS 429 Rate Limiting with Exponential Backoff & Retry
    do {
        print("  ▶ Verifying 123pan 429 rate limit backoff & retry...")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        var requestCount = 0
        Mock123PanURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw Pan123TestFailure(description: "No URL") }
            if url.path.contains("api/v1/access_token") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": {\"accessToken\": \"retry_token\", \"expiredAt\": \"2099-01-01T00:00:00Z\"}}".data(using: .utf8)!)
            }
            
            if url.path.contains("api/v2/file/list") {
                requestCount += 1
                if requestCount <= 2 {
                    // First 2 requests return 429
                    let resp = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (resp, "{\"code\": 429, \"message\": \"请求太频繁\"}".data(using: .utf8)!)
                } else {
                    // 3rd request succeeds
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": {\"lastFileId\": -1, \"fileList\": []}}".data(using: .utf8)!)
                }
            }
            throw Pan123TestFailure(description: "Unhandled URL: \(url.absoluteString)")
        }
        
        let tempDBURL7 = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test7_\(UUID().uuidString).db")
        let dbStore7 = Pan123DatabaseStore(dbURL: tempDBURL7)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL7)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL7.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL7.path + "-shm"))
        }
        
        let panConfig = Pan123StorageConfig(clientID: "test_qps_\(UUID().uuidString)", clientSecret: "test_sec")
        let client = Pan123StorageClient(config: panConfig, session: mockSession, databaseStore: dbStore7, baseRetryDelay: 0.01, maxRateLimitRetries: 3)
        
        let items = try await client.listDirectory(path: "/")
        assert(requestCount == 3, "API client retried after 429 responses exactly 2 times and succeeded on 3rd attempt")
        assert(items.isEmpty, "listDirectory returned empty list after retry success")
    }

    // 8. Token Concurrency Deduplication (In-flight Task Sharing)
    do {
        print("  ▶ Verifying 123pan token concurrency deduplication (prevents 3 token limit churn)...")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        var tokenCalls = 0
        Mock123PanURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw Pan123TestFailure(description: "No URL") }
            if url.path.contains("api/v1/access_token") {
                tokenCalls += 1
                // Micro sleep to ensure concurrent tasks queue up
                Thread.sleep(forTimeInterval: 0.05)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": {\"accessToken\": \"concurrent_token\", \"expiredAt\": \"2099-01-01T00:00:00Z\"}}".data(using: .utf8)!)
            }
            throw Pan123TestFailure(description: "Unhandled URL: \(url.absoluteString)")
        }
        
        let tempDBURL8 = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test8_\(UUID().uuidString).db")
        let dbStore8 = Pan123DatabaseStore(dbURL: tempDBURL8)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL8)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL8.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL8.path + "-shm"))
        }
        
        let panConfig = Pan123StorageConfig(clientID: "concurrent_client_\(UUID().uuidString)", clientSecret: "sec")
        let apiClient = Pan123APIClient(config: panConfig, session: mockSession, databaseStore: dbStore8)
        
        // Concurrently invoke getValidAccessToken 5 times
        async let t1 = apiClient.getValidAccessToken()
        async let t2 = apiClient.getValidAccessToken()
        async let t3 = apiClient.getValidAccessToken()
        async let t4 = apiClient.getValidAccessToken()
        async let t5 = apiClient.getValidAccessToken()
        
        let results = try await [t1, t2, t3, t4, t5]
        assert(results.allSatisfy { $0 == "concurrent_token" }, "All concurrent tasks received the valid token")
        assert(tokenCalls == 1, "Only 1 network request was made across 5 concurrent token requests")
    }

    // 9. Batch Chunking (100 items per request)
    do {
        print("  ▶ Verifying 123pan 100-item batch chunking for move & trash...")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        var trashChunks: [Int] = []
        var moveChunks: [Int] = []
        
        Mock123PanURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw Pan123TestFailure(description: "No URL") }
            if url.path.contains("api/v1/access_token") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": {\"accessToken\": \"batch_token\", \"expiredAt\": \"2099-01-01T00:00:00Z\"}}".data(using: .utf8)!)
            }
            if url.path.contains("api/v1/file/trash") {
                let body = try JSONDecoder().decode(Pan123TrashRequest.self, from: extractBodyData(from: request))
                trashChunks.append(body.fileIDs.count)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": null}".data(using: .utf8)!)
            }
            if url.path.contains("api/v1/file/move") {
                let body = try JSONDecoder().decode(Pan123MoveRequest.self, from: extractBodyData(from: request))
                moveChunks.append(body.fileIDs.count)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, "{\"code\": 0, \"message\": \"ok\", \"data\": null}".data(using: .utf8)!)
            }
            throw Pan123TestFailure(description: "Unhandled URL: \(url.absoluteString)")
        }
        
        let tempDBURL9 = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test9_\(UUID().uuidString).db")
        let dbStore9 = Pan123DatabaseStore(dbURL: tempDBURL9)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL9)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL9.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL9.path + "-shm"))
        }
        
        let panConfig = Pan123StorageConfig(clientID: "batch_id_\(UUID().uuidString)", clientSecret: "batch_sec")
        let apiClient = Pan123APIClient(config: panConfig, session: mockSession, databaseStore: dbStore9)
        
        // Batch trash 250 items
        let testIDs = (Int64(1)...Int64(250)).map { $0 }
        try await apiClient.batchTrash(fileIDs: testIDs)
        assert(trashChunks == [100, 100, 50], "250 trash items chunked into [100, 100, 50]")
        
        // Batch move 150 items
        let moveIDs = (Int64(1)...Int64(150)).map { $0 }
        try await apiClient.batchMove(fileIDs: moveIDs, toParentFileID: 999)
        assert(moveChunks == [100, 50], "150 move items chunked into [100, 50]")
    }

    // 10. Specific Error Codes Mapping
    do {
        print("  ▶ Verifying 123pan specific error code mappings (200020, 5113, 5066, 5067, 5068, 5070, 5075)...")
        let tempDBURL10 = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test10_\(UUID().uuidString).db")
        let dbStore10 = Pan123DatabaseStore(dbURL: tempDBURL10)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL10)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL10.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL10.path + "-shm"))
        }
        let apiClient = Pan123APIClient(config: Pan123StorageConfig(clientID: "err", clientSecret: "sec"), databaseStore: dbStore10)
        
        let err200020 = await apiClient.mapPan123Error(code: 200020, message: "仅限开发者权益包")
        assert(err200020.localizedDescription.contains("开发者权益包"), "200020 mapped with developer rights package explanation")
        
        let err5113 = await apiClient.mapPan123Error(code: 5113, message: "流量超出")
        assert(err5113.localizedDescription.contains("1GB"), "5113 mapped with 1GB daily traffic limit explanation")
        
        let err5066 = await apiClient.mapPan123Error(code: 5066, message: "文件不存在")
        if case .notFound = err5066 {
            assert(true, "5066 mapped to .notFound")
        } else {
            assert(false, "5066 mapped to .notFound")
        }
        
        let err5067 = await apiClient.mapPan123Error(code: 5067, message: "已存在")
        if case .serverError(let code, _) = err5067 {
            assert(code == 412, "5067 mapped to 412 Precondition Failed")
        }
        
        let err5068 = await apiClient.mapPan123Error(code: 5068, message: "配额不足")
        if case .serverError(let code, _) = err5068 {
            assert(code == 507, "5068 mapped to 507 Insufficient Storage")
        }
        
        let err5070 = await apiClient.mapPan123Error(code: 5070, message: "已清理")
        if case .serverError(let code, _) = err5070 {
            assert(code == 410, "5070 mapped to 410 Gone")
        }
        
        let err5075 = await apiClient.mapPan123Error(code: 5075, message: "非法文件名")
        if case .notSupported = err5075 {
            assert(true, "5075 mapped to .notSupported")
        }
    }
    
    // 11. SQLite Token Persistence (Cross-Restart Reuse)
    do {
        print("  ▶ Verifying 123pan SQLite token persistence & cross-restart reuse...")
        let tempDBURL = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_test_\(UUID().uuidString).db")
        let dbStore = Pan123DatabaseStore(dbURL: tempDBURL)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL.path + "-shm"))
        }
        
        let clientID = "persisted_client_001"
        let token = "jwt_token_persisted_in_sqlite"
        let expiresAt = Date().addingTimeInterval(30 * 86400) // 30 days
        
        // Save to DB
        try dbStore.saveToken(clientID: clientID, token: token, expiredAt: expiresAt)
        
        // Read back
        let loaded = try dbStore.loadToken(clientID: clientID)
        assert(loaded?.token == token, "Token correctly retrieved from SQLite")
        assert(loaded?.expiredAt != nil, "Token expiration correctly retrieved from SQLite")
        
        // Now create Pan123APIClient with this dbStore and NO network access allowed
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock123PanURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        Mock123PanURLProtocol.requestHandler = { _ in
            throw Pan123TestFailure(description: "Network MUST NOT be called when valid token exists in SQLite!")
        }
        
        let panConfig = Pan123StorageConfig(clientID: clientID, clientSecret: "secret_xyz")
        let apiClient = Pan123APIClient(config: panConfig, session: mockSession, databaseStore: dbStore)
        
        // getValidAccessToken should load directly from SQLite without network call!
        let tokenFromClient = try await apiClient.getValidAccessToken()
        assert(tokenFromClient == token, "getValidAccessToken successfully reused persisted token from SQLite without hitting network")
        
        // Delete token
        try dbStore.deleteToken(clientID: clientID)
        let loadedAfterDel = try dbStore.loadToken(clientID: clientID)
        assert(loadedAfterDel == nil, "Token successfully deleted from SQLite")
    }

    // 12. SQLite Rate Limiting (Per-Minute, Per-Day, and Daily Bandwidth)
    do {
        print("  ▶ Verifying 123pan per-minute & daily rate limits and bandwidth tracking...")
        let tempDBURL = FileManager.default.temporaryDirectory.appendingPathComponent("pan123_ratelimit_\(UUID().uuidString).db")
        let dbStore = Pan123DatabaseStore(dbURL: tempDBURL)
        defer {
            try? FileManager.default.removeItem(at: tempDBURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempDBURL.path + "-shm"))
        }
        
        let clientID = "quota_client_999"
        
        // Test acquire slot with max 3 per minute
        try await dbStore.acquireRequestSlot(clientID: clientID, maxPerMinute: 3, maxPerDay: 100)
        try await dbStore.acquireRequestSlot(clientID: clientID, maxPerMinute: 3, maxPerDay: 100)
        try await dbStore.acquireRequestSlot(clientID: clientID, maxPerMinute: 3, maxPerDay: 100)
        
        let statsAfter3 = try dbStore.getUsageStats(clientID: clientID)
        assert(statsAfter3.currentMinuteRequestCount == 3, "Minute request count tracked accurately (3)")
        assert(statsAfter3.todayRequestCount == 3, "Day request count tracked accurately (3)")
        
        // Test daily limit exhaustion
        var dailyLimitBlocked = false
        do {
            try await dbStore.acquireRequestSlot(clientID: clientID, maxPerMinute: 100, maxPerDay: 3)
        } catch let err as StorageError {
            if err.localizedDescription.contains("今日请求次数上限") {
                dailyLimitBlocked = true
            }
        }
        assert(dailyLimitBlocked, "Request correctly blocked when maxPerDay limit is reached")
        
        // Test download bytes tracking
        try dbStore.recordDownloadBytes(clientID: clientID, bytes: 50 * 1024 * 1024) // 50MB
        try dbStore.recordDownloadBytes(clientID: clientID, bytes: 100 * 1024 * 1024) // 100MB
        
        let statsWithBandwidth = try dbStore.getUsageStats(clientID: clientID, maxDailyDownloadBytes: 1024 * 1024 * 1024)
        assert(statsWithBandwidth.todayDownloadBytes == 150 * 1024 * 1024, "Total daily download bytes tracked accurately (150MB)")
        assert(statsWithBandwidth.remainingDailyDownloadBytes == (1024 - 150) * 1024 * 1024, "Remaining daily download bytes computed accurately")
    }
    
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎉 All 123 Cloud Drive Storage Regressions Successfully Verified!")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
