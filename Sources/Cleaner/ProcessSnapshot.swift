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

/// What runs right now, taken once per cleanup scan for the in-use guard (F-0015).
public struct ProcessSnapshot: Sendable {
    public var apps: [RunningApp]
    public var openFiles: [OpenFile]

    public init(apps: [RunningApp], openFiles: [OpenFile]) {
        self.apps = apps
        self.openFiles = openFiles
    }

    /// This user's processes via libproc, and the files they hold open under `root`.
    /// Processes that refuse inspection are left out, which only weakens the guard to the name and age checks.
    public static func current(under root: URL) -> ProcessSnapshot {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var apps: [RunningApp] = []
        var openFiles: [OpenFile] = []
        for pid in userProcessIDs() {
            guard let executable = executablePath(of: pid) else { continue }
            // The outermost .app is the one the user knows: Chrome, not "Google Chrome Helper (GPU)".
            let bundlePath = executable.range(of: ".app/").map { String(executable[..<$0.lowerBound]) + ".app" }
            let bundle = bundlePath.flatMap(Bundle.init(path:))
            let app = RunningApp(
                bundleIdentifier: bundle?.bundleIdentifier,
                bundleName: bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                executableName: (executable as NSString).lastPathComponent
            )
            apps.append(app)
            openFiles += openPaths(of: pid).filter { $0.hasPrefix(prefix) }.map { OpenFile(path: $0, processName: app.displayName) }
        }
        return ProcessSnapshot(apps: apps, openFiles: openFiles)
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

    private static func openPaths(of pid: pid_t) -> [String] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return [] }
        return descriptors.prefix(Int(filled) / stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
    }
}
