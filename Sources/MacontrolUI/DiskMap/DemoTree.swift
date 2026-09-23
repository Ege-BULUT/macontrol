import Foundation
import MacontrolCore

extension DiskMapModel {
    /// A plausible home folder with a selection and two staged items. Touches no real files.
    static func demo() -> DiskMapModel {
        let tree = ScanTree.demo()
        let model = DiskMapModel(engine: nil, trash: nil, tree: tree)
        let named = { (name: String) in (0..<tree.count).first { tree.name(of: $0) == name } }
        if let derivedData = named("DerivedData"), let installer = named("Xcode_26.6.xip") {
            model.stage(derivedData)
            model.stage(installer)
        }
        model.selection = named("Library").map(MapItem.node)
        return model
    }
}

extension ScanTree {
    /// About 1,100 nodes shaped like a developer's home folder, sizes fixed by a seeded generator.
    static func demo() -> ScanTree {
        var demo = DemoBuilder(root: URL(fileURLWithPath: "/Users/demo"))
        let root = ScanTree.root

        let library = demo.folder(root, "Library")
        let developer = demo.folder(library, "Developer")
        let derivedData = demo.folder(demo.folder(developer, "Xcode"), "DerivedData")
        for (name, gigabytes) in [("Macontrol-bfk", 6.8), ("Radiant-cqa", 4.1), ("Weather-dzl", 2.2), ("Notes-emx", 0.9)] {
            let project = demo.folder(derivedData, name)
            demo.file(demo.folder(project, "Build"), "Intermediates.noindex", gigabytes * 0.7)
            demo.file(demo.folder(project, "Index.noindex"), "DataStore", gigabytes * 0.3)
        }
        let devices = demo.folder(demo.folder(developer, "CoreSimulator"), "Devices")
        for index in 1...5 { demo.file(devices, "Simulator-\(index)", Double(index) * 1.1 + 2) }
        let caches = demo.folder(library, "Caches")
        for (name, gigabytes) in [("com.spotify.client", 2.4), ("Homebrew", 1.8), ("com.apple.Safari", 0.9), ("pip", 0.6)] {
            demo.file(caches, name, gigabytes)
        }
        demo.files(caches, prefix: "com.example.cache", ext: "", count: 40, megabytes: 1...60)
        let support = demo.folder(library, "Application Support")
        let steam = demo.folder(support, "Steam")
        for (name, gigabytes) in [("Portal 2", 12.4), ("Hades", 8.1), ("Celeste", 1.2)] { demo.file(steam, name, gigabytes) }
        demo.file(demo.folder(support, "MobileSync"), "Backup", 18.2)
        demo.file(support, "Code", 2.1)
        demo.file(support, "Slack", 1.2)
        demo.files(support, prefix: "app-support", ext: "", count: 30, megabytes: 1...90)
        demo.folder(library, "Mail", flags: .unreadable)
        let iCloud = demo.folder(library, "Mobile Documents")
        demo.files(iCloud, prefix: "Keynote", ext: ".key", count: 12, megabytes: 20...400, flags: .dataless, charged: false)
        demo.files(library, prefix: "Preferences-", ext: ".plist", count: 60, megabytes: 0.01...0.4)

        let movies = demo.folder(root, "Movies")
        demo.file(movies, "Holiday.fcpbundle", 22.4, flags: [.directory, .package])
        demo.files(movies, prefix: "Clip", ext: ".mov", count: 14, megabytes: 200...2_400)

        let pictures = demo.folder(root, "Pictures")
        demo.file(pictures, "Photos Library.photoslibrary", 38.6, flags: [.directory, .package])
        demo.files(pictures, prefix: "IMG_", ext: ".heic", count: 180, megabytes: 1...6)

        let projects = demo.folder(root, "projects")
        for (name, weight) in [("macontrol", 3.2), ("website", 1.9), ("ml-sandbox", 7.4), ("game-jam", 2.6), ("dotfiles", 0.05)] {
            let project = demo.folder(projects, name)
            let megabytes = weight * 1_000
            demo.files(demo.folder(project, "node_modules"), prefix: "package-", ext: "", count: 25, megabytes: megabytes * 0.004...megabytes * 0.05)
            demo.files(demo.folder(project, ".git"), prefix: "pack-", ext: ".pack", count: 4, megabytes: megabytes * 0.02...megabytes * 0.08)
            demo.file(project, "build.zip", weight * 0.25)
            demo.files(project, prefix: "src", ext: ".swift", count: 40, megabytes: 0.01...2)
        }
        let dataset = demo.file(demo.folder(projects, "datasets"), "imagenet-subset.tar", 9.8)
        demo.hardLink(projects, "imagenet-link.tar", to: dataset)

        let downloads = demo.folder(root, "Downloads")
        demo.file(downloads, "Xcode_26.6.xip", 11.9)
        demo.file(downloads, "ubuntu-26.04-desktop.iso", 6.1)
        demo.files(downloads, prefix: "Installer", ext: ".dmg", count: 12, megabytes: 40...900)
        demo.files(downloads, prefix: "Invoice", ext: ".pdf", count: 90, megabytes: 0.05...3)

        let documents = demo.folder(root, "Documents")
        demo.files(documents, prefix: "Report", ext: ".pages", count: 50, megabytes: 0.2...40)
        demo.file(documents, "Taxes 2025.pdf", 0.02)
        let music = demo.folder(root, "Music")
        demo.file(music, "Logic Pro Library.bundle", 6.3, flags: [.directory, .package])
        demo.files(music, prefix: "Track", ext: ".m4a", count: 120, megabytes: 3...12)
        let desktop = demo.folder(root, "Desktop")
        demo.files(desktop, prefix: "Screenshot", ext: ".png", count: 70, megabytes: 0.3...5)
        demo.files(root, prefix: ".config", ext: "", count: 20, megabytes: 0.001...0.5)

        demo.tree.finalizeTotals()
        return demo.tree
    }
}

