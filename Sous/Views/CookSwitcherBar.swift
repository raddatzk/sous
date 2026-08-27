import SousKit
import SwiftUI

/// One chip per pot on the hob, for cook mode's toolbars.
///
/// Both platforms put them in a real bar now — the Mac in the title bar, the
/// phone in the bottom toolbar, where the hand already is: switching pots is
/// a one-handed move made with the phone propped against something.
struct CookSwitcherChips: View {
    /// Where the chips are standing, which decides how the active one is
    /// marked.
    enum Presentation {
        /// In the bar along the foot, on its own ground.
        case bar
        /// In the title bar, where the system already draws a capsule around
        /// the whole item — a second one inside it reads as a box in a box.
        case toolbar
    }

    @Environment(CookTimerCenter.self) private var timers

    let entries: [CookSessionEntry]
    let titles: [UUID: String]
    let activeRecipeID: UUID?
    let onSelect: (UUID) -> Void
    var presentation: Presentation = .bar

    var body: some View {
        HStack(spacing: 8) {
            ForEach(entries) { entry in
                chip(for: entry)
            }
        }
    }

    @ViewBuilder
    private func chip(for entry: CookSessionEntry) -> some View {
        let isActive = entry.recipeID == activeRecipeID
        Button {
            onSelect(entry.recipeID)
        } label: {
            HStack(spacing: 6) {
                Text(titles[entry.recipeID] ?? "Rezept")
                    .font(SousStyle.recipeChip)
                    .lineLimit(1)
                // Only on the pots the cook is not watching: a countdown on
                // the recipe already on screen is one they can see anyway.
                if !isActive, let timer = nextTimer(of: entry.recipeID) {
                    timerBadge(timer)
                }
            }
            .padding(.horizontal, presentation == .bar ? 14 : 8)
            .padding(.vertical, presentation == .bar ? 8 : 2)
            // In the toolbar the active pot is told apart by weight and
            // colour rather than by a filled capsule, since the item already
            // sits in one.
            .foregroundStyle(
                isActive
                    ? AnyShapeStyle(presentation == .bar ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                    : AnyShapeStyle(.secondary)
            )
            .background(
                isActive && presentation == .bar
                    ? AnyShapeStyle(Color.sousField)
                    : AnyShapeStyle(.clear),
                in: .capsule
            )
        }
        .buttonStyle(.plain)
    }

    /// A ringing timer says so; a running one says how long is left.
    @ViewBuilder
    private func timerBadge(_ timer: CookTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let finished = timer.isFinished(at: tick.date)
            HStack(spacing: 3) {
                Image(systemName: finished ? "bell.fill" : "timer")
                    .symbolEffect(.pulse, isActive: finished)
                if !finished {
                    Text(timer.remaining(at: tick.date).cookTimerBadge)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(finished ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            // Same beat as the banner's bell: felt once, when it rings.
            .sensoryFeedback(.warning, trigger: finished) { old, new in !old && new }
        }
    }

    private func nextTimer(of recipeID: UUID) -> CookTimer? {
        timers.timers(forRecipe: recipeID).first
    }
}


extension TimeInterval {
    /// `4:12`, `1:02:30` — a countdown small enough to sit inside a chip.
    var cookTimerBadge: String {
        let total = Int(rounded())
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
