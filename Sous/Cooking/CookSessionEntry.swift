import Foundation

/// One recipe on the hob, and where the cook has got to in it.
///
/// The recipe itself is not kept here, only its id. A recipe edited while it
/// is being cooked should change under the cook's hands, and one deleted
/// should take its entry with it — both of which a stored copy would quietly
/// prevent. What this holds is the part that belongs to the cooking rather
/// than to the recipe: the step in focus, the ingredients already dealt with.
struct CookSessionEntry: Identifiable, Codable, Hashable, Sendable {
    /// Which side of a recipe is showing.
    enum Page: String, Codable, Hashable, Sendable {
        case steps
        case ingredients
    }

    /// Also the entry's identity: the same recipe twice in one session would
    /// be two cooks working from one page.
    var recipeID: UUID
    /// The serving count the cook chose, so every amount shown — in the list
    /// and inside the step text — matches what they were reading.
    var servings: Int
    /// Where the cook is. `nil` until the recipe is first drawn, and reset to
    /// the first step when an edit takes the step it pointed at away.
    var focusedStepID: UUID?
    var checkedIngredients: Set<UUID> = []
    /// Kept per recipe, because switching to the other pot and back should
    /// return to what was being read, not to the top of the steps.
    var page: Page = .steps
    /// Whether the last step has been in focus at any point. Kept rather than
    /// compared on the way out, because scrolling back up to check something
    /// does not undo having cooked the dish.
    var didReachLastStep = false
    var startedAt = Date()

    var id: UUID { recipeID }
}
