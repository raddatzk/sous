import Foundation
import SwiftData

/// The persisted form of a recipe.
///
/// A mirror of ``Recipe`` rather than the domain type itself: SwiftData
/// models are reference types bound to a `ModelContext` and cannot cross an
/// actor boundary, while the domain aggregate is a `Sendable` value.
///
/// Ingredients and instructions are single text columns, because the text is
/// what the recipe *is*. Structure is parsed from it when something needs it,
/// which is why there are no child entities here and no relationship order to
/// keep straight.
@Model
public final class StoredRecipe {
    #Index<StoredRecipe>([\.title], [\.updatedAt])

    public var id: UUID = UUID()
    public var title: String = ""
    public var summary: String?
    public var servings: Int = 2
    public var ingredientsText: String = ""
    public var instructionsText: String = ""
    public var categories: [String] = []
    public var isFavorite: Bool = false
    public var wantToCook: Bool = false
    public var notes: String?
    public var sourceKind: String = RecipeSource.Kind.manual.rawValue
    public var sourceURL: URL?
    public var sourceName: String?
    public var prepTimeSeconds: Int?
    public var cookTimeSeconds: Int?
    public var totalTimeSeconds: Int?
    public var imageIDs: [UUID] = []
    /// ``Recipe/suitableSlots`` as raw values; `nil` where nobody chose.
    public var suitableSlotsRaw: [String]?
    /// ``Recipe/effortOverride`` as its raw value; `nil` where nobody
    /// overruled the structure.
    public var effortOverrideRaw: String?
    /// The ``StoredVariantGroup`` this recipe is one version of. A plain id
    /// rather than a relationship: the group owns nothing, and a member that
    /// outlives its group row reads as ungrouped rather than as a broken
    /// object graph.
    public var variantGroupID: UUID?
    public var createdBy: UUID?
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision
    public var deletedAt: Date?

    /// Title, variant group title, categories and ingredient names,
    /// lowercased.
    ///
    /// Denormalized so that searching by ingredient stays a single indexed
    /// comparison instead of parsing every recipe on every keystroke.
    public var searchText: String = ""
    /// Canonical ingredient keys, so filtering by "Tomate" finds a recipe
    /// that writes "Cocktailtomaten".
    public var ingredientKeys: [String] = []

    public init(
        _ recipe: Recipe,
        catalog: IngredientCatalog = .bundled,
        variantGroupTitle: String? = nil
    ) {
        id = recipe.id
        apply(recipe, catalog: catalog, variantGroupTitle: variantGroupTitle)
    }

    /// Overwrites every field from `recipe`, keeping the identity.
    ///
    /// `variantGroupTitle` is the one thing here the recipe cannot supply
    /// itself: the group's name is folded into `searchText` so that "Chili"
    /// finds the members and the group's row appears because they did — see
    /// ``StoredVariantGroup``. The caller looks it up, because only the store
    /// can.
    public func apply(
        _ recipe: Recipe,
        catalog: IngredientCatalog = .bundled,
        variantGroupTitle: String? = nil
    ) {
        title = recipe.title
        summary = recipe.summary
        servings = recipe.servings
        ingredientsText = recipe.ingredientsText
        instructionsText = recipe.instructionsText
        categories = recipe.categories
        isFavorite = recipe.isFavorite
        wantToCook = recipe.wantToCook
        notes = recipe.notes
        sourceKind = recipe.source.kind.rawValue
        sourceURL = recipe.source.url
        sourceName = recipe.source.name
        prepTimeSeconds = recipe.prepTimeSeconds
        cookTimeSeconds = recipe.cookTimeSeconds
        totalTimeSeconds = recipe.totalTimeSeconds
        imageIDs = recipe.imageIDs
        suitableSlotsRaw = recipe.suitableSlots.map { slots in
            slots.map(\.rawValue).sorted()
        }
        effortOverrideRaw = recipe.effortOverride?.rawValue
        variantGroupID = recipe.variantGroupID
        createdBy = recipe.createdBy
        createdAt = recipe.createdAt
        updatedAt = recipe.updatedAt
        deletedAt = recipe.deletedAt
        searchText = RecipeIndex.searchText(for: recipe, variantGroupTitle: variantGroupTitle, catalog: catalog)
        ingredientKeys = RecipeIndex.ingredientKeys(for: recipe, catalog: catalog)
    }

    public var domainValue: Recipe {
        Recipe(
            id: id,
            title: title,
            summary: summary,
            servings: servings,
            ingredientsText: ingredientsText,
            instructionsText: instructionsText,
            categories: categories,
            isFavorite: isFavorite,
            wantToCook: wantToCook,
            notes: notes,
            source: RecipeSource(
                kind: RecipeSource.Kind(rawValue: sourceKind) ?? .manual,
                url: sourceURL,
                name: sourceName
            ),
            prepTimeSeconds: prepTimeSeconds,
            cookTimeSeconds: cookTimeSeconds,
            totalTimeSeconds: totalTimeSeconds,
            imageIDs: imageIDs,
            suitableSlots: suitableSlotsRaw.map { raw in
                Set(raw.compactMap(MealSlot.init(rawValue:)))
            },
            effortOverride: effortOverrideRaw.flatMap(RecipeEffort.Level.init(rawValue:)),
            variantGroupID: variantGroupID,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
