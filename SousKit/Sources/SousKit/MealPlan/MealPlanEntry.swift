import Foundation

/// One recipe planned for one day.
///
/// Days are stored as the start of the day in the current calendar, so a plan
/// entry is a date, not a moment — moving across a time zone must not shift
/// dinner to the day before.
public struct MealPlanEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var day: Date
    /// Dinner unless said otherwise — it is what gets planned most.
    public var slot: MealSlot
    public var recipeID: UUID
    /// Set when this meal is cooked for a different number of people than the
    /// recipe is written for.
    public var servings: Int?
    public var sortOrder: Int

    public var createdAt: Date
    public var updatedAt: Date
    /// Tombstone, for the same reason recipes have one.
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: UUID = UUID(),
        day: Date,
        slot: MealSlot = .dinner,
        recipeID: UUID,
        servings: Int? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .nowInSyncPrecision,
        updatedAt: Date = .nowInSyncPrecision,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.day = day.startOfDay
        self.slot = slot
        self.recipeID = recipeID
        self.servings = servings
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension Date {
    /// Midnight of this date, at sync precision.
    public var startOfDay: Date {
        Calendar.current.startOfDay(for: self).syncPrecision
    }

    /// The seven days of the week this date falls in.
    public var weekDays: [Date] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: self) else {
            return [startOfDay]
        }
        return (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)?.startOfDay
        }
    }

    public func addingWeeks(_ count: Int) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: count, to: self) ?? self
    }
}
