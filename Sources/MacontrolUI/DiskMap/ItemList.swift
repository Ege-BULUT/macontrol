import MacontrolCore
import SwiftUI

/// The focus folder's contents, sorted by size, with the same colours as the map.
struct ItemList: View {
    @Bindable var model: DiskMapModel
    let tree: ScanTree

    var body: some View {
        let rows = model.listRows
        let total = tree.allocatedSize(of: model.focus)
        let branches = branchSlots()
        VStack(spacing: 0) {
            HStack {
                Text("Contents").font(.headline)
                Text(DiskMapText.itemCount(tree.children(of: model.focus).count)).foregroundStyle(.secondary)
                Spacer()
                if model.showsAllSmallerItems && !model.focusSmallerItems.isEmpty {
                    Button("Group Small Items") { model.showsAllSmallerItems = false }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.vertical, 10)
            List(selection: selection) {
                ForEach(rows) { row in
                    ItemRow(row: row, tree: tree, total: total, branch: rowBranch(row, branches))
                        .tag(row.id)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: Int.self) { ids in
                if let id = ids.first, id >= 0 { DiskMapItemMenu(model: model, node: id) }
            } primaryAction: { ids in
                guard let id = ids.first else { return }
                if id >= 0 { model.open(.node(id)) } else { expand(id) }
            }
        }
    }

    /// List selection mapped onto the map's: node rows select the node, the "smaller items" row expands.
    private var selection: Binding<Int?> {
        Binding {
            model.selectedNode
        } set: { id in
            guard let id else { return }
            if id >= 0 { model.select(.node(id)) } else { expand(id) }
        }
    }

    /// The "smaller items" row lists its members, the "more items" row the next page.
    private func expand(_ id: Int) {
        if id == ListRow.smallerItemsID { model.showsAllSmallerItems = true }
        if id == ListRow.moreID { model.showMoreRows() }
    }

    private func branchSlots() -> [Int: Int] {
        guard let layout = model.layout, layout.key.focus == model.focus else { return [:] }
        var slots: [Int: Int] = [:]
        for index in layout.topLevel {
            if let node = layout.elements[index].node, let branch = layout.elements[index].branch { slots[node] = branch }
        }
        return slots
    }

    private func rowBranch(_ row: ListRow, _ slots: [Int: Int]) -> Int? {
        if case .node(let node) = row.kind { slots[node] } else { nil }
    }
}

private struct ItemRow: View {
    let row: ListRow
    let tree: ScanTree
    let total: UInt64
    let branch: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(swatch)
                .frame(width: 8, height: 8)
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(isInTrash)
                    .foregroundStyle(isInTrash ? .secondary : .primary)
                if let note {
                    Text(note).font(.caption).foregroundStyle(noteColor).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(row.bytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(swatch.opacity(0.14))
                    .frame(width: isInTrash ? 0 : proxy.size.width * share, height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isInTrash: Bool {
        if case .inTrash = row.kind { true } else { false }
    }

    private var share: Double {
        total > 0 ? Double(row.bytes) / Double(total) : 0
    }

    private var swatch: Color {
        switch row.kind {
        case .node: MapPalette.rgb(branch: branch, depth: 0, dark: colorScheme == .dark).color
        case .smallerItems: MapPalette.smallerItems.color
        case .more, .folderEntries, .inTrash: .clear
        }
    }

    private var title: String {
        switch row.kind {
        case .node(let node): tree.name(of: node)
        case .smallerItems(let members): DiskMapText.smallerItems(members.count)
        case .more(let count): "\(DiskMapText.itemCount(count)) more"
        case .folderEntries: "Folder entries"
        case .inTrash(let item): item.name
        }
    }

    private var note: String? {
        switch row.kind {
        case .node(let node): DiskMapText.notes(for: tree.flags(of: node)).first?.text
        case .smallerItems: "Too small to draw. Click to list them"
        case .more: "Click to show the next \(DiskMapModel.listPage.formatted())"
        case .folderEntries: "The folder's own directory records"
        case .inTrash: "In Trash: space returns when the Trash is emptied"
        }
    }

    private var noteColor: Color {
        if case .node = row.kind { .orange } else { .secondary }
    }

    private var symbol: String {
        switch row.kind {
        case .node(let node): Self.symbol(for: tree.flags(of: node))
        case .smallerItems: "square.stack.3d.up"
        case .more: "ellipsis.circle"
        case .folderEntries: "list.bullet.rectangle"
        case .inTrash: "trash"
        }
    }

    static func symbol(for flags: NodeFlags) -> String {
        if flags.contains(.unreadable) { return "lock.fill" }
        if flags.contains(.dataless) { return "icloud" }
        if flags.contains(.symlink) { return "arrowshape.turn.up.right" }
        if flags.contains(.mountPoint) { return "externaldrive.fill" }
        if flags.contains(.package) { return "shippingbox.fill" }
        if flags.contains(.directory) { return "folder.fill" }
        return "doc.fill"
    }
}
