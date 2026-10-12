import Foundation
import FileProvider
import CloudDriveCore
import Darwin

/// Persisted enumeration history is independent of the VFS database's latest snapshot.
/// A background refresh can therefore remove a DB row without losing Finder's deletion.
final class FileProviderStateStore {
    struct Snapshot: Codable { var sequence: UInt64; var versions: [String: Data] }
    struct Container: Codable { var current = Snapshot(sequence: 0, versions: [:]); var history: [Snapshot] = [] }
    struct State: Codable { var containers: [String: Container] = [:]; var materialized: Set<String> = [] }
    private let url: URL
    init(vaultId: String) { url = CloudDrivePaths.vaultDirectory(for: vaultId).appendingPathComponent("FileProvider/state.json") }

    private func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var state = State()
        if FileManager.default.fileExists(atPath: url.path) { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) }
        let result = try body(&state)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        return result
    }
    func currentAnchor(container: String) -> NSFileProviderSyncAnchor? {
        try? transaction { anchor($0.containers[container]?.current.sequence ?? 0) }
    }
    func record(container: String, items: [FileProviderItem]) throws {
        _ = try changes(container: container, from: nil, items: items)
    }
    func changes(container: String, from: NSFileProviderSyncAnchor?, items: [FileProviderItem]) throws -> (updated: [FileProviderItem], deleted: [NSFileProviderItemIdentifier], anchor: NSFileProviderSyncAnchor) {
        try transaction { state in
            var record = state.containers[container] ?? Container()
            let sequence: UInt64
            if let from {
                guard let string = String(data: from.rawValue, encoding: .utf8), string.hasPrefix("v1:"), let parsed = UInt64(string.dropFirst(3)) else { throw NSFileProviderError(.syncAnchorExpired) }
                sequence = parsed
            } else { sequence = record.current.sequence }
            let baseline: Snapshot
            if sequence == record.current.sequence { baseline = record.current }
            else if let old = record.history.first(where: { $0.sequence == sequence }) { baseline = old }
            else if sequence == 0 && record.history.count < 64 { baseline = Snapshot(sequence: 0, versions: [:]) }
            else { throw NSFileProviderError(.syncAnchorExpired) }
            let versions = Dictionary(items.map { ($0.itemIdentifier.rawValue, fingerprint($0)) }, uniquingKeysWith: { _, value in value })
            if versions != record.current.versions {
                record.history.append(record.current)
                record.history = Array(record.history.suffix(64))
                record.current = Snapshot(sequence: record.current.sequence + 1, versions: versions)
                state.containers[container] = record
            }
            let updates = items.filter { baseline.versions[$0.itemIdentifier.rawValue] != versions[$0.itemIdentifier.rawValue] }
            let deleted = baseline.versions.keys.filter { versions[$0] == nil }.map { NSFileProviderItemIdentifier($0) }
            return (updates, deleted, anchor(record.current.sequence))
        }
    }
    private func fingerprint(_ item: FileProviderItem) -> Data {
        var data = item.itemVersion.contentVersion
        data.append(item.itemVersion.metadataVersion)
        data.append(Data("|\(item.filename)|\(item.parentItemIdentifier.rawValue)|\(item.isUploaded)|\(item.isDownloaded)|\(item.isUploading)|\(item.isDownloading)|\(item.downloadProgress)|\(String(describing: item.contentPolicy))|\(item.capabilities.rawValue)|\(item.parentItemIdentifier == .trashContainer)".utf8))
        return data
    }
    private func anchor(_ sequence: UInt64) -> NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(Data("v1:\(sequence)".utf8)) }
    func materializedIds() -> Set<String> { (try? transaction { $0.materialized }) ?? [] }
    func setMaterializedIds(_ ids: Set<String>) throws { try transaction { $0.materialized = ids } }
}

final class MaterializedSetObserver: NSObject, NSFileProviderEnumerationObserver {
    private let enumerator: NSFileProviderEnumerator
    private let completion: (Set<String>?) -> Void
    private var ids = Set<String>()
    private var keepAlive: MaterializedSetObserver?
    init(enumerator: NSFileProviderEnumerator, completion: @escaping (Set<String>?) -> Void) { self.enumerator = enumerator; self.completion = completion }
    func start() { keepAlive = self; enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)) }
    func didEnumerate(_ updatedItems: [NSFileProviderItem]) { for item in updatedItems { ids.insert(item.itemIdentifier.rawValue) } }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage { enumerator.enumerateItems(for: self, startingAt: nextPage) }
        else { completion(ids); enumerator.invalidate(); keepAlive = nil }
    }
    func finishEnumeratingWithError(_ error: Error) { completion(nil); enumerator.invalidate(); keepAlive = nil }
}
