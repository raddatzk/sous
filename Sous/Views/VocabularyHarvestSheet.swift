import SousKit
import SwiftUI

/// "Vokabular exportieren": what this household's vocabulary taught the app
/// that the catalog could use, as a YAML file for a `Data/` pull request
/// (INGREDIENTS-DATA §6). Writes nothing back; the in-app curation it
/// rescues retires in phase 6b.
struct VocabularyHarvestSheet: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var file: URL?
    @State private var proposals: [VocabularyHarvest.Proposal] = []
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if proposals.isEmpty {
                        Text("Das Vokabular enthält nichts, was der Katalog nicht schon weiß.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(proposals, id: \.self) { proposal in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proposal.name)
                                Text(summary(of: proposal))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(proposals.count) Vorschläge für den Katalog")
                } footer: {
                    Text("Aliasse, Sorten, eigene Zutaten, abweichende BLS-Zeilen, eigene Werte und Gewichte. Vorrat, Supermarkt und Notiz bleiben im Haushalt.")
                }
                if let file {
                    Section {
                        ShareLink("Datei teilen", item: file)
                    }
                }
                if let failure {
                    Label(failure, systemImage: "xmark.octagon")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Vokabular exportieren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .sousSheetSizing(.form)
        .task { await prepare() }
    }

    private func summary(of proposal: VocabularyHarvest.Proposal) -> String {
        var parts: [String] = [proposal.catalogID == nil ? "neu" : "im Katalog"]
        if !proposal.aliases.isEmpty { parts.append("Aliasse: " + proposal.aliases.joined(separator: ", ")) }
        if let parent = proposal.parent { parts.append("Sorte von \(parent)") }
        if let category = proposal.category { parts.append(category.title) }
        if !proposal.codes.isEmpty { parts.append("BLS " + proposal.codes.values.sorted().joined(separator: ", ")) }
        if !proposal.values.isEmpty { parts.append("eigene Werte") }
        if !proposal.weights.isEmpty {
            parts.append(proposal.weights.keys.sorted().map { "1 \($0) = \(Int((proposal.weights[$0] ?? 0).rounded())) g" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func prepare() async {
        await catalog.ensureLoaded()
        proposals = VocabularyHarvest.proposals(from: catalog.entries)
        let household = ActiveHousehold.id.map { String($0.uuidString.prefix(8)) } ?? "ohne Haushalt"
        let text = VocabularyHarvest.yaml(proposals, household: household)
        let day = Date.now.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sous-vokabular-\(day).yaml")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            file = url
        } catch {
            failure = error.localizedDescription
        }
    }
}
