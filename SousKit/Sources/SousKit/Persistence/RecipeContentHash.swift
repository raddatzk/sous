import CryptoKit
import Foundation

/// Whether a recipe's ingredients or instructions have changed since
/// something was cached against them — the same "derive an identity from
/// content" idea as `StableID`, but content-only: no position, and no
/// stamping into UUID shape, since this is compared as a plain string, not
/// used for SwiftUI identity.
enum RecipeContentHash {
    /// Bumped when the *reading* of unchanged text changes, not the text
    /// itself — otherwise every already-cached recipe keeps serving what the
    /// old parser derived. Raised to 2 when `IngredientParser` stopped
    /// splitting catalog names that carry a comma ("Sauerrahm/Schmand, mind.
    /// 20 % Fett"), which silently left those ingredients out of a recipe's
    /// nutrition.
    private static let readingVersion = 2

    static func hash(for recipe: Recipe) -> String {
        let digest = SHA256.hash(
            data: Data("v\(readingVersion)\n\(recipe.ingredientsText)\n\(recipe.instructionsText)".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Like `hash(for:)`, but folds in every recipe `recipe` links to —
    /// transitively, up to the same depth `NutritionAggregator` follows.
    /// Nutrition depends on what a linked sub-recipe is made of, so editing
    /// "Naan" has to invalidate the cached nutrition of every recipe that
    /// links to it, even though their own text never changed.
    static func hash(for recipe: Recipe, resolve: @Sendable (UUID) -> Recipe?) -> String {
        var seen: Set<UUID> = [recipe.id]
        var parts = [hash(for: recipe)]
        collectLinkedHashes(of: recipe, depth: 0, seen: &seen, into: &parts, resolve: resolve)
        return hash(for: parts.joined(separator: "\n"))
    }

    private static func collectLinkedHashes(
        of recipe: Recipe, depth: Int, seen: inout Set<UUID>, into parts: inout [String], resolve: @Sendable (UUID) -> Recipe?
    ) {
        guard depth < 3 else { return }
        for id in recipe.linkedRecipeIDs where seen.insert(id).inserted {
            guard let linked = resolve(id) else { continue }
            parts.append(hash(for: linked))
            collectLinkedHashes(of: linked, depth: depth + 1, seen: &seen, into: &parts, resolve: resolve)
        }
    }

    private static func hash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
