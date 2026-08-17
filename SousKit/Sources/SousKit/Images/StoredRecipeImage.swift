import Foundation
import SwiftData

/// The persisted form of a picture.
///
/// Linked to its recipe by id rather than by a relationship, because an image
/// is its own unit for syncing and should not be dragged along by the
/// recipe's object graph.
@Model
public final class StoredRecipeImage {
    #Index<StoredRecipeImage>([\.recipeID])

    public var id: UUID = UUID()
    public var recipeID: UUID = UUID()
    public var sortOrder: Int = 0
    public var createdAt: Date = Date.nowInSyncPrecision

    /// Kept out of the database file itself; SwiftData writes it beside the
    /// store, so loading a recipe does not drag megabytes along.
    @Attribute(.externalStorage) public var data: Data = Data()
    /// Small enough to live in the row and be read for every list cell.
    public var thumbnail: Data = Data()

    public init(id: UUID = UUID(), recipeID: UUID, sortOrder: Int, data: Data, thumbnail: Data) {
        self.id = id
        self.recipeID = recipeID
        self.sortOrder = sortOrder
        self.data = data
        self.thumbnail = thumbnail
    }
}
