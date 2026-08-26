import Foundation
import SwiftData
@testable import SousKit

/// Writes rows in the shapes the app used before the vocabulary absorbed
/// them, so the migrations can be tested against a store that looks like a
/// cook's did.
///
/// The stores that used to write these shapes are gone — that is the point of
/// phase 4 — but the rows they left behind are not, and a migration nobody
/// can set up a fixture for is a migration nobody can test.
@ModelActor
actor LegacyRows {
    func addOwnIngredient(_ ingredient: CatalogIngredient) throws {
        modelContext.insert(StoredCatalogIngredient(ingredient))
        try modelContext.save()
    }

    func addOwnNutrition(_ nutrition: CatalogNutrition) throws {
        modelContext.insert(StoredCatalogNutrition(nutrition))
        try modelContext.save()
    }

    func addAlias(_ alias: String, toKey key: String) throws {
        modelContext.insert(StoredIngredientAliasOverride(canonicalKey: key, alias: alias))
        try modelContext.save()
    }

    func addPantryFlag(key: String) throws {
        modelContext.insert(StoredPantryFlag(key: key))
        try modelContext.save()
    }

    // MARK: - Reading back, as values rather than as models

    func ownNutritionNames() throws -> [String] {
        try modelContext.fetch(FetchDescriptor<StoredCatalogNutrition>()).map(\.name).sorted()
    }

    func ownNutritionCodes() throws -> [String: String?] {
        try modelContext.fetch(FetchDescriptor<StoredCatalogNutrition>())
            .reduce(into: [:]) { $0[$1.name] = $1.blsCode }
    }

    func flaggedNutritionNames() throws -> [String] {
        try modelContext.fetch(FetchDescriptor<StoredCatalogNutrition>())
            .filter(\.needsBasisReview).map(\.name).sorted()
    }

    func aliasesByKey() throws -> [String: [String]] {
        try modelContext.fetch(FetchDescriptor<StoredIngredientAliasOverride>())
            .reduce(into: [:]) { $0[$1.canonicalKey, default: []].append($1.alias) }
    }

    func flaggedAliases() throws -> [String] {
        try modelContext.fetch(FetchDescriptor<StoredIngredientAliasOverride>())
            .filter(\.needsBasisReview).map(\.alias).sorted()
    }

    /// How many legacy rows are left. Zero after a fold: the content has been
    /// written elsewhere, and a row that stayed would be folded twice.
    func remainingCount() throws -> Int {
        try modelContext.fetch(FetchDescriptor<StoredCatalogIngredient>()).count
            + (try modelContext.fetch(FetchDescriptor<StoredIngredientAliasOverride>()).count)
            + (try modelContext.fetch(FetchDescriptor<StoredCatalogNutrition>()).count)
            + (try modelContext.fetch(FetchDescriptor<StoredPantryFlag>()).count)
    }
}
