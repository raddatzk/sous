import CoreSpotlight
import SousKit
import SwiftUI

/// Deleting everything this household has — the app's one irreversible
/// action.
///
/// What it means, exactly: the cook's *own* household, on this device and in
/// iCloud. Those are not two steps. Every row here is mirrored, so deleting
/// it locally is what removes it from iCloud and from the cook's other
/// devices; deleting the store file instead would remove nothing from iCloud
/// and the library would simply come back on the next sync.
///
/// Households the cook has joined are left alone. Their rows belong to
/// somebody else, and deleting them there would delete them for that person
/// — a button in *these* settings must not reach into another kitchen. Which
/// is also why the wipe forces the own household for its duration: it may be
/// started while a joined one is showing, and then everything below would
/// otherwise be scoped to the wrong kitchen.
///
/// Not deleted: the household itself, so the other devices keep working; the
/// welcome's "seen it" mark, which belongs to this install rather than to
/// the recipes (a fresh install is greeted again, an emptied library is
/// not); and the settings — appearance, the chat for step ingredients.
@MainActor
struct LibraryWipe {
    let library: RecipeLibrary
    let plan: MealPlanLibrary
    let shopping: ShoppingLibrary
    let catalog: IngredientCatalogLibrary
    let session: CookSession
    let timers: CookTimerCenter
    let calendarMirror: CalendarMirror?
    /// Where "own" is looked up. Without it the wipe reaches only what waits
    /// for a household.
    let households: CoreDataHouseholds?

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
        await inOwnHousehold {
            Counts(
                recipes: await library.allRecipesIncludingTrash().count,
                meals: await plan.plannedCount(),
                shopping: shopping.planEntries.count + shopping.items.count,
                ingredients: catalog.ownIngredients.count
            )
        }
    }

    /// Erases the lot. `onProgress` reports the recipes, which are the slow
    /// part — each one carries its pictures out with it.
    func eraseEverything(onProgress: @MainActor @escaping (Int, Int) -> Void) async {
        await inOwnHousehold {
            await library.eraseEverything(onProgress: onProgress)
            await plan.removeEverything()
            await shopping.removeEverything()
            await catalog.removeOwnEntries()
        }

        // Everything that is not a row in the household's stores, and would
        // otherwise outlive it: the search index, the calendar the plan was
        // mirrored into, what is on the hob, and the timers ticking for it.
        await RecipeSpotlight.removeAll()
        await calendarMirror?.disable()
        session.forgetEverything()
        await timers.stopAll()
    }

    /// Runs `work` against the cook's own household, whatever is showing —
    /// the oldest they own, which together with what waits for a household
    /// is everything a build with one household called "mine".
    private func inOwnHousehold<T>(_ work: () async -> T) async -> T {
        let active = ActiveHousehold.id
        ActiveHousehold.id = households?.oldestOwnID()
        defer { ActiveHousehold.id = active }
        return await work()
    }
}
