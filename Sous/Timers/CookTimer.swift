import Foundation

/// One countdown running beside the cooking, as the app shows it.
///
/// A timer is an end time, not a number counting down. A stored count only
/// falls while something is there to decrease it, so a phone put down for two
/// minutes comes back two minutes wrong — and keeping time while the cook
/// does not is the entire job.
struct CookTimer: Identifiable, Codable, Hashable, Sendable {
    /// Also the alarm's id, so the two can be matched up again.
    var id: UUID
    /// The step it was started from, so it can be shown where it belongs.
    var stepID: UUID
    /// The recipe the step belongs to, so the switcher can say which pot a
    /// countdown is for. Optional only so timers written down by an earlier
    /// version still decode — a missing key would drop a running alarm.
    var recipeID: UUID?
    var recipeTitle: String
    var stepNumber: Int
    /// What was asked for, which is not what is left.
    var duration: TimeInterval
    var fireDate: Date
    /// Whether it has gone off and is still ringing.
    var isAlerting = false

    func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, fireDate.timeIntervalSince(now))
    }

    func isFinished(at now: Date = Date()) -> Bool {
        remaining(at: now) <= 0
    }
}

extension TimeInterval {
    /// `5 Min.`, `1:30 Std.` — how a duration is offered before it is started.
    var cookTimerLabel: String {
        let total = Int(rounded())
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        if hours > 0 {
            return minutes > 0
                ? String(format: "%d:%02d Std.", hours, minutes)
                : "\(hours) Std."
        }
        if minutes > 0 {
            return seconds > 0
                ? String(format: "%d:%02d Min.", minutes, seconds)
                : "\(minutes) Min."
        }
        return "\(seconds) Sek."
    }
}
