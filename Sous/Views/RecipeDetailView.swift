import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(CookSession.self) private var session
    let recipe: Recipe

    /// `nil` means "as written". Reset whenever another recipe is shown.
    @State private var servingsOverride: Int?
    /// A linked recipe the reader tapped through to.
    @State private var linkedRecipe: Recipe?
    /// Whether the page's own title has scrolled up behind the navigation
    /// bar, which is when the bar takes the name over.
    @State private var showsToolbarTitle = false
    @State private var didAddToShoppingList = false
    @State private var isPlanning = false
    @State private var export: RecipeExport?

    private let formatter = QuantityFormatter(locale: .sous)

    private var servings: Int { servingsOverride ?? recipe.servings }

    var body: some View {
        // The bar's own edge is what the title has to pass, and only a
        // geometry reader knows where that is on this device.
        GeometryReader { screen in
            let barEdge = screen.safeAreaInsets.top + Self.barHeight

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroImage
                    VStack(alignment: .leading, spacing: 28) {
                        titleBlock(barEdge: barEdge)
                        if recipe.isDeleted {
                            trashBanner
                        } else {
                            actionBar
                        }
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
        }
        .ignoresSafeArea(edges: recipe.imageIDs.isEmpty ? [] : .top)
        // The name is on the page already; the bar only says it once the
        // page's own title is gone.
        .navigationTitle(showsToolbarTitle ? recipe.title : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(
            recipe.imageIDs.isEmpty || showsToolbarTitle ? .automatic : .hidden,
            for: .navigationBar
        )
        #endif
        .toolbar { detailToolbar }
        .recipeExporter($export)
        .onChange(of: recipe.id) {
            servingsOverride = nil
            didAddToShoppingList = false
        }
        .sheet(isPresented: $isPlanning) {
            PlanRecipeSheet(recipe: recipe, servings: servings)
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

    /// How much of the navigation bar sits below the safe area.
    private static let barHeight: CGFloat = 44

    @ViewBuilder
    private func titleBlock(barEdge: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.title)
                .font(SousStyle.recipeTitle)
                .fixedSize(horizontal: false, vertical: true)
                // Watched rather than computed from the scroll offset: the
                // title sits below a hero image that may or may not be there,
                // and may itself run to three lines.
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.frame(in: .global).maxY <= barEdge
                } action: { isBehindBar in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsToolbarTitle = isBehindBar
                    }
                }

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

    /// The times worth showing, in the order they happen.
    ///
    /// "Gesamt" appears whenever it says something the other numbers do not
    /// — either because waiting stretches it, or because it is all a recipe
    /// records. Repeating a total that is plainly the sum of two numbers
    /// beside it would be noise.
    private var timeItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        if let prep = recipe.prepTimeSeconds, prep > 0 {
            items.append(("Vorbereitung", minutes(prep)))
        }
        if let cook = recipe.cookTimeSeconds, cook > 0 {
            items.append(("Zubereitung", minutes(cook)))
        }
        if let resting = recipe.restingTimeSeconds {
            items.append(("Ruhezeit", minutes(resting)))
        }
        if let elapsed = recipe.elapsedTimeSeconds, items.count != 1 {
            items.append(("Gesamt", minutes(elapsed)))
        }
        return items
    }

    /// Minutes up to an hour, then hours and minutes: "1:30 Std" is read at
    /// a glance where "90 Min" has to be divided first.
    private func minutes(_ seconds: Int) -> String {
        let total = seconds / 60
        guard total >= 60 else { return "\(total) Min" }
        let rest = total % 60
        return rest == 0 ? "\(total / 60) Std" : String(format: "%d:%02d Std", total / 60, rest)
    }

    /// What a deleted recipe offers instead of an action bar.
    ///
    /// Cooking, planning and shopping all assume the recipe is part of the
    /// collection. It is readable — that is the point of keeping it — but the
    /// only thing to do with it here is to take it back.
    @ViewBuilder
    private var trashBanner: some View {
        HStack(spacing: 12) {
            Label("Im Papierkorb", systemImage: "trash")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Wiederherstellen") {
                Task { await library.restore(recipe) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.sousSurface, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                // Puts the recipe on the hob and opens cook mode on it — the
                // session decides whether that is the only pot or a second.
                session.start(recipe, servings: servings)
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
                set: { servingsOverride = $0.clamped(to: Recipe.servingsRange) }
            ), in: Recipe.servingsRange)
            .labelsHidden()
            if servingsOverride != nil, servingsOverride != recipe.servings {
                Button("Zurücksetzen") { servingsOverride = nil }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
        }
        .padding(14)
        .background(Color.sousSurface, in: .rect(cornerRadius: 12))
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
                if recipe.isDeleted {
                    Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                        Task { await library.restore(recipe) }
                    }
                }
                // Editing stays: a recipe in the trash is an ordinary recipe
                // that happens to be marked, and fixing a typo while reading
                // it costs nothing. Saving keeps the tombstone.
                Button("Bearbeiten", systemImage: "pencil") { library.editing = recipe }
                Button("Exportieren", systemImage: "square.and.arrow.up") {
                    Task {
                        if let data = await library.exportedRecipe(recipe) {
                            export = RecipeExport(recipe: recipe, data: data)
                        }
                    }
                }
                if !recipe.isDeleted {
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
