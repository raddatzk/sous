import Foundation
import Observation

/// Cooking, carried from one of the cook's devices to the other.
///
/// Started at the Mac, finished at the hob with the phone — or the other way
/// round. What travels is the session as it stands: the pots, the step each
/// one is at, what has been ticked off, and the timers with the time they
/// have left.
///
/// A move, not a copy. Once the other device has taken over, this one closes
/// cook mode and stops its timers — two devices ringing for the same pasta,
/// and a half-finished session left behind to be offered again, would both
/// be worse than the handoff not existing.
///
/// Managed by hand rather than with SwiftUI's `userActivity` modifier: that
/// one keeps the activity's delegate to itself, and the delegate is the only
/// place the system says "the other device has taken this".
@MainActor
@Observable
final class CookHandoff {
    /// Declared under `NSUserActivityTypes` in `project.yml` as well; an
    /// activity whose type the app does not list is never offered.
    static let activityType = "me.raddatz.sous.cooking"

    /// Everything the other device needs to stand where this one stood.
    struct Payload: Codable {
        var entries: [CookSessionEntry]
        var activeRecipeID: UUID?
        /// End times rather than a count left: the two clocks agree, and the
        /// time between offering and taking over is then counted too.
        var timers: [CookTimer]
    }

    private static let payloadKey = "payload"

    @ObservationIgnored private var activity: NSUserActivity?
    @ObservationIgnored private var relay: Relay?
    /// What is currently on offer — and so what has to stop here once it has
    /// been taken.
    @ObservationIgnored private var offered: Payload?
    @ObservationIgnored private weak var session: CookSession?
    @ObservationIgnored private weak var timers: CookTimerCenter?

    /// Offers the session to the other devices, or refreshes the offer.
    /// Called on every change to the session or the timers, so what is
    /// handed over is never older than the last step scrolled to.
    func offer(_ session: CookSession, timers: CookTimerCenter, title: String?) {
        guard session.isPresented, !session.isEmpty else {
            withdraw()
            return
        }
        let cooking = Set(session.entries.map(\.recipeID))
        let now = Date()
        let payload = Payload(
            entries: session.entries,
            activeRecipeID: session.activeEntry?.recipeID,
            // A timer already ringing is for this kitchen to silence, not
            // for the other device to start again at zero.
            timers: timers.timers.filter { timer in
                guard let recipeID = timer.recipeID else { return false }
                return cooking.contains(recipeID) && !timer.isAlerting && !timer.isFinished(at: now)
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }

        self.session = session
        self.timers = timers
        offered = payload

        let activity = activity ?? makeActivity()
        activity.title = title
        activity.userInfo = [Self.payloadKey: data]
        activity.needsSave = true
        activity.becomeCurrent()
    }

    /// Takes the offer back — cook mode closed, or the last pot came off.
    func withdraw() {
        activity?.invalidate()
        activity = nil
        relay = nil
        offered = nil
    }

    /// What an incoming activity carries, or `nil` if it carries nothing
    /// readable.
    static func payload(from userInfo: [AnyHashable: Any]?) -> Payload? {
        guard let data = userInfo?[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func makeActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.isEligibleForHandoff = true
        // Not a place to come back to through search or Siri's suggestions:
        // a cooking session is over by tomorrow.
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif
        let relay = Relay { [weak self] in
            Task { @MainActor in self?.handedOver() }
        }
        activity.delegate = relay
        self.activity = activity
        self.relay = relay
        return activity
    }

    /// The other device has it now: stop here what is running there.
    private func handedOver() {
        guard let offered else { return }
        withdraw()
        if let timers {
            for handed in offered.timers {
                if let running = timers.timers.first(where: { $0.id == handed.id }) {
                    timers.cancel(running)
                }
            }
        }
        // Removing the last entry closes cook mode, and on the Mac its window.
        if let session {
            for entry in offered.entries {
                session.remove(entry.recipeID)
            }
        }
    }

    /// The activity's delegate. Its own object, because the system calls it
    /// on whatever thread it likes and `CookHandoff` belongs to the main
    /// actor.
    private final class Relay: NSObject, NSUserActivityDelegate {
        private let continued: @Sendable () -> Void

        init(continued: @escaping @Sendable () -> Void) {
            self.continued = continued
        }

        func userActivityWasContinued(_ userActivity: NSUserActivity) {
            continued()
        }
    }
}
