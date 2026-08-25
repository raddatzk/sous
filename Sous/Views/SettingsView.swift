import SwiftUI

/// What the app looks like, and the one place it is allowed to look different.
struct SettingsForm: View {
    @AppStorage(SousSetting.appearance, store: .sous)
    private var appearance: SousAppearance = .system

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

            dataSources
        }
        .formStyle(.grouped)
    }

    /// Where the nutrition figures come from, and what was done to them.
    ///
    /// The central half of the attribution CC BY 4.0 asks for: naming the
    /// source, saying that the data was changed, and linking the licence.
    /// The local half is the „Quelle: …“ line under each ingredient's
    /// nutrition, which is what makes this section legible once a second
    /// source joins BLS.
    private var dataSources: some View {
        Section {
            Text("Die Nährwerte stammen aus dem Bundeslebensmittelschlüssel (BLS) 4.0 des Max-Rubner-Instituts.")
            Text("Die Daten wurden für diese App verändert: gefiltert, nach Zustand (roh/gegart) zusammengefasst und gemittelt. Eigene Angaben, die du zu einer Zutat einträgst, sind bei der Zutat als solche gekennzeichnet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Lizenz CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)
        } header: {
            Text("Datenquellen")
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
