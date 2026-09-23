import Foundation
import MacontrolCore
import Observation
import Safety
import ScanEngine

/// State of the Disk Map: the scanned tree, where the map is focused, what is selected and staged.
///
/// Navigation never touches the disk: drill-down, back and up read the tree in memory (F-0013), and
/// a Move to Trash splices the tree in place instead of rescanning (F-0052).
@Observable
public final class DiskMapModel {
    public internal(set) var tree: ScanTree?
    public private(set) var progress: ScanProgress?
    public private(set) var isScanning = false
    public private(set) var scanError: String?
    /// The folder the map is drilled into.
    public var focus: Int = ScanTree.root {
        didSet { if focus != oldValue { showsAllSmallerItems = false } }
    }
    /// Bumped whenever `tree` changes, so layouts of an older tree are never reused.
    private(set) var treeVersion = 0

    var selection: MapItem?
    var style: MapStyle = .sunburst
    /// The side list shows every member of the focus's "smaller items" row instead of one summary row.
    var showsAllSmallerItems = false
    var quickLookURL: URL?
    /// Why the last "Add to Discard Pile" was refused, shown until the selection changes.
    var stagingMessage: String?

    var backStack: [Int] = []
    var forwardStack: [Int] = []

    var pile = DiscardPile()
    var review: ReviewState?
    /// Items this session moved to the Trash. Their bytes are "In Trash", never "freed" (F-0042).
    var trashed: [TrashedItem] = []

    /// The layout on screen. It stays until its replacement is ready, so the map never flashes empty.
    private(set) var layout: MapLayout?
    private var layoutCache: [LayoutKey: MapLayout] = [:]
    private var cacheOrder: [LayoutKey] = []

    let scanEngine: ScanEngine?
    let trashService: TrashService?
    private var scanTask: Task<Void, Never>?

    public init(engine: ScanEngine?, trash: TrashService?, tree: ScanTree? = nil) {
        self.scanEngine = engine
        self.trashService = trash
        self.tree = tree
    }

    // MARK: Scanning

