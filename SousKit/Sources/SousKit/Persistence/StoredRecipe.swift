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
        variantGroupID = recipe.variantGroupID
        createdBy = recipe.createdBy
        createdAt = recipe.createdAt
        updatedAt = recipe.updatedAt
        deletedAt = recipe.deletedAt
        searchText = Self.searchText(for: recipe, variantGroupTitle: variantGroupTitle, catalog: catalog)
        ingredientKeys = Self.ingredientKeys(for: recipe, catalog: catalog)
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
            variantGroupID: variantGroupID,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    /// The ingredients a recipe can be filtered by — each line's own key and,
    /// for a variety, its parent's as well.
    ///
    /// Both, because a recipe calling for Cocktailtomaten *is* a recipe with
    /// tomatoes in it. Filtering by "Tomate" and not finding it would be the
    /// swallowing the variety relation exists to prevent, in the other
    /// direction: the shopping list keeps them apart, the library keeps them
    /// together.
    static func ingredientKeys(for recipe: Recipe, catalog: IngredientCatalog) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for ingredient in recipe.ingredients {
            let name = ShoppingItem.displayName(for: ingredient.name)
            let own = ShoppingItem.key(for: ingredient.name, catalog: catalog)
            let parent = catalog.ingredient(for: name)?.parentName.map(IngredientCatalog.normalize)
            for key in [own, parent].compactMap({ $0 }) {
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                keys.append(key)
            }
        }
        return keys
    }

    static func searchText(for recipe: Recipe, variantGroupTitle: String? = nil, catalog: IngredientCatalog = .bundled) -> String {
        var parts = [recipe.title]
        if let variantGroupTitle, !variantGroupTitle.isEmpty {
            parts.append(variantGroupTitle)
        }
        parts.append(contentsOf: recipe.categories)
        parts.append(contentsOf: recipe.ingredients.map(\.name))
        // The canonical keys as well, parents included — typing "Kürbis"
        // into the search field must find the recipe whose list only ever
        // says "Hokkaido", the same reach the ingredient filter has always
        // had through `ingredientKeys`.
        parts.append(contentsOf: ingredientKeys(for: recipe, catalog: catalog))
        return parts.joined(separator: " ").lowercased()
    }
}
