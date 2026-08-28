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

            dataSources
        }
        .formStyle(.grouped)
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
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
        // The screen that changes the setting is the one screen that has to
        // react to it: a sheet takes the window's scheme when it opens and
        // then keeps it.
        .sousAppearance()
        .sousSheetSizing(.form)
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
