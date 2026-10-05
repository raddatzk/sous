import SousKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the app looks like, and the one place it is allowed to look different.
struct SettingsForm: View {
    @AppStorage(SousSetting.appearance, store: .sous)
    private var appearance: SousAppearance = .system
    /// The catalog release this process runs on, and the last daily check.
    private let dataSet = DataSet.current.manifest
    private let dataSetIsFetched = DataSet.current.origin != .bundled
    private let lastDataCheck = DataUpdateSchedule().lastCheck
    /// Absent where the form is the Mac's `Settings` scene and nothing was
    /// injected — then the button is not offered.
    @Environment(OnboardingNotice.self) private var onboarding: OnboardingNotice?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            CatalogNudgeCard()

            Section {
                Picker("Erscheinungsbild", selection: $appearance) {
                    ForEach(SousAppearance.allCases) { option in
                        Label(option.title, systemImage: option.symbol)
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Erscheinungsbild")
            } footer: {
                Text("„System“ folgt der Einstellung des Geräts.")
            }

            HouseholdSettingsRow()


            Section {
                OptimizationChatPicker()
            } header: {
                Text("Für Sous optimieren")
            } footer: {
                Text("""
                Feste Zeilen und die Zutaten jedes Schritts fragst du in einem \
                Chat, den du schon nutzt. Sous öffnet ihn neben dem kopierten \
                Prompt. „Keine KI verwenden“ blendet das Fragen ganz aus — \
                Zutaten pro Schritt lassen sich dann von Hand zuordnen.
                """)
            }

            if let onboarding {
                Section {
                    Button("Einführung erneut zeigen", systemImage: "questionmark.circle") {
                        onboarding.replay()
                        // The phone's settings are a sheet, and the welcome
                        // comes once it is gone; on the Mac there is nothing
                        // to close, and the welcome opens in the main window.
                        #if os(iOS)
                        dismiss()
                        #else
                        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                        #endif
                    }
                } footer: {
                    Text("Die Seiten, die beim ersten Start erscheinen — mit allem, was seitdem dazugekommen ist.")
                }
            }

            catalogRelease
            CatalogSharingSettingsSection()
            DataSourcesSettingsRow()
        }
        .formStyle(.grouped)
    }

