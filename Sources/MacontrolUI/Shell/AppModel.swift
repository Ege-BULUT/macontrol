import Cleaner
import Foundation
import MacontrolCore
import Observation
import Safety
import ScanEngine
import Uninstaller

/// App-wide state: services, navigation and one model per screen.
@Observable
public final class AppModel {
    public var selection: SidebarItem
    public var volume: VolumeSummary?
    /// When `volume` was read. Purgeable space is a moving promise, so it is shown with its date.
    public private(set) var volumeReadAt: Date?
    public private(set) var scope: ScanScope?
    public private(set) var isScanning = false
    /// Drives the "Choose Folder" panel, which both the toolbar and ⌘O open.
    public var isChoosingFolder = false

    public let access: AccessModel
    public let diskMap: DiskMapModel
    public let clean: CleanModel
    public let uninstall: UninstallModel
    public let history: HistoryModel

    private var scanTask: Task<Void, Never>?

    public var fullDiskAccess: FullDiskAccess { access.status }

    public init(
        selection: SidebarItem = .overview,
        fullDiskAccess: FullDiskAccess,
        volume: VolumeSummary?,
        diskMap: DiskMapModel,
        clean: CleanModel,
        uninstall: UninstallModel,
        history: HistoryModel,
        access: AccessModel? = nil,
        volumeReadAt: Date? = nil
    ) {
        self.selection = selection
        self.access = access ?? AccessModel(status: fullDiskAccess, probe: { fullDiskAccess }, openURL: { _ in false })
        self.volume = volume
        self.volumeReadAt = volumeReadAt ?? (volume == nil ? nil : Date())
        self.diskMap = diskMap
        self.clean = clean
        self.uninstall = uninstall
        self.history = history
    }

    /// Starts a Disk Map scan of `scope`, replacing any scan in flight.
    public func scan(_ scope: ScanScope) {
        self.scope = scope
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            await diskMap.scan(scope.url)
            guard !Task.isCancelled else { return }
            isScanning = false
            refreshVolume()
        }
    }

    public func rescan() {
        scan(scope ?? .home)
    }

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func refreshVolume() {
        guard let fresh = try? VolumeSummary.of(URL(fileURLWithPath: "/")) else { return }
        volume = fresh
        volumeReadAt = Date()
    }

    /// The real app, wired to the real services.
    public static func live() -> AppModel {
        let engine = ScanEngine()
        let trash = TrashService()
        let catalog = (try? CleanupCatalog.bundled()) ?? CleanupCatalog(version: 0, rules: [])
        // Probing at launch also gets the app listed in the Full Disk Access pane (P8).
        let access = AccessModel(status: .probe())
        access.isOnboardingPresented = access.isLimited
        return AppModel(
            fullDiskAccess: access.status,
            volume: try? VolumeSummary.of(URL(fileURLWithPath: "/")),
            diskMap: DiskMapModel(engine: engine, trash: trash),
            clean: CleanModel(cleaner: Cleaner(catalog: catalog, engine: engine), trash: trash),
            uninstall: UninstallModel(uninstaller: Uninstaller(engine: engine, trash: trash)),
            history: HistoryModel(trash: trash),
            access: access
        )
    }

    /// Fixed sample data for snapshots and previews. Touches no real files.
    public static func demo(selection: SidebarItem = .overview, fullDiskAccess: FullDiskAccess = .granted) -> AppModel {
        let model = AppModel(
            selection: selection,
            fullDiskAccess: fullDiskAccess,
            volume: VolumeSummary(
                name: "Macintosh HD", capacity: 494_384_795_648,
                available: 131_207_000_000, availableForImportantUsage: 139_415_000_000
            ),
            diskMap: .demo(),
            clean: .demo(),
            uninstall: .demo(),
            history: .demo(),
            volumeReadAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        model.scope = .home
        return model
    }
}
