import SwiftUI

public struct RootView: View {
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
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: OverviewScreen(model: model)
        case .diskMap: DiskMapScreen(model: model.diskMap)
        case .clean: CleanScreen(model: model.clean)
        case .uninstall: UninstallScreen(model: model.uninstall)
        case .history: HistoryScreen(model: model.history)
        }
    }
}
