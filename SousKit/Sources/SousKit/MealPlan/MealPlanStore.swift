import Foundation

/// Storage for the meal plan.
public protocol MealPlanStore: Sendable {
    /// Entries for the given days, ordered by day and position.
    func entries(for days: [Date]) async throws -> [MealPlanEntry]
    @discardableResult
    func save(_ entry: MealPlanEntry) async throws -> MealPlanEntry
    func delete(id: UUID) async throws
}
