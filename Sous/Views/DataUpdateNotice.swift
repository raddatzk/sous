import Observation
import SwiftUI

/// Whether this launch was the one that found the shipped data had changed —
/// the channel the app never had for saying so.
///
/// Both migrations before phase 6 threw their reports away (`_ = try? await
/// …`), which was fine while they had nothing a cook needed to hear. The
/// orphan pass does: concept §7 asks the app to *tell* the cook which
/// mappings a new release took away, rather than let them discover it one
/// recipe at a time.
///
/// Decision D draws the line this type respects exactly. Only orphans are
/// reported. Changed values are not mentioned, not counted, and not looked
/// for — they flow into the sums silently, and a notice about them would be
/// the nagging the decision exists to prevent.
///
/// It holds a flag rather than the list. The list is read live off the
/// vocabulary (`NutritionLibrary.orphanedIngredients`), so answering a
/// question shortens it in place — and once the marker matches on the next
/// launch, nothing announces anything again.
@MainActor
@Observable
final class DataUpdateNotice {
    /// Set by the launch that ran the reconciliation and found something.
    var didFindOrphans = false
    /// The cook looked at it. Kept for as long as the app runs, and no
    /// longer: this is not a decision worth persisting, and the questions
    /// themselves stay visible in every recipe that uses one.
    var isDismissed = false

    var isShowing: Bool { didFindOrphans && !isDismissed }
}
