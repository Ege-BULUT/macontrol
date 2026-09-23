import MacontrolCore
import SwiftUI

/// The fills of a laid-out map. Equatable on the layout key, so hovering and selecting never redraw it.
struct MapFillLayer: View, Equatable {
    let layout: MapLayout
    let tree: ScanTree
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: MapFillLayer, rhs: MapFillLayer) -> Bool {
        lhs.layout.key == rhs.layout.key
    }

    var body: some View {
        let dark = colorScheme == .dark
        Canvas { context, size in
            let geometry = MapGeometry(layout: layout, size: size)
            let separator = dark ? Color(white: 0.12) : Color.white
            for element in layout.elements {
                let path = geometry.path(for: element)
                let fill = MapPalette.rgb(branch: element.branch, depth: element.depth, dark: dark)
                context.fill(path, with: .color(fill.color.opacity(element.item.isSmallerItems ? 0.55 : 1)))
                context.stroke(path, with: .color(separator), lineWidth: layout.key.style == .sunburst ? 1 : 0.75)
            }
            if layout.key.style == .treemap { drawLabels(in: &context, geometry: geometry, dark: dark) }
        }
    }

    /// Names on tiles big enough to read them; folders get theirs in the header strip.
    private func drawLabels(in context: inout GraphicsContext, geometry: MapGeometry, dark: Bool) {
        let nameFont = Font.system(size: 11, weight: .medium)
        let headerFont = Font.system(size: 11, weight: .semibold)
        let sizeFont = Font.system(size: 10).monospacedDigit()
        for element in layout.elements {
            let rect = geometry.rect(for: element)
            let isContainer = !element.children.isEmpty
            guard rect.width >= 40, rect.height >= (isContainer ? MapLayoutBuilder.headerHeight : 22) else { continue }
            let fill = MapPalette.rgb(branch: element.branch, depth: element.depth, dark: dark)
            let ink: Color = element.item.isSmallerItems ? .primary : (fill.prefersDarkText ? .black.opacity(0.82) : .white)
            let label = MapGeometry.label(for: element, in: tree)
            let origin = CGPoint(x: rect.minX + 5, y: rect.minY + (isContainer ? 1.5 : 4))
            let width = rect.width - 10
            guard let name = fitted(label.name, font: isContainer ? headerFont : nameFont, color: ink, width: width, in: context) else { continue }
            context.draw(name.text, at: origin, anchor: .topLeading)
            let size = context.resolve(Text(label.size).font(sizeFont).foregroundStyle(ink.opacity(0.75)))
            let sizeWidth = size.measure(in: CGSize(width: CGFloat.infinity, height: 20)).width
            if isContainer, name.width + 6 + sizeWidth <= width {
                context.draw(size, at: CGPoint(x: origin.x + name.width + 6, y: origin.y + 1), anchor: .topLeading)
            } else if !isContainer, rect.height >= 36, sizeWidth <= width {
                context.draw(size, at: CGPoint(x: origin.x, y: origin.y + 15), anchor: .topLeading)
            }
        }
    }

    /// `string` on one line within `width`, cut with an ellipsis if needed; nil if not even one letter fits.
    private func fitted(_ string: String, font: Font, color: Color, width: Double, in context: GraphicsContext) -> (text: GraphicsContext.ResolvedText, width: Double)? {
        func resolved(_ candidate: String) -> (text: GraphicsContext.ResolvedText, width: Double) {
            let text = context.resolve(Text(candidate).font(font).foregroundStyle(color))
            return (text, text.measure(in: CGSize(width: CGFloat.infinity, height: 20)).width)
        }
        let whole = resolved(string)
        if whole.width <= width { return whole }
        let characters = Array(string)
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if resolved(String(characters[..<middle]) + "…").width <= width { low = middle } else { high = middle - 1 }
        }
        return low == 0 ? nil : resolved(String(characters[..<low]) + "…")
    }
}

/// Hover, selection and Discard Pile marks, redrawn on every pointer move; cheap because it draws only those.
struct MapHighlightLayer: View {
    let layout: MapLayout
    let hovered: Int?
    let selection: MapItem?
    let staged: Set<Int>

    var body: some View {
        Canvas { context, size in
            let geometry = MapGeometry(layout: layout, size: size)
            for element in layout.elements {
                guard let node = element.node, staged.contains(node) else { continue }
                let path = geometry.path(for: element)
                context.fill(path, with: .color(.black.opacity(0.22)))
                context.drawLayer { layer in
                    layer.clip(to: path)
                    layer.stroke(Self.hatch(in: path.boundingRect), with: .color(.white.opacity(0.45)), lineWidth: 1)
                }
            }
            if let hovered, layout.elements.indices.contains(hovered) {
                let path = geometry.path(for: layout.elements[hovered])
                context.fill(path, with: .color(.white.opacity(0.22)))
                context.stroke(path, with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
            }
            if let selection, let index = layout.elements.firstIndex(where: { $0.item == selection }) {
                let path = geometry.path(for: layout.elements[index])
                context.stroke(path, with: .color(.primary), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
    }

    private static func hatch(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        return path
    }
}

/// Maps a layout onto the size it is drawn at. The layout keeps its own size while a newer one is
/// computed, so a resize stretches the old map instead of blanking it.
struct MapGeometry {
    let layout: MapLayout
    let size: CGSize

    private var scaleX: Double { layout.size.width > 0 ? size.width / layout.size.width : 1 }
    private var scaleY: Double { layout.size.height > 0 ? size.height / layout.size.height : 1 }

    func toLayout(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scaleX, y: point.y / scaleY)
    }

    func rect(for element: MapElement) -> CGRect {
        guard case .tile(let rect) = element.shape else { return .zero }
        return CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
    }

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var radius: Double { MapLayout.chartRadius(in: size) }

    func path(for element: MapElement) -> Path {
        switch element.shape {
        case .tile:
            return Path(rect(for: element))
        case .wedge(let start, let end):
            let ring = layout.ring(element.depth)
            let inner = ring.inner * radius, outer = ring.outer * radius - 1
            // Angles run clockwise from 12 o'clock; SwiftUI's run from 3 o'clock.
            let from = Angle.radians(start - .pi / 2), to = Angle.radians(end - .pi / 2)
            var path = Path()
            if end - start >= 2 * .pi - 1e-9 {
                path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
                path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
                return path.normalized(eoFill: true)
            }
            path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
            path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
            path.closeSubpath()
            return path
        }
    }

    static func label(for element: MapElement, in tree: ScanTree) -> (name: String, size: String) {
        switch element.item {
        case .node(let node): (tree.name(of: node), element.bytes.formattedBytes)
        case .smallerItems(_, let members): (DiskMapText.smallerItems(members.count), element.bytes.formattedBytes)
        }
    }
}

extension MapItem {
    var isSmallerItems: Bool {
        if case .smallerItems = self { true } else { false }
    }
}
