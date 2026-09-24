import SousKit
import SwiftUI

/// What the app looks like, and the one place it is allowed to look different.
struct SettingsForm: View {
    @AppStorage(SousSetting.appearance, store: .sous)
    private var appearance: SousAppearance = .system
    @Environment(\.households) private var households
    @Environment(\.calendarMirror) private var calendarMirror

    /// The shipped table speaking for itself. Reachable without any
    /// environment — which this form does not get on the Mac, where it is the
    /// `Settings` scene's root and nothing injects anything into it.
    private let source = BLSCatalog.bundled.source
    /// The supplements file, where the app ships one — the second source the
    /// section below was written to expect.
    private let supplements = BLSCatalog.bundled.supplementSource
    /// When this device first ran against that data — the trace concept §7
    /// asks the sources screen to leave.
    private let lastSeen = BundledDataMarker().lastSeen
    /// Recipes erased so far, while "Alles löschen" runs. Held here rather
    /// than in its section: an overlay on a section is laid on each of its
    /// rows, header and footer included, and the count showed up twice.
    @State private var eraseProgress: (done: Int, total: Int)?

    var body: some View {
        Form {
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

            if let households {
                HouseholdSharingSection(households: households)
            }

            if let calendarMirror {
                CalendarMirrorSection(mirror: calendarMirror)
            }

            Section {
                StepReferencesChatPicker()
            } header: {
                Text("Zutaten pro Schritt")
            } footer: {
                Text("""
                Welche Zutaten jeder Schritt braucht, fragst du in einem Chat, \
                den du schon nutzt. Sous öffnet ihn neben dem kopierten Prompt. \
                „Keine KI verwenden“ blendet das Fragen ganz aus — zuordnen \
                lässt es sich dann weiter von Hand.
                """)
            }

            dataSources
            HouseholdDataSection(progress: $eraseProgress)
        }
        .formStyle(.grouped)
        .overlay {
            if let eraseProgress {
                EraseProgressOverlay(done: eraseProgress.done, total: eraseProgress.total)
            }
        }
    }

    /// Where the nutrition figures come from, what was done to them, and
    /// which release the app is currently reading.
    ///
    /// The central half of the attribution CC BY 4.0 asks for: naming the
    /// source, saying that the data was changed, and linking the licence.
    /// The local half is the „Quelle: …“ line under each ingredient's
    /// nutrition, which is what makes this section legible once a second
    /// source joins BLS.
    ///
    /// Every word of it now comes out of `bls.json`, which is the file that
    /// changes when the data changes. It used to be hardcoded here — and had
    /// gone false: it claimed the values were "zusammengefasst und
    /// gemittelt", which is exactly the averaging decision O2 abolished in
    /// phase 3. A licence notice that describes changes the data no longer
    /// carries is not a detail; CC BY 4.0 asks for it to be accurate.
    @ViewBuilder
    private var dataSources: some View {
        Section {
            Text(source.attribution)
            LabeledContent("Datenstand") {
                Text("\(source.datasetVersion), Stand \(source.release)")
            }
            if let lastSeen {
                LabeledContent("Zuletzt aktualisiert") {
                    Text(lastSeen.seenAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
            Text(source.changeNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Eigene Angaben, die du zu einer Zutat einträgst, sind bei der Zutat als solche gekennzeichnet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(
                "Lizenz \(source.license)",
                destination: URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!
            )
        } header: {
            Text("Datenquellen")
        }

        if let supplements {
            supplementSources(supplements)
        }
    }

    /// The foods the BLS does not list, and who measured them instead.
    ///
    /// Its own section rather than a line in the one above, because the
    /// attribution it carries is somebody else's: CC BY asks for the source
    /// to be named, and naming it inside a block headed by the BLS's own
    /// attribution would credit the wrong institute. The per-row half of the
    /// same duty is the „Quelle: …“ line under each ingredient.
    @ViewBuilder
    private func supplementSources(_ supplements: BLSCatalog.Source) -> some View {
        Section {
            Text(supplements.attribution)
            LabeledContent("Datenstand") {
                Text("\(supplements.datasetVersion), Stand \(supplements.release)")
            }
            Text(supplements.changeNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(
                "Lizenz \(supplements.license)",
                destination: URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!
            )
        } header: {
            Text("Ergänzungen")
        }
    }
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

/// The meal plan in the Apple calendar — a projection the cook opts into.
private struct CalendarMirrorSection: View {
    let mirror: CalendarMirror

    @State private var isOn = false
    @State private var wasDeclined = false

    var body: some View {
        Section {
            Toggle("Essensplan im Kalender", systemImage: "calendar", isOn: $isOn)
                .onChange(of: isOn) { _, wanted in
                    Task { await apply(wanted) }
                }
            if wasDeclined {
                Text("""
                Sous darf nicht auf den Kalender zugreifen. Erlaube den \
                Zugriff in den Systemeinstellungen unter Datenschutz.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Kalender")
        } footer: {
            Text("""
            Geplante Rezepte erscheinen als Termine in einem eigenen Kalender \
            „Sous“ — den du wie jeden Kalender teilen kannst, auch mit Leuten \
            ohne die App. Der Plan bleibt die Wahrheit: Änderungen am Termin \
            wandern nicht zurück.
            """)
        }
        .task { isOn = mirror.isEnabled }
    }

    private func apply(_ wanted: Bool) async {
        guard wanted != mirror.isEnabled else { return }
        if wanted {
            let granted = await mirror.enable()
            if !granted {
                // The system prompt was declined; the toggle falls back and
                // says why rather than pretending.
                isOn = false
                wasDeclined = true
            }
        } else {
            await mirror.disable()
        }
    }
}

/// The irreversible things, for the household that is showing: emptying it,
/// deleting it — or, for one somebody else owns, leaving it.
///
/// At the very bottom, under the dry data sources, because that is where a
/// destructive action belongs: found when looked for, not met on the way to
/// something else. Every button names the household, and every question
/// names what would go, in numbers — "alles" is a word, 166 Rezepte is a
/// fact.
private struct HouseholdDataSection: View {
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
    @Environment(\.dismiss) private var dismiss

    /// The household showing, as far as leaving or deleting it goes.
    @State private var standing: HouseholdStanding?
    /// Set once the counting is done and the emptying question can be asked.
    @State private var emptyQuestion: LibraryWipe.Counts?
    @State private var isAskingToDelete = false
    @State private var failure: String?
    /// Recipes erased so far, while it runs — shown by the form, over all of it.
    @Binding var progress: (done: Int, total: Int)?

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
            .task(id: switcher?.activeID) {
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
        die Einkaufsliste und die eigenen Zutaten, der Haushalt selbst bleibt. \
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
        // Onto the empty library: the settings have nothing left to say
        // about a household that no longer holds anything.
        dismiss()
    }

    /// Stays in the settings afterwards: they now show the household the
    /// switch fell back to, which is the one thing worth seeing next.
    private func deleteOrLeave(with wipe: LibraryWipe) async {
        do {
            try await wipe.deleteOrLeave()
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
            parts.append(counts.ingredients == 1 ? "1 eigene Zutat" : "\(counts.ingredients) eigene Zutaten")
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
private struct EraseProgressOverlay: View {
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
