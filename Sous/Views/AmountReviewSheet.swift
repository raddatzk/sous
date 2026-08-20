import SousKit
import SwiftUI

/// What the cook decided in `AmountReviewSheet` — which suggestions to
/// write in, and what to write for the ones they edited instead of taking
/// as offered.
struct AmountReviewOutcome {
    let accepted: Set<AmountSuggestion.ID>
    let corrections: [AmountSuggestion.ID: String]
}

/// Lets the cook confirm, correct, or wave off the amounts the resolver
/// found — both a bare mention with no amount of its own, and a value
/// `AmountAIExtractor` found but never gets to write in on its own — before
/// any of them become real text.
///
/// Nothing here is written in until "N übernehmen" is tapped — see
/// VISION.md, "amounts written into a step name an ingredient", and memory
/// `amount-confirmation-vs-guessing-tension` for why a guess, AI-sourced or
/// not, is never applied on its own.
struct AmountReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    let resolution: StepAmountResolver.Resolution
    /// `nil` means "not now" — nothing changes, but the recipe still counts
    /// as reviewed against its current text, so the same list does not come
    /// back until the recipe itself changes.
    let onFinish: (AmountReviewOutcome?) -> Void

    /// On by default — one tap accepts everything, which matters when a
    /// single recipe can carry two or three dozen of these.
    @State private var accepted: Set<AmountSuggestion.ID>
    /// Seeded from each suggestion's computed amount; edited in place when
    /// the cook corrects one instead of taking it as offered.
    @State private var edited: [AmountSuggestion.ID: String]

    init(recipe: Recipe, resolution: StepAmountResolver.Resolution, onFinish: @escaping (AmountReviewOutcome?) -> Void) {
        self.recipe = recipe
        self.resolution = resolution
        self.onFinish = onFinish
        _accepted = State(initialValue: Set(resolution.allSuggestions.map(\.id)))
        _edited = State(initialValue: Dictionary(uniqueKeysWithValues: resolution.allSuggestions.map { ($0.id, $0.displayAmount) }))
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
                                suggestionRow(suggestion)
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
                        onFinish(accepted.isEmpty ? nil : AmountReviewOutcome(accepted: accepted, corrections: edited))
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

    private func amountBinding(for suggestion: AmountSuggestion) -> Binding<String> {
        Binding(
            get: { edited[suggestion.id] ?? suggestion.displayAmount },
            set: { edited[suggestion.id] = $0 }
        )
    }

    private func suggestionRow(_ suggestion: AmountSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("Menge", text: amountBinding(for: suggestion))
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .textFieldStyle(.plain)
                    .foregroundStyle(.tint)
                    .fontWeight(.medium)
                    .fixedSize()
                Text(suggestion.ingredientName)
            }
            if case .aiExtracted(let writtenText) = suggestion.origin {
                Text("KI-Vorschlag für „\(writtenText)“ — bitte prüfen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
