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
    /// nutrition. Raised to 3 when the parser learned unquantified amounts
    /// ("Salz nach Geschmack") and the aggregator began carrying coverage.
    /// Raised to 4 when nutrition began resolving through SBLS codes instead
    /// of curated names, "Tasse" entered the unit vocabulary, and the set of
    /// known names moved from `ingredients.json` into `synonyms.json` — that
    /// set decides which lines the parser leaves whole at a comma. Raised to
    /// 5 when a basis gained a status: the same line now reads as counted,
    /// counted-but-unconfirmed, or deliberately without, and a figure cached
    /// before that says nothing about which.
    private static let readingVersion = 5

    /// The bundled data files. Everything the catalogs and the resolver read
    /// belongs in this list.
    static let bundledDataResources = ["bls", "synonyms", "measures", "aisles"]

    /// How many bytes each listed file contributed — internal so a test can
    /// tell "hashed four files" from "found none and hashed the void", which
    /// produce a perfectly ordinary-looking hash either way.
    static var bundledDataSizes: [(name: String, bytes: Int)] {
        bundledDataResources.map { resource in
            guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
                  let data = try? Data(contentsOf: url)
            else { return (resource, 0) }
            return (resource, data.count)
        }
    }

    /// What the bundled catalog data currently is, hashed from the shipped
    /// files themselves — an app update that ships new data has to invalidate
    /// every cached figure on its own, not wait for someone to remember a
    /// `readingVersion` bump.
    ///
    /// A file that cannot be read trips an assertion instead of being skipped
    /// over. Skipping was the quiet failure: rename the files and the loop
    /// finds nothing, the fingerprint collapses to the constant hash of no
    /// input, and from then on no data change ever invalidates a cached
    /// figure again — with nothing anywhere saying so.
    static let bundledDataFingerprint: String = {
        var hasher = SHA256()
        var found = 0
        for resource in bundledDataResources {
            guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
                  let data = try? Data(contentsOf: url)
            else { continue }
            found += 1
            hasher.update(data: data)
        }
        assert(
            found == bundledDataResources.count,
            "Only \(found) of \(bundledDataResources.count) bundled data files "
                + "(\(bundledDataResources)) could be read for the fingerprint"
        )
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    static func hash(for recipe: Recipe) -> String {
        hash(for: recipe, dataFingerprint: bundledDataFingerprint)
    }

    /// The fingerprint is injectable only so a test can prove new bundled
    /// data changes the hash without re-bundling the app.
    static func hash(for recipe: Recipe, dataFingerprint: String) -> String {
        let digest = SHA256.hash(
            data: Data("v\(readingVersion)|\(dataFingerprint)\n\(recipe.ingredientsText)\n\(recipe.instructionsText)".utf8)
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
