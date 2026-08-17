import Foundation

/// One instruction in a recipe.
///
/// Durations are plain seconds rather than `Duration`: the serialized
/// aggregate is the cross-platform interchange format, and `Duration`
/// encodes as a Swift-specific pair of integers.
public struct RecipeStep: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    /// Optional heading this step belongs to: "Teig zubereiten".
    public var group: String?
    /// A timer the cook mode can offer for this step.
    public var durationSeconds: Int?
    /// Set when the step refers to another recipe in the library.
    public var linkedRecipeID: UUID?

    public init(
        id: UUID = UUID(),
        text: String,
        group: String? = nil,
        durationSeconds: Int? = nil,
        linkedRecipeID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.group = group
        self.durationSeconds = durationSeconds
        self.linkedRecipeID = linkedRecipeID
    }
}
