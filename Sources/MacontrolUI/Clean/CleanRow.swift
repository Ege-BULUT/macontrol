import Cleaner
import MacontrolCore
import SwiftUI

/// One cleanup match: checkbox, name and path, safety badge, size.
/// Skipped items show their reason with the checkbox off; manual items offer Reveal in Finder only.
/// A caution explains why a cleanable item starts unchecked.
struct CleanRow: View {
    let item: CleanupItem
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 20)
            Image(systemName: item.measurement.fileCount == 1 ? "doc" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                Text(item.url.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reason = item.skipReason {
                    Label("Skipped: \(reason)", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cautionText)
                } else if let caution = item.caution {
                    Label(caution, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if item.rule.safety == .manual {
                Button("Reveal in Finder") { item.url.revealInFinder() }
                    .controlSize(.small)
            }
            SafetyBadge(rule: item.rule)
            size.frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(item.skipReason == nil ? 1 : 0.7)
        .contextMenu {
            Button("Reveal in Finder") { item.url.revealInFinder() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.canClean ? (isChecked ? "selected" : "not selected") : "cannot be selected")
    }

    @ViewBuilder
    private var leading: some View {
        if item.rule.safety == .manual {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.secondary)
                .help("Manual: never part of a bulk clean")
        } else {
            Toggle("Select \(item.name)", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.canClean)
        }
    }

    private var size: some View {
        // A folder that could not be read completely is at least this big (F-0057).
        Text((item.measurement.isIncomplete ? "≥ " : "") + item.measurement.allocated.formattedBytes)
            .monospacedDigit()
            .foregroundStyle(item.canClean && isChecked ? .primary : .secondary)
            .help(item.measurement.isIncomplete ? "Some folders inside could not be read, so it may be larger." : "")
    }
}

/// Safe / Review / Manual capsule; clicking it explains the rule.
struct SafetyBadge: View {
    let rule: CleanupRule
    @State private var isExplaining = false

    var body: some View {
        Button { isExplaining.toggle() } label: {
            Text(rule.safety.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(rule.safety.textTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(rule.safety.tint.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(width: 64)
        .help("Why is this \(rule.safety.title)?")
        .popover(isPresented: $isExplaining, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(rule.title).font(.headline)
                Text(rule.note)
                Divider()
                Label(rule.safety.explanation, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280, alignment: .leading)
            .padding(14)
        }
    }
}
