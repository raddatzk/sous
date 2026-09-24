import Foundation

/// Storage for the meal plan.
public protocol MealPlanStore: Sendable {
    /// Entries for the given days, ordered by day and position. Entries
    /// without a day are not among them — those are the pool.
    func entries(for days: [Date]) async throws -> [MealPlanEntry]
    /// Entries with no day of their own, oldest first.
    func poolEntries() async throws -> [MealPlanEntry]
    /// One entry of the active household, by id — `nil` once it has been
    /// removed, or when it belongs to another household.
    func entry(id: UUID) async throws -> MealPlanEntry?
    /// Every entry planning one of these recipes, whatever day it sits on
    /// and including the pool — what deleting a recipe has to take with it.
    func entries(ofRecipes recipeIDs: [UUID]) async throws -> [MealPlanEntry]
    @discardableResult
    func save(_ entry: MealPlanEntry) async throws -> MealPlanEntry
    func delete(id: UUID) async throws
}
