import SousKit
import SwiftUI

/// Picking the recipe that turns out to be another version of the same dish.
///
/// The other way a group comes about, and the one a collection grown by hand
/// has something to offer today: "Ajvar-Suppe" and "Ajvar-Suppe vegan" were
/// written separately and know nothing about each other. Nothing is copied
/// and nothing is rewritten — the two recipes stay exactly as they are, and
/// only learn that they belong together.
///
/// Still an action on a recipe rather than an administrative one: there is no
/// screen listing groups, and no way to make an empty one.
struct VariantJoinPicker: View {
    /// The recipe the cook started from, and what happens next.
    enum Target {
        /// Two loose recipes become a group named after what they share.
        case recipe(Recipe)
        /// A group that exists takes another recipe in.
        case group(VariantGroup)
    }

    let target: Target
    /// Handed the group the two of them are now in.
    var onJoined: (VariantGroup) -> Void = { _ in }

    @Environment(RecipeLibrary.self) private var library

    var body: some View {
        RecipePickerView(
            title: title,
            excluding: excludedID,
            unavailable: { recipe in
                // Only what the list can see. A recipe whose sibling is in
                // the trash looks free from here and is not — the library
                // refuses that one and says why.
                guard let id = recipe.variantGroupID,
                      let group = library.variantGroups[id]
                else { return nil }
                return "Gehört zu „\(group.title)“"
            }
        ) { picked in
            Task {
                switch target {
                case .recipe(let recipe):
                    if let group = await library.groupAsVariants(recipe, picked) {
                        onJoined(group)
                    }
                case .group(let group):
                    if await library.addToVariantGroup(group.id, recipe: picked) {
                        onJoined(group)
                    }
                }
            }
        }
    }

    private var title: String {
        switch target {
        case .recipe: "Variante auswählen"
        case .group: "Rezept aufnehmen"
        }
    }

    private var excludedID: Recipe.ID {
        switch target {
        case .recipe(let recipe): recipe.id
        // Nothing to exclude by id — the members are already in a group and
        // are greyed out for that reason, which also says why.
        case .group: UUID()
        }
    }
}