    /// Which release of the catalog — words, weights, aisles, the BLS rows —
    /// the app is reading, and where its history is: the Git log of `Data/`,
    /// where every change is a reviewed commit. A newer release arrives on
    /// its own, at most daily, and is read from the next cold start.
    private var catalogRelease: some View {
        Section {
            LabeledContent("Version") {
                Text(verbatim: String(dataSet.dataVersion))
            }
            if let day = dataSet.day {
                LabeledContent("Stand") {
                    Text(day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
                }
            }
            LabeledContent("Herkunft") {
                Text(dataSetIsFetched ? "Nachgeladen" : "Mit der App geliefert")
            }
            if let lastDataCheck {
                LabeledContent("Zuletzt nach Neuem gesehen") {
                    Text(lastDataCheck.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Link("Änderungen ansehen", destination: Self.dataHistory)
        } header: {
            Text("Zutatenkatalog")
        } footer: {
            Text("Neue Katalogdaten lädt Sous höchstens einmal am Tag und verwendet sie ab dem nächsten Start.")
        }
    }

    private static let dataHistory = URL(string: "https://github.com/raddatzk/sous/commits/main/Data")!
}

/// The same settings as a sheet, for the phone and the app's own menu.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm()
                .navigationTitle("Einstellungen")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        // The screen that changes the setting is the one screen that has to
        // react to it: a sheet takes the window's scheme when it opens and
        // then keeps it.
        .sousAppearance()
        // A page, not a form: six sections outgrow a half-height sheet on
        // the phone, which could not be pulled any taller, and the iPad's
        // form size left most of them below the fold.
        .sousSheetSizing(.page)
    }
}


/// The irreversible things, for the household that is showing: emptying it,
/// deleting it — or, for one somebody else owns, leaving it.
///
/// At the bottom of the household's page, because that is where a
/// destructive action belongs: found when looked for, not met on the way to
/// something else. Every button names the household, and every question
/// names what would go, in numbers — "alles" is a word, 166 Rezepte is a
/// fact.
struct HouseholdDataSection: View {
    /// Optional throughout: on the Mac this form is the settings scene's own
    /// root, and a scene that failed to hand it the libraries should show no
    /// button rather than crash on one that deletes.
    @Environment(RecipeLibrary.self) private var library: RecipeLibrary?
    @Environment(MealPlanLibrary.self) private var plan: MealPlanLibrary?
    @Environment(ShoppingLibrary.self) private var shopping: ShoppingLibrary?
    @Environment(IngredientCatalogLibrary.self) private var catalog: IngredientCatalogLibrary?
    @Environment(CookSession.self) private var session: CookSession?
    @Environment(CookTimerCenter.self) private var timers: CookTimerCenter?
    @Environment(\.calendarMirror) private var calendarMirror
    @Environment(\.households) private var households
    @Environment(\.householdSwitcher) private var switcher

    /// The household showing, as far as leaving or deleting it goes.
    @State private var standing: HouseholdStanding?
    @State private var isAskingToStopSharing = false
    /// Set once the counting is done and the emptying question can be asked.
    @State private var emptyQuestion: LibraryWipe.Counts?
    @State private var isAskingToDelete = false
    @State private var failure: String?
    /// Recipes erased so far, while it runs — shown by the page, over all of
    /// it: an overlay on a section is laid on each of its rows, header and
    /// footer included, and the count showed up twice.
    @Binding var progress: (done: Int, total: Int)?
    /// Tells the page something about the household changed — its members,
    /// after sharing ends.
    var onChange: () async -> Void = {}

    private var wipe: LibraryWipe? {
        guard let library, let plan, let shopping, let catalog, let session, let timers,
              let households, let switcher
        else { return nil }
        return LibraryWipe(
            library: library,
            plan: plan,
            shopping: shopping,
            catalog: catalog,
            session: session,
            timers: timers,
            calendarMirror: calendarMirror,
            households: households,
            switcher: switcher
        )
    }

    var body: some View {
        if let wipe {
            Section {
                if let standing {
                    if standing.isOwn {
                        if standing.isShared {
                            Button("Teilen beenden …", systemImage: "person.2.slash", role: .destructive) {
                                isAskingToStopSharing = true
                            }
                        }
                        Button("„\(standing.name)“ leeren …", systemImage: "trash", role: .destructive) {
                            Task { emptyQuestion = await wipe.counts() }
                        }
                        Button("„\(standing.name)“ löschen …", systemImage: "trash.slash", role: .destructive) {
                            isAskingToDelete = true
                        }
                    } else {
                        Button(
                            "„\(standing.name)“ verlassen …",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            isAskingToDelete = true
                        }
                    }
                }
            } header: {
                Text("Daten")
            } footer: {
                Text(footer)
            }
            .task(id: "\(switcher?.activeID?.uuidString ?? "")|\(switcher?.choices.first { $0.id == switcher?.activeID }?.name ?? "")") {
                guard let id = switcher?.activeID else {
                    standing = nil
                    return
                }
                standing = await households?.standing(of: id)
            }
            .alert(
                "„\(standing?.name ?? "")“ wirklich leeren?",
                isPresented: Binding(presence: $emptyQuestion),
                presenting: emptyQuestion
            ) { _ in
                Button("Leeren", role: .destructive) {
                    Task { await empty(with: wipe) }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { counts in
                Text(Self.message(for: counts, sharedWith: standing?.otherParticipants ?? 0))
            }
            .alert(
                deleteTitle,
                isPresented: $isAskingToDelete
            ) {
                Button(standing?.isOwn == false ? "Verlassen" : "Löschen", role: .destructive) {
                    Task { await deleteOrLeave(with: wipe) }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert(
                "Teilen von „\(standing?.name ?? "")“ beenden?",
                isPresented: $isAskingToStopSharing
            ) {
                Button("Teilen beenden", role: .destructive) {
                    Task { await stopSharing() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("""
                Alle, mit denen du den Haushalt teilst, verlieren ihn. Bei dir \
                bleibt er, wie er ist; wer wieder dabei sein soll, braucht eine \
                neue Einladung.
                """)
            }
            .alert(
                "Das hat nicht geklappt",
                isPresented: Binding(presence: $failure),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure)
            }
        }
    }

    private var footer: String {
        guard let standing else { return "" }
        if !standing.isOwn {
            return """
            Wer einen Haushalt verlässt, sieht ihn auf seinen Geräten nicht \
            mehr. Für alle anderen bleibt er, wie er ist.
            """
        }
        return """
        Leeren löscht Rezepte samt Bildern, den Papierkorb, den Essensplan, \
        die Einkaufsliste und die lokalen Angaben zu Zutaten, der Haushalt selbst bleibt. \
        Löschen nimmt auch den Haushalt mit. Beides gilt für dieses Gerät und \
        iCloud, also auch für deine anderen Geräte — und für alle, mit denen \
        du den Haushalt teilst.
        """
    }

    private var deleteTitle: String {
        guard let standing else { return "" }
        return standing.isOwn
            ? "„\(standing.name)“ wirklich löschen?"
            : "„\(standing.name)“ wirklich verlassen?"
    }

    private var deleteMessage: String {
        guard let standing else { return "" }
        guard standing.isOwn else {
            return """
            Der Haushalt verschwindet von deinen Geräten. Die anderen behalten \
            ihn; zurück kommst du nur mit einer neuen Einladung.
            """
        }
        var parts = [
            "Der Haushalt wird mit allem, was darin ist, gelöscht — hier und in iCloud."
        ]
        if standing.otherParticipants > 0 {
            parts.append(standing.otherParticipants == 1
                ? "Auch die Person, mit der du ihn teilst, verliert ihn."
                : "Auch die \(standing.otherParticipants) Personen, mit denen du ihn teilst, verlieren ihn.")
        }
        if (switcher?.ownChoices.count ?? 0) <= 1 {
            parts.append("Danach beginnt ein leerer „\(CoreDataHouseholds.defaultName)“.")
        }
        parts.append("Das lässt sich nicht rückgängig machen.")
        return parts.joined(separator: " ")
    }

    private func empty(with wipe: LibraryWipe) async {
        progress = (0, 0)
        await wipe.empty { done, total in
            progress = (done, total)
        }
        progress = nil
    }

    private func stopSharing() async {
        guard let id = switcher?.activeID, let households else { return }
        do {
            try await households.stopSharing(id)
            standing = await households.standing(of: id)
            await onChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Stays on the page afterwards: it now shows the household the switch
    /// fell back to, which is the one thing worth seeing next.
    private func deleteOrLeave(with wipe: LibraryWipe) async {
        do {
            try await wipe.deleteOrLeave()
            await onChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// "166 Rezepte, 12 geplante Mahlzeiten …" — and the one sentence that
    /// matters, which is that none of it comes back.
    private static func message(for counts: LibraryWipe.Counts, sharedWith others: Int) -> String {
        var parts: [String] = []
        if counts.recipes > 0 {
            parts.append(counts.recipes == 1 ? "1 Rezept" : "\(counts.recipes) Rezepte")
        }
        if counts.meals > 0 {
            parts.append(counts.meals == 1 ? "1 geplante Mahlzeit" : "\(counts.meals) geplante Mahlzeiten")
        }
        if counts.shopping > 0 {
            parts.append(counts.shopping == 1 ? "1 Zeile der Einkaufsliste" : "\(counts.shopping) Zeilen der Einkaufsliste")
        }
        if counts.ingredients > 0 {
            parts.append(counts.ingredients == 1 ? "1 Angabe zu einer Zutat" : "\(counts.ingredients) Angaben zu Zutaten")
        }
        guard !parts.isEmpty else {
            return "Es ist nichts da, was gelöscht werden könnte."
        }
        let shared = others == 0 ? "" : " Auch für alle, mit denen du den Haushalt teilst."
        return parts.joined(separator: ", ")
            + " werden gelöscht — hier und in iCloud." + shared
            + " Das lässt sich nicht rückgängig machen."
    }
}

/// The count of an erase in progress, over a scrim that keeps the form
/// from being used while its data is going.
struct EraseProgressOverlay: View {
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Color.sousScrim.ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 200)
                Text("\(done) von \(total) Rezepten")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: SousStyle.cardRadius))
        }
    }
}
