// Probe driver for munki's rmpkgs.swift (munki/munki@28d92fe, compiled unmodified).
// Modes:
//   fixture <FIX>   builds a fake receipt DB whose paths all live under <FIX>, then runs
//                   munki's own removePackages() in the configurations munki uses.
//   rebuild         runs munki's own initReceiptDB(forcerebuild:) against this Mac's real
//                   receipts (read-only: pkgutil --pkg-info-plist / --files, lsbom) into $PROBE_DIR.
// Apple's receipt DB is never touched: every removePackages call passes noUpdateApplePkgDB: true.
import Foundation

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "fixture"

func tree(_ root: String) -> [String] {
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: root) else { return [] }
    return (e.allObjects as? [String] ?? []).sorted()
}

func touch(_ p: String) {
    try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
}

let fooFiles = ["Applications", "Applications/Foo.app", "Applications/Foo.app/Contents",
                "Applications/Foo.app/Contents/Info.plist", "Applications/Foo.app/Contents/MacOS",
                "Applications/Foo.app/Contents/MacOS/Foo",
                "Library", "Library/Shared", "Library/Shared/common.dylib",
                "Library/Foo", "Library/Foo/foo.conf"]
let barFiles = ["Applications", "Library", "Library/Shared", "Library/Shared/common.dylib",
                "Library/Bar", "Library/Bar/bar.conf"]

func setUp(_ fix: String) throws {
    let fm = FileManager.default
    try? fm.removeItem(atPath: fix)
    try? fm.removeItem(atPath: pkgDBPath())
    for f in ["Applications/Foo.app/Contents/Info.plist", "Applications/Foo.app/Contents/MacOS/Foo",
              "Library/Shared/common.dylib", "Library/Foo/foo.conf", "Library/Bar/bar.conf"] {
        touch(fix + "/" + f)
    }
    // State after install + normal use:
    touch(fix + "/Applications/Foo.app/Contents/MacOS/FooUpdateHelper")   // added by the app's own updater
    touch(fix + "/Applications/Foo.app/Contents/PlugIns/UserAdded.plugin/x") // added by the user
    touch(fix + "/Library/Foo/user-settings.plist")                        // user data next to a pkg file
    let conn = try SQL3Connection(pkgDBPath())
    try createReceiptDBTables(conn)
    try conn.close()
    let ppath = String(fix.dropFirst()) // munki stores paths without the leading "/"
    try insertPkgDataIntoPkgDB(pkgdata: PkgData(timestamp: 1, pkgid: "com.fixture.foo", version: "1", ppath: ppath, files: fooFiles))
    try insertPkgDataIntoPkgDB(pkgdata: PkgData(timestamp: 1, pkgid: "com.fixture.bar", version: "1", ppath: ppath, files: barFiles))
}

func show(_ title: String, _ fix: String) {
    print("--- \(title): files left under fixture")
    for p in tree(fix) { print("    \(p)") }
}

switch mode {
case "fixture":
    let fix = args[2]
    try setUp(fix)

    print("=== A. pkg-key lookup (rmpkgs.swift:354-370, quoteAndJoin + string-built IN list)")
    for ids in [["com.fixture.foo"], ["pkgid"], ["pkgname"], ["vers"], ["no.such.pkg", "com.fixture.foo"], ["a\"b"]] {
        do { print("  \(ids) -> keys \(try getPkgKeysFromPkgDB(pkgids: ids))") }
        catch { print("  \(ids) -> threw: \(error)") }
    }
    print("  dry run of removePackages([\"pkgname\"], listFiles: true):")
    let rcA = await removePackages(["pkgname"], listFiles: true, noUpdateApplePkgDB: true)
    print("  rc=\(rcA)")

    print("\n=== B. managedsoftwareupdate path: removePackages(pkgids) with default flags (installer.swift:489)")
    let rcPrev = await removePackages(["com.fixture.foo"], listFiles: true, noUpdateApplePkgDB: true)
    print("  preview rc=\(rcPrev)")
    let rcB = await removePackages(["com.fixture.foo"], noUpdateApplePkgDB: true)
    print("  remove rc=\(rcB)  (0 = success reported)")
    show("after B", fix)
    do { print("  receipt still in munki DB? keys=\(try getPkgKeysFromPkgDB(pkgids: ["com.fixture.foo"]))") }
    catch { print("  receipt lookup threw: \(error)") }
    let rcB2 = await removePackages(["com.fixture.foo"], noUpdateApplePkgDB: true)
    print("  retry rc=\(rcB2)  (-4 = no matching pkgs: leftovers can no longer be found by receipt)")

    print("\n=== C. removepackages -f (forceDeleteBundles: true), fresh fixture")
    try setUp(fix)
    let rcC = await removePackages(["com.fixture.foo"], forceDeleteBundles: true, noUpdateApplePkgDB: true)
    print("  remove rc=\(rcC)")
    show("after C", fix)

case "rebuild":
    let t0 = Date()
    do { try await initReceiptDB(forcerebuild: true) } catch { print("initReceiptDB threw: \(error)") }
    let secs = Date().timeIntervalSince(t0)
    let conn = try SQL3Connection(pkgDBPath())
    for q in ["SELECT count(*) FROM pkgs", "SELECT count(*) FROM paths", "SELECT count(*) FROM pkgs_paths"] {
        let s = try SQL3Statement(connection: conn, SQLString: q)
        _ = s.step()
        print("  \(q) = \(s.int64(column: 0))")
    }
    print(String(format: "  initReceiptDB(forcerebuild: true) wall time: %.2f s", secs))
default:
    print("unknown mode")
}
