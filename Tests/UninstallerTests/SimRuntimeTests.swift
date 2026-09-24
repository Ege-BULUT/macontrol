import Foundation
import Testing
@testable import Uninstaller

/// DESIGN-debloat section 4.4: CoreSimulator's own simctl, at its fixed path, with an argument array and the
/// removed Xcode's DEVELOPER_DIR. No test here runs a tool, except the live list behind MACONTROL_SIMCTL=1.
@Suite struct SimRuntimeTests {
    /// Captured on this Mac on 2026-09-24: `simctl runtime list -j` (CoreSimulator's binary, DEVELOPER_DIR of Xcode 26.6).
    static let captured = #"""
    {
      "9AC467AB-22DE-48A1-89DA-CB942B60CE83" : {
        "build" : "23F77",
        "deletable" : true,
        "identifier" : "9AC467AB-22DE-48A1-89DA-CB942B60CE83",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-09-23T13:31:04Z",
        "mountPath" : "\/Library\/Developer\/CoreSimulator\/Volumes\/iOS_23F77",
        "parentMountPath" : "\/System\/Library\/AssetsV2\/com_apple_MobileAsset_iOSSimulatorRuntime\/26c9174130fa5962f3e60f2a49963194dadbae4c.asset\/AssetData",
        "path" : "\/System\/Library\/AssetsV2\/com_apple_MobileAsset_iOSSimulatorRuntime\/26c9174130fa5962f3e60f2a49963194dadbae4c.asset\/AssetData\/Restore\/094-56039-099.dmg",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeBundlePath" : "\/Library\/Developer\/CoreSimulator\/Volumes\/iOS_23F77\/Library\/Developer\/CoreSimulator\/Profiles\/Runtimes\/iOS 26.5.simruntime",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "signatureState" : "Verified",
        "sizeBytes" : 8494282293,
        "state" : "Ready",
        "supportedArchitectures" : [
          "arm64"
        ],
        "version" : "26.5"
      },
      "F8C76A0E-1793-436F-847B-57A0501E798E" : {
        "build" : "23T570",
        "deletable" : true,
        "identifier" : "F8C76A0E-1793-436F-847B-57A0501E798E",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-08-07T11:15:05Z",
        "mountPath" : "\/Library\/Developer\/CoreSimulator\/Volumes\/watchOS_23T570",
        "parentMountPath" : "\/System\/Library\/AssetsV2\/com_apple_MobileAsset_watchOSSimulatorRuntime\/c523dafdf621ee4b7146d710acd2235b03562449.asset\/AssetData",
        "path" : "\/System\/Library\/AssetsV2\/com_apple_MobileAsset_watchOSSimulatorRuntime\/c523dafdf621ee4b7146d710acd2235b03562449.asset\/AssetData\/Restore\/094-56758-089.dmg",
        "platformIdentifier" : "com.apple.platform.watchsimulator",
        "runtimeBundlePath" : "\/Library\/Developer\/CoreSimulator\/Volumes\/watchOS_23T570\/Library\/Developer\/CoreSimulator\/Profiles\/Runtimes\/watchOS 26.5.simruntime",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
        "signatureState" : "Verified",
        "sizeBytes" : 3935033546,
        "state" : "Ready",
        "supportedArchitectures" : [
          "arm64"
        ],
        "version" : "26.5"
      }
    }
    """#

    static let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")

    /// Records every call instead of running anything.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(tool: URL, arguments: [String], environment: [String: String])] = []
        var all: [(tool: URL, arguments: [String], environment: [String: String])] { lock.withLock { recorded } }

        func tool(status: Int32 = 0, output: String = captured) -> SimRuntimeTool {
            SimRuntimeTool { tool, arguments, environment in
                self.lock.withLock { self.recorded.append((tool, arguments, environment)) }
                return (status, Data(output.utf8))
            }
        }
    }

    @Test func parsesTheCapturedList() throws {
        let runtimes = try SimRuntimeTool.parse(Data(Self.captured.utf8))
        #expect(runtimes == [
            SimRuntime(id: "9AC467AB-22DE-48A1-89DA-CB942B60CE83", name: "iOS 26.5", bytes: 8_494_282_293),
            SimRuntime(id: "F8C76A0E-1793-436F-847B-57A0501E798E", name: "watchOS 26.5", bytes: 3_935_033_546),
        ])
        #expect(runtimes.reduce(0) { $0 + $1.bytes } == 12_429_315_839)
    }

    /// Only deletable images whose identifier is a UUID: nothing like `all` or an option can reach `delete`.
    @Test func dropsWhatCantBeDeletedByUUID() throws {
        let entries = [
            #""a": {"deletable": false, "identifier": "9AC467AB-22DE-48A1-89DA-CB942B60CE83", "sizeBytes": 1}"#,
            #""b": {"deletable": true, "identifier": "all", "sizeBytes": 1}"#,
            #""c": {"deletable": true, "identifier": "--notUsedSinceDays", "sizeBytes": 1}"#,
            #""d": {"deletable": true, "identifier": "F8C76A0E-1793-436F-847B-57A0501E798E"}"#,
        ]
        #expect(try SimRuntimeTool.parse(Data("{\(entries.joined(separator: ","))}".utf8)) == [])
        #expect(throws: SimRuntimeError.unreadable) { try SimRuntimeTool.parse(Data("not json".utf8)) }
        #expect(throws: SimRuntimeError.unreadable) { try SimRuntimeTool.parse(Data("[1, 2]".utf8)) }
    }

    @Test func listAndDeleteRunCoreSimulatorsBinaryWithAnArgumentArray() async throws {
        let calls = Calls()
        let tool = calls.tool()
        let runtimes = try await tool.list(xcode: Self.xcode)
        try await tool.delete(runtimes[0], xcode: Self.xcode)

        let fixed = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl")
        #expect(calls.all.map(\.tool) == [fixed, fixed])
        #expect(calls.all.map(\.arguments) == [["runtime", "list", "-j"], ["runtime", "delete", "9AC467AB-22DE-48A1-89DA-CB942B60CE83"]])
        for call in calls.all {
            #expect(call.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
            #expect(call.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
            #expect(Set(call.environment.keys).isSubset(of: ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "DEVELOPER_DIR"]))
        }
    }

    @Test func environmentKeepsOnlyTheAllowlist() {
        let environment = SimRuntimeTool.environment(xcode: Self.xcode, from: [
            "HOME": "/Users/me", "TMPDIR": "/tmp/x", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "BASH_ENV": "/tmp/x.sh",
            "DEVELOPER_DIR": "/Applications/Other.app/Contents/Developer", "PATH": "/tmp/bin:/usr/bin",
        ])
        #expect(environment == [
            "HOME": "/Users/me", "TMPDIR": "/tmp/x", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ])
    }

    @Test func failuresThrowAndOddIdentifiersNeverRun() async throws {
        let failing = Calls()
        await #expect(throws: SimRuntimeError.failed(72)) { try await failing.tool(status: 72).list(xcode: Self.xcode) }
        await #expect(throws: SimRuntimeError.failed(1)) {
            try await failing.tool(status: 1).delete(SimRuntime(id: "9AC467AB-22DE-48A1-89DA-CB942B60CE83", name: "iOS", bytes: 1), xcode: Self.xcode)
        }
        let calls = Calls()
        await #expect(throws: SimRuntimeError.unreadable) {
            try await calls.tool().delete(SimRuntime(id: "all", name: "every runtime", bytes: 0), xcode: Self.xcode)
        }
        #expect(calls.all.isEmpty)
    }

    /// An Xcode never opened has no CoreSimulator: no runtimes, and nothing is run.
    @Test func noToolMeansNoRuntimes() async throws {
        let calls = Calls()
        let missing = SimRuntimeTool(run: calls.tool().run, isInstalled: { false })
        #expect(try await missing.list(xcode: Self.xcode) == [])
        #expect(calls.all.isEmpty)
    }

    /// Review 7: a tool that hangs is stopped at the limit and counts as failed. Runs only /bin/sleep and /usr/bin/true.
    @Test func aHungToolIsStoppedAndFails() async {
        let started = ContinuousClock.now
        let hung = await SimRuntimeTool.runner(timeout: .milliseconds(300))(URL(fileURLWithPath: "/bin/sleep"), ["20"], [:])
        #expect(hung.status != 0)
        #expect(ContinuousClock.now - started < .seconds(10))
        let quick = await SimRuntimeTool.runner(timeout: .seconds(10))(URL(fileURLWithPath: "/usr/bin/true"), [], [:])
        #expect(quick.status == 0)
    }

    /// Lists this Mac's runtimes with the real binary (read-only). Never deletes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_SIMCTL"] == "1"))
    func liveListReadsThisMac() async throws {
        let runtimes = try await SimRuntimeTool.live.list(xcode: Self.xcode)
        #expect(runtimes.allSatisfy { UUID(uuidString: $0.id) != nil && $0.bytes > 0 })
    }
}
