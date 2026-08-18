import AlarmKit
import SwiftUI
import WidgetKit

/// The app's presence outside the app.
@main
struct SousWidgetBundle: WidgetBundle {
    var body: some Widget {
        CookTimerLiveActivity()
    }
}

/// A cooking timer on the lock screen, in the Dynamic Island, and in StandBy.
///
/// AlarmKit hands over a countdown and expects it drawn; the countdown itself
/// is `Text(timerInterval:)`, which ticks without the widget being woken for
/// every second.
struct CookTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CookTimerMetadata>.self) { context in
            lockScreen(context)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer")
                        .font(.title2)
                        .foregroundStyle(Color.sousAccent)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(context))
                            .font(.headline)
                            .lineLimit(1)
                        subtitle(context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context)
                        .font(.system(.title, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.sousAccent)
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(Color.sousAccent)
            } compactTrailing: {
                countdown(context)
                    .monospacedDigit()
                    .foregroundStyle(Color.sousAccent)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(Color.sousAccent)
            }
        }
    }

    @ViewBuilder
    private func lockScreen(
        _ context: ActivityViewContext<AlarmAttributes<CookTimerMetadata>>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.title)
                .foregroundStyle(Color.sousAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(context))
                    .font(.headline)
                    .lineLimit(1)
                subtitle(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            countdown(context)
                .font(.system(.title, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.sousAccent)
        }
    }

    /// The dish, so a glance at a locked phone says which pot this is.
    private func title(
        _ context: ActivityViewContext<AlarmAttributes<CookTimerMetadata>>
    ) -> String {
        context.attributes.metadata?.recipeTitle ?? "Sous"
    }

    @ViewBuilder
    private func subtitle(
        _ context: ActivityViewContext<AlarmAttributes<CookTimerMetadata>>
    ) -> some View {
        if let step = context.attributes.metadata?.stepNumber {
            Text("Schritt \(step)")
        }
    }

    /// The remaining time, or what the timer is doing instead of counting.
    @ViewBuilder
    private func countdown(
        _ context: ActivityViewContext<AlarmAttributes<CookTimerMetadata>>
    ) -> some View {
        switch context.state.mode {
        case let .countdown(countdown):
            Text(timerInterval: Date.now...countdown.fireDate, countsDown: true)
        case .paused:
            Text("Pause")
        case .alert:
            Text("Fertig")
        @unknown default:
            EmptyView()
        }
    }
}
