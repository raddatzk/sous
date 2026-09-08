import SousKit
import SwiftUI

/// What the cook decided in `AmountReviewSheet` — which suggestions to
/// write in, what to write for the ones they edited instead of taking as
/// offered, and which ones they turned down for good.
struct AmountReviewOutcome {
    let accepted: Set<AmountSuggestion.ID>
    let corrections: [AmountSuggestion.ID: String]
    /// The ``AmountSuggestion/declineKey``s of everything left unticked.
    ///
    /// Going through the list *is* the answer to each line in it, including
    /// the lines answered "no". Without this the no's lived only in the
    /// recipe's content hash, so the next comma typed anywhere in the recipe
    /// asked every one of them again.
    let declined: Set<String>
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
    /// `nil` means "not now" — nothing changes and nothing is turned down,
    /// but the recipe still counts as reviewed against its current text, so
    /// the same list does not come back until the recipe itself changes.
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
        _edited = State(initialValue: Self.amounts(of: resolution))
    }

    private var total: Int { resolution.allSuggestions.count }

    /// The suggestions on offer, by id — as a set, because `allSuggestions`
    /// walks a dictionary's values: the same resolution hands them over in no
    /// fixed order, and comparing ordered lists would report a change that is
    /// not one.
    private var suggestionIDs: Set<AmountSuggestion.ID> {
        Set(resolution.allSuggestions.map(\.id))
    }

    private static func amounts(
        of resolution: StepAmountResolver.Resolution
    ) -> [AmountSuggestion.ID: String] {
        Dictionary(uniqueKeysWithValues: resolution.allSuggestions.map { ($0.id, $0.displayAmount) })
    }

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
                } footer: {
                    // Said out loud because the second half of it used not to
                    // be true: unticking something meant "not this time", and
                    // the next edit asked again.
                    Text("Ausgewählte Mengen werden in den Text geschrieben, nicht ausgewählte nicht mehr vorgeschlagen. „Nicht jetzt“ lässt beides offen.")
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
            // A later resolve can replace the one this sheet opened on while
            // it is still up — the background enrichment pass behind the
            // recipe, most often. Every suggestion carries a fresh `id` per
            // resolve, so what was ticked then names nothing now: the header
            // read "23 von 12 ausgewählt", every row showed itself unticked,
            // and "übernehmen" would have written none of them in while
            // turning down all twelve. Start again from the list actually on
            // screen, which is also this sheet's ordinary default.
            .onChange(of: suggestionIDs) { _, ids in
                accepted = ids
                edited = Self.amounts(of: resolution)
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
                        onFinish(AmountReviewOutcome(
                            accepted: accepted, corrections: edited, declined: declined
                        ))
                        dismiss()
                    }
                }
            }
        }
        .sousSheetSizing(.form)
    }

    /// Everything left unticked, by the key that outlives this resolve.
    private var declined: Set<String> {
        Set(resolution.allSuggestions.filter { !accepted.contains($0.id) }.map(\.declineKey))
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
