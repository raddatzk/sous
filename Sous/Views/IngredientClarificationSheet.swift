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

    /// The questions still open, newest reading first — the caller owns the
    /// coverage and re-reads it after every answer.
    ///
    /// One entry per open *question*, not per name: a basis is stored per
    /// preparation state, so the same word can be settled raw and open
    /// cooked, and an answer given here has to know which of the two it is.
    let open: [NutritionCoverage.OpenIngredient]
    let onDecision: () async -> Void

    @State private var expanded: String?

    var body: some View {
        NavigationStack {
            Group {
                if open.isEmpty {
                    ContentUnavailableView("Alles geklärt", systemImage: "checkmark.circle")
                } else {
                    List(open) { question in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                withAnimation {
                                    expanded = expanded == question.id ? nil : question.id
                                }
                            } label: {
                                HStack {
                                    Text(title(of: question))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(expanded == question.id ? 90 : 0))
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if expanded == question.id {
                                IngredientBasisPicker(
                                    name: question.name, state: question.state
                                ) {
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

    /// "Kartoffeln (gegart)" where the state is what tells two open questions
    /// about one word apart, and the bare name where it says nothing.
    private func title(of question: NutritionCoverage.OpenIngredient) -> String {
        guard question.state != .unspecified else { return question.name }
        return "\(question.name) (\(question.state.title.lowercased()))"
    }
}
