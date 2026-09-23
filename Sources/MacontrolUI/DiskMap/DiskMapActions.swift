import AppKit
import MacontrolCore
import SwiftUI

/// Finder-side actions. None of them changes a file: the only way to remove anything is the Discard Pile.
extension DiskMapModel {
    func revealInFinder(_ node: Int) {
        guard let url = url(of: node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quickLook(_ node: Int) {
        quickLookURL = url(of: node)
    }

    func copyPath(_ node: Int) {
        guard let url = url(of: node) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func openInTerminal(_ node: Int) {
        guard let tree, let url = url(of: node),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let folder = tree.flags(of: node).contains(.directory) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The same actions for context menus on the map and the list.
struct DiskMapItemMenu: View {
    let model: DiskMapModel
    let node: Int

    var body: some View {
        let isFolder = model.tree?.flags(of: node).contains(.directory) == true
        if isFolder {
            Button("Open", systemImage: "arrow.down.right.circle") { model.open(.node(node)) }
        }
        Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder(node) }
        Button("Quick Look", systemImage: "eye") { model.quickLook(node) }
        Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node) }
        Button("Open in Terminal", systemImage: "terminal") { model.openInTerminal(node) }
        Divider()
        if model.pile.contains(node) {
            Button("Remove from Discard Pile", systemImage: "arrow.uturn.backward") { model.unstage(node) }
        } else {
            Button("Add to Discard Pile", systemImage: "trash") {
                model.select(.node(node))
                model.stage(node)
            }
        }
    }
}
