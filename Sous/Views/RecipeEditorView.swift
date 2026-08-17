import PhotosUI
import SousKit
import SwiftUI

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipeLibrary.self) private var library

    @State private var draft: Recipe
    @State private var categoriesText: String
    @State private var isSaving = false
    @State private var linkTarget: LinkTarget?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// Pictures stored during this edit, so cancelling does not leave them
    /// behind with nothing referencing them.
    @State private var addedImageIDs: [UUID] = []

    /// Which field a picked recipe link should be appended to.
    private enum LinkTarget: String, Identifiable {
        case ingredients
        case instructions
        var id: String { rawValue }
    }

    private let onSave: (Recipe) async -> Void

    init(recipe: Recipe, onSave: @escaping (Recipe) async -> Void) {
        _draft = State(initialValue: recipe)
        _categoriesText = State(initialValue: recipe.categories.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                basics
                imageSection

                Section {
                    TextEditor(text: $draft.ingredientsText)
                        .frame(minHeight: 180)
                    Button("Rezept verlinken", systemImage: "link") {
                        linkTarget = .ingredients
                    }
                } header: {
                    Text("Zutaten")
                } footer: {
                    Text("Eine Zutat pro Zeile, etwa „300 g Zucchini (fein gehackt)“. „# Für den Teig“ beginnt einen Abschnitt.")
                }

                Section {
                    TextEditor(text: $draft.instructionsText)
                        .frame(minHeight: 220)
                    Button("Rezept verlinken", systemImage: "link") {
                        linkTarget = .instructions
                    }
                } header: {
                    Text("Zubereitung")
                } footer: {
                    Text("Ein Schritt pro Zeile, Nummerierung übernimmt die App. **Fett**, *kursiv* und ***beides*** sind erlaubt. „# Überschrift“ beginnt einen Abschnitt und zählt neu.")
                }

                Section("Notizen") {
                    TextField("Notizen", text: optional(\.notes), axis: .vertical)
                        .lineLimit(3...)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.title.isEmpty ? "Neues Rezept" : draft.title)
            .toolbar { editorToolbar }
            .sheet(item: $linkTarget) { target in
                RecipePickerView(excluding: draft.id) { picked in
                    append(link: picked, to: target)
                }
            }
        }
        // A minimum size is right for a macOS sheet and wrong on a phone,
        // where it pushes the content wider than the screen.
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    @ViewBuilder
    private var basics: some View {
        Section {
            TextField("Titel", text: $draft.title)
            TextField("Kurzbeschreibung", text: optional(\.summary), axis: .vertical)
                .lineLimit(1...3)
            Stepper("Portionen: \(draft.servings)", value: $draft.servings, in: 1...50)
            LabeledContent("Vorbereitung") {
                MinutesField(seconds: $draft.prepTimeSeconds)
            }
            LabeledContent("Kochzeit") {
                MinutesField(seconds: $draft.cookTimeSeconds)
            }
            TextField("Kategorien, mit Komma getrennt", text: $categoriesText)
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        Section("Bilder") {
            if !draft.imageIDs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(draft.imageIDs, id: \.self) { imageID in
                            RecipeImageView(imageID: imageID, thumbnail: true)
                                .frame(width: 84, height: 84)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button("Entfernen", systemImage: "xmark.circle.fill") {
                                        remove(imageID)
                                    }
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .padding(4)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }

            PhotosPicker(selection: $pickedPhotos, matching: .images) {
                Label("Bild hinzufügen", systemImage: "photo.badge.plus")
            }
        }
        .onChange(of: pickedPhotos) { _, items in
            Task { await store(items) }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Abbrechen") { cancel() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Sichern") { save() }
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
        }
    }

    /// Reads picked photos into storage and references them on the draft.
    private func store(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let id = await library.addImage(data, to: draft.id)
            else { continue }
            draft.imageIDs.append(id)
            addedImageIDs.append(id)
        }
        pickedPhotos = []
    }

    private func remove(_ imageID: UUID) {
        draft.imageIDs.removeAll { $0 == imageID }
        if let index = addedImageIDs.firstIndex(of: imageID) {
            addedImageIDs.remove(at: index)
            // Never referenced by a saved recipe, so it can go straight away.
            Task { await library.deleteImage(id: imageID) }
        }
    }

    private func cancel() {
        let orphans = addedImageIDs
        Task {
            for id in orphans {
                await library.deleteImage(id: id)
            }
        }
        dismiss()
    }

    private func save() {
        isSaving = true
        var recipe = draft
        recipe.title = recipe.title.trimmingCharacters(in: .whitespaces)
        recipe.categories = categoriesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        Task {
            await onSave(recipe)
            dismiss()
        }
    }

    /// Appends the link on its own line. Inserting at the cursor would be
    /// nicer, but a `TextEditor` does not hand out its selection, and a link
    /// on the last line is easy to move.
    private func append(link recipe: Recipe, to target: LinkTarget) {
        let markdown = RecipeLink.markdown(title: recipe.title, id: recipe.id)
        switch target {
        case .ingredients:
            draft.ingredientsText = appending(markdown, to: draft.ingredientsText)
        case .instructions:
            draft.instructionsText = appending(markdown, to: draft.instructionsText)
        }
    }

    private func appending(_ line: String, to text: String) -> String {
        text.isEmpty ? line : text + (text.hasSuffix("\n") ? "" : "\n") + line
    }

    /// Bridges an optional string property to a `TextField`, treating empty
    /// input as absent.
    private func optional(_ keyPath: WritableKeyPath<Recipe, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

/// A minutes field over a seconds-based property.
private struct MinutesField: View {
    @Binding var seconds: Int?

    var body: some View {
        HStack(spacing: 4) {
            TextField("–", text: minutes)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            Text("Min.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var minutes: Binding<String> {
        Binding(
            get: { seconds.map { String($0 / 60) } ?? "" },
            set: { seconds = Int($0).map { $0 * 60 } }
        )
    }
}
