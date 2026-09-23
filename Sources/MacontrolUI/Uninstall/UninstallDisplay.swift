import Uninstaller

extension AppKind {
    var sectionTitle: String {
        switch self {
        case .thirdParty: "Apps"
        case .appleAppStore: "Apple apps"
        case .builtIn: "Part of macOS"
        }
    }

    /// Display order of the list sections.
    static let listOrder: [AppKind] = [.thirdParty, .appleAppStore, .builtIn]
}

extension LeftoverEvidence {
    /// Display order: strongest evidence first, the unselected exact-name matches last.
    static let displayOrder: [LeftoverEvidence] = [.bundleIdentifier, .containerMetadata, .appGroup, .launchdJob, .exactName, .contentLibrary]

    /// The evidence kinds present in `leftovers`, in display order. A kind missing from `displayOrder`
    /// still gets its section at the end, so no leftover is ever hidden.
    static func sections(of leftovers: [Leftover]) -> [LeftoverEvidence] {
        var present: [LeftoverEvidence] = []
        for leftover in leftovers where !present.contains(leftover.evidence) { present.append(leftover.evidence) }
        return displayOrder.filter(present.contains) + present.filter { !displayOrder.contains($0) }
    }

    var title: String {
        switch self {
        case .bundleIdentifier: "Named with the app's ID"
        case .containerMetadata: "App sandbox"
        case .appGroup: "Shared app group"
        case .launchdJob: "Background items"
        case .exactName: "Same name as the app"
        case .contentLibrary: "Sound library"
        }
    }

    /// One line on why these items belong to the app.
    var explanation: String {
        switch self {
        case .bundleIdentifier: "In the folders where apps keep their data."
        case .containerMetadata: "The container's own record names this app."
        case .appGroup: "The app lists this group container in its entitlements."
        case .launchdJob: "They start a program inside the app and are stopped first."
        case .exactName: "Likely the app's, but not certain. Not selected: check them first."
        case .contentLibrary: "Loops and instruments for Apple's music apps. Removing them needs an administrator."
        }
    }

    var systemImage: String {
        switch self {
        case .bundleIdentifier: "checkmark.seal.fill"
        case .containerMetadata: "shippingbox.fill"
        case .appGroup: "person.2.fill"
        case .launchdJob: "gearshape.2.fill"
        case .exactName: "questionmark.folder.fill"
        case .contentLibrary: "music.note.list"
        }
    }
}
