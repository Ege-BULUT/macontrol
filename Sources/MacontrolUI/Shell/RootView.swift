import AppKit
import SwiftUI

public struct RootView: View {
    /// The window's minimum. Every screen must fit it whole: SnapshotTests lays each one out at this size.
    public static let minimumSize = CGSize(width: 900, height: 600)

    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: Binding($model.selection)) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                if model.access.isLimited {
                    SidebarAccessNote(access: model.access)
                }
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { ScanToolbar(model: model) }
        }
        .sheet(isPresented: Bindable(model.access).isOnboardingPresented) {
            OnboardingSheet(access: model.access)
        }
        .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.scan(.folder(url)) }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.access.appDidBecomeActive()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: OverviewScreen(model: model)
        case .diskMap: DiskMapScreen(model: model.diskMap)
        case .clean: CleanScreen(model: model.clean)
        case .uninstall: UninstallScreen(model: model.uninstall)
        case .debloat: DebloatScreen(model: model.debloat)
        case .history: HistoryScreen(model: model.history)
        }
    }
}

private struct SidebarAccessNote: View {
    let access: AccessModel

    var body: some View {
        Button { access.showOnboarding() } label: {
            Label("Full Disk Access is off", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.callout)
                .foregroundStyle(Theme.cautionText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(8)
        .accessibilityHint("Shows how to turn on Full Disk Access")
    }
}
