import SousKit
import SwiftUI

/// The irreversible things the app can do to a household: empty it, delete
/// it, or leave it.
///
/// Always the household that is showing. The settings say its name in every
/// button, so what is about to go is the thing on screen, and nothing reaches
/// a household the person is not looking at.
///
/// On this device and in iCloud — those are not two steps. Every row is
/// mirrored, so deleting it locally is what removes it from iCloud and from
/// the other devices; deleting a store file instead would remove nothing
/// from iCloud and the library would simply come back on the next sync.
///
/// Emptying keeps the household itself, so the other devices and anybody it
/// is shared with keep working in it; deleting takes it along. Neither
/// touches the welcome's "seen it" mark, which belongs to this install
/// rather than to the recipes, or the settings.
@MainActor
struct LibraryWipe {
    let library: RecipeLibrary
    let plan: MealPlanLibrary
    let shopping: ShoppingLibrary
    let catalog: IngredientCatalogLibrary
    let session: CookSession
    let timers: CookTimerCenter
    let calendarMirror: CalendarMirror?
    let households: CoreDataHouseholds
    let switcher: HouseholdSwitcher

    /// What the cook is about to lose, so the question can name it rather
    /// than asking them to trust a word like "alles".
    struct Counts: Equatable {
        var recipes = 0
        var meals = 0
        var shopping = 0
        var ingredients = 0

        var isEmpty: Bool { recipes == 0 && meals == 0 && shopping == 0 && ingredients == 0 }
    }

    func counts() async -> Counts {
        Counts(
            recipes: await library.allRecipesIncludingTrash().count,
            meals: await plan.plannedCount(),
            shopping: shopping.planEntries.count + shopping.items.count,
            ingredients: catalog.ownIngredients.count
        )
    }

    /// Empties the household that is showing. `onProgress` reports the
    /// recipes, which are the slow part — each one carries its pictures out
    /// with it.
    func empty(onProgress: @MainActor @escaping (Int, Int) -> Void) async {
        await library.eraseEverything(onProgress: onProgress)
        await plan.removeEverything()
        await shopping.removeEverything()
        await catalog.removeOwnEntries()
        await forgetWhatOutlivesTheRows()
    }

    /// Deletes the household that is showing if it is this person's, or
    /// leaves it if they joined it — `CoreDataHouseholds.delete` knows which.
    /// Afterwards the switch falls back to the oldest own household.
    func deleteOrLeave() async throws {
        guard let id = switcher.activeID else { return }
        try await households.delete(id)
        await switcher.refresh()
        await forgetWhatOutlivesTheRows()
    }

    /// Everything that is not a row in the household's stores, and would
    /// otherwise outlive it: the search index, the calendar the plan was
    /// mirrored into, what is on the hob, and the timers ticking for it.
    private func forgetWhatOutlivesTheRows() async {
        let remaining = await library.allRecipesIncludingTrash().filter { !$0.isDeleted }
        await RecipeSpotlight.replaceAll(with: remaining)
        await calendarMirror?.syncIfEnabled()
        session.forgetEverything()
        await timers.stopAll()
    }
}
