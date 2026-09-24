import EventKit
import Foundation
import SousKit
import SwiftUI
import os

/// Mirrors each household's meal plan into a calendar of its own.
///
/// A projection, not a sync: the plan is the truth, the calendar shows it,
/// and nothing flows back — an event edited or deleted in the calendar is
/// simply restored on the next pass. What this buys over an in-app plan is
/// reach: a calendar can be shared with somebody who does not have Sous,
/// which is where a family's "Was gibt es heute?" actually lives.
///
/// One calendar per household, switched on per household, because that is
/// what sharing a calendar means: the family's calendar goes to the family,
/// the flat's to the flat. A single calendar following whichever household
/// is showing would replace every event on each switch.
///
/// An actor, because EventKit's objects are not thread-safe and every pass
/// touches store, calendar and events together.
actor CalendarMirror {
    private static let log = Logger(subsystem: "me.raddatz.sous", category: "calendar")
    /// Household id → calendar identifier, for every household mirrored.
    private static let calendarsKey = "calendarMirrorCalendars"
    /// From the single calendar before households had their own; handed to
    /// the oldest own household once, see `adoptTheSingleCalendar`.
    private static let legacyEnabledKey = "calendarMirrorEnabled"
    private static let legacyCalendarKey = "calendarMirrorCalendarID"
    /// How far back the mirror reaches. Meals older than this keep their
    /// events untouched — the calendar doubles as a record of what was
    /// actually cooked, and a mirror that erased history would be worse
    /// than none.
    private static let horizon: TimeInterval = -30 * 24 * 3600

    private let eventStore = EKEventStore()
    private let mealPlan: CoreDataMealPlanStore
    private let recipes: CoreDataRecipeStore
    private let households: CoreDataHouseholds

    init(mealPlan: CoreDataMealPlanStore, recipes: CoreDataRecipeStore, households: CoreDataHouseholds) {
        self.mealPlan = mealPlan
        self.recipes = recipes
        self.households = households
    }

    nonisolated func isEnabled(for household: UUID) -> Bool {
        Self.calendars[household.uuidString] != nil
            // Until the first pass has handed it over, the single calendar
            // still counts for the household it is about to belong to.
            || (UserDefaults.sous.bool(forKey: Self.legacyEnabledKey) && household == households.oldestOwnID())
    }

    /// Asks for calendar access and, when granted, gives the household its
    /// calendar and runs the first pass. Returns whether it is on now —
    /// `false` means the person declined, and the toggle should say so by
    /// falling back.
    func enable(for household: UUID) async -> Bool {
        let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        guard granted else {
            Self.log.info("Calendar access declined; the mirror stays off.")
            return false
        }
        adoptTheSingleCalendar()
        var calendars = Self.calendars
        // Marked now, made on the pass: the pass knows the household's name.
        calendars[household.uuidString] = calendars[household.uuidString] ?? ""
        Self.calendars = calendars
        await syncIfEnabled()
        return true
    }

    /// Stops mirroring a household and takes its calendar with it. The
    /// events in it were a view of the plan; a view nobody asked to see any
    /// more should not linger as stale data in somebody's week.
    func disable(for household: UUID) {
        adoptTheSingleCalendar()
        var calendars = Self.calendars
        if let identifier = calendars.removeValue(forKey: household.uuidString),
           let calendar = eventStore.calendar(withIdentifier: identifier) {
            try? eventStore.removeCalendar(calendar, commit: true)
        }
        Self.calendars = calendars
    }

    /// One reconciliation pass per mirrored household: its plan as it stands
    /// against its calendar as it stands. Create what is missing, correct
    /// what drifted, delete what the plan no longer holds. Safe to run as
    /// often as anything changes — a pass over an unchanged plan writes
    /// nothing.
    func syncIfEnabled() async {
        adoptTheSingleCalendar()
        guard !Self.calendars.isEmpty else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            Self.log.info("Calendar access has been revoked; the mirror is idle.")
            return
        }
        guard let choices = try? await households.choices(), !choices.isEmpty else {
            // No household known yet — a reinstall before its first import.
            // Nothing to mirror, and nothing to judge as gone.
            return
        }

        var calendars = Self.calendars
        for (key, identifier) in calendars {
            guard let id = UUID(uuidString: key) else { continue }
            guard let household = choices.first(where: { $0.id == id }) else {
                // Deleted or left: the calendar showed a household that no
                // longer exists on this device.
                if let calendar = eventStore.calendar(withIdentifier: identifier) {
                    try? eventStore.removeCalendar(calendar, commit: true)
                }
                calendars.removeValue(forKey: key)
                continue
            }
            do {
                let calendar = try calendar(identifier: identifier, for: household.name)
                calendars[key] = calendar.calendarIdentifier
                let since = Date(timeIntervalSinceNow: Self.horizon)
                let entries = try await mealPlan.datedEntries(onOrAfter: since, inHousehold: id)
                let titles = try await recipes.titles(byIDs: entries.map(\.recipeID))
                let wanted = entries.compactMap { entry in
                    MealPlanCalendarPlanner.event(for: entry, recipeTitle: titles[entry.recipeID])
                }
                try apply(wanted, since: since, to: calendar)
            } catch {
                Self.log.error("Calendar pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.calendars = calendars
    }

    private func apply(_ wanted: [PlannedCalendarEvent], since: Date, to calendar: EKCalendar) throws {
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

    /// The household's own calendar, made if it has none yet and renamed if
    /// the household was — so the mirror only ever touches events it wrote,
    /// and each household can be hidden or shown in the Calendar app with
    /// one checkbox.
    private func calendar(identifier: String, for householdName: String) throws -> EKCalendar {
        let title = Self.title(for: householdName)
        if let existing = eventStore.calendar(withIdentifier: identifier) {
            if existing.title != title {
                existing.title = title
                try eventStore.saveCalendar(existing, commit: true)
            }
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = title
        // iCloud where there is one, so the calendar syncs and can be shared
        // like any other; the default source otherwise.
        calendar.source = eventStore.sources.first {
            $0.sourceType == .calDAV && $0.title == "iCloud"
        } ?? eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first { $0.sourceType == .local }
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private static func title(for householdName: String) -> String {
        "Sous – \(householdName)"
    }

    /// Hands the single "Sous" calendar of the time before households had
    /// their own to the oldest own household — the one that calendar showed
    /// all along — keeping the calendar itself, so whoever it was shared
    /// with keeps receiving it. Once; afterwards there is nothing to hand.
    private func adoptTheSingleCalendar() {
        let defaults = UserDefaults.sous
        guard defaults.object(forKey: Self.legacyEnabledKey) != nil else { return }
        let wasOn = defaults.bool(forKey: Self.legacyEnabledKey)
        let identifier = defaults.string(forKey: Self.legacyCalendarKey)
            ?? eventStore.calendars(for: .event).first { $0.title == "Sous" }?.calendarIdentifier
        if wasOn, let household = households.oldestOwnID() {
            var calendars = Self.calendars
            calendars[household.uuidString] = identifier ?? ""
            Self.calendars = calendars
        } else if wasOn {
            // No household yet to hand it to: try again on the next pass.
            return
        }
        defaults.removeObject(forKey: Self.legacyEnabledKey)
        defaults.removeObject(forKey: Self.legacyCalendarKey)
    }

    private static var calendars: [String: String] {
        get { UserDefaults.sous.dictionary(forKey: calendarsKey) as? [String: String] ?? [:] }
        set { UserDefaults.sous.set(newValue, forKey: calendarsKey) }
    }
}

extension EnvironmentValues {
    @Entry var calendarMirror: CalendarMirror?
}
