import SousKit
import SwiftUI
import UniformTypeIdentifiers

/// A finished export on its way to the file picker.
///
/// The bytes are made before the picker opens rather than while it is up: a
/// library with its photos takes seconds to assemble, and a save panel that
/// waits on that looks broken.
struct RecipeExport: FileDocument, Identifiable {
    static let recipe = UTType(filenameExtension: "sousrecipe") ?? .data
    static let library = UTType(filenameExtension: "sousrecipes") ?? .data

    static var readableContentTypes: [UTType] { [library, recipe] }

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

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.preferredFilename ?? "Rezepte"
        contentType = Self.library
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension View {
    /// Presents the save panel once an export has been assembled.
    func recipeExporter(_ export: Binding<RecipeExport?>) -> some View {
        modifier(RecipeExporter(export: export))
    }
}

private struct RecipeExporter: ViewModifier {
    @Binding var export: RecipeExport?
    @Environment(RecipeLibrary.self) private var library

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: Binding(
                    get: { export != nil },
                    set: { if !$0 { export = nil } }
                ),
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
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
    }
}
