import Foundation

/// One instruction in a recipe.
public struct RecipeStep: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    /// Optional heading this step belongs to: "Teig zubereiten".
    public var group: String?
    /// A timer the cook mode can offer for this step.
    public var durationSeconds: Int?

    public init(
        id: UUID = UUID(),
        text: String,
        group: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.group = group
        self.durationSeconds = durationSeconds
    }
}
