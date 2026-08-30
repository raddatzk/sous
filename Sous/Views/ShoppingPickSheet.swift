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
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<UUID> = []
    /// Set once the pantry vocabulary has been read, so the first pass at
    /// the pre-selection is not made against an empty cupboard.
    @State private var hasSeeded = false
    /// The recipes this one's lines point at, by the id in the link.
    ///
    /// One level deep. A naan that is itself made of a spice mix still goes
    /// on entire — the list builder follows three levels, but a picker that
    /// unfolded all of them would be asking about flour the cook has never
    /// heard of in the context of this dish.
    @State private var linked: [UUID: Recipe] = [:]
    /// Which link lines are open, by the *parent* line's id.
    @State private var expanded: Set<UUID> = []

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups, id: \.group) { group in
                    Section {
                        ForEach(group.ingredients) { ingredient in
                            if let sub = linkedRecipe(for: ingredient) {
                                linkRow(ingredient, sub)
                            } else {
                                row(ingredient)
                            }
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
                // Before seeding: what is pre-ticked has to include the
                // lines a linked recipe brings, or opening one would show
                // every line unticked under a ticked heading.
                for id in recipe.linkedRecipeIDs {
                    linked[id] = await library.recipe(id: id)
                }
                seed()
            }
        }
    }

    private var selectAllButton: some View {
        Button(allPicked ? "Nichts auswählen" : "Alles auswählen") {
            picked = allPicked ? [] : Set(pickableLines.map(\.id))
        }
    }

    private func row(_ ingredient: RecipeIngredient, indented: Bool = false) -> some View {
        Button {
            toggle(ingredient)
        } label: {
            HStack(spacing: 12) {
                if indented { Spacer().frame(width: 20) }
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

    /// A link line: the sentence the cook wrote, and under it — once
    /// unfolded — the lines it will actually put on the list.
    ///
    /// Ticking "2 Portionen Naan" used to add eight lines of flour and yeast
    /// without saying so anywhere. The lines were right; the silence was the
    /// problem, because the one screen whose whole job is "say what is about
    /// to be added" was the one place they did not appear.
    private func linkRow(_ ingredient: RecipeIngredient, _ sub: Recipe) -> some View {
        let lines = subLines(of: ingredient, sub)
        let isOpen = expanded.contains(ingredient.id)
        return Group {
            Button {
                toggleAll(ingredient, lines)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: mark(for: lines))
                        .foregroundStyle(pickedCount(of: lines) > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line(ingredient))
                            .foregroundStyle(.primary)
                        Text(subtitle(picked: pickedCount(of: lines), of: lines.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // Unfolding is its own tap, on its own target: the row
                    // itself still ticks, which is what most cooks want from
                    // it most of the time.
                    Button {
                        withAnimation { toggleExpanded(ingredient.id) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .padding(.leading, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOpen ? "Zutaten ausblenden" : "Zutaten anzeigen")
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(lines) { sub in
                    row(sub, indented: true)
                }
            }
        }
    }

    private func subtitle(picked: Int, of total: Int) -> String {
        let what = total == 1 ? "Zutat" : "Zutaten"
        return picked == total
            ? "Bringt \(total) \(what) mit"
            : "\(picked) von \(total) \(what)"
    }

    /// A half-filled mark for a link only some of whose lines are wanted —
    /// the state that used not to be reachable at all.
    private func mark(for lines: [RecipeIngredient]) -> String {
        switch pickedCount(of: lines) {
        case 0: "circle"
        case lines.count: "checkmark.circle.fill"
        default: "circle.righthalf.filled"
        }
    }

    private func pickedCount(of lines: [RecipeIngredient]) -> Int {
        lines.count { picked.contains($0.id) }
    }

    /// The linked recipe a line points at, if it has been resolved. A link
    /// whose target is missing falls back to the plain row — and to the
    /// builder's own fallback, which puts the line on as written.
    private func linkedRecipe(for ingredient: RecipeIngredient) -> Recipe? {
        RecipeLink.referencedIDs(in: ingredient.name).first.flatMap { linked[$0] }
    }

    /// What the linked recipe contributes, at the count this line asks of
    /// it — the same rule `ShoppingListBuilder` follows, so the sheet cannot
    /// promise a different list than the one that arrives.
    private func subLines(of ingredient: RecipeIngredient, _ sub: Recipe) -> [RecipeIngredient] {
        let portions: Int? = if let quantity = ingredient.quantity, quantity.unit == .portion {
            max(1, Int(quantity.amount.rounded()))
        } else {
            nil
        }
        return sub.scaledIngredients(toServings: portions ?? sub.servings)
    }

    private func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// The heading ticks and unticks everything under it — and the parent
    /// line goes with them, because the builder needs it to descend at all.
    private func toggleAll(_ ingredient: RecipeIngredient, _ lines: [RecipeIngredient]) {
        if pickedCount(of: lines) == lines.count {
            picked.subtract(lines.map(\.id))
            picked.remove(ingredient.id)
        } else {
            picked.formUnion(lines.map(\.id))
            picked.insert(ingredient.id)
        }
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

    /// Every line the sheet can be asked about: the recipe's own, and the
    /// ones a link brings in place of itself. A link line counts as both —
    /// it is shown, and the builder needs it ticked to descend.
    private var pickableLines: [RecipeIngredient] {
        ingredients.flatMap { ingredient in
            guard let sub = linkedRecipe(for: ingredient) else { return [ingredient] }
            return [ingredient] + subLines(of: ingredient, sub)
        }
    }

    private var groups: [(group: String?, ingredients: [RecipeIngredient])] {
        recipe.ingredientGroups(scaledToServings: servings)
    }

    private var allPicked: Bool {
        picked.count == pickableLines.count
    }

    private func toggle(_ ingredient: RecipeIngredient) {
        if picked.contains(ingredient.id) {
            picked.remove(ingredient.id)
        } else {
            picked.insert(ingredient.id)
        }
        syncLinkLines()
    }

    /// Keeps each link line ticked exactly while something under it is.
    ///
    /// The parent line is not decoration: `ShoppingListBuilder` skips a link
    /// whose own line was not picked, so unticking the last of a naan's
    /// ingredients has to untick the naan, and ticking the first has to tick
    /// it back. Done here rather than in the row so that "Alles auswählen"
    /// and the pantry seeding land in the same state.
    private func syncLinkLines() {
        for ingredient in ingredients {
            guard let sub = linkedRecipe(for: ingredient) else { continue }
            let lines = subLines(of: ingredient, sub)
            if lines.contains(where: { picked.contains($0.id) }) {
                picked.insert(ingredient.id)
            } else {
                picked.remove(ingredient.id)
            }
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
        // The cupboard is read line by line, which now reaches the naan's
        // flour as well — a staple inside a linked recipe is the same staple.
        picked = Set(pickableLines.filter { !isPantry($0) }.map(\.id))
        syncLinkLines()
    }
}
