import Foundation
import MacontrolCore
import Safety
import TestSupport
import Uninstaller

/// A temporary home and system root for one test, with a recorder standing in for quit, launchd and the Trash.
/// Nothing here touches a real app, launchd job or file outside the temporary folder.
final class Fixture {
    let tmp: TemporaryDirectory
    let recorder: Recorder
    var home: URL { tmp.url.appendingPathComponent("home") }
    /// Stands in for `/`: `root/Applications`, `root/System/Applications`, `root/Library`.
    var root: URL { tmp.url.appendingPathComponent("root") }

    init() throws {
        tmp = try TemporaryDirectory()
        try tmp.directory("home/Library")
        try tmp.directory("root/Applications")
        recorder = Recorder(fixture: tmp.url, trash: try tmp.directory("Trash"))
    }

    /// An app bundle with an Info.plist; `folder` is relative to the fixture (default `root/Applications`).
    @discardableResult
    func app(_ name: String, id: String?, in folder: String = "root/Applications", info: [String: Any] = [:]) throws -> URL {
        var plist: [String: Any] = ["CFBundleName": name, "CFBundleExecutable": name]
        plist["CFBundleIdentifier"] = id
        plist.merge(info) { $1 }
        try write(plist, to: "\(folder)/\(name).app/Contents/Info.plist")
        return tmp.url.appendingPathComponent("\(folder)/\(name).app")
    }

    /// A file with some bytes, relative to the fixture.
    @discardableResult
    func file(_ path: String) throws -> URL {
        try tmp.file(path, size: 4096)
    }

    @discardableResult
    func write(_ plist: [String: Any], to path: String) throws -> URL {
        let url = try tmp.file(path)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    /// A launchd plist, relative to the fixture.
    @discardableResult
    func launchdJob(_ path: String, label: String, program: String) throws -> URL {
        try write(["Label": label, "ProgramArguments": [program, "--background"]], to: path)
    }

    func uninstaller() -> Uninstaller {
        Uninstaller(
            home: home,
            systemRoot: root,
            trash: TrashService(journalURL: tmp.url.appendingPathComponent("journal.jsonl")),
            actions: recorder.actions
        )
    }

    func app(named name: String) async throws -> InstalledApp {
        let apps = try await uninstaller().installedApps()
        guard let app = apps.first(where: { $0.name == name }) else { throw FixtureError.noApp(name, apps.map(\.name)) }
        return app
    }

    func plan(_ name: String) async throws -> UninstallPlan {
        try await uninstaller().plan(for: app(named: name))
    }

    enum FixtureError: Error {
        case noApp(String, [String])
    }
}

extension UninstallPlan {
    /// Leftover paths relative to `base`, for readable expectations.
    func paths(relativeTo base: URL, where include: (Leftover) -> Bool = { _ in true }) -> [String] {
        leftovers.filter(include).map { String($0.url.path.dropFirst(base.path.count + 1)) }
    }

    func leftover(_ path: String, in base: URL) -> Leftover? {
        leftovers.first { $0.url.path == base.appendingPathComponent(path).path }
    }
}

/// Records what an uninstall asked for, in order, and answers as configured. Its Trash is a folder in the fixture,
/// and it moves nothing from outside the fixture.
final class Recorder: @unchecked Sendable {
    enum Event: Hashable {
        case quit(String)
        case bootout(String)
        case trash([TrashItem])
    }

    private let fixture: URL
    private let trash: URL
    // Written only from the actions below, which the uninstaller calls one at a time.
    private let lock = NSLock()
    private var recorded: [Event] = []
    /// Answers to the quit calls, in order; every call after these succeeds.
    var quitResults: [Bool] = []
    var failingLabel: String?
    /// Runs inside every quit, as an app saving its settings or an updater swapping the bundle would.
    var whileQuitting: (@Sendable () -> Void)?
    /// A path the Trash refuses, as Safety does when the object at it changed.
    var refusedPath: String?
    /// Runs after each Trash batch, as an updater that finishes late would.
    var afterTrashing: (@Sendable () -> Void)?

    init(fixture: URL, trash: URL) {
        self.fixture = fixture
        self.trash = trash
    }

    var events: [Event] { lock.withLock { recorded } }
    /// The mode of each Trash batch, in order.
    var modes: [DeletionMode] { lock.withLock { recordedModes } }
    private var recordedModes: [DeletionMode] = []

    private func record(_ event: Event) {
        lock.withLock { recorded.append(event) }
    }

    var actions: UninstallActions {
        UninstallActions(
            quit: { app in
                self.record(.quit(app.name))
                self.lock.withLock { self.whileQuitting }?()
                return self.lock.withLock { self.quitResults.isEmpty ? true : self.quitResults.removeFirst() }
            },
            bootout: { label in
                self.record(.bootout(label))
                if self.lock.withLock({ self.failingLabel }) == label {
                    throw UninstallError.bootoutFailed(label: label, status: 5)
                }
            },
            remove: { items, mode in
                self.record(.trash(items))
                self.lock.withLock { self.recordedModes.append(mode) }
                let refused = self.lock.withLock { self.refusedPath }
                let outcomes = items.map { $0.url.path == refused ? .refused($0.url, .identityChanged) : self.moveIntoTrash($0.url, mode) }
                self.lock.withLock { self.afterTrashing }?()
                return TrashReport(batch: UUID(), outcomes: outcomes)
            }
        )
    }

    /// Permanent mode moves too, as the real engine's first step does (DESIGN-debloat D3), and reports `.deleted`.
    private func moveIntoTrash(_ url: URL, _ mode: DeletionMode) -> TrashOutcome {
        guard url.path.hasPrefix(fixture.path + "/"), !url.path.split(separator: "/").contains("..") else {
            return .refused(url, .protectedLocation("Outside the fixture"))
        }
        let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return mode == .permanent ? .deleted(original: url) : .trashed(original: url, trashedTo: destination)
        } catch {
            return .failed(url, message: error.localizedDescription)
        }
    }
}
