//
//  SyncService.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  同步子系统统一门面服务
//

import Foundation
import CloudDriveContracts

extension SyncService {
    // MARK: - 队列消费执行
    
    public func processSyncQueue() {
        guard automaticallyProcessesQueue else { return }
        guard getStorageClient() != nil else { return }
        processingLock.lock()
        guard !isProcessingQueue else {
            hasPendingQueueCheck = true
            processingLock.unlock()
            return
        }
        isProcessingQueue = true
        hasPendingQueueCheck = false
        scheduledRetry?.cancel()
        scheduledRetry = nil
        processingLock.unlock()
        Task { [weak self] in
            guard let self else { return }
            var retryAt = await self.processQueueAsync()
            
            while true {
                let rerun = self.processingLock.withLock { () -> Bool in
                    if self.hasPendingQueueCheck {
                        self.hasPendingQueueCheck = false
                        return true
                    }
                    self.isProcessingQueue = false
                    return false
                }
                guard rerun else { break }
                retryAt = await self.processQueueAsync()
            }
            
            if let retryAt {
                self.scheduleRetry(at: retryAt)
            } else if let queued = try? self.queue.allItemsPersistent(),
                      let next = queued.compactMap({ $0.nextAttemptAt }).filter({ $0 > Date() }).min() {
                self.scheduleRetry(at: next)
            }
        }
    }

    /// Await one drain for explicit synchronization and deterministic callers.
    public func processPendingOperations() async {
        guard getStorageClient() != nil else { return }
        let acquired = processingLock.withLock { () -> Bool in
            guard !isProcessingQueue else { return false }
            isProcessingQueue = true
            return true
        }
        guard acquired else { return }
        let retryAt = await processQueueAsync()
        processingLock.withLock { isProcessingQueue = false }
        if automaticallyProcessesQueue, let retryAt { scheduleRetry(at: retryAt) }
    }

    func scheduleRetry(at date: Date) {
        let delay = max(0.05, date.timeIntervalSinceNow)
        processingLock.withLock {
            scheduledRetry?.cancel()
            scheduledRetry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(delay, 300) * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.processSyncQueue()
            }
        }
    }

    /// An exclusive OS lease elects one consumer for this vault. Work is read
    /// afresh after every completion, so operations added during an upload drain.

}
