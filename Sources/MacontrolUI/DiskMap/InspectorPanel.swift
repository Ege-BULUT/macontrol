import MacontrolCore
import SwiftUI

/// Details and actions for the selection, or for the focus folder when nothing is selected.
struct InspectorPanel: View {
    @Bindable var model: DiskMapModel
    let tree: ScanTree

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.selection {
            case .smallerItems(let parent, let members):
                smallerItems(parent: parent, members: members)
            case .node(let node):
                details(node)
            case nil:
                details(model.focus)
            }
            if let message = model.stagingMessage {
                Label(message, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.cautionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ node: Int) -> some View {
        let flags = tree.flags(of: node)
        let parent = tree.parent(of: node)
        let bytes = tree.allocatedSize(of: node)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(for: flags))
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tree.name(of: node)).font(.headline).lineLimit(2)
                    Text(tree.url(of: node).path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bytes.formattedBytes)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                Text("on disk").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Size", tree.logicalSize(of: node).formattedBytes)
                if flags.contains(.directory) { row("Contains", DiskMapText.itemCount(tree.fileCount(of: node))) }
                if let parent { row("Of enclosing folder", DiskMapText.percent(bytes, of: tree.allocatedSize(of: parent))) }
                row("Of scan", DiskMapText.percent(bytes, of: tree.allocatedSize(of: ScanTree.root)))
            }
            .font(.callout)
            ForEach(DiskMapText.notes(for: flags), id: \.self) { note in
                Label(note.text, systemImage: note.symbol)
                    .font(.callout)
                    .foregroundStyle(Theme.cautionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(node)
        }
    }

    private func actions(_ node: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder(node) }
                    // ⌘R is the app's Rescan.
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .frame(maxWidth: .infinity)
                Button("Quick Look", systemImage: "eye") { model.quickLook(node) }
                    .labelStyle(.iconOnly)
                    .help("Quick Look (Space)")
                Menu {
                    DiskMapItemMenu(model: model, node: node)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if model.pile.contains(node) {
                Button("Remove from Discard Pile", systemImage: "arrow.uturn.backward") { model.unstage(node) }
                    .frame(maxWidth: .infinity)
            } else {
                Button("Add to Discard Pile", systemImage: "trash") { model.stage(node) }
                    // Only a real selection is staged from the keyboard, never the folder being viewed.
                    .keyboardShortcut(model.selectedNode == node ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }

    private func smallerItems(parent: Int, members: [Int]) -> some View {
        let bytes = members.reduce(0) { $0 + tree.allocatedSize(of: $1) }
        return VStack(alignment: .leading, spacing: 10) {
            Label(DiskMapText.smallerItems(members.count), systemImage: "square.stack.3d.up")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bytes.formattedBytes).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                Text("in \(tree.name(of: parent))").foregroundStyle(.secondary)
            }
            Text("Each is too small to draw on the map, so they share one piece of it. Every one is listed and sized.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show in List", systemImage: "list.bullet") { model.open(.smallerItems(parent: parent, members: members)) }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private static func symbol(for flags: NodeFlags) -> String {
        if flags.contains(.package) { return "shippingbox.fill" }
        if flags.contains(.directory) { return "folder.fill" }
        return "doc.fill"
    }
}
