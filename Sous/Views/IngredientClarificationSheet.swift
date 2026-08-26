import SousKit
import SwiftUI

/// "5 Zutaten zu klären" — every ingredient of one recipe whose numbers rest
/// on a guess or on nothing, gathered so the answers can be given in one
/// sitting.
///
/// Built like `IngredientReviewSheet`, and for the same reason: there is no
/// separate "apply" step. Each answer saves itself the moment it is given,
/// and the list is read live off the coverage, so answering one visibly
/// shortens it instead of leaving a settled name sitting there.
///
/// The unconfirmed lines come first. They are the ones already moving a
/// number — decision A's price, paid where it is visible.
struct IngredientClarificationSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The names still open, newest reading first — the caller owns the
    /// coverage and re-reads it after every answer.
    let names: [String]
    let onDecision: () async -> Void

    @State private var expanded: String?

    var body: some View {
        NavigationStack {
            Group {
                if names.isEmpty {
                    ContentUnavailableView("Alles geklärt", systemImage: "checkmark.circle")
                } else {
                    List(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                withAnimation { expanded = expanded == name ? nil : name }
                            } label: {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(expanded == name ? 90 : 0))
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if expanded == name {
                                IngredientBasisPicker(name: name) {
                                    await onDecision()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Zutaten klären")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .sousSheetSizing(.form)
    }
}
