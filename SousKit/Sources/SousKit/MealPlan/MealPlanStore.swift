import Foundation

/// Storage for the meal plan.
public protocol MealPlanStore: Sendable {
    /// Entries for the given days, ordered by day and position. Entries
    /// without a day are not among them — those are the pool.
    func entries(for days: [Date]) async throws -> [MealPlanEntry]
    /// Entries with no day of their own, oldest first.
    func poolEntries() async throws -> [MealPlanEntry]
    @discardableResult
    func save(_ entry: MealPlanEntry) async throws -> MealPlanEntry
    func delete(id: UUID) async throws
}
