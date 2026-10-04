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
    /// before that says nothing about which. Raised to 6 when the parser
    /// began reading preparation states and the measure table's densities
    /// went live: the same unchanged line now picks a different basis and a
    /// different number of grams. The bundled data moved with it, so the
    /// fingerprint would have caught most of this — but not all of it, since
    /// the resolver's order changed in code alone. Raised to 7 when the
    /// container words entered the unit vocabulary ("Dose", "Glas",
    /// "Stange", "Zweig", "Stiel", "cm"): the same unchanged line now
    /// parses to a different name — "Kokosmilch" instead of
    /// "Dose Kokosmilch" — and everything keyed on the name moves with it.
    /// Raised to 8 when the catalog began reading a variety written the list
    /// way round: "1 Zwiebel, rot" is no longer an onion prepared "rot" but
    /// a whole name that resolves to "Rote Zwiebel".
    /// Raised to 9 when `IngredientCatalog.normalize` began folding ß and
    /// hyphens: "Weisswein" and "Hokkaido-Kürbis" now find what "Weißwein"
    /// and "Hokkaidokürbis" found, in code alone.
    /// Raised to 10 when `IngredientLineReader` replaced the tolerant parser:
    /// a line outside the fixed form ("Salz nach Geschmack", "1 Chili (rot)")
    /// no longer reaches a name, and "1 1/2 TL" is one and a half.
    /// Raised to 11 when the household vocabulary stopped taking part:
    /// a spelling or variety the cook once taught no longer
    /// reaches a name, and no basis is "proposed" or "orphaned" any more.
    /// Raised to 12 when a value the source leaves out became absent rather
    /// than zero: a cached figure carries no per-nutrient coverage,
    /// and the NRF badge and the fibre tag now ask for it.
    static let readingVersion = 12

    /// What the data a recipe was read against is: the reading version and
    /// the data set's release, `r<readingVersion>-<dataVersion>`.
    ///
    /// It used to be a hash over the bundled files. With data that can
    /// change without an app release (INGREDIENTS-DATA §5), the set names
    /// itself instead: its `dataVersion` is raised by the compiler whenever
    /// any file's bytes change, bundled and fetched sets are one series, and
    /// a process keeps its set for life — so the number says everything the
    /// hash did, and a switch of the set changes it the same way an app
    /// update with new data does.
    ///
    /// The reading version rides along: the fingerprint answers "would the
    /// app derive something different from the same stored text?", and a
    /// reader that reads differently is exactly such a change —
    /// `BundledDataMarker` compares this string, so a code-only bump re-runs
    /// the reconciliation and the search reindex the same way new data does.
    static func fingerprint(dataVersion: Int) -> String {
        "r\(readingVersion)-\(dataVersion)"
    }

    /// The fingerprint of the data set this process runs on.
    static var dataFingerprint: String { DataSet.current.fingerprint }

    static func hash(for recipe: Recipe) -> String {
        hash(for: recipe, dataFingerprint: dataFingerprint)
    }

    /// The fingerprint is injectable only so a test can prove a new data set
    /// changes the hash without activating one.
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
