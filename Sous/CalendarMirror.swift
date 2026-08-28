import EventKit
import Foundation
import SousKit
import SwiftUI
import os

/// Mirrors the meal plan into the Apple calendar.
///
/// A projection, not a sync: the plan is the truth, the calendar shows it,
/// and nothing flows back — an event edited or deleted in the calendar is
/// simply restored on the next pass. What this buys over an in-app plan is
/// reach: a calendar can be shared with somebody who does not have Sous,
/// which is where a family's "Was gibt es heute?" actually lives.
///
/// An actor, because EventKit's objects are not thread-safe and every pass
/// touches store, calendar and events together.
actor CalendarMirror {
    private static let log = Logger(subsystem: "me.raddatz.sous", category: "calendar")
    private static let enabledKey = "calendarMirrorEnabled"
    private static let calendarKey = "calendarMirrorCalendarID"
    /// How far back the mirror reaches. Meals older than this keep their
    /// events untouched — the calendar doubles as a record of what was
    /// actually cooked, and a mirror that erased history would be worse
    /// than none.
    private static let horizon: TimeInterval = -30 * 24 * 3600

    private let eventStore = EKEventStore()
    private let mealPlan: CoreDataMealPlanStore
    private let recipes: CoreDataRecipeStore

    init(mealPlan: CoreDataMealPlanStore, recipes: CoreDataRecipeStore) {
        self.mealPlan = mealPlan
        self.recipes = recipes
    }

    nonisolated var isEnabled: Bool {
        UserDefaults.sous.bool(forKey: Self.enabledKey)
    }

    /// Asks for calendar access and, when granted, turns the mirror on and
    /// runs the first pass. Returns whether it is on now — `false` means the
    /// person declined, and the toggle should say so by falling back.
    func enable() async -> Bool {
        let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        guard granted else {
            Self.log.info("Calendar access declined; the mirror stays off.")
            return false
        }
        UserDefaults.sous.set(true, forKey: Self.enabledKey)
        await syncIfEnabled()
        return true
    }

    /// Turns the mirror off and takes the Sous calendar with it. The events
    /// in it were a view of the plan; a view nobody asked to see any more
    /// should not linger as stale data in somebody's week.
    func disable() {
        UserDefaults.sous.set(false, forKey: Self.enabledKey)
        if let calendar = existingCalendar() {
            try? eventStore.removeCalendar(calendar, commit: true)
        }
        UserDefaults.sous.removeObject(forKey: Self.calendarKey)
    }

    /// One reconciliation pass: the plan as it stands against the calendar
    /// as it stands. Create what is missing, correct what drifted, delete
    /// what the plan no longer holds. Safe to run as often as anything
    /// changes — a pass over an unchanged plan writes nothing.
    func syncIfEnabled() async {
        guard isEnabled else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            Self.log.info("Calendar access has been revoked; the mirror is idle.")
            return
        }

        do {
            let since = Date(timeIntervalSinceNow: Self.horizon)
            let entries = try await mealPlan.allDatedEntries(onOrAfter: since)
            let titles = try await recipes.titles(byIDs: entries.map(\.recipeID))
            let wanted = entries.compactMap { entry in
                MealPlanCalendarPlanner.event(for: entry, recipeTitle: titles[entry.recipeID])
            }
            try apply(wanted, since: since)
        } catch {
            Self.log.error("Calendar pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ wanted: [PlannedCalendarEvent], since: Date) throws {
        let calendar = try findOrCreateCalendar()

        // A year past the last planned meal is far beyond anything the plan
        // can hold; everything of ours in that window is up for reconciling.
        let until = Date(timeIntervalSinceNow: 400 * 24 * 3600)
        let predicate = eventStore.predicateForEvents(
            withStart: since, end: until, calendars: [calendar]
        )
        var existingByID: [UUID: EKEvent] = [:]
        for event in eventStore.events(matching: predicate) {
            guard let id = MealPlanCalendarPlanner.entryID(of: event.url) else { continue }
            existingByID[id] = event
        }

        var changed = false
        for spec in wanted {
            guard let id = MealPlanCalendarPlanner.entryID(of: spec.url) else { continue }
            if let event = existingByID.removeValue(forKey: id) {
                // Restored to the plan's reading, whatever happened to the
                // event meanwhile — the projection has no second author.
                guard event.title != spec.title
                    || event.startDate != spec.start
                    || event.endDate != spec.end
                else { continue }
                event.title = spec.title
                event.startDate = spec.start
                event.endDate = spec.end
                try eventStore.save(event, span: .thisEvent, commit: false)
                changed = true
            } else {
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = spec.title
                event.startDate = spec.start
                event.endDate = spec.end
                event.url = spec.url
                event.notes = spec.notes
                try eventStore.save(event, span: .thisEvent, commit: false)
                changed = true
            }
        }
        // Whatever is left was planned once and is not any more.
        for event in existingByID.values {
            try eventStore.remove(event, span: .thisEvent, commit: false)
            changed = true
        }
        if changed { try eventStore.commit() }
    }

    private func existingCalendar() -> EKCalendar? {
        UserDefaults.sous.string(forKey: Self.calendarKey)
            .flatMap { eventStore.calendar(withIdentifier: $0) }
            ?? eventStore.calendars(for: .event).first { $0.title == "Sous" }
    }

    /// The app's own calendar, so the mirror only ever touches events it
    /// wrote — and so the whole plan can be hidden or shown in the Calendar
    /// app with one checkbox.
    private func findOrCreateCalendar() throws -> EKCalendar {
        if let existing = existingCalendar() { return existing }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "Sous"
        // iCloud where there is one, so the calendar syncs and can be shared
        // like any other; the default source otherwise.
        calendar.source = eventStore.sources.first {
            $0.sourceType == .calDAV && $0.title == "iCloud"
        } ?? eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first { $0.sourceType == .local }
        try eventStore.saveCalendar(calendar, commit: true)
        UserDefaults.sous.set(calendar.calendarIdentifier, forKey: Self.calendarKey)
        return calendar
    }
}

extension EnvironmentValues {
    @Entry var calendarMirror: CalendarMirror?
}
