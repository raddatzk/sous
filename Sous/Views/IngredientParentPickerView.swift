import SousKit
import SwiftUI

/// Picks the ingredient another one is a variety of.
///
/// The way into the relation that existed only as a way out. A parent could
/// be *accepted* — the word-ending heuristic asked once, while an ingredient
/// was coming into being — and it could be released, and that was all; once
/// the proposal was declined and the form saved, nothing in the app could set
/// it again. `IngredientCatalogLibrary.setParent` had been there the whole
/// time. This is the screen it was missing.
///
/// Built like ``IngredientAliasPickerView`` and for the same reason: the
/// proposals lead, the search covers everything else, and one tap decides.
/// What the tap does is the caller's — the form takes the name into its
/// draft, the unknown-ingredient menu creates the variety on the spot.
struct IngredientParentPickerView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    /// The ingredient being filed. Shown so it stays in view while searching,
    /// and kept out of its own list along with everything under it.
    let ingredientName: String
    /// Handed the chosen parent. Awaited before the sheet goes: a caller
    /// that writes to the store on the pick gets to finish before whoever
    /// is watching the dismissal re-reads the catalog — the form only takes
    /// the name into its draft and comes back at once.
    let onPick: (CatalogIngredient) async -> Void

    @State private var searchText = ""
    /// Set once a row was tapped, so a second tap while the first pick is
    /// still writing does not write again.
    @State private var isPicking = false

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty, !proposals.isEmpty {
                    Section {
                        ForEach(proposals) { row($0) }
                    } header: {
                        Text("Vorschläge").sousGroupHeader()
                    } footer: {
                        Text("Nach dem Wortende: was „\(ingredientName)“ dem Namen nach sein könnte.")
                    }
                }
                Section {
                    ForEach(results) { row($0) }
                } header: {
                    Text(trimmedQuery.isEmpty ? "Alle Zutaten" : "Treffer").sousGroupHeader()
                }
            }
            .navigationTitle("„\(ingredientName)“ einordnen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Stamm-Zutat suchen")
            .overlay {
                if results.isEmpty, proposals.isEmpty {
                    ContentUnavailableView(
                        "Keine Zutat gefunden",
                        systemImage: "magnifyingglass",
                        description: Text("Eine Stamm-Zutat ist eine gewöhnliche Zutat. Gibt es sie noch nicht, leg sie im Katalog an und komm hierher zurück.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .sousSheetSizing(.form)
    }

    /// A button rather than a tap gesture, as in the alias picker: the
    /// pointer changes over it, the keyboard reaches it, and the Mac gets the
    /// click it expects.
    private func row(_ ingredient: CatalogIngredient) -> some View {
        Button {
            guard !isPicking else { return }
            isPicking = true
            Task {
                await onPick(ingredient)
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient.name)
                Text(lineage(of: ingredient))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// "Sorte von Pilz" for a candidate that is itself a variety — the chain
    /// may be any depth, and a cook choosing Champignon should see that
    /// Champignon already stands under something — or the aisle otherwise.
    private func lineage(of ingredient: CatalogIngredient) -> String {
        let ancestors = catalog.catalog.ancestors(of: ingredient.name)
        guard !ancestors.isEmpty else { return ingredient.category.title }
        return "Sorte von " + ancestors.map(\.name).joined(separator: " → ")
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// The head-noun matches, best first — what the heuristic would have
    /// asked about at creation time, offered again now that the question can
    /// be reopened.
    private var proposals: [CatalogIngredient] {
        VariantHeuristic.candidates(for: ingredientName, in: catalog.catalog).filter(isEligible)
    }

    private var results: [CatalogIngredient] {
        let matches = catalog.catalog.suggestions(for: searchText, limit: 60)
        // Two characters is the search's own floor; below it, the whole
        // catalog beats nothing.
        let pool = matches.isEmpty && trimmedQuery.count < 2
            ? Array(catalog.catalog.ingredients.prefix(60))
            : matches
        let offered = Set(proposals.map(\.key))
        return pool.filter { isEligible($0) && (!trimmedQuery.isEmpty || !offered.contains($0.key)) }
    }

    /// Not itself, and nothing that descends from it: filing Tomate under
    /// Kirschtomate would run the chain in a circle. The store refuses that
    /// out loud too, but a list should not offer what a tap cannot do.
    private func isEligible(_ candidate: CatalogIngredient) -> Bool {
        let own = IngredientCatalog.normalize(ingredientName)
        guard !own.isEmpty, candidate.key != own else { return false }
        return !catalog.catalog.ancestors(of: candidate.name).contains { $0.key == own }
    }
}
