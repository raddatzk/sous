import Foundation

/// Storage for what `AmountAIExtractor` found, kept separate from the
/// recipe itself for the same reason images are: it is a derived,
/// replaceable fact about a recipe, not part of the aggregate a person
/// typed. Unlike an image, though, it goes stale — the content hash
/// comparison lives here rather than in the caller, so nothing outside
/// this store needs to know how staleness is decided.
public protocol RecipeEnrichmentStore: Sendable {
    /// The claims cached for `recipe`, or `nil` if nothing is cached, or
    /// what is cached was found against different ingredients or
    /// instructions than `recipe` currently has.
    func claims(for recipe: Recipe) async throws -> [StoredAmountClaim]?
    /// Replaces whatever was cached for this recipe with `claims`, stamped
    /// against `recipe`'s current text.
    func save(_ claims: [StoredAmountClaim], for recipe: Recipe) async throws
    func delete(recipeID: UUID) async throws
}
