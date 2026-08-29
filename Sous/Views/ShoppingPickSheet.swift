import SousKit
import SwiftUI

/// Which of a recipe's ingredients are actually wanted on the list.
///
/// The whole recipe used to go on at a tap, and half of what arrived was
/// crossed off at the shelf: the salt, the oil, the pepper — things that are
/// in the cupboard every week. Asking first is cheaper than crossing off
/// afterwards, because crossing off has to happen in the shop and picking
/// happens while the recipe is still being read.
///
/// The choice is captured, not remembered as a preference. What lands on the
/// list *is* the picked set, and the portion dial there scales exactly that
/// — a line left out has no way back through the dial, which is why the
/// sheet says what it is doing rather than presenting itself as a filter.
struct ShoppingPickSheet: View {
    let recipe: Recipe
    /// The count the recipe is being read at, which is the scale the amounts
    /// are shown and captured at.
    let servings: Int
    /// The picked line ids, or nothing if the sheet was dismissed.
    let onAdd: (Set<UUID>) -> Void

    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<UUID> = []
    /// Set once the pantry vocabulary has been read, so the first pass at
    /// the pre-selection is not made against an empty cupboard.
    @State private var hasSeeded = false

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups, id: \.group) { group in
                    Section {
                        ForEach(group.ingredients) { ingredient in
                            row(ingredient)
                        }
                    } header: {
                        if let name = group.group {
                            Text(name)
                        }
                    }
                }
            }
            .navigationTitle("Auf die Einkaufsliste")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Hinzufügen") {
                        onAdd(picked)
                        dismiss()
                    }
                    // Nothing picked is not a shorter list, it is no errand
                    // at all — and it would still put the recipe's heading
                    // and its dial on the list with nothing underneath.
                    .disabled(picked.isEmpty)
                }
                // The Mac has no bottom bar to hang it under; there it
                // stands with the other actions.
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) { selectAllButton }
                #else
                ToolbarItem(placement: .automatic) { selectAllButton }
                #endif
            }
            .task {
                // The flags live in the ingredient catalog, which this screen
                // may be the first to want; without this the cupboard reads
                // as empty and everything arrives picked.
                await shopping.ensurePantryLoaded()
                seed()
            }
        }
    }

    private var selectAllButton: some View {
        Button(allPicked ? "Nichts auswählen" : "Alles auswählen") {
            picked = allPicked ? [] : Set(ingredients.map(\.id))
        }
    }

    private func row(_ ingredient: RecipeIngredient) -> some View {
        Button {
            toggle(ingredient)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked.contains(ingredient.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked.contains(ingredient.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line(ingredient))
                        .foregroundStyle(.primary)
                    // Why it starts unpicked, said once per line rather than
                    // as a legend the reader has to hold in mind.
                    if isPantry(ingredient) {
                        Text("Vorrat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked.contains(ingredient.id) ? [.isSelected] : [])
    }

    /// The line as the list would write it: the amount at the count on
    /// screen, then the name — what is being agreed to, not what the recipe
    /// happens to say at its own scale.
    private func line(_ ingredient: RecipeIngredient) -> String {
        // The same sentence the kit writes everywhere else, over a name with
        // its link syntax taken off: a line that points at another recipe
        // reads as "2 Portionen Naan", not as its markdown.
        var shown = ingredient
        shown.name = ShoppingItem.displayName(for: ingredient.name)
        return formatter.string(for: shown)
    }

    private var ingredients: [RecipeIngredient] {
        recipe.scaledIngredients(toServings: servings)
    }

    private var groups: [(group: String?, ingredients: [RecipeIngredient])] {
        recipe.ingredientGroups(scaledToServings: servings)
    }

    private var allPicked: Bool {
        picked.count == ingredients.count
    }

    private func toggle(_ ingredient: RecipeIngredient) {
        if picked.contains(ingredient.id) {
            picked.remove(ingredient.id)
        } else {
            picked.insert(ingredient.id)
        }
    }

    /// A staple the cook has said is always in the house.
    private func isPantry(_ ingredient: RecipeIngredient) -> Bool {
        shopping.isPantry(ShoppingItem(
            key: ShoppingItem.key(for: ingredient.name),
            name: ShoppingItem.displayName(for: ingredient.name),
            demands: []
        ))
    }

    /// Everything but the cupboard, once.
    ///
    /// Only the first time: a pantry flag changed from somewhere else while
    /// this sheet is open must not quietly re-tick a line the cook just
    /// untangled.
    private func seed() {
        guard !hasSeeded else { return }
        hasSeeded = true
        picked = Set(ingredients.filter { !isPantry($0) }.map(\.id))
    }
}
