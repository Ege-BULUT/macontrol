import MacontrolCore
import SwiftUI

/// PLACEHOLDER (scaffold): a sized list of the focused folder. M4 replaces it with the
/// sunburst and treemap, breadcrumb, inspector and staging tray.
struct DiskMapScreen: View {
    @Bindable var model: DiskMapModel

    var body: some View {
        Group {
            if let tree = model.tree {
                FolderList(tree: tree, focus: $model.focus)
            } else if let progress = model.progress {
                ProgressView("Scanned \(progress.filesVisited) items, \(progress.bytesVisited.formattedBytes)")
            } else {
                ContentUnavailableView {
                    Label("No scan yet", systemImage: "chart.pie")
                } actions: {
                    Button("Scan Home Folder") {
                        Task { await model.scan(FileManager.default.homeDirectoryForCurrentUser) }
                    }
                }
            }
        }
        .navigationTitle("Disk Map")
    }
}

private struct FolderList: View {
    let tree: ScanTree
    @Binding var focus: Int

    var body: some View {
        let total = max(tree.allocatedSize(of: focus), 1)
        let children = tree.children(of: focus).sorted { tree.allocatedSize(of: $0) > tree.allocatedSize(of: $1) }
        List(children, id: \.self) { child in
            let size = tree.allocatedSize(of: child)
            HStack {
                Image(systemName: tree.flags(of: child).contains(.directory) ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.tint)
                Text(tree.name(of: child))
                Spacer()
                ProgressView(value: Double(size), total: Double(total)).frame(width: 120)
                Text(size.formattedBytes).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) {
                if tree.flags(of: child).contains(.directory) { focus = child }
            }
        }
    }
}
