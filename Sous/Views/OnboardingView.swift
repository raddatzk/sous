import SousKit
import SwiftUI

/// What the app says the first time it is opened.
///
/// Eight pages, and every one of them either does something or names the
/// place where it is done: a welcome that only describes the app is a page a
/// cook taps through without reading. So the last page carries the import and
/// the editor, the optimization page the choice of chat, and the household
/// page the invitation itself — the same controls the settings offer, not
/// pointers to them. The ingredients page has nothing to press, so it shows
/// instead: one line run through the app's own catalog and nutrition tables,
/// stage by stage. The cooking page names the button that starts it.
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
    @State private var journeyStage: IngredientJourneyStage = .reading

    /// The eight pages: what the app is, what it does with a recipe once it
    /// has one, what becomes of each ingredient line, cooking along, how a
    /// chat brings a recipe into shape, how it makes another version of it,
    /// who else is cooking — and last,
    /// bringing recipes in.
    ///
    /// The ingredients page follows planning because it is the why of
    /// planning's last sentence: the list can add things up only because
    /// every line was found in the catalog. Cooking comes before the
    /// optimization, which says what the cook mode gains from it.
    ///
    /// Importing is last because its two buttons close the welcome: put it
    /// anywhere earlier and the pages behind it are never seen.
    private enum Step: Int, CaseIterable, Hashable {
        case welcome
        case planning
        case ingredients
        case cooking
        case steps
        case editing
        case household
        case recipes

        var symbol: String {
            switch self {
            case .welcome: "fork.knife"
            case .recipes: "book.closed"
            case .cooking: "frying.pan"
            case .steps: "wand.and.stars"
            case .editing: "sparkles"
            case .planning: "calendar"
            case .ingredients: "carrot"
            case .household: "person.2"
            }
        }

        var title: String {
            switch self {
            case .welcome: "Willkommen bei Sous"
            case .recipes: "Rezepte hineinbringen"
            case .cooking: "Kochen"
            case .steps: "Für Sous optimieren"
            case .editing: "Mit KI bearbeiten"
            case .planning: "Planen und einkaufen"
            case .ingredients: "Aus einer Zeile wird mehr"
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
                einem anderen Gerät weiter, wo du aufgehört hast.
                """
            case .steps:
                """
                Ein Chat, den du schon nutzt, bringt ein Rezept in Form: \
                Zutaten so geschrieben, dass Sous jede erkennt, und zu jedem \
                Schritt die Zutaten, die er braucht — dann rechnet der \
                Kochmodus Mengen im Text mit. Wörter, die Sous noch nicht \
                kennt, schlägt er für deinen Haushalt vor. Sous kopiert die \
                Frage, du fügst sie dort ein und die Antwort zurück; du \
                wählst, was davon gilt, und das Original bleibt erhalten. \
                Ohne KI ordnest du Schritte von Hand zu. Zu finden im Menü \
                eines Rezepts.
                """
            case .editing:
                """
                Aus einem Rezept wird eine andere Version: vegan, \
                glutenfrei, schneller, für mehr Personen. Im Menü eines \
                Rezepts wählst du einen Prompt oder schreibst selbst, was \
                sich ändern soll. Sous kopiert ihn mit dem Rezept, deinen \
                Kategorien und dem Zutatenkatalog; ihr redet im Chat \
                darüber, und den JSON-Block der letzten Antwort fügst du \
                zurück — gleich für Sous optimiert, mit den Zutaten jedes \
                Schritts. Das Rezept wird ersetzt — jede frühere Fassung \
                bleibt unter „Versionen“ im Menü des Rezepts, zum \
                Vergleichen und Zurückholen —, oder du legst die Version \
                als neues Rezept oder Variante an. Die Prompts, auch \
                die mitgelieferten, pflegst du unter Einstellungen › \
                Haushalt › KI-Prompts.
                """
            case .planning:
                """
                Leg Rezepte auf die Tage der Woche — oder lass dir mit \
                „Vorschlagen“ Abende zusammenstellen, die zusammen ausgewogen \
                sind. Was geplant ist, steht zusammengezählt auf der \
                Einkaufsliste.
                """
            case .ingredients:
                """
                Jede Zutat im Rezept findet Sous in seinem Zutatenkatalog \
                wieder. Das sortiert die Einkaufsliste und rechnet die \
                Nährwerte. Nennt ihr etwas anders oder kauft ein bestimmtes \
                Produkt, bringst du es dem Katalog für euren Haushalt bei — \
                unter \(Self.catalogPlace).
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

    /// What each page can do, which for three of them is nothing: the welcome
    /// has nothing to offer yet, and planning and cooking have nothing to
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
            OptimizationChatPicker()
                .pickerStyle(.menu)
                .buttonStyle(.bordered)
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
        case .ingredients:
            IngredientJourneyView(
                stage: $journeyStage,
                isPlaying: self.step == .ingredients
            )
            .multilineTextAlignment(.leading)
        case .welcome, .planning, .cooking, .editing:
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

    /// Where in the eight the cook is. Decorative, so it is hidden from
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
