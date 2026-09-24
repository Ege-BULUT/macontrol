import Foundation
@testable import MacontrolUI
import Testing

/// F-0049: every pair of map colours stays distinguishable for deuteranopes and protanopes.
/// The maths is a port of research/bench/windirstat-windirstat/palette_probe.py
/// (Machado 2009 CVD simulation at severity 1, CIEDE2000).
@Suite struct DiskMapPaletteTests {
    typealias RGB = MapPalette.RGB

    @Test func everyPairOfBranchColoursIsAtLeastTenApartUnderDeutanAndProtan() {
        let colours = MapPalette.branches + [MapPalette.smallerItems]
        var closest = Double.infinity
        for first in colours.indices {
            for second in colours.indices where second > first {
                for vision in Vision.allCases {
                    let distance = Self.de2000(vision.simulate(colours[first]), vision.simulate(colours[second]))
                    closest = min(closest, distance)
                    #expect(distance >= 10, "\(colours[first]) vs \(colours[second]) under \(vision): \(distance)")
                }
            }
        }
        print("disk-map palette: closest pair dE00 \(closest.formatted(.number.precision(.fractionLength(2))))")
    }

    /// The probe's own reference value, so the port is checked against the Python it copies.
    @Test func portMatchesTheProbe() {
        let green = RGB(0, 255, 0), yellow = RGB(255, 255, 0)
        #expect(abs(Self.de2000(Vision.deutan.simulate(green), Vision.deutan.simulate(yellow)) - Self.probeDeutanGreenYellow) < 0.01)
    }

    @Test func theRingNeverClosesOnTwoNeighboursOfOneColour() {
        let count = MapPalette.branches.count
        for total in 2...(count * 3 + 1) {
            let slots = (0..<total).map { MapPalette.slot(for: $0, of: total) }
            for index in slots.indices {
                #expect(slots[index] != slots[(index + 1) % total], "\(total) branches, index \(index)")
            }
        }
    }

    /// T-0063 review 3: through a scan's previews the eight largest names always have eight colours, and a name
    /// changes colour only in the update that brings it among them. The finished map puts no colour on two
    /// neighbours, the ring's last and first included (review 4: 45 of 500 maps did), and a later scan of the folder keeps its eight largest colours whatever order the walk finds
    /// things in. Colours fixed by first sight, zero-byte names included, gave two of the finished map's eight
    /// largest one colour in 409 of 500 such scans.
    @Test func scanColoursKeepTheLargestApartAndEachNameSteady() {
        let count = MapPalette.branches.count
        var random = SeededRandom(seed: 11)
        var changes = 0, updates = 0
        for _ in 0..<500 {
            let names = (0..<random.next(in: 1...40)).map { "n\($0)" }
            let final = names.map { _ in UInt64(1) << random.next(in: 10...36) }
            // Each name fills in over its own stretch of the walk; by step 60 all have their final size.
            func walk() -> (Int) -> [String] {
                let start = names.map { _ in random.next(in: 0...30) }, span = names.map { _ in random.next(in: 1...30) }
                return { step in
                    let sizes = names.indices.map { UInt64(Double(final[$0]) * min(1, max(0, Double(step - start[$0]) / Double(span[$0])))) }
                    return names.indices.filter { sizes[$0] > 0 }.sorted { (sizes[$1], names[$0]) < (sizes[$0], names[$1]) }.map { names[$0] }
                }
            }
            var colours = MapPalette.ScanColours()
            var largest: Set<String> = []
            let first = walk()
            for step in 0...60 {
                let before = colours.slots, ranked = first(step)
                colours.update(ranked: ranked)
                updates += 1
                let top = ranked.prefix(count)
                #expect(Set(top.compactMap { colours.slots[$0] }).count == top.count, "\(ranked) -> \(colours.slots)")
                #expect(ranked.allSatisfy { colours.slots[$0] != nil })
                for (name, slot) in before where colours.slots[name] != slot {
                    changes += 1
                    #expect(top.contains(name) && !largest.contains(name), "\(name) changed colour at step \(step)")
                }
                largest = Set(top)
            }
            let ranked = first(60)
            colours.finish(ranked: ranked)
            #expect(Set(ranked.prefix(count).compactMap { colours.slots[$0] }).count == min(count, ranked.count))
            // The sunburst's ring closes: the last name also touches the first.
            for index in ranked.indices where ranked.count > 1 {
                #expect(colours.slots[ranked[index]] != colours.slots[ranked[(index + 1) % ranked.count]], "neighbours \(index), \((index + 1) % ranked.count): \(ranked)")
            }

            let kept = ranked.prefix(count).map { ($0, colours.slots[$0]) }
            let again = walk()
            for step in 0...60 {
                colours.update(ranked: again(step))
                #expect(kept.allSatisfy { colours.slots[$0.0] == $0.1 }, "a rescan moved a colour of the last map's largest at step \(step)")
            }
        }
        print("scan colours: \(changes) colour changes in \(updates) updates")
    }

