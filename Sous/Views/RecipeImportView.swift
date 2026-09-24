import SousKit
import SwiftUI
import UniformTypeIdentifiers

/// Reading an exported recipe file into the library.
///
/// The picker, the progress while it runs and the report of what came
/// through are one flow, so they live in one modifier that any screen can
/// attach — today the recipe list, tomorrow an empty-library screen offering
/// the import as a first step.
///
/// Nothing is stored on the spot, whether the file was picked here or opened
/// with Sous from outside (through `LibraryCommands.openedFiles`): it is
/// read, measured against the library (`RecipeImportOffer`), and a single
/// recipe already here is simply opened, while anything else is laid out in
/// `RecipeImportPreviewSheet` to choose from.
struct RecipeImporter: ViewModifier {
    @Binding var isPresented: Bool

    @Environment(RecipeLibrary.self) private var library
    @Environment(LibraryCommands.self) private var commands
    @Environment(RecipeSelection.self) private var selection
    @State private var summary: RecipeImportSummary?
    /// The recipes being looked through before import.
    @State private var preview: PendingPreview?
    /// Set while opened files are being read, so that more arriving in the
    /// meantime join the same preview instead of starting a second one.
    @State private var isReadingOpenedFiles = false

    /// A sheet needs an identity, and two previews of the same file are
    /// still two different sheets.
    private struct PendingPreview: Identifiable {
        let id = UUID()
        let preview: RecipeImportPreview
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: Self.readableTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await offer(await readFiles(urls)) }
                case .failure(let error):
                    library.errorMessage = error.localizedDescription
                }
            }
            // `initial`, because opening a file can be what mounts this
            // screen: on the phone the recipes tab is switched to first.
            .onChange(of: commands.openedFiles, initial: true) { takeOpenedFiles() }
            .onChange(of: commands.isLaunchSettled) { takeOpenedFiles() }
            .overlay { progressOverlay }
            .sheet(item: $preview, onDismiss: takeOpenedFiles) { pending in
                RecipeImportPreviewSheet(preview: pending.preview) { batch in
                    importChosen(batch)
                }
            }
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

    /// Every extension an import format reads, plus anything at all — a file
    /// whose name lost its extension on the way is still worth a try, and a
    /// picker that greys out the file the user came to import is worse than
    /// one that shows too much.
    private static var readableTypes: [UTType] {
        RecipeImport.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    /// Reads whatever has been opened from outside, once the launch allows
    /// it and no preview is up, until nothing more is waiting — then offers
    /// all of it at once.
    private func takeOpenedFiles() {
        guard commands.isLaunchSettled, !isReadingOpenedFiles, preview == nil,
              !commands.openedFiles.isEmpty
        else { return }
        isReadingOpenedFiles = true
        Task {
            var batch = RecipeImportBatch()
            while !commands.openedFiles.isEmpty {
                let urls = commands.openedFiles
                commands.openedFiles = []
                let read = await readFiles(urls)
                batch.recipes += read.recipes
                batch.problems += read.problems
            }
            await offer(batch)
            isReadingOpenedFiles = false
        }
    }

    /// What happens to a file once it has been read: nothing to show, a
    /// recipe to open, or recipes to choose from.
    private func offer(_ batch: RecipeImportBatch) async {
        switch await library.offer(for: batch) {
        case .nothingReadable(let problems):
            summary = RecipeImportSummary(imported: 0, problems: problems)
        case .alreadyHere(let recipe):
            selection.show(recipe)
        case .preview(let offered):
            preview = PendingPreview(preview: offered)
        }
    }

    /// Stores what the cook chose. A single recipe is then opened rather
    /// than reported — the page is the proof it arrived, and the place the
    /// cook was heading anyway.
    private func importChosen(_ batch: RecipeImportBatch) {
        Task {
            let result = await library.importRecipes(batch)
            if batch.recipes.count == 1, result.imported == 1, result.problems.isEmpty,
               let recipe = await library.recipe(id: batch.recipes[0].recipe.id) {
                selection.show(recipe)
            } else {
                summary = result
            }
        }
    }

    /// Reads files without storing anything, one bundle for all of them.
    private func readFiles(_ urls: [URL]) async -> RecipeImportBatch {
        var batch = RecipeImportBatch()

        for url in urls {
            // A file picked or opened outside the sandbox is only readable
            // while its security scope is held.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                batch.problems.append(
                    RecipeImportProblem(name: name, reason: "Die Datei ließ sich nicht öffnen.")
                )
                continue
            }
            do {
                let read = try await library.readRecipes(from: data, named: name)
                batch.recipes += read.recipes
                batch.problems += read.problems
            } catch {
                batch.problems.append(
                    RecipeImportProblem(name: name, reason: error.localizedDescription)
                )
            }
        }
        return batch
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
