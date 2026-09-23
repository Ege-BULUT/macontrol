import Foundation
let u = URL(fileURLWithPath: CommandLine.arguments[1])
try! "x".write(to: u, atomically: true, encoding: .utf8)
do { var r: NSURL?; try FileManager.default.trashItem(at: u, resultingItemURL: &r); print("trashItem ->", r?.path ?? "nil") }
catch let e as NSError { print("trashItem failed", e.domain, e.code, e.localizedDescription) }
