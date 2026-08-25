import Foundation

/// Storage for a recipe's computed nutrition, kept separate from the recipe
/// itself the same way `RecipeEnrichmentStore` is: a derived, replaceable
/// fact, not part of what a person typed — but one that also goes stale when
/// a linked sub-recipe changes, not only when the recipe's own text does.
public protocol RecipeNutritionStore: Sendable {
    /// The nutrition cached for `recipe` given `resolve`, or `nil` if
    /// nothing is cached, or what is cached was computed against different
    /// content than `recipe` (or one of its links) currently has.
    func nutrition(for recipe: Recipe, resolve: @Sendable (UUID) -> Recipe?) async throws -> RecipeNutrition?
    /// Replaces whatever was cached for this recipe with `nutrition`,
    /// stamped against `recipe`'s and its links' current content.
    func save(_ nutrition: RecipeNutrition, for recipe: Recipe, resolve: @Sendable (UUID) -> Recipe?) async throws
    func delete(recipeID: UUID) async throws
    /// Drops every cached figure.
    ///
    /// The cache is keyed by a recipe's *text*, which says nothing about the
    /// catalog the text was resolved against — so teaching the app a new
    /// alias or a new nutrition entry would otherwise leave every recipe
    /// already looked at showing the old, partial total forever.
    func invalidateAll() async throws
}