    // MARK: Reference maths

    /// Printed by `python3 -c "from palette_probe import *; print(de2000(simulate((0,255,0),'deutan'), simulate((255,255,0),'deutan')))"`.
    static let probeDeutanGreenYellow = 8.7811

    enum Vision: CaseIterable {
        case normal, deutan, protan

        private var matrix: [[Double]]? {
            switch self {
            case .normal: nil
            case .deutan: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
            case .protan: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
            }
        }

        func simulate(_ colour: RGB) -> RGB {
            guard let matrix else { return colour }
            let linear = [colour.red, colour.green, colour.blue].map(DiskMapPaletteTests.linear)
            let out = matrix.map { row in (DiskMapPaletteTests.gamma(zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 }) * 255).rounded() }
            return RGB(out[0], out[1], out[2])
        }
    }

    static func linear(_ value: Double) -> Double {
        let unit = value / 255
        return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ value: Double) -> Double {
        let unit = min(max(value, 0), 1)
        return unit <= 0.0031308 ? 12.92 * unit : 1.055 * pow(unit, 1 / 2.4) - 0.055
    }

    static func lab(_ colour: RGB) -> (l: Double, a: Double, b: Double) {
        let (r, g, b) = (linear(colour.red), linear(colour.green), linear(colour.blue))
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func de2000(_ first: RGB, _ second: RGB) -> Double {
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func degrees(_ radians: Double) -> Double {
            let value = radians * 180 / .pi
            return value < 0 ? value + 360 : value
        }
        let (l1, a1, b1) = lab(first), (l2, a2, b2) = lab(second)
        let meanC = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - sqrt(pow(meanC, 7) / (pow(meanC, 7) + pow(25, 7))))
        let (a1p, a2p) = (a1 * (1 + g), a2 * (1 + g))
        let (c1p, c2p) = (hypot(a1p, b1), hypot(a2p, b2))
        let (h1p, h2p) = (degrees(atan2(b1, a1p)), degrees(atan2(b2, a2p)))
        var dh = h2p - h1p
        if c1p * c2p == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dL = l2 - l1, dC = c2p - c1p
        let dH = 2 * sqrt(c1p * c2p) * sin(radians(dh / 2))
        let meanL = (l1 + l2) / 2, meanCp = (c1p + c2p) / 2
        let meanH: Double = if c1p * c2p == 0 {
            h1p + h2p
        } else if abs(h1p - h2p) > 180 {
            h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2
        } else {
            (h1p + h2p) / 2
        }
        let t = 1 - 0.17 * cos(radians(meanH - 30)) + 0.24 * cos(radians(2 * meanH))
            + 0.32 * cos(radians(3 * meanH + 6)) - 0.20 * cos(radians(4 * meanH - 63))
        let dTheta = 30 * exp(-pow((meanH - 275) / 25, 2))
        let rc = 2 * sqrt(pow(meanCp, 7) / (pow(meanCp, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(meanL - 50, 2) / sqrt(20 + pow(meanL - 50, 2))
        let sc = 1 + 0.045 * meanCp, sh = 1 + 0.015 * meanCp * t
        let rt = -sin(radians(2 * dTheta)) * rc
        return sqrt(pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dH / sh, 2) + rt * (dC / sc) * (dH / sh))
    }
}
