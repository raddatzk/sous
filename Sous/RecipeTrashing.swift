import CoreSpotlight
import SousKit
import SwiftUI

/// Moving recipes to the trash, with everything that hangs off them.
///
/// Deleting a recipe used to mean one row getting a `deletedAt` and nothing
/// else: Thursday's dinner went on naming it, the shopping list went on
/// carrying its lines, and Spotlight went on offering it. A cook who deletes
/// a dish means all of that, so it happens here — in one place, so the swipe,
/// the menu and the multi-selection cannot drift apart on what "löschen"
/// does.
///
/// The recipe itself is only trashed, not erased: its pictures and its
/// cached figures stay until the trash is emptied, which is what makes
/// restoring it possible. The plan and the list do not come back with it —
/// a meal that was planned for a day now past is not worth resurrecting.
@MainActor
struct RecipeTrashing {
    let library: RecipeLibrary
    let plan: MealPlanLibrary
    let shopping: ShoppingLibrary

    /// The surviving recipes that name one of these, so the cook can be told
    /// before deciding. Reads the whole library rather than what is filtered
    /// onto the screen: a link is a link whether or not its recipe is
    /// currently shown.
    func breaks(deleting recipes: [Recipe]) async -> [RecipeLinkAudit.Break] {
        guard !recipes.isEmpty else { return [] }
        let all = await library.allRecipes()
        return RecipeLinkAudit.breaks(deleting: recipes, in: all)
    }

    /// Trashes the recipes and clears what pointed at them.
    func trash(_ recipes: [Recipe]) async {
        guard !recipes.isEmpty else { return }
        let ids = recipes.map(\.id)
        await library.delete(recipes)
        await plan.removeMeals(ofRecipes: ids)
        await shopping.removeRecipes(ids)
        await RecipeSpotlight.remove(ids)
    }
}

/// The system search index, as far as recipes are concerned.
///
/// Indexing happens once per launch for the whole library (see
/// `SousApp.indexRecipesForSpotlight`), which adds and updates but never
/// removes: `indexAppEntities` says nothing about what is absent. So a
/// deleted recipe stayed findable in Spotlight — and opened to nothing —
/// until this said otherwise.
enum RecipeSpotlight {
    static func remove(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        try? await CSSearchableIndex.default()
            .deleteAppEntities(identifiedBy: ids, ofType: RecipeEntity.self)
    }

    /// Everything at once, for erasing the library. `deleteAllSearchableItems`
    /// clears what this app put in the index and nothing else.
    static func removeAll() async {
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
    }

    /// Makes the index hold exactly these recipes — the active household's.
    /// Cleared first, because entities are only ever added: a switch would
    /// otherwise leave the previous household's recipes findable, leading to
    /// pages this household cannot open.
    static func replaceAll(with recipes: [Recipe]) async {
        await removeAll()
        // An empty household has nothing to index, and handed an empty list
        // the index never answers — which held up a new household's sheet.
        guard !recipes.isEmpty else { return }
        try? await CSSearchableIndex.default().indexAppEntities(recipes.map(RecipeEntity.init))
    }

    /// Puts a recipe back, for a restore out of the trash — the launch would
    /// index it again, but not before the next launch.
    static func add(_ recipes: [Recipe]) async {
        guard !recipes.isEmpty else { return }
        try? await CSSearchableIndex.default().indexAppEntities(recipes.map(RecipeEntity.init))
    }
}
