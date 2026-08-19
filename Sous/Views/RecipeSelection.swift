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
    /// The plan entry `recipe` was opened from, if it got here from one.
    ///
    /// An id rather than a captured serving count: the plan row stays live
    /// on screen beside the detail column, so a stepper pressed there has to
    /// be reflected here too — capturing the count at the moment of opening
    /// would freeze it at whatever it was when the cook clicked through.
    /// Whoever sets `recipe` from somewhere else is responsible for clearing
    /// this back to `nil`.
    var plannedEntryID: MealPlanEntry.ID?
}
