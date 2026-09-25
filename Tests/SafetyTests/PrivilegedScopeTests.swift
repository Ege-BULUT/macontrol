import Foundation
import Safety
import TestSupport
import Testing

/// DESIGN-debloat section 3.9: the root allowlist, on canonical paths. Lexical except the receipts, which must be
/// regular files, so those use a temporary folder as the system root.
@Suite struct PrivilegedScopeTests {
    static let home = "/Users/tester"

    static let allowed: [(path: String, bundleIdentifier: String?)] = [
        ("/Applications/X.app", nil),
        ("/Applications/Utilities/X.app", nil),
        ("/Library/Application Support/Vendor/X", nil),
        ("/Library/LaunchDaemons/com.vendor.helper.plist", nil),
        ("/Library/PrivilegedHelperTools/com.vendor.helper", nil),
        ("/Library/Preferences/com.apple.dt.Xcode.plist", "com.apple.dt.Xcode"),
        ("/Library/Audio/Apple Loops/Apple/x", nil),
        ("/Library/Developer/CoreSimulator/Caches/dyld", nil),
        ("/Users/tester/Library/Caches/com.vendor.app", nil),
        ("/Users/tester/Library/Caches/com.apple.bird/x", "com.apple.bird"),
    ]

    static let refused: [(path: String, bundleIdentifier: String?)] = [
        ("/private/etc/sudoers", nil),
        ("/Library/Keychains/x", nil),
        ("/Library/Extensions/x.kext", nil),
        ("/Applications", nil),
        ("/Applications/Folder", nil),
        ("/Applications/X.app/Contents/MacOS/X", nil),
        ("/Applications/.app", nil),
        ("/private/var/db/receipts/../x", nil),
        ("/private/var/db/receipts/sub/x.plist", nil),
        ("/System/Applications/Chess.app", nil),
        ("/Users/other/Library/Caches/x", nil),
        ("/Users/Shared/x", nil),
        ("/Library/Caches", nil),
        ("/Library/Application Support/./x", nil),
        ("/Library/Preferences/com.apple.loginwindow.plist", nil),
        ("/Library/Preferences/com.apple.loginwindow.plist", "com.vendor.app"),
        // A two-part identifier would claim all of Apple.
        ("/Library/Preferences/com.apple.loginwindow.plist", "com.apple"),
        ("/Library/Preferences/com.apple.dt.XcodeHelper.plist", "com.apple.dt.Xcode"),
        ("/Library/Preferences/.GlobalPreferences.plist", nil),
        ("/Library/Application Support/Apple/ParentalControls/x", nil),
        ("/Library/Application Support/AppleHelper", nil),
        ("/Users/tester/Library/Caches/com.apple.bird/x", nil),
        ("/Users/tester/Documents/x", nil),
        // macOS's own state under names without an Apple prefix, which any app can claim (T-0075 review 2, Risk 8).
        ("/Library/Preferences/org.cups.printers.plist", nil),
        ("/Library/Preferences/org.cups.printers.plist", "org.cups.printers"),
        ("/Library/Preferences/Logging/Subsystems/x.plist", nil),
        ("/Library/Application Support/CrashReporter", nil),
        ("/Library/Application Support/App Store/x", nil),
        ("/Library/Application Support/btserver", nil),
    ]

    @Test(arguments: allowed.indices) func allowedPath(index: Int) {
        let (path, id) = Self.allowed[index]
        #expect(PrivilegedScope.refusal(canonical: path, home: Self.home, bundleIdentifier: id) == nil, "\(path)")
    }

    @Test(arguments: refused.indices) func refusedPath(index: Int) {
        let (path, id) = Self.refused[index]
        #expect(PrivilegedScope.refusal(canonical: path, home: Self.home, bundleIdentifier: id) == .protectedLocation(path), "\(path) \(id ?? "-")")
    }

    /// `pkgutil --forget`'s two files per package, and nothing else in that folder.
    @Test func receiptsAreRegularFilesNamedByAPackageIdentifier() throws {
        let tmp = try TemporaryDirectory()
        let root = tmp.url.path
        try tmp.file("private/var/db/receipts/com.vendor.pkg.plist")
        try tmp.file("private/var/db/receipts/com.vendor.pkg.bom")
        try tmp.directory("private/var/db/receipts/com.vendor.dir.plist")
        try tmp.file("private/var/db/receipts/com.vendor.pkg.txt")
        try tmp.file("private/var/db/receipts/bad name.plist")
        try tmp.symlink("private/var/db/receipts/com.vendor.link.plist", to: "/private/etc/sudoers")
        func refusal(_ name: String) -> RefusalReason? {
            PrivilegedScope.refusal(canonical: root + "/private/var/db/receipts/" + name, home: Self.home, bundleIdentifier: nil, systemRoot: root)
        }
        #expect(refusal("com.vendor.pkg.plist") == nil)
        #expect(refusal("com.vendor.pkg.bom") == nil)
        for name in ["com.vendor.dir.plist", "com.vendor.pkg.txt", "bad name.plist", "com.vendor.link.plist", "missing.plist"] {
            #expect(refusal(name) != nil, "\(name)")
        }
    }

    /// Every path the constant names really is Apple-named content below an allowed Library folder.
    @Test func appleContentLiesInsideTheAllowedFolders() {
        for path in PrivilegedScope.appleContent {
            #expect(PrivilegedScope.refusal(canonical: path + "/x", home: Self.home, bundleIdentifier: nil) == nil, "\(path)")
        }
    }
}
