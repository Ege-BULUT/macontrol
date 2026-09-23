import MacontrolCore

/// What the side list's rows depend on; any change rebuilds them.
struct ListRowsKey: Equatable {
    let treeVersion: Int
    let focus: Int
    let showsAllSmallerItems: Bool
    let layout: LayoutKey?
    let limit: Int
}

extension DiskMapModel {
    /// The focus's contents, largest first. The rows other than "In Trash" add up to the folder's size:
    /// the map's "smaller items" are one row until expanded, rows past `listLimit` fold into one
    /// "more items" row, and the folder's own entries get a row too.
    var listRows: [ListRow] {
        guard let tree else { return [] }
        let key = ListRowsKey(treeVersion: treeVersion, focus: focus, showsAllSmallerItems: showsAllSmallerItems, layout: layout?.key, limit: listLimit)
        if let rowsCache, rowsCache.key == key { return rowsCache.rows }

        let merged = showsAllSmallerItems ? [] : focusSmallerItems
        let mergedSet = Set(merged)
        let listed = sortedChildren(of: focus).filter { !mergedSet.contains($0) }
        var rows = listed.prefix(listLimit).map { ListRow(kind: .node($0), bytes: tree.allocatedSize(of: $0)) }
        if listed.count > listLimit {
            let rest = listed.dropFirst(listLimit)
            rows.append(ListRow(kind: .more(rest.count), bytes: bytes(of: rest, in: tree)))
        }
        if !merged.isEmpty {
            rows.append(ListRow(kind: .smallerItems(merged), bytes: bytes(of: merged, in: tree)))
        }
        let childBytes = bytes(of: tree.children(of: focus), in: tree)
        let total = tree.allocatedSize(of: focus)
        if total > childBytes { rows.append(ListRow(kind: .folderEntries, bytes: total - childBytes)) }
        rows += trashed(from: focus).map { ListRow(kind: .inTrash($0), bytes: $0.bytes) }
        rowsCache = (key, rows)
        return rows
    }

    func showMoreRows() {
        listLimit += Self.listPage
    }

    /// `node`'s children by size, largest first, kept for the current tree.
    func sortedChildren(of node: Int) -> [Int] {
        guard let tree else { return [] }
        if let sortedCache, sortedCache.version == treeVersion, sortedCache.node == node { return sortedCache.children }
        let children = tree.sortedChildren(of: node)
        sortedCache = (treeVersion, node, children)
        return children
    }

    private func bytes(of nodes: some Sequence<Int>, in tree: ScanTree) -> UInt64 {
        nodes.reduce(0) { $0 + tree.allocatedSize(of: $1) }
    }
}

struct ListRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case node(Int)
        case smallerItems([Int])
        /// Children past the list's limit, shown on request.
        case more(Int)
        /// Bytes of the folder's own directory entries, so the rows add up.
        case folderEntries
        /// Moved to the Trash this session: shown, not counted.
        case inTrash(TrashedItem)
    }

    let kind: Kind
    let bytes: UInt64

    static let smallerItemsID = -1
    static let moreID = -3

    /// Node rows use the node number, which the list's selection binding relies on.
    var id: Int {
        switch kind {
        case .node(let node): node
        case .smallerItems: Self.smallerItemsID
        case .folderEntries: -2
        case .more: Self.moreID
        case .inTrash(let item): -4 - item.node
        }
    }
}
