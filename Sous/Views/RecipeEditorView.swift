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
    /// Where the cursor sits in each editor, so a link lands where the writer
    /// is looking instead of at the very end.
    @State private var ingredientsSelection: TextSelection?
    @State private var instructionsSelection: TextSelection?
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
                imageStrip
                titleSection
                factsSection
                ingredientSection
                stepSection
                notesSection
            }
            .formStyle(.grouped)
            .navigationTitle(draft.title.isEmpty ? "Neues Rezept" : draft.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { editorToolbar }
            .sheet(item: $linkTarget) { target in
                RecipePickerView(excluding: draft.id) { picked in
                    insert(link: picked, at: target)
                }
            }
        }
        // A minimum size is right for a macOS sheet and wrong on a phone,
        // where it pushes the content wider than the screen.
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    /// Pictures come first, as a row of tiles with the picker as the last one
    /// — the same shape as what it adds, rather than a button in a list.
    @ViewBuilder
    private var imageStrip: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(draft.imageIDs, id: \.self) { imageID in
                        RecipeImageView(imageID: imageID, thumbnail: true)
                            .frame(width: 88, height: 88)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button("Entfernen", systemImage: "xmark.circle.fill") {
                                    remove(imageID)
                                }
                                .labelStyle(.iconOnly)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                                .padding(5)
                            }
                    }

                    PhotosPicker(selection: $pickedPhotos, matching: .images) {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(.tertiary)
                            .frame(width: 88, height: 88)
                            .overlay {
                                Image(systemName: "photo.badge.plus")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
        .listRowBackground(Color.clear)
        .onChange(of: pickedPhotos) { _, items in
            Task { await store(items) }
        }
    }

    /// The title is typed the way it will be read — large and in the serif —
    /// so the recipe looks like itself while it is being written.
    @ViewBuilder
    private var titleSection: some View {
        Section {
            TextField("Titel", text: $draft.title, axis: .vertical)
                .font(SousStyle.recipeTitle)
                .lineLimit(1...3)
            TextField("Kurzbeschreibung", text: optional(\.summary), axis: .vertical)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
        }
    }

    @ViewBuilder
    private var factsSection: some View {
        Section {
            Stepper(value: $draft.servings, in: 1...50) {
                Label("\(draft.servings) Portionen", systemImage: "person.2")
            }
            LabeledContent {
                MinutesField(seconds: $draft.prepTimeSeconds)
            } label: {
                Label("Vorbereitung", systemImage: "clock")
            }
            LabeledContent {
                MinutesField(seconds: $draft.cookTimeSeconds)
            } label: {
                Label("Zubereitung", systemImage: "flame")
            }
            LabeledContent {
                TextField("Nachtisch, Schnell", text: $categoriesText)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Kategorien", systemImage: "tag")
            }
        } header: {
            sectionHeader("Angaben")
        }
    }

    @ViewBuilder
    private var ingredientSection: some View {
        Section {
            TextEditor(text: $draft.ingredientsText, selection: $ingredientsSelection)
                .frame(minHeight: 180)
            Button("Rezept verlinken", systemImage: "link") {
                linkTarget = .ingredients
            }
        } header: {
            sectionHeader("Zutaten")
        } footer: {
            Text("Eine Zutat pro Zeile, etwa „300 g Zucchini (fein gehackt)“. „# Für den Teig“ beginnt einen Abschnitt.")
        }
    }

    @ViewBuilder
    private var stepSection: some View {
        Section {
            TextEditor(text: $draft.instructionsText, selection: $instructionsSelection)
                .frame(minHeight: 220)
            Button("Rezept verlinken", systemImage: "link") {
                linkTarget = .instructions
            }
        } header: {
            sectionHeader("Zubereitung")
        } footer: {
            Text("Ein Schritt pro Zeile, Nummerierung übernimmt die App. **Fett**, *kursiv* und ***beides*** sind erlaubt. „# Überschrift“ beginnt einen Abschnitt und zählt neu.")
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section {
            TextField("Notizen", text: optional(\.notes), axis: .vertical)
                .lineLimit(3...)
        } header: {
            sectionHeader("Notizen")
        }
    }

    /// Section headings share the serif with the rest of the app; `textCase`
    /// is cleared because a form would otherwise shout them in capitals.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(SousStyle.groupHeading)
            .foregroundStyle(.primary)
            .textCase(nil)
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

    /// Inserts the link where the cursor is, replacing whatever is selected.
    private func insert(link recipe: Recipe, at target: LinkTarget) {
        let markdown = RecipeLink.markdown(title: recipe.title, id: recipe.id)
        switch target {
        case .ingredients:
            insert(markdown, into: &draft.ingredientsText, at: &ingredientsSelection)
        case .instructions:
            insert(markdown, into: &draft.instructionsText, at: &instructionsSelection)
        }
    }

    private func insert(_ snippet: String, into text: inout String, at selection: inout TextSelection?) {
        guard case .selection(let range)? = selection?.indices else {
            // Nobody has put a cursor in the field yet, so the end is the only
            // sensible place — on its own line, since one line is one entry.
            text = text.isEmpty ? snippet : text + (text.hasSuffix("\n") ? "" : "\n") + snippet
            selection = nil
            return
        }

        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + snippet.count
        text.replaceSubrange(range, with: snippet)
        // Indices did not survive the edit; rebuild the cursor from the offset.
        let cursor = text.index(text.startIndex, offsetBy: min(offset, text.count))
        selection = TextSelection(insertionPoint: cursor)
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
