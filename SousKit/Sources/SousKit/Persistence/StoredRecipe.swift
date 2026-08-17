import Foundation
import SwiftData

/// The persisted form of a recipe.
///
/// Deliberately a mirror of ``Recipe`` rather than the domain type itself:
/// SwiftData models are reference types bound to a `ModelContext` and cannot
/// cross an actor boundary, while the domain aggregate is a `Sendable` value.
/// The mapping between them is the price for keeping the domain free of the
/// persistence framework.
@Model
public final class StoredRecipe {
    #Index<StoredRecipe>([\.title], [\.updatedAt])

    public var id: UUID = UUID()
    public var title: String = ""
    public var summary: String?
    public var servings: Int = 2
    public var categories: [String] = []
    public var isFavorite: Bool = false
    public var wantToCook: Bool = false
    public var notes: String?
    public var sourceKind: String = RecipeSource.Kind.manual.rawValue
    public var sourceURL: URL?
    public var sourceName: String?
    public var prepTimeSeconds: Int?
    public var cookTimeSeconds: Int?
    public var createdBy: UUID?
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision
    public var deletedAt: Date?

    /// Title, categories and ingredient names, lowercased.
    ///
    /// Denormalized because predicates across a relationship are fragile, and
    /// searching by ingredient is a first-class need, not an afterthought.
    public var searchText: String = ""

    @Relationship(deleteRule: .cascade, inverse: \StoredIngredient.recipe)
    public var ingredients: [StoredIngredient] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredStep.recipe)
    public var steps: [StoredStep] = []

    public init(_ recipe: Recipe) {
        id = recipe.id
        apply(recipe)
    }

    /// Overwrites every field from `recipe`, keeping the identity.
    public func apply(_ recipe: Recipe) {
        title = recipe.title
        summary = recipe.summary
        servings = recipe.servings
        categories = recipe.categories
        isFavorite = recipe.isFavorite
        wantToCook = recipe.wantToCook
        notes = recipe.notes
        sourceKind = recipe.source.kind.rawValue
        sourceURL = recipe.source.url
        sourceName = recipe.source.name
        prepTimeSeconds = recipe.prepTimeSeconds
        cookTimeSeconds = recipe.cookTimeSeconds
        createdBy = recipe.createdBy
        createdAt = recipe.createdAt
        updatedAt = recipe.updatedAt
        deletedAt = recipe.deletedAt

        ingredients = recipe.ingredients.enumerated().map { index, ingredient in
            StoredIngredient(ingredient, sortOrder: index)
        }
        steps = recipe.steps.enumerated().map { index, step in
            StoredStep(step, sortOrder: index)
        }

        searchText = Self.searchText(for: recipe)
    }

    public var domainValue: Recipe {
        Recipe(
            id: id,
            title: title,
            summary: summary,
            servings: servings,
            ingredients: ingredients.sorted { $0.sortOrder < $1.sortOrder }.map(\.domainValue),
            steps: steps.sorted { $0.sortOrder < $1.sortOrder }.map(\.domainValue),
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
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    static func searchText(for recipe: Recipe) -> String {
        var parts = [recipe.title]
        parts.append(contentsOf: recipe.categories)
        parts.append(contentsOf: recipe.ingredients.map(\.name))
        return parts.joined(separator: " ").lowercased()
    }
}
