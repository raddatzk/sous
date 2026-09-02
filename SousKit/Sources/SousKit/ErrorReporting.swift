import Foundation

/// Something that keeps the last thing that went wrong, for a screen to show.
///
/// Every library sets `errorMessage` when a write fails and clears it once
/// the message has been read. What none of them can do is show it — that is
/// a screen's job — and for a while only half of them had a screen that did.
/// A shopping list that could not be written, a plan entry that did not
/// move, a nutrition cache that failed to clear: set, and never seen. One
/// protocol lets one alert modifier serve all of them, so binding a new
/// library to the screen is a line rather than a copy of the last one.
@MainActor
public protocol ErrorReporting: AnyObject {
    /// What last went wrong, in the words the screen shows — `nil` once seen.
    var errorMessage: String? { get set }
}

extension RecipeLibrary: ErrorReporting {}
extension ShoppingLibrary: ErrorReporting {}
extension MealPlanLibrary: ErrorReporting {}
extension DinnerPlannerLibrary: ErrorReporting {}
extension NutritionLibrary: ErrorReporting {}
extension IngredientCatalogLibrary: ErrorReporting {}
