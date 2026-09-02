import SousKit
import SwiftUI
import UniformTypeIdentifiers

/// Reading an exported recipe file into the library.
///
/// The picker, the progress while it runs and the report of what came
/// through are one flow, so they live in one modifier that any screen can
/// attach — today the recipe list, tomorrow an empty-library screen offering
/// the import as a first step.
struct RecipeImporter: ViewModifier {
    @Binding var isPresented: Bool

    @Environment(RecipeLibrary.self) private var library
    @State private var summary: RecipeImportSummary?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: Self.readableTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await load(urls) }
                case .failure(let error):
                    library.errorMessage = error.localizedDescription
                }
            }
            .overlay { progressOverlay }
            .alert(
                "Import abgeschlossen",
                isPresented: Binding(presence: $summary),
                presenting: summary
            ) { _ in
                Button("OK", role: .cancel) { summary = nil }
            } message: { summary in
                Text(report(for: summary))
            }
    }

    /// Sous's extensions and Mela's, plus anything at all — a Mac that has
    /// seen neither app does not know those types, and a picker that greys
    /// out the file the user came to import is worse than one that shows too
    /// much.
    private static var readableTypes: [UTType] {
        ["sousrecipes", "sousrecipe", "melarecipes", "melarecipe"]
            .compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private func load(_ urls: [URL]) async {
        var imported = 0
        var problems: [RecipeImportProblem] = []

        for url in urls {
            // A file picked outside the sandbox is only readable while its
            // security scope is held.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                problems.append(
                    RecipeImportProblem(name: name, reason: "Die Datei ließ sich nicht öffnen.")
                )
                continue
            }
            let result = await library.importRecipes(from: data, named: name)
            imported += result.imported
            problems.append(contentsOf: result.problems)
        }
        summary = RecipeImportSummary(imported: imported, problems: problems)
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = library.importProgress {
            ZStack {
                Color.sousScrim.ignoresSafeArea()
                VStack(spacing: 10) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 200)
                        Text("\(progress.done) von \(progress.total) Rezepten")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        ProgressView()
                        Text("Datei wird gelesen …")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: .rect(cornerRadius: SousStyle.cardRadius))
            }
            .transition(.opacity)
        }
    }

    /// What happened, in one paragraph: how much arrived, and what did not.
    private func report(for summary: RecipeImportSummary) -> String {
        var lines: [String] = []
        switch summary.imported {
        case 0: lines.append("Es wurde kein Rezept importiert.")
        case 1: lines.append("1 Rezept importiert.")
        default: lines.append("\(summary.imported) Rezepte importiert.")
        }

        if !summary.problems.isEmpty {
            let count = summary.problems.count
            lines.append(count == 1 ? "1 Eintrag übersprungen:" : "\(count) Einträge übersprungen:")
            // Only the first few by name; a broken export could list hundreds.
            lines.append(
                summary.problems.prefix(3)
                    .map { "· \($0.name): \($0.reason)" }
                    .joined(separator: "\n")
            )
            if count > 3 {
                lines.append("… und \(count - 3) weitere.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension View {
    /// Attaches the file picker that reads recipes into the library.
    func recipeImporter(isPresented: Binding<Bool>) -> some View {
        modifier(RecipeImporter(isPresented: isPresented))
    }
}
