import SousKit
import SwiftUI

/// The recipes of a file, looked through and chosen from before any of them
/// is stored.
///
/// Rows look like the recipe list's, because that is where the recipes are
/// going and what the cook will recognize them by. Each opens into a page
/// to read — only to read: cooking, the plan and the shopping list need a
/// recipe the library has, and this one is not there yet.
///
/// A file with a single new recipe skips the list and opens on its page.
struct RecipeImportPreviewSheet: View {
    let preview: RecipeImportPreview
    /// Called with the chosen recipes when the cook confirms.
    let onImport: (RecipeImportBatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<UUID>

    init(preview: RecipeImportPreview, onImport: @escaping (RecipeImportBatch) -> Void) {
        self.preview = preview
        self.onImport = onImport
        _picked = State(initialValue: preview.initialSelection)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let only = singleEntry {
                    ImportedRecipePage(entry: only)
                } else {
                    list
                }
            }
            .navigationDestination(for: RecipeImportPreview.Entry.ID.self) { id in
                if let entry = preview.entries.first(where: { $0.id == id }) {
                    ImportedRecipePage(entry: entry, isPicked: binding(for: entry))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importieren") {
                        let ids = singleEntry.map { [$0.id] } ?? picked
                        dismiss()
                        onImport(preview.batch(selecting: ids))
                    }
                    .disabled(singleEntry == nil && picked.isEmpty)
                }
                if singleEntry == nil {
                    // The Mac has no bottom bar to hang it under; there it
                    // stands with the other actions.
                    #if os(iOS)
                    ToolbarItem(placement: .bottomBar) { selectAllButton }
                    #else
                    ToolbarItem(placement: .automatic) { selectAllButton }
                    #endif
                }
            }
        }
        // A choice made across a few hundred rows is work worth keeping; once
        // it differs from where it started, only the buttons close the sheet.
        .interactiveDismissDisabled(picked != preview.initialSelection)
        .sousSheetSizing(.page)
    }

    private var singleEntry: RecipeImportPreview.Entry? {
        preview.entries.count == 1 ? preview.entries.first : nil
    }

    private var list: some View {
        List {
            Section {
                ForEach(preview.entries) { entry in
                    row(entry)
                }
            } header: {
                Text(summary)
            }
            if !preview.problems.isEmpty {
                Section("Nicht lesbar") {
                    ForEach(preview.problems, id: \.self) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.name)
                            Text(problem.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Rezepte importieren")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// "12 von 15 ausgewählt · 3 schon in Sous".
    private var summary: String {
        var parts = ["\(picked.count) von \(preview.entries.count) ausgewählt"]
        let here = preview.entries.count - preview.newCount
        if here > 0 { parts.append("\(here) schon in Sous") }
        return parts.joined(separator: " · ")
    }

    /// The tick and the row beside each other rather than one button: the
    /// row opens the recipe, the way it does in the list, and choosing is
    /// the circle's job alone.
    private func row(_ entry: RecipeImportPreview.Entry) -> some View {
        let isPicked = picked.contains(entry.id)
        return HStack(spacing: 12) {
            Button {
                toggle(entry)
            } label: {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(entry.recipe.title)
            .accessibilityAddTraits(isPicked ? [.isSelected] : [])

            NavigationLink(value: entry.id) {
                VStack(alignment: .leading, spacing: 4) {
                    RecipeRow(recipe: entry.recipe, unsavedPictures: entry.item.images)
                    if entry.existing != nil {
                        Text(isPicked ? "Ersetzt das Rezept in Sous" : "Schon in Sous")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var selectAllButton: some View {
        let all = Set(preview.entries.map(\.id))
        return Button(picked == all ? "Nichts auswählen" : "Alles auswählen") {
            picked = picked == all ? [] : all
        }
    }

    private func toggle(_ entry: RecipeImportPreview.Entry) {
        if picked.contains(entry.id) {
            picked.remove(entry.id)
        } else {
            picked.insert(entry.id)
        }
    }

    private func binding(for entry: RecipeImportPreview.Entry) -> Binding<Bool> {
        Binding {
            picked.contains(entry.id)
        } set: { isOn in
            if isOn { picked.insert(entry.id) } else { picked.remove(entry.id) }
        }
    }
}

/// One recipe from a file, to read before deciding on it.
///
/// Its own view rather than the recipe page with its actions switched off:
/// that page reads and writes the library under the recipe's id as soon as
/// it appears — nutrition is cached, Handoff is offered, a step is shown as
/// the library's copy has it — and a recipe from a file may share its id
/// with one the cook already has. This one only looks at what it was given.
struct ImportedRecipePage: View {
    let entry: RecipeImportPreview.Entry
    /// Whether it is ticked for import, when the page was opened from the
    /// list; `nil` for a file of one recipe, where the sheet's own button
    /// is the choice.
    var isPicked: Binding<Bool>?

    private let formatter = QuantityFormatter(locale: .sous)

    private var recipe: Recipe { entry.recipe }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let data = entry.item.images.first {
                    UnsavedPictureView(data: data)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 24) {
                    header
                    ingredients
                    steps
                    notes
                    source
                }
                .padding(20)
            }
        }
        .navigationTitle(recipe.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let isPicked {
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        isPicked.wrappedValue ? "Ausgewählt" : "Auswählen",
                        systemImage: isPicked.wrappedValue ? "checkmark.circle.fill" : "circle"
                    ) {
                        isPicked.wrappedValue.toggle()
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        // A link to another recipe names an id that may not be in this
        // library at all; followed, it would leave the preview for nowhere.
        .environment(\.openURL, OpenURLAction { url in
            RecipeLink.recipeID(from: url) == nil ? .systemAction : .discarded
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.title)
                .font(SousStyle.recipeTitle)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .foregroundStyle(.secondary)
            }
            if !recipe.categories.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(recipe.categories, id: \.self) { category in
                        Text(category)
                            .font(.footnote)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Color.sousCategory(category).opacity(SousStyle.chipTint),
                                in: .capsule
                            )
                            .foregroundStyle(Color.sousCategory(category))
                    }
                }
            }
            facts
            if let existing = entry.existing {
                Label(
                    "Schon in Sous als „\(existing.title)“. Importieren ersetzt es.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Portions, times and effort in the recipe page's shape — flowing
    /// onto a second line rather than squeezing, since unlike the page this
    /// one also names the portions, and five of them do not fit a phone.
    private var facts: some View {
        FlowLayout(spacing: 16, lineSpacing: 8) {
            fact("\(recipe.servings)", label: "Portionen")
            ForEach(timeItems, id: \.label) { item in
                fact(item.value, label: item.label)
            }
            if let effort = recipe.effortOverride ?? recipe.effort()?.level {
                fact(effort.title, label: "Aufwand")
            }
        }
        .padding(.top, 2)
    }

    private func fact(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.footnote.weight(.medium))
            Text(label)
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    /// As the recipe page counts them: a total only where it says something
    /// the parts do not.
    private var timeItems: [(label: String, value: String)] {
        RecipeTimes.items(for: recipe)
    }

    @ViewBuilder
    private var ingredients: some View {
        if !recipe.ingredients.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Zutaten")
                    .font(SousStyle.sectionHeading)
                ForEach(recipe.ingredientGroups(), id: \.group) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if let name = group.group {
                            Text(name)
                                .font(SousStyle.groupHeading)
                                .padding(.top, 4)
                        }
                        ForEach(group.ingredients) { ingredient in
                            IngredientLineView(ingredient: ingredient, formatter: formatter)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        if !recipe.steps.isEmpty {
            let rendition = recipe.stepRendition(toServings: recipe.servings, formatter: formatter)
            VStack(alignment: .leading, spacing: 14) {
                Text("Zubereitung")
                    .font(SousStyle.sectionHeading)
                ForEach(recipe.stepGroups, id: \.group) { group in
                    if let name = group.group {
                        Text(name)
                            .font(SousStyle.groupHeading)
                            .padding(.top, 4)
                    }
                    ForEach(Array(group.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(index + 1)")
                                .font(SousStyle.groupHeading)
                                .foregroundStyle(.tint)
                                .frame(minWidth: 20, alignment: .trailing)
                            Text(attributedText(for: rendition.segments(for: step)))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let notes = recipe.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notizen")
                    .font(SousStyle.sectionHeading)
                Text(markdown(notes))
            }
        }
    }

    @ViewBuilder
    private var source: some View {
        if let url = recipe.source.url {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Link(recipe.source.name ?? url.host() ?? url.absoluteString, destination: url)
                    .font(.footnote)
            }
        } else if let name = recipe.source.name {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text(name).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func attributedText(for segments: [StepAmountSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let string):
                result += markdown(string)
            case .amount(let string):
                var run = AttributedString(string)
                run.foregroundColor = .sousAccent
                result += run
            }
        }
        return result
    }
}
