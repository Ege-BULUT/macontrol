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

    /// Slots for the top-level children in size order. `preferred[i]` is a colour the `i`-th child keeps (a scan's
    /// first-seen colours, T-0063), or nil for its rank slot. A child whose colour matches the one before it, or the
    /// first one when it is the last, takes the first colour neither neighbour nor the next child wants.
    static func slots(preferring preferred: [Int?]) -> [Int] {
        let wanted = preferred.indices.map { preferred[$0] ?? slot(for: $0, of: preferred.count) }
        var result: [Int] = []
        for (index, slot) in wanted.enumerated() {
            var taken = [result.last]
            if index == wanted.count - 1, index > 0 { taken.append(result.first) }
            guard taken.contains(slot) else {
                result.append(slot)
                continue
            }
            if index + 1 < wanted.count { taken.append(wanted[index + 1]) }
            result.append(branches.indices.first { !taken.contains($0) } ?? slot)
        }
        return result
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
