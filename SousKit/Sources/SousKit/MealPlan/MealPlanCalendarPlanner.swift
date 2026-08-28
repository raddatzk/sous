import Foundation

/// What the Apple calendar should show for a planned meal.
///
/// A projection, not a sync: the plan is the truth, the calendar is a view of
/// it, and nothing flows back. The planner is pure — entries in, specs out —
/// so the one part of the feature that contains decisions is testable without
/// an `EKEventStore`, which cannot be had in a test host.
public struct PlannedCalendarEvent: Hashable, Sendable {
    /// `sous://plan/<entry-id>` — stored in the event's URL field, and the
    /// only thing that ties an event to its entry across runs. Matching by
    /// title would break on the first rename; matching by time on the first
    /// move.
    public let url: URL
    public let title: String
    public let start: Date
    public let end: Date
    /// "4 Portionen · Geplant mit Sous" — so the event says what it is when
    /// it shows up in a calendar shared with somebody who has never heard of
    /// the app.
    public let notes: String

    public init(url: URL, title: String, start: Date, end: Date, notes: String) {
        self.url = url
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
    }
}

public enum MealPlanCalendarPlanner {
    /// The event a dated entry should appear as, or `nil` for an entry whose
    /// recipe is unknown — a plan pointing at a recipe this device has not
    /// imported yet is a gap to close on the next pass, not an event called
    /// "Unbekannt".
    public static func event(
        for entry: MealPlanEntry,
        recipeTitle: String?,
        calendar: Calendar = .current
    ) -> PlannedCalendarEvent? {
        guard let day = entry.day, let recipeTitle, !recipeTitle.isEmpty else { return nil }
        guard let url = URL(string: "sous://plan/\(entry.id.uuidString)") else { return nil }

        // Meal times, not all-day banners: the day view answering "what am I
        // cooking tonight" is the point of having the plan in the calendar.
        let (hour, minute) = switch entry.slot {
        case .breakfast: (8, 0)
        case .lunch: (12, 30)
        case .dinner: (19, 0)
        }
        guard let start = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: day
        ) else { return nil }

        var notes = "Geplant mit Sous"
        if let servings = entry.servings {
            notes = "\(servings) Portionen · " + notes
        }

        return PlannedCalendarEvent(
            url: url,
            title: recipeTitle,
            start: start,
            end: start.addingTimeInterval(60 * 60),
            notes: notes
        )
    }

    /// The id an event's URL names, if the event is one of ours.
    public static func entryID(of url: URL?) -> UUID? {
        guard let url, url.scheme == "sous", url.host() == "plan" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
