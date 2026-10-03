//
//  ProgressDelegates.swift
//  CloudDriveSupport
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  异步下载/上传进度回调代理
//

import Foundation

public final class AsyncDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    
    public init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress(min(max(pct, 0.0), 1.0))
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public final class AsyncUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    
    public init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            let pct = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            onProgress(min(max(pct, 0.0), 1.0))
        }
    }
}
