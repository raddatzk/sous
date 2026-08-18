import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(ShoppingLibrary.self) private var shopping
    let recipe: Recipe

    /// `nil` means "as written". Reset whenever another recipe is shown.
    @State private var servingsOverride: Int?
    /// A linked recipe the reader tapped through to.
    @State private var linkedRecipe: Recipe?
    @State private var isCooking = false
    @State private var didAddToShoppingList = false
    @State private var isPlanning = false

    private let formatter = QuantityFormatter(locale: .sous)

    private var servings: Int { servingsOverride ?? recipe.servings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroImage
                VStack(alignment: .leading, spacing: 28) {
                    titleBlock
                    actionBar
                    servingsControl
                    ingredients
                    steps
                    notes
                    sourceFooter
                }
                .padding(24)
                .frame(maxWidth: 700, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: recipe.imageIDs.isEmpty ? [] : .top)
        .navigationTitle(recipe.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(recipe.imageIDs.isEmpty ? .automatic : .hidden, for: .navigationBar)
        #endif
        .toolbar { detailToolbar }
        .onChange(of: recipe.id) {
            servingsOverride = nil
            didAddToShoppingList = false
        }
        .sheet(isPresented: $isPlanning) {
            PlanRecipeSheet(recipe: recipe, servings: servings)
        }
        .fullScreenCoverIfAvailable(isPresented: $isCooking) {
            CookModeView(recipe: recipe, servings: servings)
        }
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

    /// Edge to edge, the way a dish deserves to be seen.
    @ViewBuilder
    private var heroImage: some View {
        if let imageID = recipe.imageIDs.first {
            // The placeholder decides the size and the image only fills it:
            // a `.fill` image sized by its own content would widen the whole
            // page past the screen and drag the text off the left edge.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .overlay { RecipeImageView(imageID: imageID) }
                .clipped()
                .overlay(alignment: .bottom) {
                    // Keeps the page from starting with a hard edge.
                    LinearGradient(
                        colors: [.clear, Color.sousBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                }
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.title)
                .font(SousStyle.recipeTitle)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            metaRow
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !recipe.categories.isEmpty {
                Label(recipe.categories.joined(separator: ", "), systemImage: "tag")
                    .metaLabel()
            }
            Label("\(recipe.servings) Portionen", systemImage: "person.2")
                .metaLabel()
            if !timeItems.isEmpty {
                HStack(spacing: 16) {
                    ForEach(timeItems, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.value).font(.footnote.weight(.medium))
                            Text(item.label)
                                .font(.caption2)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var timeItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        if let prep = recipe.prepTimeSeconds, prep > 0 {
            items.append(("Vorbereitung", "\(prep / 60) Min"))
        }
        if let cook = recipe.cookTimeSeconds, cook > 0 {
            items.append(("Zubereitung", "\(cook / 60) Min"))
        }
        if items.count == 2 {
            let total = (recipe.prepTimeSeconds ?? 0) + (recipe.cookTimeSeconds ?? 0)
            items.append(("Gesamt", "\(total / 60) Min"))
        }
        return items
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                isCooking = true
            } label: {
                Label("Kochen", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recipe.steps.isEmpty)

            Button {
                isPlanning = true
            } label: {
                Label("Einplanen", systemImage: "calendar.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)

            Button {
                addToShoppingList()
            } label: {
                Label(
                    didAddToShoppingList ? "Auf der Einkaufsliste" : "Auf die Einkaufsliste",
                    systemImage: didAddToShoppingList ? "checkmark" : "cart.badge.plus"
                )
                // Icons only: three labelled buttons do not fit a phone
                // without wrapping mid-word.
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(recipe.ingredients.isEmpty || didAddToShoppingList)

        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var servingsControl: some View {
        HStack {
            Label("Portionen", systemImage: "person.2")
                .font(.subheadline.weight(.medium))
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
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var ingredients: some View {
        if !recipe.ingredients.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Zutaten")
                    .font(SousStyle.sectionHeading)
                ForEach(recipe.ingredientGroups(scaledToServings: servings), id: \.group) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if let name = group.group {
                            Text(name)
                                .font(SousStyle.groupHeading)
                                .padding(.top, 4)
                        }
                        ForEach(group.ingredients) { ingredient in
                            IngredientLineView(ingredient: ingredient, formatter: formatter)
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
            VStack(alignment: .leading, spacing: 14) {
                Text("Zubereitung")
                    .font(SousStyle.sectionHeading)
                ForEach(recipe.stepGroups, id: \.group) { group in
                    if let name = group.group {
                        Text(name)
                            .font(SousStyle.groupHeading)
                            .padding(.top, 4)
                    }
                    // Numbering restarts per group, as the heading implies.
                    ForEach(Array(group.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(index + 1)")
                                .font(.system(.headline, design: .serif))
                                .foregroundStyle(.tint)
                                .frame(minWidth: 20, alignment: .trailing)
                            Text(markdown(recipe.scaledStepText(step, toServings: servings)))
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
                Text(notes)
            }
        }
    }

    @ViewBuilder
    private var sourceFooter: some View {
        if recipe.source.kind != .manual || recipe.source.url != nil {
            VStack(alignment: .leading, spacing: 6) {
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

    /// What a recipe *is* to the cook — kept apart from the action bar
    /// below, which is for what to do with it now.
    ///
    /// A menu rather than a row of icons: a filled star beside a filled
    /// bookmark asks the reader to remember which is which, where a menu
    /// says it in words, and it leaves the toolbar to the recipe's name.
    /// The wording matches the list's context menu, so the same action
    /// reads the same wherever it is reached from.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Mehr", systemImage: "ellipsis.circle") {
                Button("Bearbeiten", systemImage: "pencil") { library.editing = recipe }
                Divider()
                Button(
                    recipe.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten",
                    systemImage: recipe.isFavorite ? "star.slash" : "star"
                ) {
                    Task { await library.toggleFavorite(recipe) }
                }
                Button(
                    recipe.wantToCook ? "Nicht mehr geplant" : "Will ich kochen",
                    systemImage: recipe.wantToCook ? "bookmark.slash" : "bookmark"
                ) {
                    Task { await library.toggleWantToCook(recipe) }
                }
            }
        }
    }

    /// Puts the ingredients on the list at the serving count on screen, so
    /// what is bought matches what was just read.
    private func addToShoppingList() {
        Task {
            await shopping.add(recipe, servings: servings)
            didAddToShoppingList = true
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
}

extension Color {
    /// The page colour behind a recipe, used to fade a hero image into it.
    static var sousBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
