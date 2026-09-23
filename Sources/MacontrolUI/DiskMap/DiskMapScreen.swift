import AppKit
import MacontrolCore
import QuickLook
import SwiftUI

/// The Disk Map: nothing scanned yet, a scan in progress, or the map with its list, inspector and Discard Pile.
struct DiskMapScreen: View {
    @Bindable var model: DiskMapModel

    var body: some View {
        Group {
            if model.isScanning {
                ScanningView(model: model)
            } else if let tree = model.tree {
                DiskMapWorkspace(model: model, tree: tree)
            } else {
                EmptyMapView(model: model)
            }
        }
        .navigationTitle("Disk Map")
    }
}

private struct DiskMapWorkspace: View {
    @Bindable var model: DiskMapModel
    let tree: ScanTree
    @FocusState private var mapFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                MapHeader(model: model, tree: tree)
                Divider()
                VStack(spacing: 0) {
                    MapChart(model: model, tree: tree)
                        .padding(Theme.spacing)
                    if !model.pile.items.isEmpty || !model.trashed.isEmpty {
                        DiscardPileBar(model: model)
                            .padding(.horizontal, Theme.spacing)
                            .padding(.bottom, Theme.spacing)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($mapFocused)
                .onKeyPress(action: handleKey)
            }
            .frame(minWidth: 460)
            Divider()
            VStack(spacing: 0) {
                InspectorPanel(model: model, tree: tree)
                Divider()
                ItemList(model: model, tree: tree)
            }
            .frame(width: 330)
            .background(.background.secondary)
        }
        .onAppear { mapFocused = true }
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: Binding { model.review != nil } set: { if !$0 { model.review = nil } }) {
            if let review = model.review { ReviewSheet(model: model, review: review) }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            guard let selection = model.selection else { return .ignored }
            model.open(selection)
        case .escape:
            model.goUp()
        case .space:
            guard let node = model.selectedNode else { return .ignored }
            model.quickLook(node)
        case .upArrow where press.modifiers.contains(.command):
            model.goUp()
        case .upArrow, .leftArrow:
            model.moveSelection(by: -1)
        case .downArrow, .rightArrow:
            model.moveSelection(by: 1)
        default:
            return .ignored
        }
        return .handled
    }
}

private struct ScanningView: View {
    let model: DiskMapModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning…").font(.title2.weight(.semibold))
            if let progress = model.progress {
                Text("\(progress.filesVisited.formatted()) items · \(progress.bytesVisited.formattedBytes)")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let path = progress.currentPath {
                    Text(path)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 480)
                }
            }
            Button("Stop Scan") { model.cancelScan() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyMapView: View {
    let model: DiskMapModel

    var body: some View {
        ContentUnavailableView {
            Label("Map Your Disk", systemImage: "chart.pie")
        } description: {
            Text(model.scanError ?? "See what takes up space, folder by folder. Nothing is changed until you review it.")
        } actions: {
            Button("Scan Home Folder") {
                Task { await model.scan(FileManager.default.homeDirectoryForCurrentUser) }
            }
            .buttonStyle(.borderedProminent)
            Button("Choose Folder…") { chooseFolder() }
        }
        .controlSize(.large)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.scan(url) }
    }
}
