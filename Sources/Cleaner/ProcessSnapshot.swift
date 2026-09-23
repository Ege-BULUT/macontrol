import Darwin
import Foundation

/// A process running for this user, named the ways a cache folder might be named after it.
public struct RunningApp: Sendable, Hashable {
    public var bundleIdentifier: String?
    public var bundleName: String?
    public var executableName: String

    public init(bundleIdentifier: String?, bundleName: String?, executableName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.executableName = executableName
    }

    var displayName: String { bundleName ?? executableName }
}

/// A file some running process holds open.
public struct OpenFile: Sendable, Hashable {
    public var path: String
    public var processName: String

    public init(path: String, processName: String) {
        self.path = path
        self.processName = processName
    }
}

/// What runs right now, taken at scan time and again right before the trash (F-0015).
public struct ProcessSnapshot: Sendable {
    public var apps: [RunningApp]
    public var openFiles: [OpenFile]
    /// Processes whose open files could not be listed. The guard then fails closed: it cannot rule out that they use an item.
    public var uninspected: [String]

    public init(apps: [RunningApp], openFiles: [OpenFile], uninspected: [String] = []) {
        self.apps = apps
        self.openFiles = openFiles
        self.uninspected = uninspected
    }

    /// This user's processes via libproc, and the files they hold open under `root`.
    /// Blocking: call it off the cooperative pool.
    public static func current(under root: URL) -> ProcessSnapshot {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var snapshot = ProcessSnapshot(apps: [], openFiles: [])
        for pid in userProcessIDs() {
            guard let executable = executablePath(of: pid) else { continue }
            let app = runningApp(executable: executable)
            snapshot.apps.append(app)
            guard let paths = openPaths(of: pid) else {
                snapshot.uninspected.append(app.displayName)
                continue
            }
            snapshot.openFiles += paths.filter { $0.hasPrefix(prefix) }.map { OpenFile(path: $0, processName: app.displayName) }
        }
        return snapshot
    }

    /// A process carries its bundle's id and name only when it is that bundle's main executable
    /// (`X.app/Contents/MacOS/X`). Tools that merely live inside a bundle, like swift and xcodebuild
    /// in Xcode.app, keep their own names: read as "Xcode", they blocked every DerivedData folder.
    static func runningApp(executable: String) -> RunningApp {
        let url = URL(fileURLWithPath: executable)
        let macOS = url.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let isMain = macOS.lastPathComponent == "MacOS" && contents.lastPathComponent == "Contents"
        let bundle = isMain ? Bundle(url: contents.deletingLastPathComponent()) : nil
        return RunningApp(
            bundleIdentifier: bundle?.bundleIdentifier,
            bundleName: bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            executableName: url.lastPathComponent
        )
    }

    private static func userProcessIDs() -> [pid_t] {
        let type = UInt32(PROC_UID_ONLY), uid = UInt32(getuid())
        let needed = proc_listpids(type, uid, nil, 0)
        guard needed > 0 else { return [] }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = proc_listpids(type, uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.prefix(max(0, Int(filled)) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// `nil` when the process exists but its descriptors cannot be read; a process that exited holds nothing.
    private static func openPaths(of pid: pid_t) -> [String]? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return errno == ESRCH ? [] : nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return errno == ESRCH ? [] : nil }
        return descriptors.prefix(Int(filled) / stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            // A descriptor closed since the listing no longer holds anything.
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
    }
}
