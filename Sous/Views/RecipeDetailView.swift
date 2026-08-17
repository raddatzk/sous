import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    let recipe: Recipe

    /// `nil` means "as written". Reset whenever another recipe is shown.
    @State private var servingsOverride: Int?

    private let formatter = QuantityFormatter()

    private var displayed: Recipe {
        guard let servingsOverride, servingsOverride != recipe.servings else { return recipe }
        return recipe.scaled(toServings: servingsOverride)
    }

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
        .toolbar { detailToolbar }
        .onChange(of: recipe.id) { servingsOverride = nil }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recipe.title)
                .font(.largeTitle.bold())
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
        let servings = servingsOverride ?? recipe.servings
        HStack {
            Text("Portionen")
                .font(.headline)
            Spacer()
            Stepper(value: Binding(
                get: { servings },
                set: { servingsOverride = max(1, $0) }
            ), in: 1...50) {
                Text("\(servings)")
                    .monospacedDigit()
                    .frame(minWidth: 24)
            }
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
        if !displayed.ingredients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Zutaten")
                    .font(.title2.bold())
                ForEach(displayed.ingredientGroups, id: \.group) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let name = group.group {
                            Text(name)
                                .font(.headline)
                                .padding(.top, 4)
                        }
                        ForEach(group.ingredients) { ingredient in
                            Text(formatter.string(for: ingredient))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        if !displayed.steps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Zubereitung")
                    .font(.title2.bold())
                ForEach(Array(displayed.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.text)
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
