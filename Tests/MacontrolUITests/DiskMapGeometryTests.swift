import CoreGraphics
import Foundation
import MacontrolCore
@testable import MacontrolUI
import Testing

@Suite struct DiskMapGeometryTests {
    /// Every block of siblings in a layout, with the folder they belong to.
    private func blocks(_ layout: MapLayout) -> [(parent: Int?, node: Int, range: Range<Int>)] {
        var result = [(parent: Int?.none, node: layout.key.focus, range: layout.topLevel)]
        for (index, element) in layout.elements.enumerated() where !element.children.isEmpty {
            result.append((index, element.node!, element.children))
        }
        return result
    }

    @Test func wedgeAnglesAreProportionalAndSumToTheParentShare() throws {
        let tree = DiskMapFixtures.mixed()
        let layout = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(.sunburst))
        #expect(layout.elements.count > 40)
        for block in blocks(layout) {
            let (start, end) = block.parent.map { index -> (Double, Double) in
                guard case .wedge(let start, let end) = layout.elements[index].shape else { return (0, 0) }
                return (start, end)
            } ?? (0, 2 * .pi)
            let total = Double(tree.allocatedSize(of: block.node))
            var sum = 0.0
            var childBytes: UInt64 = 0
            for index in block.range {
                guard case .wedge(let wedgeStart, let wedgeEnd) = layout.elements[index].shape else { Issue.record("not a wedge"); continue }
                let angle = wedgeEnd - wedgeStart
                #expect(abs(angle - (end - start) * Double(layout.elements[index].bytes) / total) < 1e-9)
                sum += angle
                childBytes += layout.elements[index].bytes
            }
            #expect(abs(sum - (end - start) * Double(childBytes) / total) < 1e-9)
        }
    }

    @Test func treemapAreasAreProportionalToBytes() throws {
        let tree = DiskMapFixtures.mixed()
        let key = DiskMapFixtures.key(.treemap)
        let layout = try MapLayoutBuilder.build(tree, key)
        var checked = 0
        for block in blocks(layout) {
            let container: CGRect = block.parent.map { index in
                guard case .tile(let rect) = layout.elements[index].shape else { return .zero }
                let inset = MapLayoutBuilder.inset
                return CGRect(x: rect.minX + inset, y: rect.minY + MapLayoutBuilder.headerHeight,
                              width: rect.width - 2 * inset, height: rect.height - MapLayoutBuilder.headerHeight - inset)
            } ?? CGRect(origin: .zero, size: key.size)
            let total = Double(tree.allocatedSize(of: block.node))
            for index in block.range where layout.elements[index].bytes > 0 {
                guard case .tile(let rect) = layout.elements[index].shape else { Issue.record("not a tile"); continue }
                let expected = container.width * container.height * Double(layout.elements[index].bytes) / total
                #expect(abs(rect.width * rect.height - expected) / expected < 0.005, "element \(index)")
                #expect(container.insetBy(dx: -1e-6, dy: -1e-6).contains(rect))
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    @Test(arguments: MapStyle.allCases)
    func everyChildIsDrawnOrListedInSmallerItems(style: MapStyle) throws {
        let tree = DiskMapFixtures.mixed()
        let layout = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style))
        var sawSmallerItems = false
        for block in blocks(layout) {
            var seen: [Int] = []
            for index in block.range {
                let element = layout.elements[index]
                #expect(element.parent == block.node)
                switch element.item {
                case .node(let node):
                    seen.append(node)
                case .smallerItems(_, let members):
                    sawSmallerItems = true
                    seen += members
                    #expect(element.bytes == members.reduce(0) { $0 + tree.allocatedSize(of: $1) })
                }
            }
            #expect(seen.sorted() == tree.children(of: block.node).sorted(), "folder \(block.node)")
        }
        #expect(sawSmallerItems)
    }

    /// F-0040: one huge file among thousands of tiny ones is drawn on its own, whatever its position.
    @Test func aHugeFileAmongTinyFilesIsNeverMergedAway() throws {
        var builder = DiskMapFixtures.Builder()
        let folder = builder.folder(ScanTree.root, "mixed")
        for index in 0..<6_000 { builder.file(folder, "tiny-\(index)", 1_024) }
        let huge = builder.file(folder, "huge.bin", 2 << 30)
        let tree = builder.finished()
        for style in MapStyle.allCases {
            let layout = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style, focus: folder))
            let top = layout.topLevel.map { layout.elements[$0] }
            #expect(top.contains { $0.node == huge })
            let merged = top.compactMap { element -> [Int]? in
                if case .smallerItems(_, let members) = element.item { members } else { nil }
            }
            #expect(merged.first?.count == 6_000)
        }
    }

    /// F-0043: thresholds are in device pixels, so a Retina layout resolves more items, never fewer.
    @Test func smallItemThresholdIsInDevicePixels() throws {
        let tree = DiskMapFixtures.mixed(seed: 11, folders: 120)
        for style in MapStyle.allCases {
            let standard = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style, scale: 1))
            let retina = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style, scale: 2))
            let named = { (layout: MapLayout) in layout.elements.filter { $0.node != nil }.count }
            #expect(named(retina) > named(standard), "\(style)")
        }
        let treemap = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(.treemap, scale: 2))
        for element in treemap.elements where element.node != nil {
            guard case .tile(let rect) = element.shape else { continue }
            #expect(rect.width * rect.height * 4 >= MapLayoutBuilder.minimumTilePixels - 1e-6)
        }
    }

    @Test(arguments: MapStyle.allCases)
    func hitTestFindsEveryLeafElement(style: MapStyle) throws {
        let tree = DiskMapFixtures.mixed()
        let layout = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style))
        let radius = MapLayout.chartRadius(in: layout.size)
        var checked = 0
        for (index, element) in layout.elements.enumerated() where element.children.isEmpty && element.bytes > 0 {
            let point: CGPoint
            switch element.shape {
            case .tile(let rect):
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                point = CGPoint(x: rect.midX, y: rect.midY)
            case .wedge(let start, let end):
                let ring = layout.ring(element.depth)
                let angle = (start + end) / 2, distance = (ring.inner + ring.outer) / 2 * radius
                point = CGPoint(x: layout.size.width / 2 + distance * sin(angle), y: layout.size.height / 2 - distance * cos(angle))
            }
            #expect(layout.element(at: point) == index)
            checked += 1
        }
        #expect(checked > 50)
        if style == .sunburst {
            let center = CGPoint(x: layout.size.width / 2, y: layout.size.height / 2)
            #expect(layout.element(at: center) == nil)
            #expect(layout.isInCenter(center))
        }
    }

    @Test func squarifiedRectsTileTheBoundsExactly() {
        let values: [Double] = [600, 300, 200, 120, 60, 30, 10, 5, 0]
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 250)
        let rects = Squarify.rects(for: values, in: bounds)
        #expect(rects.count == values.count)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            #expect(abs(rect.width * rect.height - bounds.width * bounds.height * value / total) < 1e-6)
            #expect(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(rect) || rect.isEmpty)
        }
        for (first, second) in zip(rects.indices, rects.indices.dropFirst()) {
            #expect(rects[first].intersection(rects[second]).width * rects[first].intersection(rects[second]).height < 1e-6)
        }
    }

    @Test func aFourThousandLevelChainLaysOutWithoutRecursion() throws {
        let depth = 4_000
        let tree = DiskMapFixtures.chain(depth: depth)
        let bottomFolder = tree.count - 2
        #expect(tree.path(to: tree.count - 1).count == depth + 2)
        #expect(tree.url(of: tree.count - 1).pathComponents.count == DiskMapFixtures.missingRoot.pathComponents.count + depth + 1)
        for focus in [ScanTree.root, depth / 2, bottomFolder] {
            for style in MapStyle.allCases {
                let layout = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style, focus: focus))
                #expect(!layout.elements.isEmpty)
                #expect(layout.elements.count <= MapLayoutBuilder.maxDepth)
            }
        }
    }

    @Test func layoutStopsWhenCancelled() async {
        let tree = DiskMapFixtures.mixed()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MapLayoutBuilder.build(tree, DiskMapFixtures.key(.sunburst))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 1,010,101 nodes: 100 folders × 100 folders × 100 files. Prints the focus-level layout time.
    @Test func millionNodeFocusLayoutTime() throws {
        var builder = DiskMapFixtures.Builder()
        var random = SeededRandom(seed: 3)
        for outer in 0..<100 {
            let top = builder.folder(ScanTree.root, "top-\(outer)")
            for inner in 0..<100 {
                let folder = builder.folder(top, "mid-\(inner)")
                for leaf in 0..<100 { builder.file(folder, "f\(leaf)", UInt64(random.next(in: 1...5_000_000))) }
            }
        }
        let tree = builder.finished()
        #expect(tree.count == 1_010_101)
        for style in MapStyle.allCases {
            let clock = ContinuousClock()
            var layout: MapLayout?
            let elapsed = try clock.measure { layout = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(style, width: 1000, height: 700)) }
            print("disk-map layout, 1,010,101 nodes, \(style): \(elapsed.formatted(.units(allowed: [.milliseconds]))) for \(layout?.elements.count ?? 0) elements")
            #expect(elapsed < .seconds(10))
        }
    }
}
