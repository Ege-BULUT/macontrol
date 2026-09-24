import CoreGraphics
import Foundation
import MacontrolCore

/// Lays out the focus folder as a sunburst or a squarified treemap.
///
/// Angle and area are proportional to allocated bytes, with nothing in between (F-0020). Children too
/// small to see at the display's pixel density merge into one "smaller items" element that lists every
/// member, so nothing is dropped (F-0016, F-0043). The decision uses every child, never a sample (F-0040).
/// Breadth-first with an explicit queue, so tree depth never reaches the call stack.
nonisolated enum MapLayoutBuilder {
    static let maxDepth = 6
    /// A wedge narrower than this, in device pixels along its outer edge, joins "smaller items".
    static let minimumWedgePixels = 4.0
    /// A tile smaller than this area, in device pixels, joins "smaller items".
    static let minimumTilePixels = 100.0
    static let headerHeight = 16.0
    static let inset = 2.0
    static let minimumContainer = CGSize(width: 48, height: 40)

    /// Runs on the cooperative pool, never the main actor; cancelling the calling task stops it.
    @concurrent
    static func layout(of tree: ScanTree, for key: LayoutKey, colours: [String: Int] = [:]) async throws -> MapLayout {
        try build(tree, key, colours: colours)
    }

    /// `colours` is the colour slot a scan gave each name at its top (`MapPalette.ScanColours`), so the preview and
    /// the finished map keep each folder's colour while sizes change rank (T-0063). Names it lacks are coloured by
    /// rank. Ignored below the scan root.
    static func build(_ tree: ScanTree, _ key: LayoutKey, colours: [String: Int] = [:]) throws -> MapLayout {
        let colours = key.focus == ScanTree.root ? colours : [:]
        return switch key.style {
        case .sunburst: try sunburst(tree, key, colours)
        case .treemap: try treemap(tree, key, colours)
        }
    }

    /// Colour slots of the scan root's drawn children, in size order.
    private static func topSlots(_ named: ArraySlice<Int>, _ tree: ScanTree, _ colours: [String: Int]) -> [Int] {
        named.enumerated().map { offset, child in colours[tree.name(of: child)] ?? MapPalette.slot(for: offset, of: named.count) }
    }

    private struct Pending {
        let element: Int?
        let node: Int
        let depth: Int
        let branch: Int?
        let wedge: (start: Double, span: Double)
        let rect: CGRect
    }

    /// Splits sorted children into those big enough to draw and the rest.
    private static func split(_ children: [Int], in tree: ScanTree, isDrawable: (UInt64) -> Bool) -> (named: ArraySlice<Int>, rest: [Int]) {
        let cut = children.firstIndex { !isDrawable(tree.allocatedSize(of: $0)) } ?? children.count
        return (children[..<cut], Array(children[cut...]))
    }

    static func sunburst(_ tree: ScanTree, _ key: LayoutKey, _ colours: [String: Int]) throws -> MapLayout {
        let radius = MapLayout.chartRadius(in: key.size)
        guard tree.allocatedSize(of: key.focus) > 0, radius > 0 else { return .empty(key) }
        let ringWidth = (1 - MapLayout.holeRadius) / Double(maxDepth)
        var elements: [MapElement] = []
        var queue = [Pending(element: nil, node: key.focus, depth: 0, branch: nil, wedge: (0, 2 * .pi), rect: .zero)]
        var next = 0
        var topLevel = 0..<0
        var deepest = 0

        while next < queue.count {
            try Task.checkCancellation()
            let pending = queue[next]
            next += 1
            let total = Double(tree.allocatedSize(of: pending.node))
            // Thresholds use the thinnest ring the layout could have, so a wedge kept here stays visible.
            let outerPixels = radius * (MapLayout.holeRadius + Double(pending.depth + 1) * ringWidth) * key.scale
            let minimumAngle = minimumWedgePixels / outerPixels
            let (named, rest) = split(tree.sortedChildren(of: pending.node), in: tree) {
                pending.wedge.span * Double($0) / total >= minimumAngle
            }
            let first = elements.count
            var cumulative: UInt64 = 0
            func wedge(adding bytes: UInt64) -> MapShape {
                let start = pending.wedge.start + pending.wedge.span * Double(cumulative) / total
                cumulative += bytes
                return .wedge(start: start, end: pending.wedge.start + pending.wedge.span * Double(cumulative) / total)
            }
            let top = pending.branch == nil ? topSlots(named, tree, colours) : []
            for (offset, child) in named.enumerated() {
                let bytes = tree.allocatedSize(of: child)
                let branch = pending.branch ?? top[offset]
                let shape = wedge(adding: bytes)
                elements.append(MapElement(item: .node(child), parent: pending.node, bytes: bytes, depth: pending.depth, branch: branch, shape: shape))
                if pending.depth + 1 < maxDepth, bytes > 0, tree.isExpandable(child), case .wedge(let start, let end) = shape {
                    queue.append(Pending(element: elements.count - 1, node: child, depth: pending.depth + 1, branch: branch, wedge: (start, end - start), rect: .zero))
                }
            }
            if !rest.isEmpty {
                let bytes = rest.reduce(0) { $0 + tree.allocatedSize(of: $1) }
                elements.append(MapElement(
                    item: .smallerItems(parent: pending.node, members: rest), parent: pending.node,
                    bytes: bytes, depth: pending.depth, branch: nil, shape: wedge(adding: bytes)
                ))
            }
            if elements.count > first { deepest = max(deepest, pending.depth) }
            attach(first..<elements.count, to: pending.element, in: &elements, topLevel: &topLevel)
        }
        return MapLayout(key: key, elements: elements, topLevel: topLevel, ringCount: elements.isEmpty ? 0 : deepest + 1)
    }

    static func treemap(_ tree: ScanTree, _ key: LayoutKey, _ colours: [String: Int]) throws -> MapLayout {
        let bounds = CGRect(origin: .zero, size: key.size)
        guard tree.allocatedSize(of: key.focus) > 0, bounds.width > 0, bounds.height > 0 else { return .empty(key) }
        let minimumArea = minimumTilePixels / (key.scale * key.scale)
        var elements: [MapElement] = []
        var queue = [Pending(element: nil, node: key.focus, depth: 0, branch: nil, wedge: (0, 0), rect: bounds)]
        var next = 0
        var topLevel = 0..<0

        while next < queue.count {
            try Task.checkCancellation()
            let pending = queue[next]
            next += 1
            let totalBytes = tree.allocatedSize(of: pending.node)
            let total = Double(totalBytes)
            let area = pending.rect.width * pending.rect.height
            let (named, rest) = split(tree.sortedChildren(of: pending.node), in: tree) {
                area * Double($0) / total >= minimumArea
            }

            // Entries in squarify order. The folder's own bytes (its directory entries) take their share
            // of the area as an undrawn gap, so every drawn tile keeps exact proportions.
            enum Entry { case child(Int, branch: Int), smallerItems, gap }
            let top = pending.branch == nil ? topSlots(named, tree, colours) : []
            var entries: [(entry: Entry, bytes: UInt64)] = named.enumerated().map { offset, child in
                (.child(child, branch: pending.branch ?? top[offset]), tree.allocatedSize(of: child))
            }
            let restBytes = rest.reduce(0) { $0 + tree.allocatedSize(of: $1) }
            if !rest.isEmpty { entries.append((.smallerItems, restBytes)) }
            let childBytes = entries.reduce(0) { $0 + $1.bytes }
            if childBytes < totalBytes { entries.append((.gap, totalBytes - childBytes)) }
            entries.sort { $0.bytes > $1.bytes }

            let first = elements.count
            for (entry, rect) in zip(entries, Squarify.rects(for: entries.map { Double($0.bytes) }, in: pending.rect)) {
                switch entry.entry {
                case .gap:
                    continue
                case .smallerItems:
                    elements.append(MapElement(
                        item: .smallerItems(parent: pending.node, members: rest), parent: pending.node,
                        bytes: restBytes, depth: pending.depth, branch: nil, shape: .tile(rect)
                    ))
                case .child(let child, let branch):
                    elements.append(MapElement(item: .node(child), parent: pending.node, bytes: entry.bytes, depth: pending.depth, branch: branch, shape: .tile(rect)))
                    if pending.depth + 1 < maxDepth, entry.bytes > 0, tree.isExpandable(child),
                       rect.width >= minimumContainer.width, rect.height >= minimumContainer.height {
                        let content = CGRect(
                            x: rect.minX + inset, y: rect.minY + headerHeight,
                            width: rect.width - 2 * inset, height: rect.height - headerHeight - inset
                        )
                        queue.append(Pending(element: elements.count - 1, node: child, depth: pending.depth + 1, branch: branch, wedge: (0, 0), rect: content))
                    }
                }
            }
            attach(first..<elements.count, to: pending.element, in: &elements, topLevel: &topLevel)
        }
        return MapLayout(key: key, elements: elements, topLevel: topLevel, ringCount: 0)
    }

    private static func attach(_ block: Range<Int>, to parent: Int?, in elements: inout [MapElement], topLevel: inout Range<Int>) {
        if let parent { elements[parent].children = block } else { topLevel = block }
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk 2000): rows along the shorter side, each row grown while
/// its worst aspect ratio improves. Areas are exactly proportional to `values`.
nonisolated enum Squarify {
    /// `values` sorted largest first; returns one rect per value, in the same order.
    static func rects(for values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else {
            return values.map { _ in CGRect(origin: bounds.origin, size: .zero) }
        }
        let areas = values.map { $0 / total * bounds.width * bounds.height }
        var result: [CGRect] = []
        result.reserveCapacity(values.count)
        var remaining = bounds
        var start = 0
        while start < areas.count {
            let side = min(remaining.width, remaining.height)
            var end = start + 1
            var rowArea = areas[start]
            while end < areas.count, worst(areas[start..<end + 1], rowArea + areas[end], side) <= worst(areas[start..<end], rowArea, side) {
                rowArea += areas[end]
                end += 1
            }
            let isLastRow = end == areas.count
            let horizontal = remaining.width >= remaining.height
            // The last row takes whatever is left, so rounding never leaves a sliver or an overflow.
            let thickness = isLastRow ? (horizontal ? remaining.width : remaining.height) : (rowArea > 0 ? rowArea / side : 0)
            var offset = 0.0
            for index in start..<end {
                let length = rowArea > 0 ? areas[index] / rowArea * side : 0
                result.append(horizontal
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness))
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end
        }
        return result
    }

    /// The row's worst aspect ratio (≥ 1) if its items are laid along a side of length `side`.
    /// The row is sorted largest first, so its ends are its extremes.
    private static func worst(_ row: ArraySlice<Double>, _ rowArea: Double, _ side: Double) -> Double {
        guard rowArea > 0, side > 0, let largest = row.first, let smallest = row.last, smallest > 0 else { return .infinity }
        let sideSquared = side * side, areaSquared = rowArea * rowArea
        return max(sideSquared * largest / areaSquared, areaSquared / (sideSquared * smallest))
    }
}