private struct DemoBuilder {
    var tree: ScanTree
    private var inode: UInt64 = 1
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(root: URL) {
        tree = ScanTree(rootURL: root, rootIdentity: FileIdentity(device: 1, inode: 1))
    }

    @discardableResult
    mutating func folder(_ parent: Int, _ name: String, flags: NodeFlags = []) -> Int {
        add(parent, name, bytes: 0, flags: flags.union(.directory))
    }

    /// A file, or an unexpanded folder when `flags` says so. Sizes in decimal gigabytes.
    @discardableResult
    mutating func file(_ parent: Int, _ name: String, _ gigabytes: Double, flags: NodeFlags = []) -> Int {
        add(parent, name, bytes: UInt64(gigabytes * 1e9), flags: flags)
    }

    /// `count` files with sizes spread over `megabytes`. Dataless files are listed but charge nothing.
    mutating func files(_ parent: Int, prefix: String, ext: String, count: Int, megabytes: ClosedRange<Double>, flags: NodeFlags = [], charged: Bool = true) {
        for index in 1...count {
            let bytes = UInt64(random(in: megabytes) * 1e6)
            add(parent, "\(prefix)\(index)\(ext)", bytes: charged ? bytes : 0, logical: bytes, flags: flags)
        }
    }

    /// A second link to `existing`, charged 0 B like the scanner charges every link after the first.
    mutating func hardLink(_ parent: Int, _ name: String, to existing: Int) {
        tree.insertFlags(.hardLinked, at: existing)
        tree.addChild(
            of: parent, name: name, flags: [.hardLinked, .sharedHardLink], allocated: 0,
            logical: tree.logicalSize(of: existing), identity: tree.identity(of: existing)
        )
    }

    @discardableResult
    private mutating func add(_ parent: Int, _ name: String, bytes: UInt64, logical: UInt64? = nil, flags: NodeFlags) -> Int {
        inode += 1
        return tree.addChild(
            of: parent, name: name, flags: flags, allocated: bytes, logical: logical ?? bytes,
            identity: FileIdentity(device: 1, inode: inode)
        )
    }

    private mutating func random(in range: ClosedRange<Double>) -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(seed >> 11) / Double(1 << 53)
        return range.lowerBound * pow(range.upperBound / range.lowerBound, unit)
    }
}
