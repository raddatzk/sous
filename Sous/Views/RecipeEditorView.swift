import PhotosUI
import SousKit
import SwiftUI

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalog

    @State private var draft: Recipe
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
    /// An unknown ingredient the cook is about to teach the app.
    @State private var teaching: CatalogIngredient?
    @FocusState private var isEditingIngredients: Bool

    /// Which field a picked recipe link should be appended to.
    private enum LinkTarget: String, Identifiable {
        case ingredients
        case instructions
        var id: String { rawValue }
    }

    private let onSave: (Recipe) async -> Void

    init(recipe: Recipe, onSave: @escaping (Recipe) async -> Void) {
        _draft = State(initialValue: recipe)
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
            // Sits above the keyboard while an ingredient is being typed.
            .safeAreaInset(edge: .bottom) { completionBar }
            .sheet(item: $linkTarget) { target in
                RecipePickerView(excluding: draft.id) { picked in
                    insert(link: picked, at: target)
                }
            }
            .sheet(item: $teaching) { ingredient in
                IngredientFormView(ingredient: ingredient)
            }
            .task { await catalog.reload() }
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
            
            Stepper(value: $draft.servings, in: Recipe.servingsRange) {
                Label("\(draft.servings) Portionen", systemImage: "person.2")
            }
            // The label sits above rather than beside: chips wrap onto as
            // many lines as they need, which no trailing-aligned row can hold.
            VStack(alignment: .leading, spacing: 8) {
                Label("Kategorien", systemImage: "tag")
                    .font(.subheadline.weight(.medium))
                TextField(
                    "Nachtisch, Schnell",
                    text: categoriesBinding
                )
                .textFieldStyle(.plain)
                .sousFieldBox()
            }
            .padding(.vertical, 4)
        } header: {
            sectionHeader("Angaben")
        }

        timesSection
    }

    private var categoriesBinding: Binding<String> {
        Binding<String>(
            get: {
                draft.categories.joined(separator: ", ")
            },
            set: { newValue in
                let parts = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var seen = Set<String>()
                var result: [String] = []
                for p in parts {
                    let key = p.lowercased()
                    if !seen.contains(key) {
                        seen.insert(key)
                        result.append(p)
                    }
                }
                draft.categories = result
            }
        )
    }

    /// The three times, with the one sentence that keeps them apart.
    ///
    /// Their own section rather than three more rows under "Angaben": the
    /// difference between working time and waiting time needs explaining,
    /// and an explanation belongs where the numbers are typed.
    @ViewBuilder
    private var timesSection: some View {
        Section {
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
                MinutesField(seconds: $draft.totalTimeSeconds)
            } label: {
                Label("Gesamt", systemImage: "hourglass")
            }
        } header: {
            sectionHeader("Zeiten")
        } footer: {
            Text("Vorbereitung und Zubereitung sind die Zeit, in der du in der Küche stehst. Gesamt ist die Zeit bis zum Essen — mit allem Warten: Teig gehen lassen, marinieren, auskühlen. Was dazwischen liegt, zeigt das Rezept als Ruhezeit.")
        }
    }

    @ViewBuilder
    private var ingredientSection: some View {
        Section {
            TextEditor(text: $draft.ingredientsText, selection: $ingredientsSelection)
                .frame(minHeight: 180)
                .focused($isEditingIngredients)
            Button("Rezept verlinken", systemImage: "link") {
                linkTarget = .ingredients
            }
            unknownIngredients
        } header: {
            sectionHeader("Zutaten")
        } footer: {
            Text("Eine Zutat pro Zeile, etwa „300 g Zucchini (fein gehackt)“. „# Für den Teig“ beginnt einen Abschnitt.")
        }
    }

    /// Suggestions for the ingredient being typed, if any.
    ///
    /// SwiftUI's `textInputSuggestions` is macOS-only and `TextEditor` has no
    /// inline completion, so the bar is drawn by hand from the cursor's line.
    @ViewBuilder
    private var completionBar: some View {
        let matches = completions
        if !matches.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(matches) { ingredient in
                        Button {
                            complete(with: ingredient)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ingredient.name)
                                    .font(.callout)
                                Text(ingredient.category.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(Color.sousField, in: .capsule)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
        }
    }

    private var completions: [CatalogIngredient] {
        guard isEditingIngredients, let range = currentIngredientLine else { return [] }
        return IngredientCompletion.suggestions(
            forLine: String(draft.ingredientsText[range]),
            catalog: catalog.catalog
        )
    }

    /// The line the cursor is in, which is what gets completed.
    private var currentIngredientLine: Range<String.Index>? {
        guard case .selection(let selected)? = ingredientsSelection?.indices else { return nil }
        return IngredientCompletion.lineRange(in: draft.ingredientsText, at: selected.lowerBound)
    }

    private func complete(with ingredient: CatalogIngredient) {
        guard let range = currentIngredientLine else { return }
        let completed = IngredientCompletion.completed(
            line: String(draft.ingredientsText[range]),
            with: ingredient
        )
        let offset = draft.ingredientsText.distance(
            from: draft.ingredientsText.startIndex, to: range.lowerBound
        ) + completed.count

        draft.ingredientsText.replaceSubrange(range, with: completed)
        // Indices did not survive the edit; put the cursor back by offset.
        let cursor = draft.ingredientsText.index(
            draft.ingredientsText.startIndex,
            offsetBy: min(offset, draft.ingredientsText.count)
        )
        ingredientsSelection = TextSelection(insertionPoint: cursor)
    }

    /// Ingredients the catalog does not know yet, offered for adding.
    ///
    /// Nothing is wrong with an unknown ingredient — it just has no aisle on
    /// the shopping list and does not merge with other spellings until the
    /// app is told what it is.
    @ViewBuilder
    private var unknownIngredients: some View {
        let unknown = catalog.unknownIngredients(in: draft.ingredientsText)
        if !unknown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Noch unbekannt", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(unknown, id: \.self) { name in
                            Button {
                                teaching = CatalogIngredient(name: name, category: .other)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(name)
                                    Image(systemName: "plus.circle.fill")
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .background(Color.sousField, in: .capsule)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
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
