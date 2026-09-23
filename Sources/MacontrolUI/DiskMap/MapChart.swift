import MacontrolCore
import SwiftUI

/// The interactive map: requests layouts for its size, draws them, and turns pointer input into
/// selection and navigation.
struct MapChart: View {
    @Bindable var model: DiskMapModel
    let tree: ScanTree
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Int?
    @State private var pointer: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            let key = model.layoutKey(width: proxy.size.width, height: proxy.size.height, scale: displayScale)
            ZStack {
                if let layout = model.layout {
                    canvas(layout, size: proxy.size)
                        .id(Self.transitionID(layout))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3), value: model.layout.map(Self.transitionID))
            .task(id: key) { await model.prepareLayout(key) }
        }
    }

    private func canvas(_ layout: MapLayout, size: CGSize) -> some View {
        let geometry = MapGeometry(layout: layout, size: size)
        let staged = Set(model.pile.items.map(\.node))
        return ZStack {
            MapFillLayer(layout: layout, tree: tree).equatable()
            MapHighlightLayer(layout: layout, hovered: hovered, selection: model.selection, staged: staged)
            if layout.key.style == .sunburst { centerLabel(layout, geometry: geometry) }
            if layout.elements.isEmpty {
                Text("Empty folder").font(.callout).foregroundStyle(.secondary)
            }
            if let hovered, layout.elements.indices.contains(hovered) {
                MapTooltip(element: layout.elements[hovered], tree: tree, focusBytes: tree.allocatedSize(of: layout.key.focus))
                    .position(tooltipPosition(in: size))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer = location
                hovered = layout.element(at: geometry.toLayout(location))
            case .ended:
                hovered = nil
            }
        }
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            if let item = item(at: value.location, layout, geometry) { model.open(item) }
        })
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            if layout.isInCenter(geometry.toLayout(value.location)) {
                model.goUp()
            } else {
                model.select(item(at: value.location, layout, geometry))
            }
        })
        .contextMenu {
            if let hovered, let node = layout.elements[hovered].node {
                DiskMapItemMenu(model: model, node: node)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk map of \(tree.name(of: layout.key.focus))")
        .accessibilityChildren {
            ForEach(Array(layout.topLevel), id: \.self) { index in
                let label = MapGeometry.label(for: layout.elements[index], in: tree)
                Rectangle()
                    .accessibilityLabel("\(label.name), \(label.size)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.open(layout.elements[index].item) }
            }
        }
    }

    /// A new map identity per folder and style, so drilling and switching animate as a new map.
    private static func transitionID(_ layout: MapLayout) -> [Int] {
        [layout.key.focus, layout.key.style == .sunburst ? 0 : 1]
    }

    private func item(at location: CGPoint, _ layout: MapLayout, _ geometry: MapGeometry) -> MapItem? {
        layout.element(at: geometry.toLayout(location)).map { layout.elements[$0].item }
    }

    private func centerLabel(_ layout: MapLayout, geometry: MapGeometry) -> some View {
        let diameter = geometry.radius * MapLayout.holeRadius * 2
        let focus = layout.key.focus
        return VStack(spacing: 2) {
            Text(tree.name(of: focus))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(tree.allocatedSize(of: focus).formattedBytes)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
            if tree.parent(of: focus) != nil {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(width: diameter * 0.8)
        .position(geometry.center)
        .allowsHitTesting(false)
    }

    private func tooltipPosition(in size: CGSize) -> CGPoint {
        let width = 230.0, height = 80.0
        let x = pointer.x + 18 + width / 2 > size.width ? pointer.x - 18 - width / 2 : pointer.x + 18 + width / 2
        let y = min(max(pointer.y + 18 + height / 2, height / 2), size.height - height / 2)
        return CGPoint(x: x, y: y)
    }
}

private struct MapTooltip: View {
    let element: MapElement
    let tree: ScanTree
    let focusBytes: UInt64

    var body: some View {
        let label = MapGeometry.label(for: element, in: tree)
        VStack(alignment: .leading, spacing: 3) {
            Text(label.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text("\(label.size) · \(DiskMapText.percent(element.bytes, of: focusBytes)) of this folder")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            if let node = element.node, let note = DiskMapText.notes(for: tree.flags(of: node)).first {
                Label(note.text, systemImage: note.symbol).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            } else if case .smallerItems = element.item {
                Text("Double-click to list them").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let node = element.node, tree.flags(of: node).contains(.directory) {
                Text(DiskMapText.itemCount(tree.fileCount(of: node))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
