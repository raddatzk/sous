import SousKit
import SwiftUI

/// The settings' way into where the nutrition figures come from: one row
/// that says how many sources there are, and the page behind it that names
/// every one.
///
/// One row rather than a section per source, because the register is the
/// catalog's to grow — a body that publishes values the BLS lacks is one more
/// entry in `Data/sources.yaml`, and the settings must not grow with it. On iOS
/// it pushes the page inside the settings; the Mac's settings window has no
/// navigation of its own, so there it is a sheet — the way
/// `HouseholdSettingsRow` does it.
struct DataSourcesSettingsRow: View {
    /// The data set the app runs on speaking for itself: the active set's,
    /// not the bundle's — a set fetched since names its own sources.
    /// Reachable without any environment, which the Mac's `Settings` scene
    /// does not inject.
    private let sources = DataSources.current

    #if os(macOS)
    @State private var isShowingPage = false
    #endif

    var body: some View {
        Section {
            #if os(macOS)
            Button { isShowingPage = true } label: { label }
                .sheet(isPresented: $isShowingPage) {
                    NavigationStack {
                        DataSourcesPage(sources: sources)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(role: .close) { isShowingPage = false }
                                }
                            }
                    }
                    .sousSheetSizing(.page)
                }
            #else
            NavigationLink { DataSourcesPage(sources: sources) } label: { label }
            #endif
        } footer: {
            Text("Quelle, Version und Lizenz der Datenbanken, aus denen die Nährwerte stammen.")
        }
    }

    private var label: some View {
        LabeledContent {
            Text(sources.count == 1 ? "1 Quelle" : "\(sources.count) Quellen")
        } label: {
            Label("Datenquellen", systemImage: "books.vertical")
        }
    }
}

/// Every source of the active data set, each as it asks to be named, the BLS
/// first.
///
/// What CC BY 4.0 asks for is the central half of an attribution: naming the
/// source, saying that the data was changed, and linking the licence. The
/// local half is the „Quelle: …“ line under each ingredient's nutrition.
/// Every source is the same record and is shown the same way — the BLS
/// no differently from any other — and a source is its own section because
/// the attribution it carries is its institute's: naming one inside a block
/// headed by another's would credit the wrong body.
///
/// Every word of it comes out of `sources.json`, which is compiled with the
/// data it describes (`Data/sources.yaml`), not hardcoded here: a hardcoded
/// notice once went false, claiming the values were "zusammengefasst und
/// gemittelt" after the data had stopped averaging. A licence notice that
/// describes changes the data no longer carries is not a detail; CC BY 4.0
/// asks for it to be accurate.
struct DataSourcesPage: View {
    let sources: [DataSource]
    /// When this device first ran against the shipped data — the trace
    /// concept §7 asks the sources screen to leave. About the data set as a
    /// whole, so it stands with the first source, the one that is most of it.
    private let lastSeen = BundledDataMarker().lastSeen

    var body: some View {
        Form {
            ForEach(sources) { source in
                section(for: source, isFirst: source.id == sources.first?.id)
            }
            Section {
                Text("Eigene Angaben, die du zu einer Zutat einträgst, sind bei der Zutat als solche gekennzeichnet. Welche Zeile woher stammt, steht bei jeder Zutat unter „Quelle“.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Datenquellen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func section(for source: DataSource, isFirst: Bool) -> some View {
        Section {
            Text(source.attribution)
            detail("Herausgeber", source.publisher)
            detail("Datenstand", "\(source.version), Stand \(source.release)")
            if let retrieved = source.retrieved {
                detail("Abgerufen", retrieved)
            }
            if isFirst, let lastSeen {
                LabeledContent("Zuletzt aktualisiert") {
                    Text(lastSeen.seenAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
            Text(source.changeNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let url = source.url {
                Link("Zur Quelle", destination: url)
            }
            Link("Lizenz: \(source.license)", destination: source.licenseURL)
        } header: {
            Text(source.title)
        }
    }

    /// A label over its value rather than beside it: the publishers' names
    /// and versions run to several lines, and a trailing column wraps them
    /// into a ragged strip.
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
