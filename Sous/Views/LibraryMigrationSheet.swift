import SousKit
import SwiftUI

/// "Bibliothek umstellen": the preview of the one-time move into the fixed
/// form, and the button that does it.
///
/// It rewrites recipe text, and recipe text syncs to every member of the
/// household — so it only ever runs from here, on the cook's word, after the
/// numbers have been shown. The preview writes nothing, and a second run
/// finds nothing left to do.
struct LibraryMigrationSheet: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var preview: LibraryMigration.Summary?
    @State private var done: LibraryMigration.Summary?
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            Form {
                if let done {
                    doneSection(done)
                } else if let preview {
                    previewSections(preview)
                } else {
                    Section {
                        ProgressView("Rezepte werden gelesen …")
                    }
                }
            }
            .navigationTitle("Bibliothek umstellen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                if done == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Umstellen", action: run)
                            .disabled(isRunning || (preview?.recipesChanged ?? 0) == 0)
                    }
                }
            }
            .task { preview = await library.libraryMigrationPreview() }
        }
        .interactiveDismissDisabled(isRunning)
        .sousSheetSizing(.page)
    }

    @ViewBuilder
    private func previewSections(_ summary: LibraryMigration.Summary) -> some View {
        Section {
            Text("Sous liest jede Zutatenzeile in einer festen Form: Menge, Einheit, Zutat und nach einem Komma eine Anmerkung. Jede Zeile, die Sous heute versteht, wird einmal in diese Form geschrieben. Der Rest bleibt, wie er ist, und wartet auf „Für Sous optimieren“.")
            Text("Das Original jedes Rezepts bleibt erhalten („Reduziert“). Die Änderung gilt für alle im Haushalt.")
                .foregroundStyle(.secondary)
        }
        Section {
            if summary.recipesChanged == 0 {
                Label("Alles ist schon in der festen Form.", systemImage: "checkmark.circle")
            } else {
                LabeledContent("Rezepte, die sich ändern", value: "\(summary.recipesChanged) von \(summary.recipes)")
                LabeledContent("Zeilen umgeschrieben", value: "\(summary.rewritten)")
            }
            LabeledContent("Zeilen mit Anmerkung", value: "\(summary.annotated)")
            LabeledContent("Zeilen zum Optimieren", value: "\(summary.outsideForm.count)")
        } header: {
            Text("Vorschau")
        } footer: {
            Text("Eine Anmerkung wie „fein gehackt“ verschiebt die Optimierung später in einen Schritt. Eine Zeile zum Optimieren wird angezeigt, wie sie dasteht, skaliert mit und bekommt keine Nährwerte.")
        }
        outsideFormSection(summary)
    }

    @ViewBuilder
    private func doneSection(_ summary: LibraryMigration.Summary) -> some View {
        Section {
            Label(
                "\(summary.rewritten) Zeilen in \(summary.recipesChanged) Rezepten umgeschrieben",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.tint)
        }
        outsideFormSection(summary)
    }

    @ViewBuilder
    private func outsideFormSection(_ summary: LibraryMigration.Summary) -> some View {
        if !summary.outsideForm.isEmpty {
            Section("Zum Optimieren") {
                ForEach(Array(summary.outsideForm.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.line)
                        Text(line.recipeTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func run() {
        isRunning = true
        Task {
            done = await library.migrateLibrary()
            isRunning = false
        }
    }
}
