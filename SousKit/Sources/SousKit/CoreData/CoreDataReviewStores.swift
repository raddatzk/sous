import CoreData
import Foundation

/// That a person looked at one of a recipe's open questions and settled it,
/// recorded against the text they settled it under.
///
/// One class for both marks: the amount review and the ingredient review hold
/// the same three fields and differ only in which question they answer.
@objc(CDReviewMark)
final class CDReviewMark: CDHouseholdMember {
    @NSManaged var recipeID: UUID?
    @NSManaged var reviewedContentHash: String
    /// `AmountSuggestion.declineKey`s as a JSON array — see
    /// ``StoredAmountReview/declinedKeysJSON``. Optional, so an existing
    /// store gains the column by lightweight migration and every row already
    /// in iCloud reads as "nothing turned down".
    @NSManaged var declinedKeysJSON: String?
    @NSManaged var updatedAt: Date?
}

/// The shared body of both review stores.
///
/// Written once and pointed at a different entity twice, rather than copied:
/// the two are identical down to the fetch, and a copy would be two places to
/// fix when the rule about what reopens a question changes.
final class CoreDataReviewMarkStore: @unchecked Sendable {
    private let context: NSManagedObjectContext
    private let entityName: String

    init(container: NSPersistentContainer, entityName: String) {
        context = SousPersistentContainer.backgroundContext(for: container)
        self.entityName = entityName
    }

    func reviewedHash(for recipeID: UUID) async throws -> String? {
        try await context.perform { try self.stored(recipeID: recipeID)?.reviewedContentHash }
    }

    func markReviewed(_ recipe: Recipe, declining: Set<String> = []) async throws {
        let hash = RecipeContentHash.hash(for: recipe)
        try await context.perform {
            guard let row = try self.stored(recipeID: recipe.id)
                ?? CDReviewMark.make(in: self.context, entityName: self.entityName)
            else { return }
            row.recipeID = recipe.id
            row.reviewedContentHash = hash
            row.declinedKeysJSON = StoredAmountReview.encode(declining)
            row.updatedAt = .nowInSyncPrecision
            try self.context.save()
        }
    }

    func declinedKeys(for recipeID: UUID) async throws -> Set<String> {
        try await context.perform {
            guard let json = try self.stored(recipeID: recipeID)?.declinedKeysJSON else { return [] }
            return (try? JSONDecoder().decode(Set<String>.self, from: Data(json.utf8))) ?? []
        }
    }

    func delete(recipeID: UUID) async throws {
        try await context.perform {
            guard let existing = try self.stored(recipeID: recipeID) else { return }
            self.context.delete(existing)
            try self.context.save()
        }
    }

    private func stored(recipeID: UUID) throws -> CDReviewMark? {
        let request = NSFetchRequest<CDReviewMark>(entityName: entityName)
        request.predicate = NSPredicate(format: "recipeID == %@", recipeID as NSUUID)
        request.fetchLimit = 1
        return try context.fetchInActiveHousehold(request).first
    }
}

private extension CDReviewMark {
    /// Inserting into one of two entities that share this class, which the
    /// ordinary `init(context:)` cannot express.
    ///
    /// Returns `nil` rather than forcing the entity: a lookup that fails
    /// means the model does not describe this store, and crashing on it turns
    /// a mark nobody would have missed into a launch that never finishes.
    static func make(in context: NSManagedObjectContext, entityName: String) -> CDReviewMark? {
        guard let entity = NSEntityDescription.entity(forEntityName: entityName, in: context) else {
            return nil
        }
        return CDReviewMark(entity: entity, insertInto: context)
    }
}

/// A ``RecipeAmountReviewStore`` backed by Core Data.
public final class CoreDataRecipeAmountReviewStore: RecipeAmountReviewStore, @unchecked Sendable {
    private let marks: CoreDataReviewMarkStore

    public init(container: NSPersistentContainer) {
        marks = CoreDataReviewMarkStore(
            container: container,
            entityName: SousManagedObjectModel.amountReviewEntityName
        )
    }

    public func reviewedHash(for recipeID: UUID) async throws -> String? {
        try await marks.reviewedHash(for: recipeID)
    }

    public func markReviewed(_ recipe: Recipe, declining: Set<String>) async throws {
        try await marks.markReviewed(recipe, declining: declining)
    }

    public func declinedKeys(for recipeID: UUID) async throws -> Set<String> {
        try await marks.declinedKeys(for: recipeID)
    }

    public func delete(recipeID: UUID) async throws {
        try await marks.delete(recipeID: recipeID)
    }
}

/// A ``RecipeIngredientReviewStore`` backed by Core Data.
public final class CoreDataRecipeIngredientReviewStore: RecipeIngredientReviewStore, @unchecked Sendable {
    private let marks: CoreDataReviewMarkStore

    public init(container: NSPersistentContainer) {
        marks = CoreDataReviewMarkStore(
            container: container,
            entityName: SousManagedObjectModel.ingredientReviewEntityName
        )
    }

    public func reviewedHash(for recipeID: UUID) async throws -> String? {
        try await marks.reviewedHash(for: recipeID)
    }

    public func markReviewed(_ recipe: Recipe) async throws {
        try await marks.markReviewed(recipe)
    }

    public func delete(recipeID: UUID) async throws {
        try await marks.delete(recipeID: recipeID)
    }
}
