import Foundation
import SwiftData

/// Folds the three user tables the vocabulary absorbs into it, once.
///
/// Before this, what the cook owned about an ingredient lay in four places
/// keyed by four different notions of the same name: an own catalog entry, an
/// added spelling, hand-typed nutrition, a pantry flag. Nothing could say
/// "this is a variety of that" or "this mapping is confirmed", because there
/// was no *this* — only rows that happened to share a normalized string.
///
/// The migration is a widening, not a rename: everything the old rows held
/// arrives in the new one, the phase-3 stamps (`blsCode`, `needsBasisReview`)
/// included, and the legacy rows are removed only once their content has been
/// written. Merging by key rather than inserting is what makes it both
/// idempotent and safe against the share extension, which never runs it and
/// may well have written a vocabulary row of its own first.
public enum VocabularyMigration {
    /// What one run did, so a caller (and a test) can see it happened.
    public struct Report: Hashable, Sendable {
        public var ingredientsFolded = 0
        public var aliasesFolded = 0
        public var nutritionFolded = 0
        public var pantryFlagsFolded = 0

        public var didChangeAnything: Bool {
            ingredientsFolded + aliasesFolded + nutritionFolded + pantryFlagsFolded > 0
        }
    }
}

/// Runs the fold against a SwiftData store.
@ModelActor
public actor SwiftDataVocabularyMigration {
    /// Idempotent by construction: the legacy rows are deleted in the same
    /// save that writes their content, so a second run finds nothing to fold.
    public func run(catalog: IngredientCatalog = .bundled) throws -> VocabularyMigration.Report {
        var report = VocabularyMigration.Report()
        var touched: [String: StoredIngredientVocabulary] = [:]

        /// The row for a key, from this run, from the store, or brand new.
        func entry(key: String, name: String) -> StoredIngredientVocabulary? {
            guard !key.isEmpty else { return nil }
            if let known = touched[key] { return known }
            var descriptor = FetchDescriptor<StoredIngredientVocabulary>(
                predicate: #Predicate { $0.key == key }
            )
            descriptor.fetchLimit = 1
            let row = (try? modelContext.fetch(descriptor).first)
                ?? StoredIngredientVocabulary(key: key, name: name)
            if row.modelContext == nil { modelContext.insert(row) }
            touched[key] = row
            return row
        }

        /// What to call an entry the cook only ever referred to by key — the
        /// alias and pantry tables never stored a display name.
        func displayName(forKey key: String) -> String {
            catalog.ingredient(for: key)?.name ?? key
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredCatalogIngredient>()) {
            guard let target = entry(key: row.key, name: row.name) else {
                modelContext.delete(row)
                continue
            }
            target.name = row.name
            target.isOwnIngredient = true
            target.aliases = merge(target.aliases, row.aliases)
            target.categoryRaw = row.categoryRaw
            modelContext.delete(row)
            report.ingredientsFolded += 1
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredIngredientAliasOverride>()) {
            guard let target = entry(
                key: row.canonicalKey, name: displayName(forKey: row.canonicalKey)
            ) else {
                modelContext.delete(row)
                continue
            }
            target.aliases = merge(target.aliases, [row.alias])
            // The stamp phase 3 set and nobody read: a spelling whose target
            // maps to no row at all is a question, and this is the list it
            // goes on.
            target.needsBasisReview = target.needsBasisReview || row.needsBasisReview
            modelContext.delete(row)
            report.aliasesFolded += 1
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredCatalogNutrition>()) {
            guard let target = entry(key: row.key, name: row.name) else {
                modelContext.delete(row)
                continue
            }
            if !target.isOwnIngredient { target.name = row.name }
            var bases = target.bases
            // Only where nothing has been said yet: an entry the extension
            // already wrote a basis for was written *later* than this row.
            if bases[IngredientState.unspecified.rawValue] == nil {
                bases[IngredientState.unspecified.rawValue] = BasisAssignment.ownValues(
                    row.values, code: row.blsCode, source: row.source
                )
            }
            target.bases = bases
            if let perPiece = row.unitWeightGramsPerPiece {
                var weights = target.unitWeightsGrams
                weights[IngredientUnit.piece.symbol] = weights[IngredientUnit.piece.symbol] ?? perPiece
                target.unitWeightsGrams = weights
            }
            target.needsBasisReview = target.needsBasisReview || row.needsBasisReview
            modelContext.delete(row)
            report.nutritionFolded += 1
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredPantryFlag>()) {
            guard let target = entry(key: row.key, name: displayName(forKey: row.key)) else {
                modelContext.delete(row)
                continue
            }
            target.isPantry = true
            modelContext.delete(row)
            report.pantryFlagsFolded += 1
        }

        if report.didChangeAnything {
            for row in touched.values { row.updatedAt = .nowInSyncPrecision }
            try modelContext.save()
        }
        return report
    }

    /// Spellings added twice are one spelling — matched normalized, kept as
    /// first written.
    private func merge(_ existing: [String], _ added: [String]) -> [String] {
        var seen = Set(existing.map(IngredientCatalog.normalize))
        return existing + added.filter { seen.insert(IngredientCatalog.normalize($0)).inserted }
    }
}

extension StoredCatalogNutrition {
    /// The flat scalars as the value set they stand for. Everything the form
    /// never asked about stays 0, which is what an unknown nutrient already
    /// means to the aggregator.
    var values: NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: proteinG, fatG: fatG, saturatedFatG: saturatedFatG ?? 0,
            carbsG: carbsG, sugarG: sugarG ?? 0, fiberG: fiberG ?? 0, sodiumMg: sodiumMg ?? 0,
            vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
            calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }
}
