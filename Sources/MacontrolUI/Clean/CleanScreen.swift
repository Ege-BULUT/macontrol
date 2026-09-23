import Cleaner
import MacontrolCore
import SwiftUI

/// PLACEHOLDER (scaffold): M5 builds grouped categories, review sheet, reclaim estimate and Move to Trash.
struct CleanScreen: View {
    @Bindable var model: CleanModel

    var body: some View {
        List(model.items, selection: $model.selection) { item in
            HStack {
                VStack(alignment: .leading) {
                    Text(item.rule.title)
                    Text(item.skipReason ?? item.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.rule.safety.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.measurement.allocated.formattedBytes).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(model.selectedBytes.formattedBytes) selected")
                Spacer()
                Button("Scan") { Task { await model.scan() } }.disabled(model.isScanning)
            }
            .padding()
        }
        .navigationTitle("Clean")
    }
}
