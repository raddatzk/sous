import Foundation

/// One stored picture.
public struct RecipeImage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let recipeID: UUID
    public let data: Data
    public let thumbnail: Data

    public init(id: UUID = UUID(), recipeID: UUID, data: Data, thumbnail: Data) {
        self.id = id
        self.recipeID = recipeID
        self.data = data
        self.thumbnail = thumbnail
    }
}

/// Storage for recipe pictures, separate from the recipe itself.
///
/// Images live in their own rows rather than inside the recipe aggregate:
/// they are large, they rarely change, and CloudKit mirrors each one as its
/// own CKAsset. Keeping them inline would mean re-uploading every photo
/// whenever a word of the text changes.
public protocol RecipeImageStore: Sendable {
    /// Thumbnails only — enough to draw a list without loading full images.
    func thumbnails(for recipeID: UUID) async throws -> [(id: UUID, data: Data)]
    func thumbnail(id: UUID) async throws -> Data?
    func image(id: UUID) async throws -> Data?
    /// Stores a picked photo, downsizing it first. Returns its new id.
    func add(_ data: Data, to recipeID: UUID) async throws -> UUID
    func delete(id: UUID) async throws
    /// Removes pictures of a recipe that are no longer referenced by it.
    func deleteImages(ofRecipe recipeID: UUID, notIn keep: [UUID]) async throws
}
