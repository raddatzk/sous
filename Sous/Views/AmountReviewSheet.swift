import SousKit
import SwiftUI

/// Lets the cook confirm, correct, or wave off the amounts the resolver
/// found bare mentions for, before any of them become real text.
///
/// Nothing here is written in until "N übernehmen" is tapped — see
/// VISION.md, "amounts written into a step name an ingredient", for why a
/// guess is never applied on its own.
struct AmountReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    let resolution: StepAmountResolver.Resolution
    /// `nil` means "not now" — nothing changes, but the recipe still counts
    /// as reviewed against its current text, so the same list does not come
    /// back until the recipe itself changes. A set (even an empty one)
    /// means the cook went through the list and this is what stayed
    /// checked.
    let onFinish: (Set<AmountSuggestion.ID>?) -> Void

    /// On by default — one tap accepts everything, which matters when a
    /// single recipe can carry two or three dozen of these.
    @State private var accepted: Set<AmountSuggestion.ID>

    init(recipe: Recipe, resolution: StepAmountResolver.Resolution, onFinish: @escaping (Set<AmountSuggestion.ID>?) -> Void) {
        self.recipe = recipe
        self.resolution = resolution
        self.onFinish = onFinish
        _accepted = State(initialValue: Set(resolution.allSuggestions.map(\.id)))
    }

    private var total: Int { resolution.allSuggestions.count }

    private var suggestionsByStep: [(step: RecipeStep, suggestions: [AmountSuggestion])] {
        recipe.steps.compactMap { step in
            let suggestions = resolution.suggestions(for: step)
            return suggestions.isEmpty ? nil : (step, suggestions)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("\(accepted.count) von \(total) ausgewählt")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(accepted.isEmpty ? "Alle auswählen" : "Keine auswählen") {
                            accepted = accepted.isEmpty ? Set(resolution.allSuggestions.map(\.id)) : []
                        }
                        .font(.footnote)
                    }
                }
                ForEach(suggestionsByStep, id: \.step.id) { entry in
                    Section(entry.step.text) {
                        ForEach(entry.suggestions) { suggestion in
                            Toggle(isOn: binding(for: suggestion)) {
                                suggestionLabel(suggestion)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mengen prüfen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Nicht jetzt") {
                        onFinish(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(accepted.isEmpty ? "Fertig" : "\(accepted.count) übernehmen") {
                        onFinish(accepted.isEmpty ? nil : accepted)
                        dismiss()
                    }
                }
            }
        }
        .sousSheetSizing(.form)
    }

    private func binding(for suggestion: AmountSuggestion) -> Binding<Bool> {
        Binding(
            get: { accepted.contains(suggestion.id) },
            set: { isOn in
                if isOn { accepted.insert(suggestion.id) } else { accepted.remove(suggestion.id) }
            }
        )
    }

    private func suggestionLabel(_ suggestion: AmountSuggestion) -> some View {
        Text("\(amountText(suggestion)) \(suggestion.ingredientName)")
    }

    /// The amount carries the accent, same as a resolved amount does
    /// everywhere else — the cook already knows what that color means.
    private func amountText(_ suggestion: AmountSuggestion) -> Text {
        Text(suggestion.displayAmount)
            .foregroundStyle(.tint)
            .fontWeight(.medium)
    }
}
