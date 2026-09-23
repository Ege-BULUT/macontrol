// What Foundation's URLResourceValues report for each file, plus volume capacity keys.
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let keys: [URLResourceKey] = [.fileSizeKey, .fileAllocatedSizeKey, .totalFileSizeKey,
    .totalFileAllocatedSizeKey, .linkCountKey, .fileContentIdentifierKey, .mayShareFileContentKey,
    .isSparseKey, .fileResourceIdentifierKey]
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
print("name          fileSize  allocSize  totalSize  totalAlloc nlink contentId mayShare sparse")
for u in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let v = try u.resourceValues(forKeys: Set(keys))
    let cid = v.fileContentIdentifier.map { String($0, radix: 16) } ?? "nil"
    print(u.lastPathComponent.padding(toLength: 13, withPad: " ", startingAt: 0),
          v.fileSize ?? -1, v.fileAllocatedSize ?? -1, v.totalFileSize ?? -1,
          v.totalFileAllocatedSize ?? -1, v.linkCount ?? -1, cid,
          v.mayShareFileContent.map { "\($0)" } ?? "nil", v.isSparse.map { "\($0)" } ?? "nil")
}
let vk: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey,
    .volumeSupportsFileCloningKey, .volumeSupportsSparseFilesKey, .volumeSupportsCompressionKey]
let vv = try URL(fileURLWithPath: "/").resourceValues(forKeys: vk)
print("volume total:", vv.volumeTotalCapacity ?? -1)
print("available (statfs-like):", vv.volumeAvailableCapacity ?? -1)
print("available for important usage:", vv.volumeAvailableCapacityForImportantUsage ?? -1)
print("available for opportunistic usage:", vv.volumeAvailableCapacityForOpportunisticUsage ?? -1)
print("cloning/sparse/compression:", vv.volumeSupportsFileCloning ?? false,
      vv.volumeSupportsSparseFiles ?? false, vv.volumeSupportsCompression ?? false)
