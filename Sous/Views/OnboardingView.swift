import SousKit
import SwiftUI

/// What the app says the first time it is opened.
///
/// Four pages, and every one of them either does something or names the place
/// where it is done: a welcome that only describes the app is a page a cook
/// taps through without reading. So the recipe page carries the import and the
/// editor, and the household page carries the invitation itself — the same
/// `ShareLink` the settings offer, not a pointer to it.
///
/// Hand-paged rather than a `TabView(.page)`, because that style is iOS only
/// and the Mac would be left with a welcome it cannot leave. One view, one
/// step, a crossfade between them — which also keeps the page dots ours to
/// place rather than the tab view's to hide.
struct OnboardingView: View {
    @Environment(OnboardingNotice.self) private var notice
    @Environment(\.households) private var households
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome

    /// The four pages, in the order the app is used: what it is, how recipes
    /// get in, what happens to them afterwards, and who else is cooking.
    private enum Step: Int, CaseIterable {
        case welcome
        case recipes
        case planning
        case household

        var symbol: String {
            switch self {
            case .welcome: "fork.knife"
            case .recipes: "book.closed"
            case .planning: "calendar"
            case .household: "person.2"
            }
        }

        var title: String {
            switch self {
            case .welcome: "Willkommen bei Sous"
            case .recipes: "Rezepte hineinbringen"
            case .planning: "Planen und einkaufen"
            case .household: "Zu zweit kochen"
            }
        }

        var text: String {
            switch self {
            case .welcome:
                """
                Deine Rezepte, der Plan für die Woche und die Einkaufsliste \
                dazu — auf allen deinen Geräten.
                """
            case .recipes:
                """
                Importiere eine Sammlung, hol dir ein Rezept aus dem Web oder \
                schreib eins selbst. Aus Safari teilst du eine Seite direkt \
                an Sous.
                """
            case .planning:
                """
                Leg Rezepte auf die Tage der Woche — oder lass Sous \
                vorschlagen, was es geben könnte. Was geplant ist, steht \
                zusammengezählt auf der Einkaufsliste.
                """
            case .household:
                #if os(iOS)
                """
                Lade jemanden in deinen Haushalt ein: dieselben Rezepte, \
                derselbe Plan, dieselbe Einkaufsliste — und beide dürfen alles \
                ändern. Geht auch später jederzeit in den Einstellungen.
                """
                #else
                """
                Auf dem iPhone oder iPad lädst du jemanden in deinen Haushalt \
                ein: dieselben Rezepte, derselbe Plan, dieselbe Einkaufsliste \
                — und beide dürfen alles ändern. Geteilt wird dann auf allen \
                deinen Geräten, hier eingeschlossen.
                """
                #endif
            }
        }

        var isLast: Bool { self == Step.allCases.last }
    }

    var body: some View {
        VStack(spacing: 0) {
            skipBar
            // Centred in what is left over, and still scrollable: four short
            // pages have room to spare on a phone, while the same text at the
            // largest type size is taller than the sheet. The geometry is what
            // gives both — the content is at least a screenful, so a short
            // page centres, and a long one scrolls instead of being cut off.
            GeometryReader { proxy in
                ScrollView {
                    page
                        // The crossfade needs something to fade *between*, and
                        // two pages differing only in their strings are one
                        // view to SwiftUI without this.
                        .id(step)
                        .transition(.opacity)
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .center
                        )
                }
            }
            footer
        }
        .animation(.smooth(duration: 0.25), value: step)
        #if os(macOS)
        // A sheet on the Mac takes the size its content asks for, and this
        // content would otherwise be as wide as its longest line.
        .frame(width: 480, height: 560)
        #endif
    }

    /// The way past all of it, on every page but the last — where "Fertig"
    /// already is one.
    @ViewBuilder
    private var skipBar: some View {
        HStack {
            Spacer()
            if !step.isLast {
                Button("Überspringen") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        // Held even when empty, so the page below does not jump upwards on
        // the last step.
        .frame(height: 28)
    }

    private var page: some View {
        VStack(spacing: 16) {
            Image(systemName: step.symbol)
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.sousAccent)
                .padding(.bottom, 8)
            Text(step.title)
                .font(.title2.weight(.semibold))
            Text(step.text)
                .foregroundStyle(.secondary)
            actions
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
    }

    /// What each page can do, which for two of them is nothing: the welcome
    /// has nothing to offer yet, and planning has nothing to plan before a
    /// recipe exists.
    @ViewBuilder
    private var actions: some View {
        switch step {
        case .recipes:
            VStack(spacing: 10) {
                Button("Rezepte importieren …") {
                    notice.followUp = .importing
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("Rezept anlegen") {
                    notice.followUp = .newRecipe
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        case .household:
            // iOS only, and not for want of a Mac API: sharing is an iOS
            // surface for now, the way the settings' own section is — see
            // `HouseholdSharingSection`. The Mac's text says so instead of
            // offering a button that leads nowhere.
            #if os(iOS)
            if let households {
                HouseholdShareLink(households: households)
                    .buttonStyle(.borderedProminent)
            }
            #endif
        case .welcome, .planning:
            EmptyView()
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            dots
            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Zurück") { move(by: -1) }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Button(step.isLast ? "Fertig" : "Weiter") {
                    if step.isLast { dismiss() } else { move(by: 1) }
                }
                .buttonStyle(.borderedProminent)
                // So the Mac's return key does what the highlighted button
                // says, on every page.
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    /// Where in the four the cook is. Decorative, so it is hidden from
    /// VoiceOver — which reads the page's own heading instead.
    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Circle()
                    .fill(item == step ? Color.sousAccent : Color.sousField)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        step = next
    }
}
