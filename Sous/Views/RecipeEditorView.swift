import PhotosUI
import SousKit
import SwiftUI

#if os(iOS)
import UIKit
#endif

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalog

    @State private var draft: Recipe
    @State private var isSaving = false
    @State private var linkTarget: LinkTarget?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// Where the cursor sits in each editor, in characters, so a link lands
    /// where the writer is looking instead of at the very end.
    @State private var ingredientsCursor: Int?
    @State private var instructionsCursor: Int?
    /// Pictures stored during this edit, so cancelling does not leave them
    /// behind with nothing referencing them.
    @State private var addedImageIDs: [UUID] = []
    /// What stands in the category field without being a chip yet. Kept
    /// here rather than inside the field, so that saving straight out of a
    /// half-typed category still keeps it — see `save()`.
    @State private var categoryEntry = ""
    /// Mirrors each `HighlightedTextEditor`'s own `@FocusState`, since a view
    /// cannot hand its focus state to a child to own directly.
    @State private var isEditingIngredients = false
    @State private var isEditingInstructions = false
    /// How many amounts the resolver could write into the draft's steps —
    /// the editor's own copy of the detail view's review count, kept in
    /// state so a keystroke re-renders without re-resolving inline.
    @State private var amountSuggestionCount = 0
    @State private var isReviewingAmounts = false
    /// The resolve the review sheet is working on, taken once when it opens.
    ///
    /// Held rather than computed in the sheet's own builder, where it was
    /// re-resolved on every re-render of the editor behind it. Each resolve
    /// mints fresh suggestion ids, so the sheet's ticks — seeded from the
    /// first one — stopped naming anything the moment a keystroke or a
    /// finished count re-rendered it.
    @State private var amountReviewResolution: StepAmountResolver.Resolution?
    /// The amount questions turned down for good — what was already on
    /// record when the editor opened, plus whatever this session's review
    /// added. Held here rather than written on the spot because the draft is
    /// not the saved recipe yet: writing a decision about text that may still
    /// be abandoned would settle a question the cook never asked.
    @State private var declinedAmountKeys: Set<String> = []
    /// Which of the plain fields is being typed in, so that "Fertig" above
    /// the keyboard has something to let go of. The two big editors are not
    /// in here: they are a `UITextView` and mirror their focus separately,
    /// through `isEditingIngredients` / `isEditingInstructions`.
    @FocusState private var focusedField: EditorField?

    /// Which field a picked recipe link should be appended to.
    private enum LinkTarget: String, Identifiable {
        case ingredients
        case instructions
        var id: String { rawValue }
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Whether editor-related actions ("Rezept verlinken", unknown
    /// ingredients) belong in the keyboard accessory bar instead of as
    /// `Form` rows below the editor — true wherever the window is
    /// phone-narrow, where the growing editor otherwise buries them behind
    /// a long recipe. The size class rather than the device: an iPad in
    /// Slide Over is exactly the window this branch exists for, and asking
    /// what the hardware is would give it the roomy layout in a narrow
    /// strip.
    private var isCompactPhone: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
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
            #if os(iOS)
            // Two ways out of the keyboard, because the fields here offer
            // none of their own: the number pads have no return key at all,
            // and the wrapping fields spend theirs on a line break.
            .toolbar { keyboardToolbar }
            .scrollDismissesKeyboard(.interactively)
            #endif
            // Sits above the keyboard while an ingredient is being typed.
            .safeAreaInset(edge: .bottom) { completionBar }
            .sheet(item: $linkTarget) { target in
                RecipePickerView(excluding: draft.id) { picked in
                    insert(link: picked, at: target)
                }
            }
            .sheet(isPresented: $isReviewingAmounts) {
                // The resolve taken when the sheet was asked for, so the apply
                // works against the exact list the sheet was showing.
                if let amountReviewResolution {
                    AmountReviewSheet(recipe: draft, resolution: amountReviewResolution) { outcome in
                        guard let outcome else { return }
                        // Both halves of the answer, where this used to keep
                        // only the first: unticking a line here meant nothing
                        // at all, so the banner on the recipe was back the
                        // moment the editor closed.
                        declinedAmountKeys.formUnion(outcome.declined)
                        draft = amountReviewResolution.applying(
                            outcome.accepted, corrections: outcome.corrections, to: draft
                        )
                    }
                }
            }
            // Recounted off the render path whenever the text settles —
            // the editor's version of the detail view's review banner.
            .task(id: "\(draft.ingredientsText)|\(draft.instructionsText)|\(draft.servings)") {
                amountSuggestionCount = StepAmountResolver.resolve(draft, toServings: draft.servings)
                    .excluding(declined: declinedAmountKeys)
                    .allSuggestions.count
            }
            .task { await catalog.reload() }
            // What the recipe has already been answered "no" about, so the
            // editor's own count and review sheet agree with the recipe's.
            .task { declinedAmountKeys = await library.declinedAmountKeys(for: draft.id) }
        }
        // A recipe is written, not glanced at.
        .sousSheetSizing(.page)
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
                            .clipShape(.rect(cornerRadius: SousStyle.fieldRadius))
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
                        RoundedRectangle(cornerRadius: SousStyle.fieldRadius)
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
            // Wrapping (`axis: .vertical`), because a long title should be
            // readable while it is written — but not *broken*: a title is
            // one line however many it takes to draw. See `flattenTitle`.
            TextField("Titel", text: $draft.title, axis: .vertical)
                .font(SousStyle.recipeTitle)
                .lineLimit(1...3)
                .focused($focusedField, equals: .title)
                .onChange(of: draft.title) { _, title in flattenTitle(title) }
            TextField("Kurzbeschreibung", text: optional(\.summary), axis: .vertical)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
                .focused($focusedField, equals: .summary)
        }
    }

    /// Keeps the title to one line.
    ///
    /// The field wraps, so it takes a return key rather than a "Fertig" —
    /// and a title with a line break in it is nothing anywhere else in the
    /// app can show: the row, the page's hero and the plan all draw it as
    /// one line. So the break is taken out again, and the return does what
    /// it does in every single-line field instead: it ends the typing.
    ///
    /// A pasted-in break becomes a space rather than being dropped, or the
    /// words on either side of it would be glued together.
    private func flattenTitle(_ title: String) {
        guard title.contains(where: \.isNewline) else { return }
        let endsWithReturn = title.last?.isNewline == true
        draft.title = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        if endsWithReturn { focusedField = nil }
    }

    @ViewBuilder
    private var factsSection: some View {
        Section {
            
            Stepper(value: $draft.servings, in: Recipe.servingsRange) {
                Label(Servings.text(draft.servings), systemImage: "person.2")
            }
            // The label sits above rather than beside: chips wrap onto as
            // many lines as they need, which no trailing-aligned row can hold.
            VStack(alignment: .leading, spacing: 8) {
                Label("Kategorien", systemImage: "tag")
                    .font(.subheadline.weight(.medium))
                CategoryField(
                    categories: $draft.categories,
                    typed: $categoryEntry,
                    known: library.categories,
                    focus: $focusedField
                )
            }
            .padding(.vertical, 4)
            suitabilityRow
            // Beside "Passt als": both are judgements about the dish rather
            // than facts of it, and both fall back to something the app
            // works out when nobody says.
            effortRow
        } header: {
            sectionHeader("Angaben")
        }

        timesSection
    }

    /// Which meals the recipe suits, as three toggle chips. All off means
    /// nobody has said — the planner then decides for itself — so there is
    /// no fourth chip and nothing to reset.
    private var suitabilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Passt als", systemImage: "fork.knife")
                .font(.subheadline.weight(.medium))
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    let isOn = draft.suitableSlots?.contains(slot) == true
                    Button {
                        var slots = draft.suitableSlots ?? []
                        if isOn { slots.remove(slot) } else { slots.insert(slot) }
                        draft.suitableSlots = slots.isEmpty ? nil : slots
                    } label: {
                        // A hand-built label: inside this row's flow layout,
                        // `Label` answers an unspecified proposal with its
                        // stacked form and the capsule grows around it.
                        HStack(spacing: 4) {
                            Image(systemName: slot.symbolName)
                            Text(slot.title)
                        }
                        .font(.subheadline)
                        .lineLimit(1)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .sousToggleChip(isOn: isOn)
                }
                if draft.suitableSlots == nil {
                    Text("Automatisch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// How much work the dish is, as three chips over a derived default.
    ///
    /// Unlike "Passt als" above, the automatic case has something to say:
    /// the structure always implies an answer, so "Automatisch" names it.
    /// A cook overruling it should see what they are overruling — and the
    /// commonest reason to overrule is that the structure genuinely misses
    /// the point, which for effort it can: a croissant is five ingredients
    /// and a hard afternoon.
    ///
    /// Tapping the chip that is already on takes the override back, the same
    /// way unticking every meal above means "decide for me".
    private var effortRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aufwand", systemImage: "gauge.with.dots.needle.50percent")
                .font(.subheadline.weight(.medium))
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(RecipeEffort.Level.allCases, id: \.self) { level in
                    let isOn = draft.effortOverride == level
                    Button {
                        draft.effortOverride = isOn ? nil : level
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: level.symbolName)
                            Text(level.title)
                        }
                        .font(.subheadline)
                        .lineLimit(1)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .sousToggleChip(isOn: isOn)
                }
                if draft.effortOverride == nil {
                    Text(derivedEffortNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// What the structure makes of the recipe as it currently stands in the
    /// editor — recomputed as it is typed, since that is when it changes.
    ///
    /// A recipe with nothing to go on says so instead of naming a rung: one
    /// block of prose and no times is not an easy recipe, it is one nothing
    /// can be read off yet.
    private var derivedEffortNote: String {
        guard let level = draft.effort()?.level else {
            return "Automatisch — noch zu wenig Struktur"
        }
        return "Automatisch: \(level.title)"
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
                MinutesField(seconds: $draft.prepTimeSeconds, field: .prepTime, focus: $focusedField)
            } label: {
                Label("Vorbereitung", systemImage: "clock")
            }
            LabeledContent {
                MinutesField(seconds: $draft.cookTimeSeconds, field: .cookTime, focus: $focusedField)
            } label: {
                Label("Zubereitung", systemImage: "flame")
            }
            LabeledContent {
                MinutesField(seconds: $draft.totalTimeSeconds, field: .totalTime, focus: $focusedField)
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
            HighlightedTextEditor(
                text: $draft.ingredientsText,
                cursorOffset: $ingredientsCursor,
                isFocused: $isEditingIngredients,
                restyle: RecipeTextEditorStyle.ingredients
            )
            // Room for a few lines even while empty, so the three text
            // fields of the form read as siblings instead of the empty
            // ones collapsing to a slit.
            .frame(minHeight: 70, alignment: .top)
            if !isCompactPhone {
                ingredientLinkAndUnknowns
            }
        } header: {
            sectionHeader("Zutaten")
        } footer: {
            Text("Eine Zutat pro Zeile, etwa „300 g Zucchini (fein gehackt)“. „# Für den Teig“ beginnt einen Abschnitt.")
        }
    }

    /// "Rezept verlinken" and the unknown-ingredient chips for the
    /// ingredients editor — ordinary `Form` rows below the editor on
    /// iPad/Mac, or the editor's keyboard accessory bar on iPhone. See
    /// `isCompactPhone`.
    @ViewBuilder
    private var ingredientLinkAndUnknowns: some View {
        Button("Rezept verlinken", systemImage: "link") {
            linkTarget = .ingredients
        }
        unknownIngredients
    }

    /// The ingredients editor's iPhone keyboard bar: completions for the
    /// line being typed take priority, since that's what the cook needs
    /// *right now*; once nothing is being completed it falls back to
    /// linking and the unknown-ingredient chips.
    @ViewBuilder
    private var ingredientAccessoryBar: some View {
        if !completions.isEmpty {
            completionChips(compact: true)
        } else {
            ingredientBarFallback
        }
    }

    /// What the ingredients keyboard bar shows while nothing is being
    /// completed — the same two actions as the iPad/Mac rows, but laid out
    /// as one scrolling line, since the keyboard bar is a single row tall
    /// and a stacked "Noch unbekannt" heading would be cut off.
    private var ingredientBarFallback: some View {
        let unknown = catalog.unknownIngredients(in: draft.ingredientsText)
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Button("Rezept verlinken", systemImage: "link") {
                    linkTarget = .ingredients
                }
                .font(.callout)
                ForEach(unknown, id: \.self) { name in
                    UnknownIngredientButton.chip(name: name)
                }
            }
            // Keeps the capsules' own edges off the scroll view's bounds,
            // so the first and last chip are not shaved flat.
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    #if os(iOS)
    /// "Fertig" over the keyboard, for the fields that have no way of their
    /// own to end: the number pads, and the wrapping ones whose return key
    /// writes a line break.
    ///
    /// It only ever appears over SwiftUI's own fields — the two big editors
    /// are a `UITextView` and get their own, in `completionBar`.
    @ToolbarContentBuilder
    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Fertig") { focusedField = nil }
        }
    }
    #endif

    /// The bar docked above the keyboard, drawn as a bottom safe-area inset
    /// so SwiftUI lifts it clear of the keyboard for us.
    ///
    /// `ToolbarItemGroup(placement: .keyboard)` would be the native way to
    /// say this, but it only attaches to SwiftUI's own `TextField`/
    /// `TextEditor`; the ingredients and steps editors are a hand-wrapped
    /// `UITextView` (`HighlightedTextEditor`), which SwiftUI does not know
    /// to hang a keyboard toolbar on — nothing appears. Hence this inset,
    /// keyed off the editors' mirrored focus instead.
    ///
    /// On iPhone it carries the actions that used to be `Form` rows below
    /// each editor: those editors now grow to fit every line, so a row
    /// underneath would sit behind a whole recipe's worth of scrolling.
    /// iPad and Mac keep those rows and only get the completions.
    @ViewBuilder
    private var completionBar: some View {
        if isCompactPhone {
            if isEditingIngredients {
                keyboardBarChrome {
                    HStack(spacing: 12) {
                        ingredientAccessoryBar
                        dismissEditorButton { isEditingIngredients = false }
                    }
                }
            } else if isEditingInstructions {
                keyboardBarChrome {
                    HStack(spacing: 16) {
                        instructionLinkButton
                        if amountSuggestionCount > 0 {
                            amountLintButton
                        }
                        Spacer(minLength: 0)
                        dismissEditorButton { isEditingInstructions = false }
                    }
                    .font(.callout)
                }
            }
        } else if !completions.isEmpty {
            keyboardBarChrome { completionChips(compact: false) }
        }
    }

    /// The way out of the two big editors. Their return key writes a step or
    /// an ingredient and cannot also mean "done", and they are the one place
    /// in this form where scrolling the keyboard away is awkward — the
    /// editor grows under the finger as the recipe does.
    private func dismissEditorButton(_ close: @escaping () -> Void) -> some View {
        Button("Tastatur schließen", systemImage: "keyboard.chevron.compact.down") {
            close()
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.plain)
    }

    /// One opaque strip, hairline-separated from the form behind it. Opaque
    /// rather than `.bar`: sitting right on top of the keyboard, a material
    /// picks up the keyboard's own grey and washes out the low-contrast
    /// `sousField` chips drawn on it.
    private func keyboardBarChrome(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sousBar)
            .overlay(alignment: .top) { Divider() }
    }

    /// `compact` drops the category subtitle: the keyboard bar is one row
    /// tall, and a second line is what got the chips clipped off at the
    /// bottom. The width cap keeps a long catalog name ("Sauerrahm/Schmand,
    /// mind. 20 % Fett") from stretching one chip past the screen edge —
    /// the row scrolls instead.
    private func completionChips(compact: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(completions) { ingredient in
                    Button {
                        complete(with: ingredient)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ingredient.name)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !compact {
                                Text(ingredient.category.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: 200, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.sousField, in: .capsule)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var completions: [CatalogIngredient] {
        guard isEditingIngredients, let range = currentIngredientLine else { return [] }
        return IngredientCompletion.suggestions(
            forLine: String(draft.ingredientsText[range]),
            in: draft.ingredientsText,
            catalog: catalog.catalog
        )
    }

    /// The line the cursor is in, which is what gets completed.
    ///
    /// Deliberately does not require the editor to still be focused:
    /// tapping a chip in the keyboard bar can hand first-responder status
    /// over for a moment, and the completion must still land on the line
    /// the cursor was left in. `completions` does the focus check, so
    /// nothing is offered once the editor is genuinely done being edited.
    private var currentIngredientLine: Range<String.Index>? {
        guard let cursor = ingredientsCursor,
              let index = draft.ingredientsText.index(
                  draft.ingredientsText.startIndex, offsetBy: cursor, limitedBy: draft.ingredientsText.endIndex
              )
        else { return nil }
        return IngredientCompletion.lineRange(in: draft.ingredientsText, at: index)
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
        ingredientsCursor = min(offset, draft.ingredientsText.count)
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
                            UnknownIngredientButton.chip(name: name)
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
            HighlightedTextEditor(
                text: $draft.instructionsText,
                cursorOffset: $instructionsCursor,
                isFocused: $isEditingInstructions,
                restyle: RecipeTextEditorStyle.instructions
            )
            .frame(minHeight: 70, alignment: .top)
            if !isCompactPhone {
                instructionLinkButton
                if amountSuggestionCount > 0 {
                    amountLintButton
                }
            }
        } header: {
            sectionHeader("Zubereitung")
        } footer: {
            Text("Ein Schritt pro Zeile, Nummerierung übernimmt die App. **Fett**, *kursiv* und ***beides*** sind erlaubt. „# Überschrift“ beginnt einen Abschnitt und zählt neu.")
        }
    }

    /// "Rezept verlinken" for the instructions editor — an ordinary `Form`
    /// row below the editor on iPad/Mac, or its keyboard accessory bar on
    /// iPhone. See `isCompactPhone`.
    private var instructionLinkButton: some View {
        Button("Rezept verlinken", systemImage: "link") {
            linkTarget = .instructions
        }
    }

    /// The editor's amount lint — the same finding the detail view banners
    /// after the fact, offered while the text is still being written: steps
    /// that name an ingredient without giving it an amount.
    private var amountLintButton: some View {
        Button(
            amountSuggestionCount == 1
                ? "1 Menge könnte ergänzt werden"
                : "\(amountSuggestionCount) Mengen könnten ergänzt werden",
            systemImage: "text.badge.checkmark"
        ) {
            amountReviewResolution = StepAmountResolver.resolve(draft, toServings: draft.servings)
                .excluding(declined: declinedAmountKeys)
            isReviewingAmounts = true
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section {
            // No placeholder: the section is already called Notizen, and
            // neither of its two siblings above carries one either.
            TextField("", text: optional(\.notes), axis: .vertical)
                .lineLimit(3...)
                .accessibilityLabel("Notizen")
                .focused($focusedField, equals: .notes)
        } header: {
            sectionHeader("Notizen")
        }
    }

    /// Section headings share the serif with the rest of the app.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).sousGroupHeader()
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

    /// Inserts the link at the cursor.
    private func insert(link recipe: Recipe, at target: LinkTarget) {
        let markdown = RecipeLink.markdown(title: recipe.title, id: recipe.id)
        switch target {
        case .ingredients:
            insert(markdown, into: &draft.ingredientsText, at: &ingredientsCursor)
        case .instructions:
            insert(markdown, into: &draft.instructionsText, at: &instructionsCursor)
        }
    }

    private func insert(_ snippet: String, into text: inout String, at cursor: inout Int?) {
        guard let cursorOffset = cursor,
              let index = text.index(text.startIndex, offsetBy: cursorOffset, limitedBy: text.endIndex)
        else {
            // Nobody has put a cursor in the field yet, so the end is the only
            // sensible place — on its own line, since one line is one entry.
            text = text.isEmpty ? snippet : text + (text.hasSuffix("\n") ? "" : "\n") + snippet
            cursor = nil
            return
        }

        text.insert(contentsOf: snippet, at: index)
        cursor = min(cursorOffset + snippet.count, text.count)
    }

    private func save() {
        isSaving = true
        var recipe = draft
        recipe.title = recipe.title.trimmingCharacters(in: .whitespaces)
        // A category typed but not yet turned into a chip is still meant:
        // "Sichern" is as good a way to finish a word as the return key.
        recipe.categories = CategoryCompletion.adding(
            categoryEntry,
            to: recipe.categories,
            known: library.categories
        )
        let declined = declinedAmountKeys
        Task {
            await onSave(recipe)
            // After the save, and only if the cook actually answered
            // something: the review sheet reached from here used to drop its
            // answers on the floor, so a recipe reviewed while editing asked
            // the whole list again on the way back out.
            if !declined.isEmpty {
                await library.markAmountsReviewed(recipe, declining: declined)
            }
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

/// The fields the editor can be typing in — the plain ones, which SwiftUI's
/// focus can address. Named at file scope because `MinutesField` is a view of
/// its own and has to speak the same language.
enum EditorField: Hashable {
    case title
    case summary
    case categories
    case notes
    case prepTime
    case cookTime
    case totalTime
}

/// A minutes field over a seconds-based property.
private struct MinutesField: View {
    @Binding var seconds: Int?
    /// Which field this is, and where the editor keeps its focus — a number
    /// pad has no return key, so without a "Fertig" that can let go of it
    /// this field is a keyboard nobody can close.
    let field: EditorField
    @FocusState.Binding var focus: EditorField?

    var body: some View {
        HStack(spacing: 4) {
            TextField("–", text: minutes)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: field)
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
