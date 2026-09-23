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
    /// The running scan so far, one level deep, drawn while it lasts (T-0063). The completed tree replaces it.
    public private(set) var preview: ScanTree?
    /// Counts previews, so each one gets a layout of its own.
    private(set) var previewVersion = 0
    /// What the running scan should reach, for its progress bar: the last scan's total when the same folder
    /// is scanned again, else the space in use when a whole volume is scanned.
    var expectedTotal: (bytes: UInt64, isLastScan: Bool)?
    /// The folder the map is drilled into. Only a folder the map can open is accepted: the Overview sets
    /// this directly, and a stale index must not put the map inside a file, a package or the Trash.
    public var focus: Int {
        get { focusNode }
        set {
            guard newValue != focusNode, canFocus(newValue) else { return }
            focusNode = newValue
            showsAllSmallerItems = false
            listLimit = Self.listPage
        }
    }
    private var focusNode = ScanTree.root
    /// Bumped whenever `tree` changes, so layouts of an older tree are never reused.
    private(set) var treeVersion = 0

    var selection: MapItem?
    var style: MapStyle = .sunburst
    /// The side list shows every member of the focus's "smaller items" row instead of one summary row.
    var showsAllSmallerItems = false
    /// Node rows the side list shows before folding the rest into one "more items" row.
    var listLimit = DiskMapModel.listPage
    static let listPage = 500
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
    // The side list asks for its rows on every selection change; sorting a flat folder of 200k
    // names took 244 ms there, so the sort and the rows are kept until what they depend on changes.
    @ObservationIgnored var sortedCache: (version: Int, node: Int, children: [Int])?
    @ObservationIgnored var rowsCache: (key: ListRowsKey, rows: [ListRow])?

    let scanEngine: ScanEngine?
    let trashService: TrashService?
    private var scanTask: Task<Void, Never>?
    /// Only the newest scan may write: a cancelled scan's stream can still deliver buffered events.
    private var scanGeneration = 0

    public init(engine: ScanEngine?, trash: TrashService?, tree: ScanTree? = nil) {
        self.scanEngine = engine
        self.trashService = trash
        self.tree = tree
    }

    // MARK: Scanning

    /// Scans `root` and shows it once complete. Until then, and after a Stop, the previous map stays.
    /// Cancelling the caller, or `cancelScan()`, stops the walk.
    func scan(_ root: URL) async {
        guard let engine = scanEngine else { return }
        scanTask?.cancel()
        let expected: (bytes: UInt64, isLastScan: Bool)? = if let tree, tree.rootURL.standardizedFileURL == root.standardizedFileURL {
            (tree.allocatedSize(of: ScanTree.root), true)
        } else {
            ScanEngine.volumeBytesInUse(at: root).map { ($0, false) }
        }
        let generation = beginScan()
        expectedTotal = expected
        let task = Task {
            do {
                for try await event in engine.scan(root) {
                    if Task.isCancelled { break }
                    receive(event, generation: generation)
                }
            } catch {
                if !Task.isCancelled, generation == scanGeneration {
                    scanError = "Could not scan “\(root.lastPathComponent)”: \(error.localizedDescription)"
                }
            }
            finishScan(generation)
        }
        scanTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// Makes a new scan the only one allowed to change what is shown.
    func beginScan() -> Int {
        scanGeneration += 1
        scanError = nil
        progress = nil
        preview = nil
        expectedTotal = nil
        isScanning = true
        return scanGeneration
    }

    func receive(_ event: ScanEvent, generation: Int) {
        guard generation == scanGeneration else { return }
        switch event {
        case .progress(let update): progress = update
        case .preview(let tree):
            preview = tree
            previewVersion += 1
        case .completed(let result): replaceTree(result)
        }
    }

    func finishScan(_ generation: Int) {
        guard generation == scanGeneration else { return }
        isScanning = false
        progress = nil
        preview = nil
        expectedTotal = nil
    }

    /// Shows a new scan. Staged items found again at the same path, as the same file, stay staged.
    /// The In Trash list described the old map; those moves stay in History.
    private func replaceTree(_ newTree: ScanTree) {
        let staged = pile.items
        tree = newTree
        treeDidChange()
        focusNode = ScanTree.root
        showsAllSmallerItems = false
        listLimit = Self.listPage
        selection = nil
        backStack = []
        forwardStack = []
        trashed = []
        layout = nil
        pile.removeAll()
        for item in staged {
            guard let node = newTree.node(at: item.url), newTree.identity(of: node) == item.identity else { continue }
            _ = pile.add(node, in: newTree)
        }
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

    /// The scan root, or a live folder the map draws into (not a package, a mount point or a file).
    func canFocus(_ node: Int) -> Bool {
        if node == ScanTree.root { return true }
        guard let tree, (0..<tree.count).contains(node) else { return false }
        return tree.isExpandable(node) && !tree.isRemoved(node)
    }

    func drill(into node: Int) {
        guard node != focus, canFocus(node) else { return }
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

    /// Selects `item` and makes sure the side list shows it.
    func select(_ item: MapItem?) {
        selection = item
        stagingMessage = nil
        guard case .node(let node) = item, tree?.parent(of: node) == focus else { return }
        if focusSmallerItems.contains(node) { showsAllSmallerItems = true }
        if let index = sortedChildren(of: focus).firstIndex(of: node), index >= listLimit {
            listLimit = (index / Self.listPage + 1) * Self.listPage
        }
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
        let siblings = sortedChildren(of: parent)
        guard !siblings.isEmpty else { return }
        guard let current, let index = siblings.firstIndex(of: current) else {
            select(.node(siblings[0]))
            return
        }
        select(.node(siblings[min(max(index + offset, 0), siblings.count - 1)]))
    }

    /// A click in the sunburst's centre goes up one level; the second click of a double-click is not another step.
    func centerClicked(clickCount: Int) {
        if clickCount <= 1 { goUp() }
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
