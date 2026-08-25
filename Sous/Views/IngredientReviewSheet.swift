import SousKit
import SwiftUI

/// Lets the cook add a recipe's unrecognized ingredients to the catalog, one
/// at a time — or leave some for later. The list is read live from the
/// catalog rather than a fixed snapshot, so adding one visibly shrinks it
/// instead of leaving an already-handled name sitting there stale.
///
/// Unlike `AmountReviewSheet`, there is no separate "apply" step: each
/// addition already saves itself through `IngredientFormView`, so "Fertig"
/// only ever closes the sheet and settles the review for the text as it
/// stands — see `RecipeLibrary.markIngredientsReviewed(_:)`.
struct IngredientReviewSheet: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    let ingredientsText: String
    let onFinish: () -> Void

    private var unknown: [String] { catalog.unknownIngredients(in: ingredientsText) }

    var body: some View {
        NavigationStack {
            Group {
                if unknown.isEmpty {
                    ContentUnavailableView("Alle Zutaten bekannt", systemImage: "checkmark.circle")
                } else {
                    List(unknown, id: \.self) { name in
                        UnknownIngredientButton(name: name) {
                            Label(name, systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                    }
                }
            }
            .navigationTitle("Zutaten prüfen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        onFinish()
                        dismiss()
                    }
                }
            }
        }
        .sousSheetSizing(.form)
    }
}
