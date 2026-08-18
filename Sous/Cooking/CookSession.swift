import Foundation
import Observation
import SousKit

/// What is on the hob right now.
///
/// Cooking is not a screen, it is a state the kitchen is in. The cook starts
/// the curry, goes to the shopping list to check whether there is yoghurt,
/// comes back, puts the naan on halfway through — and none of that may reset
/// where they were. So the progress lives here rather than in the view that
/// draws it, the same way timers live in ``CookTimerCenter`` rather than in
/// the step they were started from.
///
/// Persisted for the same reason the timers are: an alarm that survives the
/// app being killed and rings "Curry — Schritt 3" needs a curry to come back
/// to.
@MainActor
@Observable
final class CookSession {
    private(set) var entries: [CookSessionEntry] = []
    /// The recipe the cook is looking at. `nil` falls back to the first.
    private(set) var activeRecipeID: UUID?
    /// Whether cook mode is on screen.
    ///
    /// Deliberately not persisted: a relaunch puts the cook back in the app
    /// with the band offering the way in, rather than in a full-screen cover
    /// they did not ask for.
    var isPresented = false

    private let defaults: UserDefaults
    private let key = "cookSession"

    init(defaults: UserDefaults = .sous) {
        self.defaults = defaults
        let stored = Self.load(from: defaults, key: key)
        entries = stored.entries
        activeRecipeID = stored.activeRecipeID
    }

    var isEmpty: Bool { entries.isEmpty }

    var activeEntry: CookSessionEntry? {
        entries.first { $0.recipeID == activeRecipeID } ?? entries.first
    }

    func entry(for recipeID: UUID) -> CookSessionEntry? {
        entries.first { $0.recipeID == recipeID }
    }

    /// Puts a recipe on the hob and opens cook mode on it.
    ///
    /// A recipe already in the session is switched to rather than added
    /// twice — and takes the serving count with it, which is the only way to
    /// change the servings of something already cooking: open it, set them,
    /// cook again.
    func start(_ recipe: Recipe, servings: Int) {
        if let index = entries.firstIndex(where: { $0.recipeID == recipe.id }) {
            entries[index].servings = servings
        } else {
            entries.append(CookSessionEntry(recipeID: recipe.id, servings: servings))
        }
        activeRecipeID = recipe.id
        isPresented = true
        save()
    }

    func show(_ recipeID: UUID) {
        guard entries.contains(where: { $0.recipeID == recipeID }) else { return }
        activeRecipeID = recipeID
        save()
    }

    /// Writes back a changed entry — the step scrolled to, an ingredient
    /// ticked off.
    func update(_ entry: CookSessionEntry) {
        guard let index = entries.firstIndex(where: { $0.recipeID == entry.recipeID }),
              entries[index] != entry
        else { return }
        entries[index] = entry
        save()
    }

    /// Takes a recipe off the hob, and closes cook mode if it was the last.
    func remove(_ recipeID: UUID) {
        entries.removeAll { $0.recipeID == recipeID }
        settle()
        save()
    }

    /// Drops entries whose recipe is no longer in the library — deleted from
    /// another window, or on another device.
    func prune(toRecipes ids: Set<UUID>) {
        let before = entries.count
        entries.removeAll { !ids.contains($0.recipeID) }
        guard entries.count != before else { return }
        settle()
        save()
    }

    /// Drops what nobody is coming back for, so last night's roast does not
    /// greet this morning's breakfast. The timers do the same with the same
    /// reasoning; this grace is longer, because a stew can sit for hours
    /// between two steps.
    func forgetStale(at now: Date = Date(), after grace: TimeInterval = 12 * 3600) {
        let before = entries.count
        entries.removeAll { $0.startedAt.addingTimeInterval(grace) < now }
        guard entries.count != before else { return }
        settle()
        save()
    }

    /// Keeps the pointers honest after the list has shrunk.
    private func settle() {
        if let active = activeRecipeID, !entries.contains(where: { $0.recipeID == active }) {
            activeRecipeID = entries.first?.recipeID
        }
        if entries.isEmpty {
            activeRecipeID = nil
            isPresented = false
        }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var entries: [CookSessionEntry] = []
        var activeRecipeID: UUID?
    }

    private func save() {
        let stored = Stored(entries: entries, activeRecipeID: activeRecipeID)
        defaults.set(try? JSONEncoder().encode(stored), forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> Stored {
        guard let data = defaults.data(forKey: key) else { return Stored() }
        return (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored()
    }
}
