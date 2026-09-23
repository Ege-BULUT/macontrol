// Probe for Radix auto-summary sampling (colinvkim/Radix@14a76df, MIT).
// `immediateChildrenSuggestAtomicDirectory` is copied verbatim from
// Radix/Services/AtomicDirectorySummaryProbe.swift:57-83; only the stub types below are ours.
// Question: a folder of >= 5,000 tiny files plus ONE 2 GB file. Does Radix summarize it
// (so the 2 GB file is never materialized: not in the map, search or largest-items lists)?
// Run: swiftc -O autosummary_sample_probe.swift -o /tmp/p && /tmp/p
typealias CancellationCheck = () throws -> Void
struct NodeMetadata { let isDirectory: Bool; let logicalSize: Int64 }
struct DirectoryEntry { let metadata: NodeMetadata? }

func immediateChildrenSuggestAtomicDirectory(
    _ childEntries: [DirectoryEntry],
    maxAverageFileSize: Int64,
    cancellationCheck: CancellationCheck
) throws -> Bool {
    try cancellationCheck()
    let sampleSize = min(100, childEntries.count)
    let step = max(1, childEntries.count / sampleSize)
    var sampleTotalSize: Int64 = 0
    var sampleFileCount = 0

    for index in stride(from: 0, to: childEntries.count, by: step).prefix(sampleSize) {
        try cancellationCheck()
        let childEntry = childEntries[index]
        guard let childMetadata = childEntry.metadata else {
            return false
        }

        if !childMetadata.isDirectory {
            sampleTotalSize += childMetadata.logicalSize
            sampleFileCount += 1
        }
    }

    guard sampleFileCount > 0 else { return false }
    return (sampleTotalSize / Int64(sampleFileCount)) <= maxAverageFileSize
}

// Radix defaults: ScanEngine.swift:771 (minFileCount 5_000), :774 (maxAverageFileSize 4_096).
let tinyCount = 6_000, tiny: Int64 = 1_024, big: Int64 = 2 << 30
var summarizedPositions = 0
for bigIndex in 0...tinyCount {            // try every position of the big file in listing order
    var entries = Array(repeating: DirectoryEntry(metadata: .init(isDirectory: false, logicalSize: tiny)), count: tinyCount)
    entries.insert(DirectoryEntry(metadata: .init(isDirectory: false, logicalSize: big)), at: bigIndex)
    if try immediateChildrenSuggestAtomicDirectory(entries, maxAverageFileSize: 4_096, cancellationCheck: {}) {
        summarizedPositions += 1
    }
}
let trueAverage = (Int64(tinyCount) * tiny + big) / Int64(tinyCount + 1)
print("entries=\(tinyCount + 1) trueAverage=\(trueAverage) B (threshold 4096)")
print("summarized in \(summarizedPositions)/\(tinyCount + 1) listing positions of the 2 GiB file")
assert(trueAverage > 4_096)
assert(summarizedPositions > tinyCount / 2, "expected the sample to miss the big file in most positions")

// Case 2: 5,000 tiny files plus one SUBDIRECTORY (any size, e.g. 50 GB of video).
// Directory entries carry logicalSize 0 at listing time and the sample skips them
// (`if !childMetadata.isDirectory`), so the subdirectory can never veto the decision.
var withSubdir = Array(repeating: DirectoryEntry(metadata: .init(isDirectory: false, logicalSize: tiny)), count: 5_000)
withSubdir.append(DirectoryEntry(metadata: .init(isDirectory: true, logicalSize: 0)))
let subdirSummarized = try immediateChildrenSuggestAtomicDirectory(withSubdir, maxAverageFileSize: 4_096, cancellationCheck: {})
print("5000 tiny files + 1 subdirectory of any size -> summarized=\(subdirSummarized)")
assert(subdirSummarized)
