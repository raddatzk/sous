import SousKit
import SwiftUI

/// What the app says the first time it is opened.
///
/// Eight pages, and every one of them either does something or shows what it
/// is about: a welcome that only describes the app is a page a cook taps
/// through without reading. So the last page carries the import and the
/// editor, the AI page the choice of how Sous asks, and the household page
/// the invitation itself — the same controls the settings offer, not pointers
/// to them. The catalog, shopping and nutrition pages have nothing to press,
/// so each shows a tile instead: one line run through the app's own catalog
/// and nutrition tables. The cooking page lets the cook change the portions
/// of an example step and watch its amounts follow.
///
/// A paging scroll view rather than a `TabView(.page)`, because that style is
/// iOS only and the Mac would be left with a welcome it cannot leave. The
/// pages lie side by side and follow the finger (or the trackpad), the
/// buttons scroll the same strip, and the page dots stay ours to place
/// rather than the tab view's to hide.
struct OnboardingView: View {
    @Environment(OnboardingNotice.self) private var notice
    @Environment(\.households) private var households
    @Environment(CloudKitInitialImport.self) private var initialImport
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome

    /// The eight pages: what the app is, the catalog every ingredient line is
    /// found in, what that does for the shopping list and for the nutrition
    /// figures, cooking along, how AI optimizes and edits a recipe, who else
    /// is cooking — and last, bringing recipes in.
    ///
    /// Importing is last because its two buttons close the welcome: put it
    /// anywhere earlier and the pages behind it are never seen.
    private enum Step: Int, CaseIterable, Hashable {
        case welcome
        case catalog
        case shopping
        case nutrition
        case cooking
        case steps
        case household
        case recipes

        var symbol: String {
            switch self {
            case .welcome: "fork.knife"
            case .recipes: "book.closed"
            case .cooking: "frying.pan"
            case .steps: "wand.and.stars"
            case .catalog: "text.book.closed"
            case .shopping: "cart"
            case .nutrition: "chart.bar"
            case .household: "person.2"
            }
        }

        var title: String {
            switch self {
            case .welcome: "Willkommen bei Sous"
            case .recipes: "Rezepte hineinbringen"
            case .cooking: "Kochen"
            case .steps: "Sous & KI"
            case .catalog: "Der Zutatenkatalog"
            case .shopping: "Einkauf"
            case .nutrition: "Nährwerte"
            case .household: "Zu zweit kochen"
            }
        }

        var text: String {
            switch self {
            case .welcome:
                """
                Deine Rezepte, der Plan für die Woche und die Einkaufsliste \
                dazu — auf allen deinen Geräten. Die Suche findet ein Rezept \
                nach Namen und filtert nach Zutaten, die du da hast.
                """
            case .recipes:
                """
                Importiere eine Sammlung, hol dir ein Rezept aus dem Web oder \
                schreib eins selbst. Aus Safari teilst du eine Seite direkt \
                an Sous.
                """
            case .cooking:
                """
                „Kochen“ führt Schritt für Schritt durchs Rezept. Hak ab, was \
                bereitliegt, starte Timer direkt aus dem Text und koch auf \
                einem anderen Gerät weiter, wo du aufgehört hast. Die Mengen \
                im Schritt und in seinen Chips rechnen mit, wenn du die \
                Portionen änderst.
                """
            case .steps:
                """
                Eine KI kann deine Rezepte für Sous optimieren und sie auf \
                Wunsch bearbeiten. Du wählst, wie Sous sie fragt, und das \
                Original bleibt immer erhalten.
                """
            case .catalog:
                """
                Jede Zutat im Rezept findet Sous in seinem Zutatenkatalog \
                wieder, egal wie ein Rezept sie schreibt. Den Katalog gibt es \
                zentral für alle. Fehlt dir etwas oder nennt ihr es anders, \
                ergänzt du es für deinen Haushalt — unter \(Self.catalogPlace) — \
                und teilst es mit der Community, damit der Katalog es für \
                alle lernt.
                """
            case .shopping:
                """
                Aus allen Rezepten wird eine Liste: Was mehrere Rezepte \
                brauchen, steht einmal da, zusammengezählt und nach Abteilung \
                sortiert, wie du durch den Laden gehst. Leg Rezepte auf die \
                Tage der Woche — oder lass dir mit „Vorschlagen“ Abende \
                zusammenstellen —, und was geplant ist, landet auf der Liste.
                """
            case .nutrition:
                """
                Zu jeder Zutat gehören Nährwerte aus verifizierten Quellen. \
                Aus Gramm und Nährwerten rechnet Sous jedes Rezept pro Portion \
                aus, ohne dass du etwas einträgst.
                """
            case .household:
                """
                Gib deinem Haushalt einen Namen und lade jemanden ein: \
                dieselben Rezepte, derselbe Plan, dieselbe Einkaufsliste — und \
                beide dürfen alles ändern. Geht auch später jederzeit in den \
                Einstellungen.
                """
            }
        }

