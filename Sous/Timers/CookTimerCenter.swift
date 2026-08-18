import Foundation
import Observation
#if os(iOS)
import AlarmKit
import SwiftUI
#endif

/// Where timers are kept while they run, so they outlive the step they were
/// started from.
///
/// Timers do not belong to a view. A cook starts the sauce, swipes to the
/// ingredients, leaves cook mode to check something and puts the phone down —
/// and the sauce is on the hob throughout.
///
/// More than one at a time, because cooking is more than one thing at a time:
/// the pasta and the oven do not take turns.
///
/// On iPhone the countdown itself belongs to AlarmKit, which owns the lock
/// screen, the Dynamic Island, and a ring that gets through silent mode — the
/// one thing a notification cannot promise, and the whole reason a kitchen
/// timer is worth having. What is kept here is only which alarm belongs to
/// which step, since an `Alarm` does not carry that back.
@MainActor
@Observable
final class CookTimerCenter {
    private(set) var timers: [CookTimer] = []
    /// Set when a timer could not be started, for the screen to explain.
    var errorMessage: String?

    private let defaults: UserDefaults
    private let key = "cookTimers"

    init(defaults: UserDefaults = .sous) {
        self.defaults = defaults
        timers = Self.load(from: defaults, key: key)
    }

    /// The timers on one step, soonest first.
    func timers(forStep stepID: UUID) -> [CookTimer] {
        timers.filter { $0.stepID == stepID }.sorted { $0.fireDate < $1.fireDate }
    }

    /// Starts a timer, replacing whatever was running for the same step.
    ///
    /// One step is one thing on the hob, so a second timer on it is a
    /// correction — five minutes was meant to be fifteen — not a second pot.
    /// Different steps run side by side.
    func start(
        seconds: TimeInterval,
        stepID: UUID,
        stepNumber: Int,
        recipeTitle: String
    ) async {
        guard seconds > 0 else { return }
        for existing in timers(forStep: stepID) { cancel(existing) }

        let timer = CookTimer(
            id: UUID(),
            stepID: stepID,
            recipeTitle: recipeTitle,
            stepNumber: stepNumber,
            duration: seconds,
            fireDate: Date().addingTimeInterval(seconds)
        )

        #if os(iOS)
        guard await ensureAuthorized() else {
            errorMessage = """
                Sous darf keine Wecker stellen. In den Einstellungen unter \
                „Sous“ lässt sich das erlauben — sonst klingelt der Timer \
                nicht, wenn das Gerät stumm ist.
                """
            return
        }
        do {
            try await AlarmManager.shared.schedule(
                id: timer.id,
                configuration: .timer(duration: seconds, attributes: attributes(for: timer))
            )
        } catch {
            errorMessage = "Der Timer konnte nicht gestellt werden: \(error.localizedDescription)"
            return
        }
        #endif

        timers.append(timer)
        save()
    }

    func cancel(_ timer: CookTimer) {
        #if os(iOS)
        try? AlarmManager.shared.stop(id: timer.id)
        try? AlarmManager.shared.cancel(id: timer.id)
        #endif
        timers.removeAll { $0.id == timer.id }
        save()
    }

    /// Drops timers nobody is coming back for, so yesterday's roast does not
    /// greet tomorrow's breakfast.
    func forgetStale(at now: Date = Date(), after grace: TimeInterval = 3600) {
        let before = timers.count
        timers.removeAll { !$0.isAlerting && $0.fireDate.addingTimeInterval(grace) < now }
        if timers.count != before { save() }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(timers), forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [CookTimer] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CookTimer].self, from: data)) ?? []
    }
}

#if os(iOS)
extension CookTimerCenter {
    /// Mirrors AlarmKit's own list back into ours: an alarm stopped from the
    /// lock screen has to disappear from the step too.
    ///
    /// The current list is read once before subscribing, because the stream
    /// reports changes rather than the state at the time of asking. Without
    /// it, timers written down before the app was replaced come back and
    /// count down against no alarm at all — a countdown that will never ring,
    /// which is worse than no countdown.
    func watchAlarms() async {
        // Off the main actor deliberately: `alarms` is a synchronous property
        // backed by a round trip to the alarm daemon, and reading it inline
        // freezes the app down to its status bar.
        let current = await Task.detached { (try? AlarmManager.shared.alarms) ?? [] }.value
        reconcile(with: current)
        for await alarms in AlarmManager.shared.alarmUpdates {
            reconcile(with: alarms)
        }
    }

    private func reconcile(with alarms: [Alarm]) {
        let byID = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, $0) })
        timers = timers.compactMap { timer in
            guard let alarm = byID[timer.id] else { return nil }
            var updated = timer
            updated.isAlerting = alarm.state == .alerting
            return updated
        }
        save()
    }

    private func ensureAuthorized() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: true
        case .denied: false
        case .notDetermined:
            (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        @unknown default: false
        }
    }

    /// How the timer presents itself once it is out of the app's hands.
    private func attributes(for timer: CookTimer) -> AlarmAttributes<CookTimerMetadata> {
        let alert = AlarmPresentation.Alert(
            title: "\(timer.recipeTitle) — Schritt \(timer.stepNumber)",
            stopButton: AlarmButton(
                text: "Fertig",
                textColor: .white,
                systemImageName: "checkmark"
            )
        )
        let countdown = AlarmPresentation.Countdown(
            title: "\(timer.recipeTitle) — Schritt \(timer.stepNumber)",
            pauseButton: AlarmButton(
                text: "Pause",
                textColor: .white,
                systemImageName: "pause.fill"
            )
        )
        let paused = AlarmPresentation.Paused(
            title: "\(timer.recipeTitle) — Schritt \(timer.stepNumber)",
            resumeButton: AlarmButton(
                text: "Weiter",
                textColor: .white,
                systemImageName: "play.fill"
            )
        )
        return AlarmAttributes(
            presentation: AlarmPresentation(alert: alert, countdown: countdown, paused: paused),
            metadata: CookTimerMetadata(
                recipeTitle: timer.recipeTitle,
                stepNumber: timer.stepNumber
            ),
            tintColor: .sousAccent
        )
    }
}
#endif
