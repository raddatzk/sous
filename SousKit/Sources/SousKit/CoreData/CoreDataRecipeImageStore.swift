import CoreData
import Foundation

/// The Core Data form of a stored picture — the counterpart to
/// ``StoredRecipeImage``.
@objc(CDRecipeImage)
final class CDRecipeImage: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var recipeID: UUID?
    @NSManaged var sortOrder: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var data: Data?
    @NSManaged var thumbnail: Data?
}

/// A ``RecipeImageStore`` backed by Core Data.
///
/// Pictures move to Core Data together with the recipes that reference them,
/// rather than after: `Recipe.imageIDs` names rows in here, and a library
/// whose recipes had synced while their pictures had not would show a recipe
/// that looks like one nobody photographed — a failure with nothing to see.
public final class CoreDataRecipeImageStore: RecipeImageStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.automaticallyMergesChangesFromParent = true
    }

    public func thumbnails(for recipeID: UUID) async throws -> [(id: UUID, data: Data)] {
        try await context.perform {
            try self.images(of: recipeID).compactMap { image in
                guard let id = image.id else { return nil }
                return (id, image.thumbnail ?? Data())
            }
        }
    }

    public func thumbnail(id: UUID) async throws -> Data? {
        try await context.perform { try self.stored(id: id)?.thumbnail }
    }

    public func image(id: UUID) async throws -> Data? {
        try await context.perform { try self.stored(id: id)?.data }
    }

    public func add(_ data: Data, to recipeID: UUID) async throws -> UUID {
        // Downsized before the context is touched: it is the expensive part
        // and it needs nothing from the store.
        guard let prepared = RecipeImageProcessing.prepare(data) else {
            throw RecipeImageError.unreadableImage
        }

        return try await context.perform {
            let image = CDRecipeImage(context: self.context)
            let id = UUID()
            image.id = id
            image.recipeID = recipeID
            image.sortOrder = Int64(try self.images(of: recipeID).count)
            image.createdAt = .nowInSyncPrecision
            image.data = prepared.data
            image.thumbnail = prepared.thumbnail
            try self.context.save()
            return id
        }
    }

    public func delete(id: UUID) async throws {
        try await context.perform {
            let request = CDRecipeImage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            for image in try self.context.fetch(request) {
                self.context.delete(image)
            }
            try self.context.save()
        }
    }

    public func deleteImages(ofRecipe recipeID: UUID, notIn keep: [UUID]) async throws {
        try await context.perform {
            let kept = Set(keep)
            // A row without an id cannot be one the recipe still names, so it
            // goes with the rest of the unreferenced ones.
            for image in try self.images(of: recipeID)
            where image.id.map(kept.contains) != true {
                self.context.delete(image)
            }
            try self.context.save()
        }
    }

    private func images(of recipeID: UUID) throws -> [CDRecipeImage] {
        let request = CDRecipeImage.fetchRequest()
        request.predicate = NSPredicate(format: "recipeID == %@", recipeID as NSUUID)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }

    private func stored(id: UUID) throws -> CDRecipeImage? {
        let request = CDRecipeImage.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

extension CDRecipeImage {
    static func fetchRequest() -> NSFetchRequest<CDRecipeImage> {
        NSFetchRequest<CDRecipeImage>(entityName: SousManagedObjectModel.recipeImageEntityName)
    }
}
