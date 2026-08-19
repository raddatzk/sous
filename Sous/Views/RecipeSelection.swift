import Observation
import SousKit
import SwiftUI

/// The recipe the detail column is showing.
///
/// On the Mac the window is one split view with the sections switched above
/// it, so the right-hand column outlives the section on the left: a recipe
/// stays open while the cook flips over to the shopping list to check whether
/// there is yoghurt. That makes the selection app state rather than something
/// the recipe list owns — the meal plan puts a recipe there too.
///
/// The phone has no second column and pushes instead, so nothing reads this
/// there.
@MainActor
@Observable
final class RecipeSelection {
    var recipe: Recipe?
    /// How many people `recipe` was on the plan for, if it got here from one.
    /// The detail column starts scaled to this instead of the recipe's own
    /// count, and whoever sets `recipe` from somewhere else is responsible
    /// for clearing it back to `nil`.
    var plannedServings: Int?
}
