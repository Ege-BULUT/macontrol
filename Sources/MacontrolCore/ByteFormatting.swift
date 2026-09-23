import Foundation

extension UInt64 {
    /// Decimal units, as Finder and Storage settings show them ("1.2 GB").
    public var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .file)
    }
}
