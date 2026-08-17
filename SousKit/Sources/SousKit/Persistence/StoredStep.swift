import Foundation
import SwiftData

/// The persisted form of one instruction.
@Model
public final class StoredStep {
    public var id: UUID = UUID()
    public var sortOrder: Int = 0
    public var text: String = ""
    public var group: String?
    public var durationSeconds: Int?
    public var linkedRecipeID: UUID?

    public var recipe: StoredRecipe?

    public init(_ step: RecipeStep, sortOrder: Int) {
        id = step.id
        self.sortOrder = sortOrder
        text = step.text
        group = step.group
        durationSeconds = step.durationSeconds
        linkedRecipeID = step.linkedRecipeID
    }

    public var domainValue: RecipeStep {
        RecipeStep(
            id: id,
            text: text,
            group: group,
            durationSeconds: durationSeconds,
            linkedRecipeID: linkedRecipeID
        )
    }
}
