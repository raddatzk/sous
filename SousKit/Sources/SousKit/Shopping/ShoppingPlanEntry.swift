import Foundation

/// One recipe put on the list, at the scale it was being viewed.
///
/// The plan entry is the mutable part of the shopping document: the portion
/// count stays adjustable after the fact, and every demand captured under it
/// re-derives from that ratio. What it never does is reach back into the
/// recipe — the demands are the snapshot, the plan entry only scales them.
public struct ShoppingPlanEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The recipe it came from — for recognizing a re-add, not for reading
    /// the recipe again.
    public var recipeID: UUID?
    /// The title as it read when added; a renamed recipe does not rewrite
    /// the list.
    public var title: String
    /// The portion count shown when the recipe was put on the list. The
    /// captured demands are scaled to this; it never changes.
    public var servingsCaptured: Int
    /// The portion count the cook wants now. Effective amounts follow
    /// `servingsCurrent / servingsCaptured`.
    public var servingsCurrent: Int
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        recipeID: UUID? = nil,
        title: String,
        servingsCaptured: Int,
        servingsCurrent: Int? = nil,
        addedAt: Date = .nowInSyncPrecision
    ) {
        self.id = id
        self.recipeID = recipeID
        self.title = title
        self.servingsCaptured = max(1, servingsCaptured)
        self.servingsCurrent = max(1, servingsCurrent ?? servingsCaptured)
        self.addedAt = addedAt
    }

    /// How far the cook has turned the dial since adding.
    public var scaleFactor: Double {
        Double(servingsCurrent) / Double(servingsCaptured)
    }
}
