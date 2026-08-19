import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(CookSession.self) private var session
    @Environment(MealPlanLibrary.self) private var plan
    let recipe: Recipe

    /// `nil` means "as written". Reset whenever another recipe is shown.
    @State private var servingsOverride: Int?
    /// The plan entry `recipe` was opened from, if it got here from one.
    /// Looked up fresh rather than carried as a count: the plan is the
    /// source of truth, and the Mac reuses this view's identity across
    /// recipes, so `onChange(of: recipe.id)` reads it again on every switch.
    let plannedEntryID: MealPlanEntry.ID?

    init(recipe: Recipe, plannedEntryID: MealPlanEntry.ID? = nil) {
        self.recipe = recipe
        self.plannedEntryID = plannedEntryID
        // Not seeded here: `plan` is an `@Environment` value, and those are
        // not available yet inside a custom initializer. `.onAppear` seeds
        // it once the environment is actually resolved.
    }

    /// The entry `plannedEntryID` names, looked up fresh from the plan every
    /// time — not cached, so a stepper pressed on the plan row beside this
    /// column (the Mac keeps both on screen at once) is reflected here too.
    private var plannedEntry: MealPlanEntry? {
        guard let plannedEntryID else { return nil }
        return (plan.entries + plan.pool).first { $0.id == plannedEntryID }
    }
    private var plannedServings: Int? { plannedEntry?.servings }
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

            // Not the size class: that describes the window, and this view
            // is a column inside it. On a Mac with a narrow window, or an
            // iPad in Split View, the window stays regular while the column
            // has no room — only its own width can answer this.
            // Both halves have to exist, or the fixed ingredient column
            // becomes 300 points of nothing with the steps shoved off to
            // the right of it.
            let isWide = screen.size.width >= Self.splitWidth
                && !recipe.ingredients.isEmpty
                && !recipe.steps.isEmpty

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroImage
                    VStack(alignment: .leading, spacing: 28) {
                        titleBlock(barEdge: barEdge)
                        if recipe.isDeleted {
                            trashBanner(isWide: isWide)
                        } else {
                            actionBar(isWide: isWide)
                        }
                        if isWide {
                            // What to get out and what to do with it, side by
                            // side: the cook reads the steps and glances left
                            // instead of scrolling back up.
                            HStack(alignment: .top, spacing: 40) {
                                ingredients
                                    .frame(width: Self.ingredientColumn, alignment: .leading)
                                steps
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            ingredients
                            steps
                        }
                        notes
                        sourceFooter
                    }
                    .padding(24)
                    .frame(maxWidth: isWide ? Self.wideContent : Self.narrowContent, alignment: .leading)
                    // Centred in whatever room is left. Capped at a readable
                    // width and pinned to the left, the page sat against the
                    // window's edge with the rest of a wide column empty
                    // beside it — on a phone the cap never bites and the
                    // difference does not show.
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Only where there is a status bar and a navigation bar to run the
        // picture under. In the Mac's detail column there is no top safe area
        // to ignore, and the line would claim to do something it cannot.
        #if os(iOS)
        .ignoresSafeArea(edges: recipe.imageIDs.isEmpty ? [] : .top)
        #endif
        // On the phone and the iPad the name is on the page already, and the
        // bar only says it once the page's own title has scrolled past.
        //
        // The Mac says it not at all. This title would name the window, and
        // the window sits above a list that already carries the name beside a
        // page that carries it again — a third copy in the title bar is one
        // too many. A window whose title appeared and disappeared as the
        // reader scrolled would be worse still.
        #if os(iOS)
        .navigationTitle(showsToolbarTitle ? recipe.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(
            recipe.imageIDs.isEmpty || showsToolbarTitle ? .automatic : .hidden,
            for: .navigationBar
        )
        #endif
        .toolbar { detailToolbar }
        .recipeExporter($export)
        // The one-time seed: `init` cannot read `plan`, since `@Environment`
        // values are not resolved yet inside a custom initializer.
        .onAppear {
            servingsOverride = plannedServings
        }
        .onChange(of: recipe.id) {
            // Not always `nil`: on the Mac this same view identity is reused
            // as the plan hands it one planned recipe after another, and
            // `plannedServings` carries whatever the new one was scaled for.
            servingsOverride = plannedServings
            didAddToShoppingList = false
        }
        // The plan row this came from stays on screen beside this column —
        // a stepper pressed there while this recipe is still the one open
        // must show up here too, not just the next time something is opened.
        .onChange(of: plannedServings) {
            servingsOverride = plannedServings
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

    /// Where the page stops being one column.
    ///
    /// The ingredient column plus a step column wide enough to read a
    /// sentence in, with the padding and the gap between them — below this
    /// the split makes both halves worse than the single column was.
    ///
    /// 820 was the first guess and it never fired: a default window leaves
    /// the detail column around 860 points, and any window smaller than that
    /// stayed single-column for good. Measured against the real thing, the
    /// two halves need 280 and 400.
    private static let splitWidth: CGFloat = 740
    private static let ingredientColumn: CGFloat = 280
    private static let narrowContent: CGFloat = 700
    private static let wideContent: CGFloat = 1100

    @ViewBuilder
    private func titleBlock(barEdge: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.title)
                .font(SousStyle.recipeTitle)
                .fixedSize(horizontal: false, vertical: true)
                // Watched rather than computed from the scroll offset: the
                // title sits below a hero image that may or may not be there,
                // and may itself run to three lines. Nothing to watch on the
                // Mac, where the window keeps its title throughout.
                #if os(iOS)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.frame(in: .global).maxY <= barEdge
                } action: { isBehindBar in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsToolbarTitle = isBehindBar
                    }
                }
                #endif

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
            // Not repeated here as a plain "recipe.servings" label: the
            // action row below is the one place that count is shown, since
            // it can differ from what the recipe is written for and a
            // second, unscaled number beside it would just read as a
            // mismatch.
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
    private func trashBanner(isWide: Bool) -> some View {
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
        // Full width where the page is barely wider than the banner, and no
        // wider than it needs where there is room. Measured rather than asked
        // of the platform: an iPad's page is as wide as a Mac's.
        .fixedSize(horizontal: isWide, vertical: false)
    }

    @ViewBuilder
    private func actionBar(isWide: Bool) -> some View {
        if isWide {
            HStack(spacing: 12) {
                cookButton(isWide: true)
                planButton
                shoppingButton
                servingsField
                resetButton
            }
            .controlSize(.large)
        } else {
            // Four controls do not fit one line at phone width — an
            // `HStack` doesn't wrap, so it either squeezed "Kochen" down to
            // a sliver or (once the reset button joined) compressed the
            // servings count down to nothing rather than touch the stepper
            // or the icons beside it. "Kochen" gets its own full-width row
            // regardless — the one unmissable action — and `FlowLayout`
            // wraps whatever else doesn't fit onto a line of its own.
            VStack(alignment: .leading, spacing: 12) {
                cookButton(isWide: false)
                FlowLayout(spacing: 12, lineSpacing: 12) {
                    planButton
                    shoppingButton
                    servingsField
                    resetButton
                }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func cookButton(isWide: Bool) -> some View {
        Button {
            // Puts the recipe on the hob and opens cook mode on it — the
            // session decides whether that is the only pot or a second.
            session.start(recipe, servings: servings)
        } label: {
            Label("Kochen", systemImage: "play.fill")
                // The one thing to press on a narrow page, so it fills it.
                // On a wide one a button a thousand points across reads as
                // a banner rather than something to click.
                .frame(maxWidth: isWide ? nil : .infinity)
                .padding(.horizontal, isWide ? 8 : 0)
        }
        .buttonStyle(.borderedProminent)
        .disabled(recipe.steps.isEmpty)
    }

    private var planButton: some View {
        Button {
            isPlanning = true
        } label: {
            Label("Einplanen", systemImage: "calendar.badge.plus")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
    }

    private var shoppingButton: some View {
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

    @ViewBuilder
    private var resetButton: some View {
        if servingsOverride != nil, servingsOverride != recipe.servings {
            // Icon rather than the word "Zurücksetzen": as text it was the
            // one flexible-width element in a row of icon chips, and wrapped
            // letter by letter the moment the row ran short on space.
            Button {
                updateServings(recipe.servings)
            } label: {
                Label("Zurücksetzen", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
        }
    }

    /// The count "Kochen" and "Auf die Einkaufsliste" both use, set right
    /// beside them rather than in a card of its own above — a cook reads it
    /// in the same glance as the buttons that act on it.
    private var servingsField: some View {
        HStack(spacing: 4) {
            // Icon rather than the word "Portionen": the row already reads
            // as icon-led buttons, and a bare number beside them would have
            // nothing saying what it counts.
            Image(systemName: "person.2")
            Text("\(servings)")
                .monospacedDigit()
            // The count is its own label: hiding the stepper's label would
            // hide the number with it.
            Stepper("Portionen", value: Binding(
                get: { servings },
                set: { updateServings($0.clamped(to: Recipe.servingsRange)) }
            ), in: Recipe.servingsRange)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.sousField, in: .capsule)
    }

    /// Scales the page for reading either way, and — when this recipe came
    /// from a planned meal — writes the new count back to that entry, since
    /// this is now the only place a cook can change it.
    private func updateServings(_ newValue: Int) {
        servingsOverride = newValue
        if let entry = plannedEntry {
            Task { await plan.setServings(entry, to: newValue, for: recipe) }
        }
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
