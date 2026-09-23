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

    /// T-0063 review 2: colours a scan fixed by first sight never put one colour on two neighbours (the ring
    /// closes), with more names than colours too. The name seen earlier keeps its colour and the later one gives
    /// way, so the first eight names seen never change colour. Without a scan order, these are the rank slots.
    @Test func firstSeenColoursKeepNeighboursApartAndTheEarliestNames() {
        let count = MapPalette.branches.count
        for total in 1...(count * 3 + 1) {
            #expect(MapPalette.slots(firstSeen: Array(repeating: nil, count: total)) == (0..<total).map { MapPalette.slot(for: $0, of: total) })
        }
        // The ninth name seen wants the first one's colour and has grown past it, so they sit side by side.
        let grown = MapPalette.slots(firstSeen: [8, 0, 1, 2, 3, 4, 5, 6, 7])
        #expect(grown[1] == 0, "the first name seen keeps its colour: \(grown)")
        #expect(grown[0] != 0 && grown[0] != grown[8], "the ninth gives way, also to its ring neighbour: \(grown)")

        var random = SeededRandom(seed: 11)
        for _ in 0..<2_000 {
            let total = random.next(in: 1...40)
            var seen = Array(0..<(total + 10))
            for index in seen.indices.reversed() { seen.swapAt(index, random.next(in: 0...index)) }
            let order: [Int?] = (0..<total).map { random.next(in: 0...4) == 0 ? nil : seen[$0] }
            let slots = MapPalette.slots(firstSeen: order)
            for index in slots.indices where total > 1 {
                #expect(slots[index] != slots[(index + 1) % total], "\(order) -> \(slots)")
            }
            for (index, first) in order.enumerated() {
                if let first, first < count { #expect(slots[index] == first, "\(order) -> \(slots)") }
            }
        }
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
