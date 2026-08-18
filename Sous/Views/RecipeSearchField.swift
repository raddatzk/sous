import SousKit
import SwiftUI

/// The search field, with recognized ingredients and categories sitting in it
/// as chips.
///
/// Typing "Tomate" could mean the word, the ingredient, or a category — the
/// app offers what it recognizes, and taking the offer turns it into a filter
/// that can be removed again on its own.
struct RecipeSearchField: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalog

    @FocusState private var isTyping: Bool

    var body: some View {
        @Bindable var library = library

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)

                FlowLayout {
                    ForEach(library.activeFilters) { filter in
                        chip(filter)
                    }
                    TextField("Titel, Zutat, Kategorie", text: $library.searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 140)
                        .focused($isTyping)
                }

                if !library.activeFilters.isEmpty || !library.searchText.isEmpty {
                    Button("Zurücksetzen", systemImage: "xmark.circle.fill") {
                        Task { await library.clearFilters() }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))

            suggestions
        }
    }

    @ViewBuilder
    private func chip(_ filter: RecipeFilter) -> some View {
        HStack(spacing: 4) {
            Image(systemName: filter.kind == .ingredient ? "carrot" : "tag")
                .font(.caption2)
            Text(filter.title)
                .font(.callout)
            Button("Entfernen", systemImage: "xmark") {
                Task { await library.remove(filter) }
            }
            .labelStyle(.iconOnly)
            .font(.caption2)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.tint.opacity(0.15), in: .capsule)
        .foregroundStyle(.tint)
    }

    @ViewBuilder
    private var suggestions: some View {
        let matches = library.filterSuggestions(catalog: catalog.catalog)
        if !matches.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(matches) { filter in
                        Button {
                            Task { await library.apply(filter) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: filter.kind == .ingredient ? "carrot" : "tag")
                                    .font(.caption2)
                                Text(filter.title)
                                    .font(.callout)
                                // Says why something matched when its own
                                // name does not contain what was typed.
                                if let matched = filter.matchedAs {
                                    Text(matched)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary, in: .capsule)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
