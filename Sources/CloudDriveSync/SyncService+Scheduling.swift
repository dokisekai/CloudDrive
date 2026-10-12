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
import CloudDriveSupport

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
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingOperations()
        }
        activeDrainTask = task
        processingLock.unlock()
    }

    /// 暂停同步队列消费（例如保险库被锁定或卸载时，优雅中断执行中的上传并防死循环）
    public func pauseSyncQueue() {
        processingLock.withLock {
            hasPendingQueueCheck = false
            scheduledRetry?.cancel()
            scheduledRetry = nil
            activeDrainTask?.cancel()
            activeDrainTask = nil
            isProcessingQueue = false
        }
    }

    /// 保险库解锁/重新挂载时调用：重置残留的在途租约、鉴权失败状态，并将元数据恢复为可上传状态后立即执行队列
    public func recoverQueueOnUnlock() {
        queue.recoverFailedAndAbandonedOperations()
        let queuedItems = queue.getAllItems()
        for item in queuedItems {
            if let meta = try? metadataStore.getMetadataPersistent(fileId: item.operation.fileId) {
                if meta.syncStatus == .error || meta.syncStatus == .uploading {
                    try? metadataStore.mutateMetadata(fileId: item.operation.fileId) { m in
                        m.syncStatus = Self.pendingStatus(for: item.operation)
                    }
                }
            }
        }
        processSyncQueue()
    }

    /// Await one drain for explicit synchronization and deterministic callers.
    public func processPendingOperations() async {
        guard getStorageClient() != nil else { return }
        let acquired = processingLock.withLock { () -> Bool in
            guard !isProcessingQueue else {
                hasPendingQueueCheck = true
                return false
            }
            isProcessingQueue = true
            hasPendingQueueCheck = false
            scheduledRetry?.cancel()
            scheduledRetry = nil
            return true
        }
        guard acquired else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingOperations()
        }
        processingLock.withLock { activeDrainTask = task }
        await task.value
    }

    private func drainPendingOperations() async {
        while !Task.isCancelled {
            let retryAt = await processQueueAsync()
            let rerun = processingLock.withLock { () -> Bool in
                if Task.isCancelled {
                    isProcessingQueue = false
                    activeDrainTask = nil
                    return false
                }
                if hasPendingQueueCheck {
                    hasPendingQueueCheck = false
                    return true
                }
                // Install the retry and release ownership atomically. A newer
                // drain cannot cancel this timer before we have installed it.
                if automaticallyProcessesQueue, let retryAt { scheduleRetryLocked(at: retryAt) }
                isProcessingQueue = false
                activeDrainTask = nil
                return false
            }
            if !rerun { return }
        }
        processingLock.withLock {
            isProcessingQueue = false
            activeDrainTask = nil
        }
    }

    /// Called only while holding processingLock.
    private func scheduleRetryLocked(at date: Date) {
        let delay = max(0.05, date.timeIntervalSinceNow)
        scheduledRetry?.cancel()
        scheduledRetry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, 300) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.processSyncQueue()
        }
    }

    /// An exclusive OS lease elects one consumer for this vault. Work is read
    /// afresh after every completion, so operations added during an upload drain.

}
