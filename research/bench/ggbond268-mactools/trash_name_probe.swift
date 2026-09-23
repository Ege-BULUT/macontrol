// macontrol probe (our code): what does an item trashed the way MacTools DiskClean does it
// look like in the Trash? DiskClean renames the verified object to ".mactools-staged-<UUID>"
// and then calls FileManager.trashItem on that staged path
// (ggbond268/MacTools@bf6550a Plugins/DiskClean/Sources/DiskCleanRemovalPrimitive.swift:257-262, 311-317, 37-40).
// StorageExplorer instead moves it to "<parent>/.mactools-trash-<UUID>/<original name>", trashes that
// path and rmdirs the staging folder (StorageExplorerSafetyPolicy.swift:256-316).
// This probe repeats both sequences on its own scratch files and removes what it put in the Trash.
// Run: swiftc -O trash_name_probe.swift -o /tmp/tp && /tmp/tp <scratch-dir>
import Foundation

let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

func report(_ label: String, _ trashed: URL?) throws {
    guard let trashed else { print("\(label): no resulting URL"); return }
    let hidden = try trashed.resourceValues(forKeys: [.isHiddenKey]).isHidden ?? false
    print("\(label): in Trash as \"\(trashed.lastPathComponent)\" isHidden(Finder)=\(hidden)")
    try fm.removeItem(at: trashed)   // remove only what this probe created
}

// DiskClean sequence
let original = scratch.appendingPathComponent("Cache-DiskClean")
try fm.createDirectory(at: original, withIntermediateDirectories: false)
try Data("x".utf8).write(to: original.appendingPathComponent("blob"))
let staged = scratch.appendingPathComponent(".mactools-staged-" + UUID().uuidString)
try fm.moveItem(at: original, to: staged)
var out: NSURL?
try fm.trashItem(at: staged, resultingItemURL: &out)
try report("DiskClean   ", out as URL?)

// StorageExplorer sequence
let original2 = scratch.appendingPathComponent("Cache-StorageExplorer")
try fm.createDirectory(at: original2, withIntermediateDirectories: false)
let stagingDir = scratch.appendingPathComponent(".mactools-trash-" + UUID().uuidString)
try fm.createDirectory(at: stagingDir, withIntermediateDirectories: false)
let staged2 = stagingDir.appendingPathComponent(original2.lastPathComponent)
try fm.moveItem(at: original2, to: staged2)
var out2: NSURL?
try fm.trashItem(at: staged2, resultingItemURL: &out2)
rmdir(stagingDir.path)
print("StorageExplorer staging folder still exists after rmdir: \(fm.fileExists(atPath: stagingDir.path))")
try report("StorageExpl.", out2 as URL?)
