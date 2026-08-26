import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(CookSession.self) private var session
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(NutritionLibrary.self) private var nutritionLibrary
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
    @State private var isResolvingWithAI = false
    @State private var aiError: String?
    /// What the review sheet would show — bare mentions and any AI-found
    /// amount pending confirmation alike. Never fed into the step text shown
    /// on this page: an AI claim only ever renders once it has been through
    /// that sheet, see `amount-confirmation-vs-guessing-tension`.
    @State private var amountReviewResolution: StepAmountResolver.Resolution?
    /// Drives the banner, separately from whether suggestions exist at all:
    /// a recipe the cook already dismissed keeps its suggestions (editing it
    /// again should still find them) but stops nagging about them.
    @State private var needsAmountReview = false
    @State private var isReviewingAmounts = false
    @State private var nutrition: RecipeNutrition?
    /// Which coverage line has the basis picker unfolded under it. One at a
    /// time: the drill-down is a list to read, not a form.
    @State private var clarifying: String?
    @State private var isClarifyingAll = false
    @State private var needsIngredientReview = false
    @State private var isReviewingIngredients = false

    private let formatter = QuantityFormatter(locale: .sous)

    private var servings: Int { servingsOverride ?? recipe.servings }
    private var unknownIngredientCount: Int { library.unknownIngredients(in: recipe).count }

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
                        actionSection(isWide: isWide)
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
                        nutritionDetail
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
            amountReviewResolution = nil
            needsAmountReview = false
            needsIngredientReview = false
        }
        // A cache read, not a model call — whatever the last save's
        // background pass found, if anything. Fires again whenever the
        // recipe shown changes, same as `onChange(of: recipe.id)` above.
        .task(id: recipe.id) {
            let (resolution, _) = await library.amountSuggestions(for: recipe)
            amountReviewResolution = resolution
            needsAmountReview = await library.needsAmountReview(recipe)
        }
        .task(id: recipe.id) {
            needsIngredientReview = await library.needsIngredientReview(recipe)
        }
        // Keyed on servings too: nutrition is per portion, so scaling the
        // recipe has to recompute it, not just re-scale what is on screen.
        .task(id: "\(recipe.id)-\(servings)") {
            nutrition = await nutritionLibrary.nutrition(for: recipe, servings: servings)
        }
        // The background pass `save(_:)` schedules can still be running
        // when this screen is already open — most often right after
        // editing this very recipe and landing straight back on it. This
        // is how it shows up without waiting for the recipe to be left and
        // reopened.
        .onChange(of: library.lastEnrichment) { _, event in
            guard event?.recipeID == recipe.id else { return }
            Task {
                let (resolution, _) = await library.amountSuggestions(for: recipe)
                amountReviewResolution = resolution
                needsAmountReview = await library.needsAmountReview(recipe)
            }
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
        .sheet(isPresented: $isReviewingAmounts) {
            if let amountReviewResolution {
                AmountReviewSheet(recipe: recipe, resolution: amountReviewResolution) { outcome in
                    Task {
                        let updated: Recipe
                        if let outcome {
                            updated = await library.applyAmountSuggestions(
                                outcome.accepted, corrections: outcome.corrections,
                                resolution: amountReviewResolution, to: recipe
                            )
                        } else {
                            await library.markAmountsReviewed(recipe)
                            updated = recipe
                        }
                        let (resolution, _) = await library.amountSuggestions(for: updated)
                        self.amountReviewResolution = resolution
                        needsAmountReview = await library.needsAmountReview(updated)
                    }
                }
            }
        }
        .sheet(isPresented: $isReviewingIngredients) {
            IngredientReviewSheet(ingredientsText: recipe.ingredientsText) {
                Task {
                    await library.markIngredientsReviewed(recipe)
                    needsIngredientReview = await library.needsIngredientReview(recipe)
                }
            }
        }
        .sheet(isPresented: $isClarifyingAll) {
            IngredientClarificationSheet(names: openIngredientNames) {
                await recomputeNutrition()
            }
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
        .alert(
            "Fehler",
            isPresented: Binding(get: { aiError != nil }, set: { if !$0 { aiError = nil } })
        ) {
            Button("OK", role: .cancel) { aiError = nil }
        } message: {
            Text(aiError ?? "")
        }
    }

    /// The explicit "try again" — `save(_:)` already schedules this
    /// automatically, but a background pass can fail quietly (the device
    /// went to sleep, the model was briefly unavailable) with nothing else
    /// to retry it. Updates the cache too, not just this screen.
    private func resolveMentionsWithAI() {
        isResolvingWithAI = true
        Task {
            defer { isResolvingWithAI = false }
            do {
                try await library.refreshAIMentions(for: recipe)
                let (resolution, _) = await library.amountSuggestions(for: recipe)
                amountReviewResolution = resolution
                needsAmountReview = await library.needsAmountReview(recipe)
            } catch {
                aiError = error.localizedDescription
            }
        }
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
                // Each category keeps its own colour, the same one
                // `RecipeRow` gives it in the list — a reader who scanned
                // the list for it recognizes the recipe by colour again
                // here, before reading the word.
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(recipe.categories, id: \.self) { category in
                        Text(category)
                            .font(.footnote)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.sousCategory(category).opacity(SousStyle.chipTint), in: .capsule)
                            .foregroundStyle(Color.sousCategory(category))
                    }
                }
            }
            // Not repeated here as a plain "recipe.servings" label: the
            // action row below is the one place that count is shown, since
            // it can differ from what the recipe is written for and a
            // second, unscaled number beside it would just read as a
            // mismatch.
            if !timeItems.isEmpty || nutrition?.coverage.isComplete == true {
                HStack(spacing: 16) {
                    // Leads the row: the rating is the one fact here worth
                    // seeing before anything else, times included. Only with
                    // full coverage — an A computed from a half-empty sum
                    // would be doubly misleading, so an incomplete recipe
                    // gets no letter at all rather than a wrong one.
                    if let nutrition, nutrition.coverage.isComplete {
                        NRFBadge(level: nutrition.nrfLevel)
                    }
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

    /// Re-reads the figure after a basis decision. Confirming a mapping
    /// drops every cached recipe total, so this is a recompute, not a
    /// refresh of what was already on screen.
    private func recomputeNutrition() async {
        nutrition = await nutritionLibrary.nutrition(for: recipe, servings: servings)
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

    /// The row below the title: trashed recipes only get the one banner
    /// that matters to them, everything else gets the normal action bar
    /// plus, if there is one, the amount-review banner underneath it.
    ///
    /// Split out of `body` on its own — nesting this `if`/`if let` directly
    /// inside the outer `VStack` was enough branching for the type checker
    /// to time out inferring the whole scroll content at once.
    @ViewBuilder
    private func actionSection(isWide: Bool) -> some View {
        if recipe.isDeleted {
            trashBanner(isWide: isWide)
        } else {
            actionBar(isWide: isWide)
            if needsAmountReview, let amountReviewResolution {
                amountReviewBanner(amountReviewResolution.allSuggestions.count, isWide: isWide)
            }
            if needsIngredientReview {
                ingredientReviewBanner(unknownIngredientCount, isWide: isWide)
            }
            if !openIngredientNames.isEmpty {
                basisReviewBanner(openIngredientNames.count, isWide: isWide)
            }
        }
    }

    /// Offers to add whatever the catalog does not recognize yet — the same
    /// check `RecipeEditorView`'s "Noch unbekannt" row runs while typing,
    /// asked again here so a recipe that skipped the editor (a bulk import)
    /// still gets noticed. Stays up until answered, same as the amount
    /// review below it: opening the sheet and tapping "Fertig" without
    /// adding anything still settles it for the text as it stands.
    @ViewBuilder
    private func ingredientReviewBanner(_ count: Int, isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Label(
                count == 1 ? "1 Zutat unbekannt" : "\(count) Zutaten unbekannt",
                systemImage: "questionmark.circle"
            )
            .font(.subheadline.weight(.medium))
            Spacer()
            Button("Prüfen") {
                isReviewingIngredients = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.sousSurface, in: .rect(cornerRadius: 12))
        .fixedSize(horizontal: isWide, vertical: false)
    }

    /// The ingredients whose numbers rest on a guess or on nothing — what
    /// the collected "Zutaten klären" view walks through.
    private var openIngredientNames: [String] {
        nutrition?.coverage.openIngredientNames ?? []
    }

    /// The batch flow of decision A: one place that names how much of this
    /// recipe's figure is still conjecture, and one tap per ingredient to
    /// settle it. Unlike the two banners above it, this one has nothing to
    /// "not now" — it disappears when the questions are answered, and
    /// "bewusst ohne" is one of the answers.
    @ViewBuilder
    private func basisReviewBanner(_ count: Int, isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Label(
                count == 1 ? "1 Zutat zu klären" : "\(count) Zutaten zu klären",
                systemImage: "questionmark.text.page"
            )
            .font(.subheadline.weight(.medium))
            Spacer()
            Button("Klären") { isClarifyingAll = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.sousSurface, in: .rect(cornerRadius: 12))
        .fixedSize(horizontal: isWide, vertical: false)
    }

    /// Offers to check what the resolver could not write in on its own —
    /// stays up until the cook actually answers it (accepts some, or says
    /// "Nicht jetzt"), not just because they looked at the recipe.
    @ViewBuilder
    private func amountReviewBanner(_ count: Int, isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Label(
                count == 1 ? "1 Menge könnte ergänzt werden" : "\(count) Mengen könnten ergänzt werden",
                systemImage: "text.badge.checkmark"
            )
            .font(.subheadline.weight(.medium))
            Spacer()
            Button("Prüfen") {
                isReviewingAmounts = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.sousSurface, in: .rect(cornerRadius: 12))
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
            }
            .controlSize(.large)
        } else {
            // Three controls do not fit one line at phone width — an
            // `HStack` doesn't wrap, so it squeezed "Kochen" down to a
            // sliver. "Kochen" gets its own full-width row regardless — the
            // one unmissable action — and `FlowLayout` wraps whatever else
            // doesn't fit onto a line of its own.
            VStack(alignment: .leading, spacing: 12) {
                cookButton(isWide: false)
                FlowLayout(spacing: 12, lineSpacing: 12) {
                    planButton
                    shoppingButton
                    servingsField
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

    /// The count "Kochen" and "Auf die Einkaufsliste" both use, set right
    /// beside them rather than in a card of its own above — a cook reads it
    /// in the same glance as the buttons that act on it.
    ///
    /// The reset button lives inside this same capsule rather than beside
    /// it as its own chip: it only means something next to the count it
    /// resets, and a wrap that separated the two — reset landing alone on
    /// its own line, far from the field it acts on — read as misplaced.
    /// One view keeps them together, on either side of a wrap.
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
            if servingsOverride != nil, servingsOverride != recipe.servings {
                Button {
                    updateServings(recipe.servings)
                } label: {
                    Label("Zurücksetzen", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.leading, 4)
            }
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
            // Resolved once for the whole recipe: which line an amount
            // belongs to can depend on every other step's claim on it. No
            // `additionalMentions` here on purpose — an AI-found amount only
            // ever renders once it has been confirmed through the review
            // sheet and is part of the written text, never live.
            let resolution = StepAmountResolver.resolve(
                recipe, toServings: servings, formatter: formatter
            )
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
                            Text(attributedText(for: resolution.segments(for: step)))
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

    /// The full breakdown behind the rating up top — kept at the very end of
    /// the page rather than beside the rating itself: a cook glancing at the
    /// recipe wants the letter grade, not a wall of numbers, and the numbers
    /// are still one scroll away for whoever wants them.
    @ViewBuilder
    private var nutritionDetail: some View {
        if let nutrition {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Nährwerte")
                        .font(SousStyle.sectionHeading)
                    if nutrition.coverage.isProvisional {
                        // Decision A's marker, and it is meant to be the
                        // loudest thing in this block: numbers computed from
                        // unchecked conjecture are in the room, and a marker
                        // that dulls with habit is the price the decision
                        // names. So: a word, not a shade of grey.
                        Text("vorläufig")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(SousStyle.chipTint), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                }
                coverageLine(for: nutrition)
                let provisional = nutrition.coverage.isProvisional
                VStack(alignment: .leading, spacing: 5) {
                    nutrientRow(
                        "Energie", Self.nutrients.string(kilocalories: nutrition.perPortion.kcal),
                        emphasized: true, provisional: provisional
                    )
                    nutrientRow("Fett", mass(nutrition.perPortion.fatG), provisional: provisional)
                    nutrientRow(
                        "davon gesättigte Fettsäuren", mass(nutrition.perPortion.saturatedFatG),
                        indented: true, provisional: provisional
                    )
                    nutrientRow("Kohlenhydrate", mass(nutrition.perPortion.carbsG), provisional: provisional)
                    nutrientRow("davon Zucker", mass(nutrition.perPortion.sugarG), indented: true, provisional: provisional)
                    nutrientRow("Ballaststoffe", mass(nutrition.perPortion.fiberG), provisional: provisional)
                    nutrientRow("Eiweiß", mass(nutrition.perPortion.proteinG), provisional: provisional)
                    // BLS reports sodium; the standard EU label shows salt, in
                    // grams — dropped to milligrams where a portion has traces.
                    nutrientRow("Salz", mass(nutrition.perPortion.sodiumMg * 2.5 / 1000), provisional: provisional)
                }
                let micronutrients = micronutrientRows(nutrition.perPortion)
                if !micronutrients.isEmpty {
                    Text("Vitamine & Mineralstoffe")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(micronutrients, id: \.label) { row in
                            nutrientRow(row.label, row.value, provisional: provisional)
                        }
                    }
                }
                Text(provisional
                     ? "Pro Portion, geschätzt aus den Zutaten — mit noch unbestätigten Zuordnungen."
                     : "Pro Portion, geschätzt aus den Zutaten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    /// The figure never appears naked: what the sum is based on, with the
    /// left-out lines one tap away. "9 von 12 Zutaten" counts what should
    /// have contributed; unquantified lines ("Salz nach Geschmack") stand
    /// outside the count and only appear in the drill-down, neutrally.
    ///
    /// "davon 4 unbestätigt" is decision A's other half: those four lines are
    /// *in* the sum — that is the whole point of computing with proposals —
    /// and the line says so rather than letting the total look settled.
    ///
    /// Every line that a basis would settle is a button here. This is the
    /// casual entry: the recipe is the earliest place a gap becomes visible,
    /// long before a sum or a list would be wrong, and answering it unfolds
    /// in place rather than opening anything.
    @ViewBuilder
    private func coverageLine(for nutrition: RecipeNutrition) -> some View {
        let coverage = nutrition.coverage
        let summary = coverageSummary(for: nutrition)
        if coverage.gaps.isEmpty && coverage.contributions.isEmpty {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(coverage.gaps, id: \.self) { gap in
                        coverageRow(
                            name: gap.ingredientName,
                            source: gap.sourceRecipeTitle,
                            detail: gap.reason.label,
                            isOpen: gap.reason.wantsBasis
                        )
                    }
                    // The lines that *did* count, each naming the catalog row
                    // it was read from. The drill-down used to explain only
                    // the failures; a figure that worked out is just as much
                    // an interpretation, and this is where it says which one.
                    ForEach(coverage.contributions, id: \.self) { line in
                        if let basis = line.basisName {
                            coverageRow(
                                name: line.ingredientName,
                                source: line.sourceRecipeTitle,
                                detail: line.isProvisional
                                    ? "vorgeschlagen: \(basis)" : "beruht auf: \(basis)",
                                isOpen: line.isProvisional
                            )
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "≈ 640 kcal pro Portion — 9 von 12 Zutaten, davon 4 unbestätigt".
    private func coverageSummary(for nutrition: RecipeNutrition) -> String {
        let coverage = nutrition.coverage
        let energy = Self.nutrients.string(kilocalories: nutrition.perPortion.kcal)
        var summary = "≈ \(energy) pro Portion"
            + " — \(coverage.includedCount) von \(coverage.accountableCount) Zutaten"
        if coverage.unconfirmedCount > 0 {
            summary += ", davon \(coverage.unconfirmedCount) unbestätigt"
        }
        return summary
    }

    /// One line of the drill-down. Open questions are tappable and unfold the
    /// picker underneath; settled ones are just text.
    @ViewBuilder
    private func coverageRow(
        name: String, source: String?, detail: String, isOpen: Bool
    ) -> some View {
        let title = source.map { "aus \($0): \(name)" } ?? name
        VStack(alignment: .leading, spacing: 0) {
            if isOpen {
                Button {
                    withAnimation { clarifying = clarifying == name ? nil : name }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .underline(pattern: .dot)
                        Spacer()
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.footnote)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if clarifying == name {
                    IngredientBasisPicker(name: name) {
                        await recomputeNutrition()
                    }
                    .padding(.leading, 12)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer()
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.footnote)
            }
        }
    }

    /// A provisional figure wears a dotted underline — the same "something
    /// is open here" mark the concept puts on an ingredient line, so the two
    /// read as one language rather than two warnings.
    private func nutrientRow(
        _ label: String, _ value: String, indented: Bool = false,
        emphasized: Bool = false, provisional: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .padding(.leading, indented ? 14 : 0)
                .foregroundStyle(indented ? .secondary : .primary)
            Spacer()
            Text(value)
                .fontWeight(emphasized ? .semibold : .regular)
                .underline(provisional, pattern: .dot)
        }
        .font(.subheadline)
    }

    /// Only nutrients BLS actually had data for - a bundled zero and "wasn't
    /// measured" are the same value here, and showing "Vitamin D: 0 µg" next
    /// to real numbers would claim a precision the data doesn't have.
    private func micronutrientRows(_ info: NutritionInfo) -> [(label: String, value: String)] {
        let candidates: [(String, Double, NutrientFormatter.MassUnit)] = [
            ("Vitamin A", info.vitaminAMcg, .micrograms),
            ("Vitamin C", info.vitaminCMg, .milligrams),
            ("Vitamin D", info.vitaminDMcg, .micrograms),
            ("Vitamin E", info.vitaminEMg, .milligrams),
            ("Calcium", info.calciumMg, .milligrams),
            ("Eisen", info.ironMg, .milligrams),
            ("Magnesium", info.magnesiumMg, .milligrams),
            ("Kalium", info.potassiumMg, .milligrams),
        ]
        return candidates
            .filter { $0.1 > 0 }
            .map { (label: $0.0, value: Self.nutrients.string($0.1, in: $0.2)) }
    }

    private static let nutrients = NutrientFormatter(locale: .sous)

    private func mass(_ grams: Double) -> String {
        Self.nutrients.string(grams, in: .grams)
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
                if !recipe.steps.isEmpty {
                    Button(
                        isResolvingWithAI ? "Wird zugeordnet…" : "Mengen mit KI neu zuordnen",
                        systemImage: "sparkles"
                    ) {
                        resolveMentionsWithAI()
                    }
                    .disabled(isResolvingWithAI)
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

    /// A step's resolved segments, concatenated into one `AttributedString`
    /// — a resolved amount in the accent color, the way `IngredientLineView`
    /// sets the amount apart in the ingredient list.
    private func attributedText(for segments: [StepAmountSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let string):
                result += markdown(string)
            case .amount(let string):
                var run = AttributedString(string)
                run.foregroundColor = .accentColor
                result += run
            }
        }
        return result
    }
}
