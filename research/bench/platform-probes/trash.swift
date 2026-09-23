// Local experiment: FileManager.trashItem vs NSWorkspace.recycle, collisions, undo, and failure codes.
import AppKit

let fm = FileManager.default
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let tag = "macontrol-trash-probe-\(ProcessInfo.processInfo.processIdentifier)"

func make(_ name: String) -> URL {
    let u = dir.appendingPathComponent(name)
    try! "probe".write(to: u, atomically: true, encoding: .utf8)
    return u
}

// 1. trashItem + returned URL + collision rename
let a1 = make("\(tag).txt")
var r1: NSURL?
try! fm.trashItem(at: a1, resultingItemURL: &r1)
print("trashItem#1 ->", r1!.path!)
let a2 = make("\(tag).txt")
var r2: NSURL?
try! fm.trashItem(at: a2, resultingItemURL: &r2)
print("trashItem#2 (same name) ->", r2!.path!)

// 2. undo = move the returned URL back
try! fm.moveItem(at: r2! as URL, to: a2)
print("undo#2 restored:", fm.fileExists(atPath: a2.path), "still in trash:", fm.fileExists(atPath: r2!.path!))

// 3. getRelationship to detect "is in Trash"
var rel = FileManager.URLRelationship.other
try! fm.getRelationship(&rel, of: .trashDirectory, in: [], toItemAt: r1! as URL)
print("relationship(trash, r1) contains:", rel == .contains)

// 4. NSWorkspace.recycle (async, needs run loop)
let b = make("\(tag)-ws.txt")
NSWorkspace.shared.recycle([b]) { map, err in
    print("recycle ->", map[b]?.path ?? "nil", "err:", err as Any)
    // 5. failure on sealed system volume (cannot succeed: read-only sealed mount)
    for p in ["/System/Applications/Chess.app", "/Library/Apple"] {
        do { var r: NSURL?; try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &r); print("UNEXPECTED success", p) }
        catch let e as NSError { print("trashItem(\(p)) failed domain=\(e.domain) code=\(e.code) underlying=\(String(describing: (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain)/\($0.code)" }))") }
    }
    print("TRASHED:", r1!.path!, map[b]?.path ?? "")
    exit(0)
}
RunLoop.main.run()
