import Foundation

/// Validates caller-supplied ranges before arithmetic or sparse-file allocation.
public struct AlignedReadRange: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public var length: Int { end - start }

    public static func calculate(location: Int, length: Int, alignment: Int, fileSize: Int64) throws -> AlignedReadRange {
        guard location >= 0, length >= 0, fileSize >= 0, fileSize <= Int64(Int.max) else { throw StorageError.invalidOperation }
        let (rawEnd, overflow) = location.addingReportingOverflow(length)
        guard !overflow else { throw StorageError.invalidOperation }
        let size = Int(fileSize)
        let align = max(1, alignment)
        let start = min((location / align) * align, size)
        guard length > 0 else { return AlignedReadRange(start: start, end: start) }
        let boundedEnd = min(rawEnd, size)
        let remainder = boundedEnd % align
        let addition = remainder == 0 ? 0 : align - remainder
        let (rounded, roundedOverflow) = boundedEnd.addingReportingOverflow(addition)
        let end = roundedOverflow ? size : min(rounded, size)
        return AlignedReadRange(start: start, end: max(start, end))
    }
}
