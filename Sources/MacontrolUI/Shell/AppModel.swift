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
    public var fullDiskAccess: FullDiskAccess
    public var volume: VolumeSummary?

    public let diskMap: DiskMapModel
    public let clean: CleanModel
    public let uninstall: UninstallModel
    public let history: HistoryModel

    public init(
        selection: SidebarItem = .overview,
        fullDiskAccess: FullDiskAccess,
        volume: VolumeSummary?,
        diskMap: DiskMapModel,
        clean: CleanModel,
        uninstall: UninstallModel,
        history: HistoryModel
    ) {
        self.selection = selection
        self.fullDiskAccess = fullDiskAccess
        self.volume = volume
        self.diskMap = diskMap
        self.clean = clean
        self.uninstall = uninstall
        self.history = history
    }

    /// The real app, wired to the real services.
    public static func live() -> AppModel {
        let engine = ScanEngine()
        let trash = TrashService()
        let catalog = (try? CleanupCatalog.bundled()) ?? CleanupCatalog(version: 0, rules: [])
        return AppModel(
            fullDiskAccess: .probe(),
            volume: try? VolumeSummary.of(URL(fileURLWithPath: "/")),
            diskMap: DiskMapModel(engine: engine, trash: trash),
            clean: CleanModel(cleaner: Cleaner(catalog: catalog, engine: engine), trash: trash),
            uninstall: UninstallModel(uninstaller: Uninstaller(engine: engine, trash: trash)),
            history: HistoryModel(trash: trash)
        )
    }

    /// Fixed sample data for snapshots and previews. Touches no real files.
    public static func demo(selection: SidebarItem = .overview) -> AppModel {
        AppModel(
            selection: selection,
            fullDiskAccess: .granted,
            volume: VolumeSummary(
                name: "Macintosh HD", capacity: 494_384_795_648,
                available: 131_207_000_000, availableForImportantUsage: 139_415_000_000
            ),
            diskMap: .demo(),
            clean: .demo(),
            uninstall: .demo(),
            history: .demo()
        )
    }
}
