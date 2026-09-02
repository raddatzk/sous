import SousKit
import SwiftUI

/// Picks the ingredient an unknown spelling actually means.
///
/// The cheaper of the two ways out of an unrecognized name: "Schmelzkäse
/// light" is not a new food, it is a way of writing one the app already
/// knows — and saying so hands it that entry's aisle and its nutrition at
/// once, with nothing to type in.
struct IngredientAliasPickerView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    /// The spelling being placed, shown so it stays visible while searching.
    let alias: String

    @State private var searchText = ""
    @State private var isPicking = false

    var body: some View {
        NavigationStack {
            List(results) { ingredient in
                // A button rather than a tap gesture: the pointer changes
                // over it, the keyboard reaches it, and the Mac gets the
                // click it expects. The write finishes before the sheet
                // goes, so the recipe page behind it re-reads a catalog that
                // already knows the spelling.
                Button {
                    guard !isPicking else { return }
                    isPicking = true
                    Task {
                        await catalog.addAlias(alias, to: ingredient)
                        dismiss()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ingredient.name)
                        Text(ingredient.category.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("„\(alias)“ zuordnen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Zutat suchen")
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        "Keine Zutat gefunden",
                        systemImage: "magnifyingglass",
                        description: Text("Wenn es die Zutat noch nicht gibt, leg sie stattdessen neu an.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        // Starts from the unknown name itself: often enough the right entry
        // is a prefix of it, and the search is already done.
        .onAppear { searchText = alias }
        .sousSheetSizing(.form)
    }

    private var results: [CatalogIngredient] {
        let matches = catalog.catalog.suggestions(for: searchText, limit: 60)
        // Two characters is the search's own floor; below it, showing the
        // whole catalog beats showing nothing.
        return matches.isEmpty && searchText.trimmingCharacters(in: .whitespaces).count < 2
            ? Array(catalog.catalog.ingredients.prefix(60))
            : matches
    }
}
