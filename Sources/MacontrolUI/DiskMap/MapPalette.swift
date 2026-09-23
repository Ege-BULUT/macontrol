import SwiftUI

/// Map colours: one hue per top-level branch, fading toward the background with depth.
///
/// Every pair of branch colours, and each against the "smaller items" grey, is at least CIEDE2000 10
/// apart in normal vision and under deutan and protan simulation (F-0049). DiskMapPaletteTests checks it;
/// research/bench/windirstat-windirstat/palette_probe.py is the reference maths.
nonisolated enum MapPalette {
    struct RGB: Hashable, Sendable {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }

        var color: Color { Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255) }

        /// Whether dark text reads better on this colour (relative luminance above the midpoint).
        var prefersDarkText: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 150 }
    }

    static let branches: [RGB] = [
        RGB(10, 132, 255),   // blue
        RGB(215, 125, 0),    // amber
        RGB(64, 200, 224),   // teal
        RGB(255, 55, 120),   // pink
        RGB(255, 214, 10),   // yellow
        RGB(130, 60, 150),   // plum
        RGB(225, 200, 145),  // sand
        RGB(200, 30, 60),    // crimson
    ]
    static let smallerItems = RGB(152, 152, 157)

    /// Slot for the `index`-th of `count` top-level children. The ring closes on itself, so when the
    /// last child would wrap onto the first child's colour it takes the next slot instead.
    static func slot(for index: Int, of count: Int) -> Int {
        let slot = index % branches.count
        if index == count - 1, index > 0, slot == 0 { return 1 }
        return slot
    }

    /// Slots for the top-level children in size order. `firstSeen[i]` is when a scan first showed the `i`-th child
    /// (T-0063), or nil. A child keeps slot `firstSeen % branches.count` through the scan and on the finished map,
    /// else its rank slot. Earlier-seen children choose first, so when two neighbours (the ring closes) want one
    /// colour, the later-seen one takes a colour neither neighbour has. Without a scan order this is `slot(for:of:)`.
    static func slots(firstSeen: [Int?]) -> [Int] {
        let count = firstSeen.count
        let wanted = firstSeen.indices.map { firstSeen[$0].map { $0 % branches.count } ?? slot(for: $0, of: count) }
        var result = [Int?](repeating: nil, count: count)
        for index in firstSeen.indices.sorted(by: { (firstSeen[$0] ?? .max, $0) < (firstSeen[$1] ?? .max, $1) }) {
            let neighbours = [(index + count - 1) % count, (index + 1) % count].filter { $0 != index }
            let held = neighbours.compactMap { result[$0] }
            guard held.contains(wanted[index]) else {
                result[index] = wanted[index]
                continue
            }
            let avoid = held + neighbours.filter { result[$0] == nil }.map { wanted[$0] }
            result[index] = branches.indices.first { !avoid.contains($0) }
        }
        return result.map { $0 ?? 0 }
    }

    /// Share of the way to the background at `depth`.
    static func fade(atDepth depth: Int) -> Double {
        min(Double(depth) * 0.1, 0.5)
    }

    static func rgb(branch: Int?, depth: Int, dark: Bool) -> RGB {
        let base = branch.map { branches[$0 % branches.count] } ?? smallerItems
        let background = dark ? RGB(30, 30, 32) : RGB(255, 255, 255)
        let t = fade(atDepth: depth)
        return RGB(
            base.red + (background.red - base.red) * t,
            base.green + (background.green - base.green) * t,
            base.blue + (background.blue - base.blue) * t
        )
    }
}
