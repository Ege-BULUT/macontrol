import MacontrolCore
import SwiftUI

/// Back, forward and up, the breadcrumb, the map style, and the focus folder's totals.
struct MapHeader: View {
    @Bindable var model: DiskMapModel
    let tree: ScanTree

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") { model.goBack() }
                        .keyboardShortcut("[")
                        .disabled(!model.canGoBack)
                    Button("Forward", systemImage: "chevron.right") { model.goForward() }
                        .keyboardShortcut("]")
                        .disabled(!model.canGoForward)
                }
                .fixedSize()
                Button("Enclosing Folder", systemImage: "arrow.up") { model.goUp() }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.upArrow)
                    .disabled(!model.canGoUp)
                    .help("Enclosing Folder (⌘↑)")
                Breadcrumb(model: model, tree: tree)
                Spacer(minLength: 8)
                Picker("Map Style", selection: $model.style) {
                    Label("Sunburst", systemImage: "circle.circle").tag(MapStyle.sunburst)
                    Label("Treemap", systemImage: "square.grid.2x2").tag(MapStyle.treemap)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Sunburst or treemap")
                Button("Rescan", systemImage: "arrow.clockwise") {
                    let root = tree.rootURL
                    Task { await model.scan(root) }
                }
                .labelStyle(.iconOnly)
                .disabled(model.scanEngine == nil)
                .help("Scan \(tree.rootURL.lastPathComponent) again")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tree.name(of: model.focus))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Text("\(tree.allocatedSize(of: model.focus).formattedBytes) · \(DiskMapText.itemCount(tree.fileCount(of: model.focus)))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if model.focus != ScanTree.root {
                    Text("\(DiskMapText.percent(tree.allocatedSize(of: model.focus), of: tree.allocatedSize(of: ScanTree.root))) of \(tree.name(of: ScanTree.root))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Theme.spacing + 4)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// The path from the scan root to the focus. Long paths keep the root and the last folders.
private struct Breadcrumb: View {
    let model: DiskMapModel
    let tree: ScanTree

    var body: some View {
        let path = tree.path(to: model.focus)
        let shown: [Int?] = path.count > 5 ? [path[0], nil] + path.suffix(3) : path
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { offset, node in
                if offset > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                if let node {
                    Button(tree.name(of: node)) { model.drill(into: node) }
                        .buttonStyle(.plain)
                        .foregroundStyle(node == model.focus ? .primary : .secondary)
                        .fontWeight(node == model.focus ? .semibold : .regular)
                        .lineLimit(1)
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}
