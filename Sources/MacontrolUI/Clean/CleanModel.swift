import Cleaner
import Foundation
import MacontrolCore
import Observation
import Safety

@Observable
public final class CleanModel {
    public private(set) var items: [CleanupItem]
    public var selection: Set<URL>
    public private(set) var isScanning = false

    private let cleaner: Cleaner?
    private let trash: TrashService?

    public init(cleaner: Cleaner?, trash: TrashService?, items: [CleanupItem] = []) {
        self.cleaner = cleaner
        self.trash = trash
        self.items = items
        self.selection = Set(items.filter(\.isPreselected).map(\.url))
    }

    var selectedBytes: UInt64 {
        items.filter { selection.contains($0.url) }.reduce(0) { $0 + $1.measurement.allocated }
    }

    func scan() async {
        guard let cleaner else { return }
        isScanning = true
        defer { isScanning = false }
        items = []
        do {
            for try await item in cleaner.scan() {
                items.append(item)
                if item.isPreselected { selection.insert(item.url) }
            }
        } catch {}
    }

    static func demo() -> CleanModel {
        func rule(_ id: String, _ title: String, _ category: CleanupCategory, _ safety: SafetyLevel) -> CleanupRule {
            CleanupRule(id: id, title: title, category: category, safety: safety, paths: [], minimumAgeDays: nil, note: "")
        }
        func item(_ rule: CleanupRule, _ path: String, _ gigabytes: Double, skip: String? = nil) -> CleanupItem {
            let bytes = UInt64(gigabytes * 1_000_000_000)
            return CleanupItem(
                rule: rule, url: URL(fileURLWithPath: path), identity: nil,
                measurement: ItemMeasurement(allocated: bytes, logical: bytes, fileCount: 1200, newestModification: nil, isIncomplete: false),
                skipReason: skip
            )
        }
        let caches = rule("user-app-caches", "App caches", .appCaches, .safe)
        let derived = rule("xcode-derived-data", "Xcode build data", .developer, .safe)
        let archives = rule("xcode-archives", "Xcode archives", .developer, .manual)
        return CleanModel(cleaner: nil, trash: nil, items: [
            item(caches, "/Users/demo/Library/Caches/com.example.Editor", 1.3),
            item(caches, "/Users/demo/Library/Caches/com.apple.Safari", 0.4, skip: "Safari is running"),
            item(derived, "/Users/demo/Library/Developer/Xcode/DerivedData/Macontrol-abc", 6.8),
            item(archives, "/Users/demo/Library/Developer/Xcode/Archives/2026-08-01", 2.1),
        ])
    }
}
