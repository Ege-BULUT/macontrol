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

    /// Colours of the folders at the top of a scan, carried from one preview to the next and onto the finished
    /// map, so a folder keeps its colour while sizes change rank (T-0063). Colour by rank reshuffled most of the
    /// legend on every preview. A scan of the same folder starts from the colours of its last finished map.
    /// The finished map never puts one colour on two neighbours; while a scan runs, two touching wedges below the
    /// largest can share one, in about 1 preview in 12 of a random sweep (see `finish` for why).
    struct ScanColours: Equatable {
        /// Each coloured name's slot in `branches`.
        private(set) var slots: [String: Int] = [:]
        /// The largest names at the last update.
        private var largest: Set<String> = []
        /// The largest names of the finished map these colours come from.
        private var kept: Set<String> = []

        /// `ranked` is the names with bytes, largest first; a name without bytes is not drawn and gets no colour.
        /// The `branches.count` largest always have different colours. Each keeps its colour unless one of them
        /// chose it first, and then takes the lowest free one. The last finished map's largest choose first, then
        /// the ones that were largest last time, then the rest by size. A smaller name keeps the first colour it
        /// gets: its rank slot, or the lowest one its neighbours lack.
        mutating func update(ranked: [String]) {
            let largest = Array(ranked.prefix(branches.count))
            func turn(_ index: Int) -> (Int, Int) {
                (kept.contains(largest[index]) ? 0 : self.largest.contains(largest[index]) ? 1 : 2, index)
            }
            var taken = Set<Int>()
            for index in largest.indices.sorted(by: { turn($0) < turn($1) }) {
                let slot = slots[largest[index]].flatMap { taken.contains($0) ? nil : $0 } ?? branches.indices.first { !taken.contains($0) } ?? 0
                slots[largest[index]] = slot
                taken.insert(slot)
            }
            for index in ranked.indices.dropFirst(branches.count) where slots[ranked[index]] == nil {
                slots[ranked[index]] = slot(at: index, of: ranked)
            }
            self.largest = Set(largest)
        }

        /// The last update, for the finished map, and again whenever its tree changes. Smaller names that sit next
        /// to one of their colour get a new one. Previews skip this: doing it on every preview flipped colours back
        /// and forth while two folders of about one size swapped places. A later scan of the folder keeps this
        /// map's largest colours.
        mutating func finish(ranked: [String]) {
            update(ranked: ranked)
            for index in ranked.indices.dropFirst(branches.count) where neighbourSlots(at: index, of: ranked).contains(slots[ranked[index]] ?? -1) {
                slots[ranked[index]] = slot(at: index, of: ranked)
            }
            kept = largest
        }

        /// The sunburst's ring closes, so the last name's other neighbour is the first.
        private func neighbourSlots(at index: Int, of ranked: [String]) -> [Int] {
            [index - 1, index + 1].map { ($0 + ranked.count) % ranked.count }.filter { $0 != index }.compactMap { slots[ranked[$0]] }
        }

        /// The rank slot, unless a neighbour has it.
        private func slot(at index: Int, of ranked: [String]) -> Int {
            let neighbours = neighbourSlots(at: index, of: ranked)
            let rank = index % branches.count
            return neighbours.contains(rank) ? branches.indices.first { !neighbours.contains($0) } ?? rank : rank
        }
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
