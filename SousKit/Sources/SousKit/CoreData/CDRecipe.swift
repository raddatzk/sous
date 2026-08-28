import CoreData
import Foundation

/// The Core Data form of a recipe — the counterpart to ``StoredRecipe``.
///
/// The two mirror each other field for field on purpose. Whichever store the
/// app is running against, the row it writes has to be readable by the other
/// one, because the migration from SwiftData to Core Data reads the old store
/// and writes the new.
@objc(CDRecipe)
final class CDRecipe: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var title: String
    @NSManaged var summary: String?
    @NSManaged var servings: Int64
    @NSManaged var ingredientsText: String
    @NSManaged var instructionsText: String
    @NSManaged var categoriesJSON: String
    @NSManaged var isFavorite: Bool
    @NSManaged var wantToCook: Bool
    @NSManaged var notes: String?
    @NSManaged var sourceKind: String
    @NSManaged var sourceURL: String?
    @NSManaged var sourceName: String?
    @NSManaged var prepTimeSeconds: NSNumber?
    @NSManaged var cookTimeSeconds: NSNumber?
    @NSManaged var totalTimeSeconds: NSNumber?
    @NSManaged var imageIDsJSON: String
    @NSManaged var suitableSlotsJSON: String?
    @NSManaged var variantGroupID: UUID?
    @NSManaged var createdBy: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var searchText: String
    @NSManaged var ingredientKeysJSON: String

    /// Overwrites every field from `recipe`, keeping the identity.
    ///
    /// `variantGroupTitle` is the one thing here the recipe cannot supply
    /// itself: the group's name is folded into `searchText` so that "Chili"
    /// finds the members. Only the store can look it up.
    func apply(
        _ recipe: Recipe,
        catalog: IngredientCatalog = .bundled,
        variantGroupTitle: String? = nil
    ) {
        id = recipe.id
        title = recipe.title
        summary = recipe.summary
        servings = Int64(recipe.servings)
        ingredientsText = recipe.ingredientsText
        instructionsText = recipe.instructionsText
        categoriesJSON = JSONField.encode(recipe.categories)
        isFavorite = recipe.isFavorite
        wantToCook = recipe.wantToCook
        notes = recipe.notes
        sourceKind = recipe.source.kind.rawValue
        sourceURL = recipe.source.url?.absoluteString
        sourceName = recipe.source.name
        prepTimeSeconds = recipe.prepTimeSeconds.map(NSNumber.init)
        cookTimeSeconds = recipe.cookTimeSeconds.map(NSNumber.init)
        totalTimeSeconds = recipe.totalTimeSeconds.map(NSNumber.init)
        imageIDsJSON = JSONField.encode(recipe.imageIDs.map(\.uuidString))
        suitableSlotsJSON = recipe.suitableSlots.map { slots in
            JSONField.encode(slots.map(\.rawValue).sorted())
        }
        variantGroupID = recipe.variantGroupID
        createdBy = recipe.createdBy
        createdAt = recipe.createdAt
        updatedAt = recipe.updatedAt
        deletedAt = recipe.deletedAt
        searchText = RecipeIndex.searchText(for: recipe, variantGroupTitle: variantGroupTitle, catalog: catalog)
        ingredientKeysJSON = JSONField.encode(RecipeIndex.ingredientKeys(for: recipe, catalog: catalog))
    }

    var categories: [String] { JSONField.decode(categoriesJSON) }
    /// The meals the recipe itself names, as raw values — empty where nobody
    /// chose, which is not the same as "suits nothing".
    var statedSlots: [String] { suitableSlotsJSON.map { JSONField.decode($0) } ?? [] }
    var ingredientKeys: [String] { JSONField.decode(ingredientKeysJSON) }

    /// `nil` for a row without an id.
    ///
    /// Not a defensive habit but the one corruption this store can actually
    /// be handed: CloudKit requires every attribute to be optional or carry a
    /// default, so a record written by a future schema — or truncated on its
    /// way here — can arrive without one. Skipping it shows the library
    /// minus one recipe, which is recoverable; inventing an id would write a
    /// duplicate on the next sync, which is not.
    var domainValue: Recipe? {
        guard let id else { return nil }
        return Recipe(
            id: id,
            title: title,
            summary: summary,
            servings: Int(servings),
            ingredientsText: ingredientsText,
            instructionsText: instructionsText,
            categories: categories,
            isFavorite: isFavorite,
            wantToCook: wantToCook,
            notes: notes,
            source: RecipeSource(
                kind: RecipeSource.Kind(rawValue: sourceKind) ?? .manual,
                url: sourceURL.flatMap(URL.init(string:)),
                name: sourceName
            ),
            prepTimeSeconds: prepTimeSeconds?.intValue,
            cookTimeSeconds: cookTimeSeconds?.intValue,
            totalTimeSeconds: totalTimeSeconds?.intValue,
            imageIDs: JSONField.decode(imageIDsJSON).compactMap(UUID.init(uuidString:)),
            suitableSlots: suitableSlotsJSON.map { raw in
                Set(JSONField.decode(raw).compactMap(MealSlot.init(rawValue:)))
            },
            variantGroupID: variantGroupID,
            createdBy: createdBy,
            // A row that lost its timestamps is readable; it just sorts last
            // and looks untouched, which is what it is.
            createdAt: createdAt ?? .distantPast,
            updatedAt: updatedAt ?? .distantPast,
            deletedAt: deletedAt
        )
    }
}

/// The Core Data form of a ``VariantGroup``.
@objc(CDVariantGroup)
final class CDVariantGroup: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var title: String
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?

    func apply(_ group: VariantGroup) {
        id = group.id
        title = group.title
        createdAt = group.createdAt
        updatedAt = group.updatedAt
    }

    var domainValue: VariantGroup? {
        guard let id else { return nil }
        return VariantGroup(
            id: id,
            title: title,
            createdAt: createdAt ?? .distantPast,
            updatedAt: updatedAt ?? .distantPast
        )
    }
}

/// The list-valued fields, as JSON in a string column.
///
/// A list of strings is the only shape any of them needs — categories, image
/// ids as their uuid strings, meal slots as raw values, ingredient keys — so
/// this stays one function each way rather than a generic codec.
enum JSONField {
    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}
