import Foundation
import SwiftData

/// Re-keys the cook's own data from curated names onto SBLS codes, once.
///
/// Everything the cook owned pointed at an ingredient by its *name* — which
/// worked only as long as the bundled catalog's names were the app's identity
/// for a food. They are not any more: a name is what a BLS release happens to
/// call something, a code is what it is. The concept's most important
/// invariant (§7) is that user data references the shipped world by domain key
/// stored as a value, so that a release can be swapped in wholesale.
///
/// The migration is deliberately non-destructive. A row whose name still maps
/// cleanly gains its code and keeps its name; a row whose name maps to nothing
/// keeps working exactly as before — the name stays the join key — and is
/// marked for the review UI phase 4 builds. Nothing is deleted, nothing is
/// guessed: an unmappable row is a question for the cook, not for a heuristic.
public enum BundledDataMigration {
    /// What one run did, so a caller (and a test) can see it happened.
    public struct Report: Hashable, Sendable {
        public var nutritionRekeyed = 0
        public var nutritionFlagged = 0
        public var aliasesRekeyed = 0
        public var aliasesFlagged = 0

        public var didChangeAnything: Bool {
            nutritionRekeyed + nutritionFlagged + aliasesRekeyed + aliasesFlagged > 0
        }
    }

    /// The code a curated name maps to, or `nil` if nothing does.
    ///
    /// "Cleanly" means: the synonym table knows the name, and it has a basis.
    /// A word that resolves to identity but to no values — the spices — is
    /// *not* a clean map: there is no code to write down, and pretending
    /// otherwise would invent one.
    static func code(forName name: String, synonyms: SynonymTable) -> String? {
        guard let entry = synonyms.entry(for: name) else { return nil }
        for state in IngredientState.displayOrder {
            if let target = entry.target(for: state) { return target.code }
        }
        return nil
    }
}

/// Runs the re-key against a SwiftData store.
@ModelActor
public actor SwiftDataBundledDataMigration {
    /// Stamps every stored row that can be stamped, and flags the rest.
    /// Idempotent: a row that already carries a code, or has already been
    /// flagged, is left alone, so this can run on every launch.
    public func run(synonyms: SynonymTable = .bundled) throws -> BundledDataMigration.Report {
        var report = BundledDataMigration.Report()

        for row in try modelContext.fetch(FetchDescriptor<StoredCatalogNutrition>()) {
            guard row.blsCode == nil, !row.needsBasisReview else { continue }
            if let code = BundledDataMigration.code(forName: row.name, synonyms: synonyms) {
                row.blsCode = code
                report.nutritionRekeyed += 1
            } else {
                row.needsBasisReview = true
                report.nutritionFlagged += 1
            }
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredIngredientAliasOverride>()) {
            guard row.blsCode == nil, !row.needsBasisReview else { continue }
            // The alias points at whichever entry answers to `canonicalKey`,
            // which is a normalized name — the same lookup the catalog does.
            if let code = BundledDataMigration.code(forName: row.canonicalKey, synonyms: synonyms) {
                row.blsCode = code
                report.aliasesRekeyed += 1
            } else {
                row.needsBasisReview = true
                report.aliasesFlagged += 1
            }
        }

        if report.didChangeAnything {
            try modelContext.save()
        }
        return report
    }
}
