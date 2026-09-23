import CoreGraphics
import Foundation
import MacontrolCore

nonisolated enum MapStyle: String, CaseIterable, Sendable {
    case sunburst
    case treemap
}

/// What one drawn element stands for.
nonisolated enum MapItem: Hashable, Sendable {
    case node(Int)
    /// Children of `parent` too small to draw one by one, merged into one element (F-0016).
    case smallerItems(parent: Int, members: [Int])
}

nonisolated enum MapShape: Sendable, Equatable {
    /// Angles in radians, clockwise from 12 o'clock. The ring comes from the element's depth.
    case wedge(start: Double, end: Double)
    /// In the layout's own coordinate space (`MapLayout.size`).
    case tile(CGRect)
}

nonisolated struct MapElement: Sendable {
    let item: MapItem
    /// The folder whose children this element belongs to.
    let parent: Int
    let bytes: UInt64
    /// 0 for the children of the focus.
    let depth: Int
    /// Palette slot of the top-level branch; `nil` for "smaller items".
    let branch: Int?
    let shape: MapShape
    /// Elements laid out inside this one. Children of one parent are always contiguous.
    var children: Range<Int> = 0..<0

    var node: Int? {
        if case .node(let index) = item { index } else { nil }
    }
}

/// Everything needed to ask for a layout. Also the cache key: a layout depends on nothing else.
nonisolated struct LayoutKey: Hashable, Sendable {
    var treeVersion: Int
    var focus: Int
    var style: MapStyle
    /// Whole points, so sub-point window jitter does not relayout.
    var width: Int
    var height: Int
    /// Device pixels per point. Thresholds are in device pixels (F-0043).
    var scale: Double

    var size: CGSize { CGSize(width: width, height: height) }
}

/// A laid-out map: elements in breadth-first order, each parent's children in one contiguous block.
nonisolated struct MapLayout: Sendable {
    /// Share of the chart radius left empty in the middle of a sunburst.
    static let holeRadius = 0.22

    let key: LayoutKey
    let elements: [MapElement]
    /// Elements that show the focus's own children.
    let topLevel: Range<Int>
    /// Rings drawn, for a sunburst.
    let ringCount: Int

    var size: CGSize { key.size }

    static func empty(_ key: LayoutKey) -> MapLayout {
        MapLayout(key: key, elements: [], topLevel: 0..<0, ringCount: 0)
    }

    /// Normalized radii (0 = centre, 1 = chart edge) of the ring at `depth`.
    func ring(_ depth: Int) -> (inner: Double, outer: Double) {
        let width = (1 - Self.holeRadius) / Double(max(ringCount, 1))
        return (Self.holeRadius + Double(depth) * width, Self.holeRadius + Double(depth + 1) * width)
    }

    /// The deepest element under `point` (layout coordinates). Descends the hierarchy, so the cost is
    /// siblings × depth, not the element count.
    func element(at point: CGPoint) -> Int? {
        let polar = polarPosition(of: point)
        var candidates = topLevel
        var found: Int?
        while let hit = candidates.first(where: { reaches(elements[$0], point: point, polar: polar) }) {
            found = hit
            candidates = elements[hit].children
        }
        // Past the outermost drawn ring of this branch is empty space.
        if let found, case .wedge = elements[found].shape, polar.radius >= ring(elements[found].depth).outer {
            return nil
        }
        return found
    }

    /// True when `point` is in the empty centre of a sunburst (click there to go up).
    func isInCenter(_ point: CGPoint) -> Bool {
        key.style == .sunburst && polarPosition(of: point).radius < Self.holeRadius
    }

    /// Whether `point` is inside the element, or (for a wedge) in its angle and at or beyond its ring,
    /// which is where its children are.
    private func reaches(_ element: MapElement, point: CGPoint, polar: (radius: Double, angle: Double)) -> Bool {
        switch element.shape {
        case .tile(let rect):
            rect.contains(point)
        case .wedge(let start, let end):
            polar.angle >= start && polar.angle < end && polar.radius >= ring(element.depth).inner
        }
    }

    /// Radius normalized to the chart radius, angle clockwise from 12 o'clock in [0, 2π).
    func polarPosition(of point: CGPoint) -> (radius: Double, angle: Double) {
        let radius = Self.chartRadius(in: size)
        guard radius > 0 else { return (.infinity, 0) }
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return (hypot(dx, dy) / radius, angle)
    }

    static func chartRadius(in size: CGSize) -> Double {
        max(0, min(size.width, size.height) / 2 - 8)
    }
}

extension ScanTree {
    /// Children by allocated size, largest first; ties by name so the order is stable.
    nonisolated func sortedChildren(of index: Int) -> [Int] {
        children(of: index).sorted {
            let left = allocatedSize(of: $0), right = allocatedSize(of: $1)
            return left != right ? left > right : name(of: $0) < name(of: $1)
        }
    }

    nonisolated func isExpandable(_ index: Int) -> Bool {
        let flags = flags(of: index)
        return flags.contains(.directory) && !flags.contains(.package) && !flags.contains(.mountPoint)
    }

    /// Ancestors from the scan root down to `index`, both included. Iterative, so any depth works.
    nonisolated func path(to index: Int) -> [Int] {
        var result: [Int] = []
        var node: Int? = index
        while let current = node {
            result.append(current)
            node = parent(of: current)
        }
        return result.reversed()
    }
}
