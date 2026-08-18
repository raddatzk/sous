import SousKit
import SwiftUI

/// The ingredient catalog: what the app knows, and what you taught it.
struct IngredientCatalogView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var editing: CatalogIngredient?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.ingredients) { ingredient in
                            row(ingredient)
                        }
                    } header: {
                        Text(group.category.title)
                            .font(SousStyle.groupHeading)
                            .textCase(nil)
                    }
                }
            }
            .navigationTitle("Zutaten")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Zutat suchen"
            )
            #else
            .searchable(text: $searchText, prompt: "Zutat suchen")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zutat hinzufügen", systemImage: "plus") { isAdding = true }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search
                }
            }
        }
        .task { await catalog.reload() }
        .sheet(item: $editing) { ingredient in
            IngredientFormView(ingredient: ingredient)
        }
        .sheet(isPresented: $isAdding) {
            IngredientFormView(ingredient: CatalogIngredient(name: "", category: .other))
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #elseif os(iOS)
        .presentationDetents([.large])
        #endif
    }

    @ViewBuilder
    private func row(_ ingredient: CatalogIngredient) -> some View {
        let isOwn = catalog.isOwn(ingredient)

        Group {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ingredient.name)
                    if !ingredient.aliases.isEmpty {
                        Text(ingredient.aliases.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isOwn {
                    // Only what the cook added can be changed; the bundled
                    // list is replaced whenever the app updates.
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture { if isOwn { editing = ingredient } }
        .swipeActions {
            if isOwn {
                Button("Entfernen", systemImage: "trash", role: .destructive) {
                    Task { await catalog.delete(ingredient) }
                }
            }
        }
    }

    /// Matching ingredients, grouped by category in aisle order.
    private var groups: [(category: IngredientCategory, ingredients: [CatalogIngredient])] {
        let matches = searchText.isEmpty
            ? catalog.catalog.ingredients
            : catalog.catalog.suggestions(for: searchText, limit: 200)

        return Dictionary(grouping: matches, by: \.category)
            .map { (category: $0.key, ingredients: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category.aisleOrder < $1.category.aisleOrder }
    }
}

/// Adds or edits one catalog entry.
struct IngredientFormView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var aliasText: String
    @State private var category: IngredientCategory

    private let isNew: Bool

    init(ingredient: CatalogIngredient) {
        _name = State(initialValue: ingredient.name)
        _aliasText = State(initialValue: ingredient.aliases.joined(separator: ", "))
        _category = State(initialValue: ingredient.category)
        isNew = ingredient.name.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Kategorie", selection: $category) {
                        ForEach(IngredientCategory.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } footer: {
                    Text("Die Kategorie bestimmt, in welcher Abteilung die Zutat auf der Einkaufsliste steht.")
                }

                Section {
                    TextField("Tomaten, Cocktailtomaten", text: $aliasText, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Andere Schreibweisen")
                } footer: {
                    Text("Mit Komma getrennt. Rezepte, die eine davon nennen, zählen zur selben Zutat.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Neue Zutat" : name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 340)
        #elseif os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func save() {
        let ingredient = CatalogIngredient(
            name: name.trimmingCharacters(in: .whitespaces),
            aliases: aliasText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            category: category
        )
        Task {
            await catalog.save(ingredient)
            dismiss()
        }
    }
}