    /// Scans `root` and shows it. Cancelling the caller, or `cancelScan()`, stops the walk.
    func scan(_ root: URL) async {
        scanTask?.cancel()
        let task = Task { await runScan(root) }
        scanTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func runScan(_ root: URL) async {
        guard let engine = scanEngine else { return }
        replaceTree(nil)
        scanError = nil
        progress = nil
        isScanning = true
        defer { isScanning = false }
        do {
            for try await event in engine.scan(root) {
                switch event {
                case .progress(let update): progress = update
                case .completed(let result): replaceTree(result)
                }
            }
        } catch {
            scanError = "Could not scan “\(root.lastPathComponent)”: \(error.localizedDescription)"
        }
        progress = nil
    }

    private func replaceTree(_ newTree: ScanTree?) {
        tree = newTree
        treeDidChange()
        focus = ScanTree.root
        selection = nil
        backStack = []
        forwardStack = []
        pile.removeAll()
        trashed = []
        layout = nil
    }

    /// Call after `tree` changed in place: layouts of the old tree are dropped, the on-screen one
    /// stays until its replacement is ready.
    func treeDidChange() {
        treeVersion += 1
        layoutCache = [:]
        cacheOrder = []
    }

    // MARK: Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { tree?.parent(of: focus) != nil }

    func drill(into node: Int) {
        guard let tree, node != focus, tree.flags(of: node).contains(.directory) else { return }
        backStack.append(focus)
        forwardStack = []
        focus = node
        selection = nil
    }

    /// Goes to the enclosing folder and selects the folder just left.
    func goUp() {
        guard let parent = tree?.parent(of: focus) else { return }
        let left = focus
        drill(into: parent)
        selection = .node(left)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(focus)
        focus = previous
        selection = nil
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(focus)
        focus = next
        selection = nil
    }

    /// Double-click or Return: a folder opens, "smaller items" opens in the list.
    func open(_ item: MapItem) {
        switch item {
        case .node(let node):
            drill(into: node)
        case .smallerItems(let parent, _):
            drill(into: parent)
            showsAllSmallerItems = true
            selection = item
        }
    }

    func select(_ item: MapItem?) {
        selection = item
        stagingMessage = nil
        if case .node(let node) = item, isInSmallerItemsRow(node) { showsAllSmallerItems = true }
    }

    /// Arrow keys: the previous or next sibling, in size order.
    func moveSelection(by offset: Int) {
        guard let tree else { return }
        let current: Int? = switch selection {
        case .node(let node): node
        case .smallerItems(_, let members): members.first
        case nil: nil
        }
        let parent = current.flatMap(tree.parent(of:)) ?? focus
        let siblings = tree.sortedChildren(of: parent)
        guard !siblings.isEmpty else { return }
        guard let current, let index = siblings.firstIndex(of: current) else {
            select(.node(siblings[0]))
            return
        }
        select(.node(siblings[min(max(index + offset, 0), siblings.count - 1)]))
    }

    var selectedNode: Int? {
        if case .node(let node) = selection { node } else { nil }
    }

    func url(of node: Int) -> URL? {
        tree?.url(of: node)
    }

    // MARK: Layout

    func layoutKey(width: Double, height: Double, scale: Double) -> LayoutKey {
        LayoutKey(treeVersion: treeVersion, focus: focus, style: style, width: Int(width), height: Int(height), scale: scale)
    }

    /// Shows the layout for `key`, from the cache or computed off the main actor.
    /// Called from `.task(id:)`, so a newer request cancels this one.
    func prepareLayout(_ key: LayoutKey) async {
        if let cached = layoutCache[key] {
            layout = cached
            return
        }
        guard let tree, key.treeVersion == treeVersion else { return }
        guard let result = try? await MapLayoutBuilder.layout(of: tree, for: key), result.key.treeVersion == treeVersion else { return }
        layoutCache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > 12 { layoutCache[cacheOrder.removeFirst()] = nil }
        layout = result
    }

    /// The top-level "smaller items" of the focus in the current layout, if any.
    var focusSmallerItems: [Int] {
        guard let layout, layout.key.focus == focus, layout.key.treeVersion == treeVersion else { return [] }
        for index in layout.topLevel {
            if case .smallerItems(_, let members) = layout.elements[index].item { return members }
        }
        return []
    }

    // MARK: Side list

    /// The focus's contents, largest first. The rows other than "In Trash" add up to the folder's size:
    /// the map's "smaller items" are one row until expanded, and the folder's own entries get a row too.
    var listRows: [ListRow] {
        guard let tree else { return [] }
        let merged = showsAllSmallerItems ? [] : focusSmallerItems
        let mergedSet = Set(merged)
        var rows: [ListRow] = tree.sortedChildren(of: focus)
            .filter { !mergedSet.contains($0) }
            .map { ListRow(kind: .node($0), bytes: tree.allocatedSize(of: $0)) }
        if !merged.isEmpty {
            rows.append(ListRow(kind: .smallerItems(merged), bytes: merged.reduce(0) { $0 + tree.allocatedSize(of: $1) }))
        }
        let childBytes = tree.children(of: focus).reduce(0) { $0 + tree.allocatedSize(of: $1) }
        let total = tree.allocatedSize(of: focus)
        if total > childBytes { rows.append(ListRow(kind: .folderEntries, bytes: total - childBytes)) }
        rows += trashed(from: focus).map { ListRow(kind: .inTrash($0), bytes: $0.bytes) }
        return rows
    }

    private func isInSmallerItemsRow(_ node: Int) -> Bool {
        tree?.parent(of: node) == focus && focusSmallerItems.contains(node)
    }
}

struct ListRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case node(Int)
        case smallerItems([Int])
        /// Bytes of the folder's own directory entries, so the rows add up.
        case folderEntries
        /// Moved to the Trash this session: shown, not counted.
        case inTrash(TrashedItem)
    }

    let kind: Kind
    let bytes: UInt64

    /// Node rows use the node number, which the list's selection binding relies on.
    var id: Int {
        switch kind {
        case .node(let node): node
        case .smallerItems: -1
        case .folderEntries: -2
        case .inTrash(let item): -3 - item.node
        }
    }
}

/// Something this session moved to the Trash.
struct TrashedItem: Identifiable, Hashable, Sendable {
    let node: Int
    let parent: Int
    let name: String
    let bytes: UInt64
    let trashedTo: URL

    var id: Int { node }
}
