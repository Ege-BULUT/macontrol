import Darwin
import Foundation

/// A scratch folder for one test. Tests create, change and delete files only in here,
/// and the folder removes itself (and only itself) when released.
public final class TemporaryDirectory {
    public let url: URL

    public init() throws {
        // realpath: /var is a symlink to /private/var, and fd-relative code must see the real path.
        guard let base = realpath(NSTemporaryDirectory(), nil) else { throw POSIXError(.ENOENT) }
        defer { free(base) }
        url = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("macontrol-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        precondition(url.lastPathComponent.hasPrefix("macontrol-tests-"), "refusing to remove \(url.path)")
        makeWritable(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// A file of `size` zero bytes, written for real (not sparse). Parent folders are created.
    @discardableResult
    public func file(_ path: String, size: Int = 0) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: target)
        return target
    }

    @discardableResult
    public func directory(_ path: String) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    public func hardLink(_ path: String, to existing: String) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: url.appendingPathComponent(existing), to: target)
        return target
    }

    /// An APFS clone: shares every block with `existing` until one of them is written.
    @discardableResult
    public func clone(_ path: String, of existing: String) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard clonefile(url.appendingPathComponent(existing).path, target.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return target
    }

    @discardableResult
    public func symlink(_ path: String, to destination: String) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
        return target
    }

    /// Undo chmod-000 fixtures so cleanup can descend.
    private func makeWritable(_ folder: URL) {
        chmod(folder.path, 0o755)
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true { makeWritable(child) }
        }
    }
}
