import Darwin
import Foundation
import MacontrolCore
import Security

/// What an app bundle says about itself, read straight from disk. (`Bundle` caches Info.plist per path for the
/// life of the process, so an app updated in place would show stale values.)
struct AppBundle {
    let url: URL
    let info: [String: Any]

    init(url: URL) {
        self.url = url
        info = FileSystem.propertyList(at: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
    }

    var bundleIdentifier: String? { info["CFBundleIdentifier"] as? String }

    /// Lowercased names a leftover folder may carry: the file name, the bundle names and the executable name.
    var names: Set<String> {
        let candidates = [url.deletingPathExtension().lastPathComponent, info["CFBundleName"], info["CFBundleDisplayName"], info["CFBundleExecutable"]]
        return Set(candidates.compactMap { ($0 as? String)?.lowercased() }.filter { !$0.isEmpty })
    }

    /// The app's `com.apple.security.application-groups` entitlement. Reading it does not validate the code.
    var appGroups: [String] {
        let entitlements = signingInformation(SecCSFlags(rawValue: kSecCSRequirementInformation))?[kSecCodeInfoEntitlementsDict as String]
        return (entitlements as? [String: Any])?["com.apple.security.application-groups"] as? [String] ?? []
    }

    func installedApp(systemRoot: URL) -> InstalledApp {
        InstalledApp(
            url: url,
            name: displayName,
            bundleIdentifier: bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            kind: kind(systemRoot: systemRoot),
            identity: FileIdentity(url: url)
        )
    }

    /// The name Finder shows, localized for system apps.
    private var displayName: String {
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    private func kind(systemRoot: URL) -> AppKind {
        let systemFolder = systemRoot.appendingPathComponent("System").path + "/"
        let restricted = FileSystem.status(of: url).map { $0.st_flags & UInt32(SF_RESTRICTED) != 0 } ?? false
        if url.path.hasPrefix(systemFolder) || restricted || isOnReadOnlyVolume {
            return .builtIn
        }
        let hasReceipt = FileSystem.exists(url.appendingPathComponent("Contents/_MASReceipt/receipt"))
        return hasReceipt && isSignedByAppleAsApple ? .appleAppStore : .thirdParty
    }

    private var isOnReadOnlyVolume: Bool {
        var volume = statfs()
        return statfs(url.path, &volume) == 0 && volume.f_flags & UInt32(MNT_RDONLY) != 0
    }

    /// Apple-anchored signature carrying Apple's own team, the mark of Apple's App Store apps
    /// (topic-platform-constraints A8). Third-party App Store apps carry their developer's team instead.
    /// The executable and resources are not hashed: the check reads only the signed code directory, so it stays fast on Xcode.
    private var isSignedByAppleAsApple: Bool {
        guard let code = staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return false }
        return signingInformation(SecCSFlags(rawValue: kSecCSSigningInformation))?[kSecCodeInfoTeamIdentifier as String] as? String == "59GAB85EFG"
    }

    private var staticCode: SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    private func signingInformation(_ flags: SecCSFlags) -> [String: Any]? {
        guard let code = staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}
