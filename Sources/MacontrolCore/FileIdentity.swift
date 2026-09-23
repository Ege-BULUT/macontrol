import Darwin
import Foundation

/// The (device, inode) pair that names one file system object.
///
/// Paths are not identities: the same folder is reachable as `/Users/me` and as
/// `/System/Volumes/Data/Users/me` (F-0039), and a path can be swapped for another object
/// between scan and delete. Every destructive action re-checks this pair first.
public struct FileIdentity: Hashable, Sendable, Codable {
    public var device: Int32
    public var inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// Identity of the object at `url` itself; a symlink is not followed.
    public init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        self.init(device: info.st_dev, inode: info.st_ino)
    }
}
