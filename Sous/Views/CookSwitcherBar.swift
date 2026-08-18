import SousKit
import SwiftUI

/// The row along the bottom of cook mode: one chip per pot, and a way to put
/// another one on.
///
/// It sits at the bottom rather than the top because that is where the hand
/// already is — switching pots is a one-handed move made with the phone
/// propped against something, in the middle of doing something else.
struct CookSwitcherBar: View {
    @Environment(CookTimerCenter.self) private var timers

    let entries: [CookSessionEntry]
    /// Recipe names by id, resolved by the screen that owns the session.
    let titles: [UUID: String]
    let activeRecipeID: UUID?
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                chips
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            Button("Rezept dazunehmen", systemImage: "plus") { onAdd() }
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(width: 34, height: 34)
                .background(Color.sousField, in: .capsule)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .background(.bar)
    }

    /// The chips on their own, without the bar around them — the Mac puts
    /// them in the toolbar, where the bar would be a second one.
    @ViewBuilder
    var chips: some View {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(isActive ? AnyShapeStyle(Color.sousField) : AnyShapeStyle(.clear), in: .capsule)
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
