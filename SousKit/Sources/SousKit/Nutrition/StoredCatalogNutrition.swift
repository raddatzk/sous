import Foundation
import SwiftData

/// Nutrition a cook entered by hand for one ingredient.
///
/// **Legacy.** Folded into ``StoredIngredientVocabulary`` as an own-values
/// basis — a widening, not a rename: this row holds one state, eight of the
/// sixteen nutrients, one piece weight and no candidates, and the assignment
/// it becomes has room for all of it. Kept in the schema for the migration.
///
/// Flat scalars rather than a stored `NutritionInfo`: this is what a person
/// can reasonably read off a packet — energy and the four macros, plus the
/// few extras a label usually prints — and a form that asked for sixteen
/// nutrients including vitamin D would not get filled in at all. Everything
/// not asked for stays 0, which is what an unknown nutrient already means to
/// the aggregator.
@Model
public final class StoredCatalogNutrition {
    #Index<StoredCatalogNutrition>([\.key])

    /// The normalized canonical name this applies to, matching
    /// ``CatalogIngredient/key`` — nutrition is looked up by the name the
    /// catalog resolved to, never by what a recipe wrote.
    public var key: String = ""
    public var name: String = ""
    /// The SBLS code this entry belongs to, once the name has been resolved to
    /// one — the value join into the shipped world that survives a data swap.
    /// `nil` until `BundledDataMigration` has run, and permanently `nil` for a
    /// name that maps to no BLS row, which keeps joining by name.
    public var blsCode: String?
    /// Set where the name maps to nothing: the compatibility path still works,
    /// and phase 4's review UI has a list of what to ask about.
    public var needsBasisReview: Bool = false
    public var kcal: Double = 0
    public var proteinG: Double = 0
    public var fatG: Double = 0
    public var carbsG: Double = 0
    public var saturatedFatG: Double?
    public var sugarG: Double?
    public var fiberG: Double?
    public var sodiumMg: Double?
    /// What one piece weighs, for the ingredients recipes count rather than
    /// weigh — "2 Zwiebeln". Absent when the ingredient has no typical size.
    public var unitWeightGramsPerPiece: Double?
    public var source: String = CatalogNutrition.ownSource
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ nutrition: CatalogNutrition) {
        key = IngredientCatalog.normalize(nutrition.name)
        apply(nutrition)
    }

    public func apply(_ nutrition: CatalogNutrition) {
        let values = nutrition.nutrition(for: .unspecified) ?? .zero
        name = nutrition.name
        kcal = values.kcal
        proteinG = values.proteinG
        fatG = values.fatG
        carbsG = values.carbsG
        saturatedFatG = values.saturatedFatG
        sugarG = values.sugarG
        fiberG = values.fiberG
        sodiumMg = values.sodiumMg
        unitWeightGramsPerPiece = nutrition.unitWeightsGrams[IngredientUnit.piece.symbol]
        source = nutrition.source
        updatedAt = .nowInSyncPrecision
    }

    public var domainValue: CatalogNutrition {
        CatalogNutrition(
            name: name,
            // One variant, not raw/cooked: nobody types a food in twice.
            perHundredGrams: [IngredientState.unspecified.rawValue: NutritionInfo(
                kcal: kcal, proteinG: proteinG, fatG: fatG, saturatedFatG: saturatedFatG ?? 0,
                carbsG: carbsG, sugarG: sugarG ?? 0, fiberG: fiberG ?? 0, sodiumMg: sodiumMg ?? 0,
                vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
                calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
            )],
            unitWeightsGrams: unitWeightGramsPerPiece.map { [IngredientUnit.piece.symbol: $0] } ?? [:],
            densityGramsPerMl: nil,
            source: source
        )
    }
}
