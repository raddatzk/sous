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
    public var createdBy: UUID?
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision
    public var deletedAt: Date?

    /// Title, categories and ingredient names, lowercased.
    ///
    /// Denormalized so that searching by ingredient stays a single indexed
    /// comparison instead of parsing every recipe on every keystroke.
    public var searchText: String = ""
    /// Canonical ingredient keys, so filtering by "Tomate" finds a recipe
    /// that writes "Cocktailtomaten".
    public var ingredientKeys: [String] = []

    public init(_ recipe: Recipe, catalog: IngredientCatalog = .bundled) {
        id = recipe.id
        apply(recipe, catalog: catalog)
    }

    /// Overwrites every field from `recipe`, keeping the identity.
    public func apply(_ recipe: Recipe, catalog: IngredientCatalog = .bundled) {
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
        createdBy = recipe.createdBy
        createdAt = recipe.createdAt
        updatedAt = recipe.updatedAt
        deletedAt = recipe.deletedAt
        searchText = Self.searchText(for: recipe)
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
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    static func ingredientKeys(for recipe: Recipe, catalog: IngredientCatalog) -> [String] {
        var seen = Set<String>()
        return recipe.ingredients.compactMap { ingredient in
            let key = ShoppingItem.key(for: ingredient.name, catalog: catalog)
            return key.isEmpty || !seen.insert(key).inserted ? nil : key
        }
    }

    static func searchText(for recipe: Recipe) -> String {
        var parts = [recipe.title]
        parts.append(contentsOf: recipe.categories)
        parts.append(contentsOf: recipe.ingredients.map(\.name))
        return parts.joined(separator: " ").lowercased()
    }
}
