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
            // With the sidebar and the inspector, this keeps the map whole in the minimum window (T-0056).
            .frame(minWidth: 380)
            Divider()
            VStack(spacing: 0) {
                InspectorPanel(model: model, tree: tree)
                Divider()
                ItemList(model: model, tree: tree)
            }
            .frame(width: 300)
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

/// A scan in progress: how far it has got, and the top of the map as it fills in (T-0063).
private struct ScanningView: View {
    let model: DiskMapModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let preview = model.preview {
                ScanPreviewChart(tree: preview, version: model.previewVersion, style: model.style, slots: model.previewSlots)
                    .equatable()
                    .padding(Theme.spacing)
                Text("Sizes grow as the scan finds more. The full map, with the folders inside, opens when it finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], Theme.spacing)
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Scanning…").font(.system(size: 22, weight: .semibold))
                if let progress = model.progress {
                    Text("\(progress.bytesVisited.formattedBytes) · \(DiskMapText.itemCount(progress.filesVisited))")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
            if let expected = model.expectedTotal, expected.bytes > 0 {
                let visited = min(model.progress?.bytesVisited ?? 0, expected.bytes)
                ProgressView(value: Double(visited), total: Double(expected.bytes)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("About \(DiskMapText.percent(visited, of: expected.bytes)) of the \(expected.bytes.formattedBytes) \(expected.isLastScan ? "the last scan found" : "in use on this volume")")
                        .monospacedDigit()
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(model.progress?.currentPath ?? " ")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.spacing + 4)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// The preview drawn like the map, without interaction; the sunburst names its wedges in a legend, since
/// nothing can be hovered yet. It is one ring of at most 256 items, so its layout is built right here:
/// microseconds, not the off-main work a full map takes.
private struct ScanPreviewChart: View, Equatable {
    let tree: ScanTree
    let version: Int
    let style: MapStyle
    /// Changes only with `version`.
    let slots: [String: Int]
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.style == rhs.style
    }

    var body: some View {
        GeometryReader { proxy in
            let legendWidth = style == .sunburst ? min(240, proxy.size.width * 0.4) : 0
            let chart = CGSize(width: proxy.size.width - legendWidth, height: proxy.size.height)
            let key = LayoutKey(
                treeVersion: version, focus: ScanTree.root, style: style,
                width: Int(chart.width), height: Int(chart.height), scale: displayScale
            )
            let layout = (try? MapLayoutBuilder.build(tree, key, slots: slots)) ?? .empty(key)
            HStack(spacing: 0) {
                ZStack {
                    MapFillLayer(layout: layout, tree: tree).equatable()
                    if style == .sunburst {
                        VStack(spacing: 2) {
                            Text(tree.name(of: ScanTree.root)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(tree.allocatedSize(of: ScanTree.root).formattedBytes)
                                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(width: MapLayout.chartRadius(in: chart) * MapLayout.holeRadius * 1.6)
                    }
                }
                .frame(width: chart.width, height: chart.height)
                if style == .sunburst { legend(layout).frame(width: legendWidth) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the scan so far")
        .accessibilityValue(tree.sortedChildren(of: ScanTree.root).prefix(12).map { "\(tree.name(of: $0)), \(tree.allocatedSize(of: $0).formattedBytes)" }.joined(separator: "; "))
    }

    private func legend(_ layout: MapLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(layout.topLevel.prefix(12)), id: \.self) { index in
                let element = layout.elements[index]
                let label = MapGeometry.label(for: element, in: tree)
                HStack(spacing: 8) {
                    Circle()
                        .fill(MapPalette.rgb(branch: element.branch, depth: 0, dark: colorScheme == .dark).color)
                        .opacity(element.item.isSmallerItems ? 0.55 : 1)
                        .frame(width: 10, height: 10)
                    Text(label.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(label.size).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
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
