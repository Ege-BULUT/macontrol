import Cleaner
import MacontrolCore
import SwiftUI

/// Junk found by the cleanup catalog, grouped by category. Nothing moves without the review sheet.
struct CleanScreen: View {
    @Bindable var model: CleanModel
    /// Highlighted rows (arrow keys, clicks). Only Space turns highlight into checks.
    @State private var highlighted: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .safeAreaInset(edge: .bottom) {
            if !model.items.isEmpty || !model.inTrash.isEmpty { footer }
        }
        .navigationTitle("Clean")
        .task { await model.scanIfNeeded() }
        .task(id: model.selection) { await model.refreshEstimate() }
        .sheet(item: $model.review) { review in
            CleanReviewSheet(model: model, review: review)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemImage: "sparkles", tint: .accentColor, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.title2.weight(.semibold)).monospacedDigit()
                Text(subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            SearchField(prompt: "Filter by name or path", text: $model.query)
                .frame(maxWidth: 240)
            Button {
                Task { await model.scan() }
            } label: {
                Label(model.hasScanned ? "Scan Again" : "Scan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var headline: String {
        if model.isScanning { return "Scanning… \(model.foundBytes.formattedBytes) so far" }
        if model.items.isEmpty { return model.hasScanned ? "Nothing to clean" : "Find junk you can remove" }
        return "\(model.foundBytes.formattedBytes) found"
    }

    private var subheadline: String {
        if let error = model.scanError { return "The scan stopped: \(error)" }
        if model.items.isEmpty && !model.isScanning {
            return "Caches, logs and build data that apps rebuild on their own."
        }
        let count = model.items.count
        return "\(count == 1 ? "1 item" : "\(count) items"). Safe items are selected; the rest wait for you."
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty && model.inTrash.isEmpty {
            if model.isScanning {
                ProgressView("Looking through caches, logs and build data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    model.hasScanned ? "Your Mac is tidy" : "Nothing scanned yet",
                    systemImage: model.hasScanned ? "checkmark.seal" : "sparkles",
                    description: Text(model.hasScanned ? "No caches, logs or build data were found." : "Scan to see what can be cleaned.")
                )
            }
        } else if model.groups.isEmpty && model.inTrash.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $highlighted) {
            if !model.inTrash.isEmpty { inTrashSection }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        CleanRow(item: item, isChecked: Binding(
                            get: { model.isChecked(item) },
                            set: { model.setChecked($0, item) }
                        ))
                    }
                } header: {
                    GroupHeader(group: group, model: model)
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            model.toggle(highlighted)
            return .handled
        }
    }

    private var inTrashSection: some View {
        Section {
            ForEach(model.inTrash) { item in
                HStack(spacing: 12) {
                    Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 20)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("In Trash").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(item.measurement.allocated.formattedBytes)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                .selectionDisabled()
            }
        } header: {
            HStack {
                Label("In Trash", systemImage: "trash").font(.headline)
                Spacer()
                Text("\(model.inTrashBytes.formattedBytes). Empty the Trash in Finder to free it.")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionSummary).font(.headline).monospacedDigit()
                Text(footnote).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Review and Clean…") { model.beginReview() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedItems.isEmpty || model.isScanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectionSummary: String {
        let count = model.selectedItems.count
        guard count > 0 else { return "Nothing selected" }
        let selected = "\(count) selected"
        switch model.estimate {
        case .working: return "\(selected), working out what this frees…"
        case .freesNow(let estimate): return "\(selected), frees about \(estimate.freesNow.formattedBytes) now"
        case .atMost(let bytes): return "\(selected), frees at most \(bytes.formattedBytes)"
        }
    }

    private var footnote: String {
        if case .freesNow(let estimate) = model.estimate, estimate.sharedElsewhere > 0 {
            return "\(estimate.sharedElsewhere.formattedBytes) more is shared with other files and stays in use."
        }
        if !model.inTrash.isEmpty {
            return "\(model.inTrashBytes.formattedBytes) is in the Trash and frees when you empty it."
        }
        return "Items go to the Trash. Put them back any time from History."
    }
}

private struct GroupHeader: View {
    let group: CleanGroup
    let model: CleanModel

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemImage: group.category.systemImage, tint: group.category.tint, size: 22)
            Text(group.category.title).font(.headline).foregroundStyle(.primary)
            Text(group.items.count == 1 ? "1 item" : "\(group.items.count) items").foregroundStyle(.secondary)
            Spacer()
            if !group.cleanable.isEmpty {
                let allChecked = group.cleanable.allSatisfy(model.isChecked)
                Button(allChecked ? "Deselect All" : "Select All") { model.setAll(!allChecked, in: group) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Text(group.allocated.formattedBytes)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
