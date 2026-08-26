import Observation
import SousKit
import SwiftUI

/// What the detail column is showing.
///
/// On the Mac the window is one split view with the sections switched above
/// it, so the right-hand column outlives the section on the left: a recipe
/// stays open while the cook flips over to the shopping list to check whether
/// there is yoghurt. That makes the selection app state rather than something
/// the recipe list owns — the meal plan puts a recipe there too.
///
/// The phone has no second column and pushes instead. It still keeps this in
/// step with what it pushed, because a page that is itself pushed has no
/// other way to say "show this one now" — which is what happens when a
/// variant is created from the recipe being read.
@MainActor
@Observable
final class RecipeSelection {
    /// A recipe or the group several versions of a dish stand in.
    ///
    /// One value rather than two optionals, so "a recipe and a group are both
    /// showing" is not a state that can be written down. The group is the
    /// only thing in the app that is opened and is not a recipe — plan
    /// entries and shopping lists always reach a variant, never the group.
    enum Target: Hashable {
        case recipe(Recipe)
        case group(VariantGroup)
    }

    var target: Target?

    /// The recipe showing, if what is showing is a recipe.
    ///
    /// A view onto `target` rather than storage of its own: the meal plan and
    /// the recipe list both set and read a recipe and have no use for groups,
    /// and this keeps them written the way they were.
    var recipe: Recipe? {
        get {
            guard case .recipe(let recipe) = target else { return nil }
            return recipe
        }
        set { target = newValue.map(Target.recipe) }
    }

    var group: VariantGroup? {
        guard case .group(let group) = target else { return nil }
        return group
    }

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