        /// Where the catalog opens: the Mac has no "Mehr" menu on the list,
        /// and keeps it in the menu bar instead.
        private static var catalogPlace: String {
            #if os(macOS)
            "Bibliothek › Zutatenkatalog"
            #else
            "Rezepte › Mehr › Zutatenkatalog"
            #endif
        }

        var isLast: Bool { self == Step.allCases.last }
    }

    var body: some View {
        VStack(spacing: 0) {
            skipBar
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Step.allCases, id: \.self) { item in
                            // Centred in what is left over, and still
                            // scrollable: five short pages have room to spare
                            // on a phone, while the same text at the largest
                            // type size is taller than the sheet. The content
                            // is at least a screenful, so a short page
                            // centres, and a long one scrolls instead of being
                            // cut off.
                            ScrollView {
                                page(item)
                                    .frame(maxWidth: 420)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 24)
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: proxy.size.height,
                                        alignment: .center
                                    )
                            }
                            .scrollIndicators(.hidden)
                            .frame(width: proxy.size.width)
                            .id(item)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                // Both ways: a swipe says which page is showing, and the
                // buttons scroll the strip to the page they name.
                .scrollPosition(id: shownStep)
            }
            footer
                .animation(.smooth(duration: 0.25), value: step)
        }
        #if os(macOS)
        // A sheet on the Mac takes the size its content asks for, and this
        // content would otherwise be as wide as its longest line.
        .frame(width: 480, height: 560)
        #else
        // Sized like the other whole-screen sheets, so the iPad does not
        // open it as a form sheet a third the size of the editor's.
        .sousSheetSizing(.page)
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

    private func page(_ step: Step) -> some View {
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
            actions(for: step)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
    }

    /// What each page shows or can do. The welcome has nothing to offer yet;
    /// the catalog, shopping and nutrition pages show a tile, and the cooking
    /// page an example to play with, because none of them has anything to
    /// work on before a recipe exists.
    @ViewBuilder
    private func actions(for step: Step) -> some View {
        switch step {
        case .recipes:
            VStack(spacing: 10) {
                // A reinstall is welcomed too, rather than kept waiting for
                // iCloud — so this page can be the one standing while the
                // cook's own recipes arrive behind it. Saying so beats
                // asking them to import what they already have.
                if initialImport.isWaiting {
                    Label("Deine Rezepte aus iCloud kommen gerade an …", systemImage: "icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.bottom, 2)
                }
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
        case .steps:
            OnboardingAIChoice()
        case .household:
            if let households {
                VStack(spacing: 10) {
                    HouseholdShareLink(households: households)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 280)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .catalog:
            IngredientJourneyTile(stage: .catalog)
                .multilineTextAlignment(.leading)
        case .shopping:
            IngredientJourneyTile(stage: .shopping)
                .multilineTextAlignment(.leading)
        case .nutrition:
            IngredientJourneyTile(stage: .nutrition)
                .multilineTextAlignment(.leading)
        case .cooking:
            CookingDemo(isShown: self.step == .cooking)
                .multilineTextAlignment(.leading)
        case .welcome:
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

    /// Where in the seven the cook is. Decorative, so it is hidden from
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

    /// The page the strip rests on, as the scroll position reads it. `nil`
    /// only mid-scroll, which leaves the last page standing.
    private var shownStep: Binding<Step?> {
        Binding(
            get: { step },
            set: { if let newValue = $0 { step = newValue } }
        )
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }
}


/// The welcome's page about AI: how Sous should ask, and, for a provider of
/// the cook's own, what to know and where to make the key.
private struct OnboardingAIChoice: View {
    @AppStorage(SousSetting.optimizationChat, store: .sous)
    private var chat: OptimizationChat?
    @AppStorage(SousSetting.aiMode, store: .sous)
    private var stored: AIMode?
    @State private var connections = AIConnections.shared
    @State private var isSettingUp = false

    private var mode: AIMode { AIMode.effective(chat: chat, stored: stored) }

    var body: some View {
        VStack(spacing: 12) {
            AIModeChoice(style: .segmented)
            switch mode {
            case .off:
                Text("Du kannst es jederzeit in den Einstellungen ändern.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .copyPaste:
                VStack(alignment: .leading, spacing: 8) {
                    copyStep("1", "Sous kopiert die Frage samt Rezept und Zutatenkatalog.")
                    copyStep("2", "Du fügst sie in einen Chat ein, den du schon nutzt, etwa ChatGPT, Claude oder Gemini.")
                    copyStep("3", "Die Antwort kopierst du einfach wieder zurück.")
                    Text("Das geht mit jedem Chat und jedem Abo, ohne API-Schlüssel und ohne zusätzliche Kosten.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .multilineTextAlignment(.leading)
                OptimizationChatPicker(includesOff: false)
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
            case .api:
                provider
            }
        }
        .sheet(isPresented: $isSettingUp) {
            NavigationStack {
                AIConnectionView(ai: connections.personal)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { isSettingUp = false }
                        }
                    }
            }
            .sousSheetSizing(.page)
        }
    }

    private func copyStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.sousAccent)
                .frame(width: 18, height: 18)
                .background(Color.sousAccent.opacity(SousStyle.chipTint), in: .circle)
            Text(text)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var provider: some View {
        VStack(spacing: 10) {
            Text(AIAPINote.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let household = connections.household.usable, connections.personal.usable == nil {
                Label("Dein Haushalt hat \(household.provider.name) eingerichtet.", systemImage: "person.2")
                    .font(.footnote)
            }
            Button(connections.personal.usable == nil ? "Anbieter einrichten …" : "Anbieter ändern …") {
                isSettingUp = true
            }
            .buttonStyle(.borderedProminent)
            // Where a key is made, for each provider Sous knows.
            HStack(spacing: 14) {
                ForEach(LLMProvider.presets, id: \.name) { preset in
                    if let page = preset.keyPage {
                        Link(preset.name, destination: page)
                    }
                }
            }
            .font(.footnote)
        }
    }
}


/// An example step whose amounts follow the portions, the way the cook mode's
/// do: in the sentence and in the chips under it. A chip can be ticked, as in
/// the cook mode, where a tick means "in the pot".
///
/// It is only an example: the timer here is a countdown on the page, not one
/// the app keeps. Leaving the page puts everything back, so a cook who returns
/// finds the example as it was first shown.
private struct CookingDemo: View {
    /// Whether the cooking page is the one showing.
    let isShown: Bool

    @State private var servings = 2
    @State private var ticked: Set<Int> = []
    /// When the example timer, once started, runs out.
    @State private var timerEnd: Date?

    /// What the example step says about time; the cook mode offers a timer for it.
    private static let timerSeconds: TimeInterval = 600

    private let formatter = QuantityFormatter(locale: .sous)

    /// The example's two amounts, for two portions.
    private var flour: Quantity { Quantity(200 * Double(servings) / 2, .gram) }
    private var water: Quantity { Quantity(200 * Double(servings) / 2, .milliliter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: $servings, in: 1...8) {
                Label(servings == 1 ? "1 Portion" : "\(servings) Portionen", systemImage: "person.2")
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("1")
                    .font(SousStyle.stepNumber)
                    .foregroundStyle(Color.sousAccent)
                Text("\(amount(flour)) Mehl und \(amount(water)) Wasser verrühren und \(Text("10 Minuten").foregroundStyle(Color.sousAccent)) ruhen lassen.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                chip(0, "\(formatter.string(for: flour)) Mehl")
                chip(1, "\(formatter.string(for: water)) Wasser")
                timerChip
            }
            .padding(.leading, 28)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: SousStyle.fieldRadius)
                .strokeBorder(.separator)
        }
        .animation(.smooth(duration: 0.2), value: servings)
        .onChange(of: isShown) { _, shown in
            // Back to the start once the page is left.
            if !shown {
                servings = 2
                ticked = []
                timerEnd = nil
            }
        }
    }

    /// The timer the step offers: a tap starts it and it counts down, a tap
    /// on "Stopp" puts it away, as in the cook mode.
    @ViewBuilder
    private var timerChip: some View {
        if let end = timerEnd {
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                let remaining = max(0, end.timeIntervalSince(tick.date))
                HStack(spacing: 8) {
                    Image(systemName: "timer").foregroundStyle(Color.sousAccent)
                    Text(remaining.cookTimerBadge).monospacedDigit()
                    Button("Stopp") { timerEnd = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.sousAccent)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.sousAccent.opacity(SousStyle.chipTint), in: .capsule)
            }
        } else {
            Button {
                timerEnd = Date().addingTimeInterval(Self.timerSeconds)
            } label: {
                Label("Timer \(Self.timerSeconds.cookTimerLabel)", systemImage: "timer")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.sousAccent, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    /// The amount in the sentence, tinted as the cook mode tints them.
    private func amount(_ quantity: Quantity) -> Text {
        Text(formatter.string(for: quantity)).foregroundStyle(Color.sousAccent)
    }

    private func chip(_ index: Int, _ text: String) -> some View {
        let isChecked = ticked.contains(index)
        return Button {
            if isChecked { ticked.remove(index) } else { ticked.insert(index) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.sousAccent)
                Text(text)
                    .strikethrough(isChecked)
                    .opacity(isChecked ? 0.45 : 1)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.sousAccent.opacity(SousStyle.chipTint), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
