import SousKit
import SwiftUI

/// The way back to the hob.
///
/// Cook mode can be put away without taking anything off the heat — to look
/// up whether there is yoghurt in the shopping list, to find the recipe that
/// should go on next. This band sits above every tab while something is
/// cooking, so that detour always has a way back and the pots are never out
/// of sight.
struct ContinueCookingBanner: View {
    @Environment(CookSession.self) private var session
    @Environment(CookTimerCenter.self) private var timers
    @Environment(RecipeLibrary.self) private var library

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var titles: [UUID: String] = [:]

    var body: some View {
        Button {
            session.isPresented = true
            #if os(macOS)
            // Opening a window that is already open brings it forward, which
            // is what the band is for once the cooking window exists.
            openWindow(id: SousApp.cookWindow)
            #endif
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "frying.pan")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weiter kochen")
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let timer = nextTimer {
                    countdown(timer)
                }
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .task(id: session.entries.map(\.recipeID)) { await resolveTitles() }
    }

    /// One pot is named; several are counted, because two names do not fit
    /// on a line a phone can spare for this.
    private var subtitle: String {
        let entries = session.entries
        if entries.count == 1, let id = entries.first?.recipeID, let title = titles[id] {
            return title
        }
        return "\(entries.count) Rezepte auf dem Herd"
    }

    private var nextTimer: CookTimer? {
        timers.timers.min { $0.fireDate < $1.fireDate }
    }

    @ViewBuilder
    private func countdown(_ timer: CookTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let finished = timer.isFinished(at: tick.date)
            HStack(spacing: 4) {
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

    private func resolveTitles() async {
        var resolved: [UUID: String] = [:]
        for entry in session.entries {
            resolved[entry.recipeID] = await library.recipe(id: entry.recipeID)?.title
        }
        titles = resolved
    }
}
