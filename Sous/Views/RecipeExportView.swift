import SousKit
import SwiftUI
import UniformTypeIdentifiers

/// A finished export on its way out of the app — the share sheet on the
/// iPhone and iPad, the save panel on the Mac.
///
/// The bytes are made before either opens rather than while it is up: a
/// library with its photos takes seconds to assemble, and a sheet that
/// waits on that looks broken.
struct RecipeExport: FileDocument, Identifiable {
    static let recipe = UTType(filenameExtension: "sousrecipe") ?? .data
    static let library = UTType(filenameExtension: "sousrecipes") ?? .data

    static let markdown = UTType("net.daringfireball.markdown") ?? .plainText

    static var readableContentTypes: [UTType] { [library, recipe] }
    static var writableContentTypes: [UTType] { [library, recipe, markdown, .pdf] }

    let id = UUID()
    var data: Data
    /// File name without its extension, which the picker adds.
    var name: String
    var contentType: UTType

    init(data: Data, name: String, contentType: UTType) {
        self.data = data
        self.name = name
        self.contentType = contentType
    }

    /// One recipe, as a file named after it.
    init(recipe: Recipe, data: Data) {
        self.init(data: data, name: recipe.title, contentType: Self.recipe)
    }

    /// One recipe as a Markdown file, at the serving count on screen.
    init(markdown document: RecipeDocument) {
        self.init(
            data: Data(RecipeMarkdown.string(for: document).utf8),
            name: document.fileName,
            contentType: Self.markdown
        )
    }

    /// One recipe as its printed page.
    init(pdf data: Data, of document: RecipeDocument) {
        self.init(data: data, name: document.fileName, contentType: .pdf)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.preferredFilename ?? "Rezepte"
        contentType = Self.library
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// The bytes as a named file in a folder of their own, for the share
    /// sheet: it hands on a file, and Mail, AirDrop and "In Dateien sichern"
    /// all take its name from the URL.
    ///
    /// The save panel cleans the name itself; a file written here does not
    /// get that, and a recipe title may well hold a slash.
    func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Export-\(id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var file = folder.appending(path: cleaned.isEmpty ? "Rezept" : String(cleaned.prefix(80)))
        if let pathExtension = contentType.preferredFilenameExtension {
            file.appendPathExtension(pathExtension)
        }
        try data.write(to: file, options: .atomic)
        return file
    }
}

extension View {
    /// Hands an export on once it has been assembled: to the share sheet
    /// where there is one, to the save panel on the Mac.
    func recipeExporter(_ export: Binding<RecipeExport?>) -> some View {
        modifier(RecipeExporter(export: export))
    }
}

private struct RecipeExporter: ViewModifier {
    @Binding var export: RecipeExport?
    @Environment(RecipeLibrary.self) private var library

    func body(content: Content) -> some View {
        #if os(iOS)
        // The share sheet rather than the save panel: sending a recipe to
        // someone is the common case, and "In Dateien sichern" is one of its
        // rows, so nothing the panel offered is lost.
        content
            .background {
                SharePresenter(export: $export) { error in
                    library.errorMessage = error.localizedDescription
                }
            }
            .overlay { progressOverlay }
        #else
        content
            .fileExporter(
                isPresented: Binding(presence: $export),
                document: export,
                contentType: export?.contentType ?? RecipeExport.library,
                defaultFilename: export?.name
            ) { result in
                export = nil
                if case .failure(let error) = result {
                    library.errorMessage = error.localizedDescription
                }
            }
            .overlay { progressOverlay }
        #endif
    }

    /// The same kind of wait as an import, and it says which one it is.
    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = library.exportProgress {
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
                        Text("Rezepte werden gesammelt …")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: .rect(cornerRadius: SousStyle.cardRadius))
            }
        }
    }
}

#if os(iOS)
/// Puts the share sheet up over whatever screen asked for it.
///
/// SwiftUI has only `ShareLink`, which wants its item before it is tapped;
/// an export is assembled after the tap, behind a progress overlay. So the
/// sheet is presented from a controller of its own, sitting invisibly
/// behind the screen — presenting from inside the hierarchy lands it above
/// a recipe page that is itself a sheet.
private struct SharePresenter: UIViewControllerRepresentable {
    @Binding var export: RecipeExport?
    var onError: (Error) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let export, context.coordinator.shownID != export.id else { return }
        // Not while the previous sheet is still going away.
        guard controller.presentedViewController == nil else { return }
        let file: URL
        do {
            file = try export.temporaryFile()
        } catch {
            onError(error)
            self.export = nil
            return
        }
        context.coordinator.shownID = export.id

        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, error in
            if let error { onError(error) }
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            context.coordinator.shownID = nil
            self.export = nil
        }
        // The iPad shows it as a popover and needs somewhere to point. The
        // export menus sit in the toolbar's trailing corner.
        if let popover = sheet.popoverPresentationController {
            let bounds = controller.view.bounds
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: bounds.maxX - 44, y: bounds.minY, width: 1, height: 1)
            popover.permittedArrowDirections = .up
        }
        controller.present(sheet, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// The export whose sheet is up, so a redraw does not put it up twice.
        var shownID: UUID?
    }
}
#endif
