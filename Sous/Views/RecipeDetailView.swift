import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    let recipe: Recipe

    /// `nil` means "as written". Reset whenever another recipe is shown.
    @State private var servingsOverride: Int?
    /// A linked recipe the reader tapped through to.
    @State private var linkedRecipe: Recipe?

    private let formatter = QuantityFormatter()

    private var servings: Int { servingsOverride ?? recipe.servings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                servingsControl
                ingredients
                steps
                notes
                sourceFooter
            }
            .padding()
            .frame(maxWidth: 700, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(recipe.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { detailToolbar }
        .onChange(of: recipe.id) { servingsOverride = nil }
        // Shown as a sheet rather than pushed: looking up how the dough is
        // made is a detour, and a swipe returns to exactly where the cook was.
        .sheet(item: $linkedRecipe) { linked in
            NavigationStack {
                RecipeDetailView(recipe: linked)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fertig") { linkedRecipe = nil }
                        }
                    }
            }
        }
        // A link to another recipe navigates inside the app; anything else
        // is left to the system.
        .environment(\.openURL, OpenURLAction { url in
            guard let id = RecipeLink.recipeID(from: url) else { return .systemAction }
            Task { linkedRecipe = await library.recipe(id: id) }
            return .handled
        })
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .foregroundStyle(.secondary)
            }
            if !metaItems.isEmpty {
                Text(metaItems.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Renders inline markdown, falling back to the raw text if it does not
    /// parse — a half-typed emphasis marker should not blank out a step.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private var metaItems: [String] {
        var items: [String] = []
        if let prep = recipe.prepTimeSeconds, prep > 0 {
            items.append("Vorbereitung \(prep / 60) Min.")
        }
        if let cook = recipe.cookTimeSeconds, cook > 0 {
            items.append("Kochzeit \(cook / 60) Min.")
        }
        items.append(contentsOf: recipe.categories)
        return items
    }

    @ViewBuilder
    private var servingsControl: some View {
        HStack {
            Text("Portionen")
                .font(.headline)
            Spacer()
            Text("\(servings)")
                .monospacedDigit()
                .frame(minWidth: 24)
            // The count is its own label: hiding the stepper's label would
            // hide the number with it.
            Stepper("Portionen", value: Binding(
                get: { servings },
                set: { servingsOverride = max(1, $0) }
            ), in: 1...50)
            .labelsHidden()
            if servingsOverride != nil, servingsOverride != recipe.servings {
                Button("Zurücksetzen") { servingsOverride = nil }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var ingredients: some View {
        if !recipe.ingredients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Zutaten")
                    .font(.title2.bold())
                ForEach(recipe.ingredientGroups(scaledToServings: servings), id: \.group) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let name = group.group {
                            Text(name)
                                .font(.headline)
                                .padding(.top, 4)
                        }
                        ForEach(group.ingredients) { ingredient in
                            Text(markdown(formatter.string(for: ingredient)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        if !recipe.steps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Zubereitung")
                    .font(.title2.bold())
                ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(markdown(step.text))
                            if let seconds = step.durationSeconds, seconds > 0 {
                                Label("\(seconds / 60) Min.", systemImage: "timer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let notes = recipe.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notizen")
                    .font(.title2.bold())
                Text(notes)
            }
        }
    }

    @ViewBuilder
    private var sourceFooter: some View {
        if recipe.source.kind != .manual || recipe.source.url != nil {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                if let url = recipe.source.url {
                    Link(recipe.source.name ?? url.host() ?? url.absoluteString, destination: url)
                        .font(.footnote)
                } else if let name = recipe.source.name {
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
                if recipe.source.kind == .generated {
                    Text("Von der KI erzeugt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Bearbeiten", systemImage: "pencil") { library.editing = recipe }
        }
        ToolbarItem(placement: .automatic) {
            Button(
                recipe.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten",
                systemImage: recipe.isFavorite ? "star.fill" : "star"
            ) {
                Task { await library.toggleFavorite(recipe) }
            }
        }
    }
}
