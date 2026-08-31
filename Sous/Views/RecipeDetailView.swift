import SousKit
import SwiftUI

struct RecipeDetailView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(CookSession.self) private var session
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @Environment(RecipeSelection.self) private var selection
    /// The way to the shopping list — where there is one. Optional because
    /// this page is also shown as a sheet out of the Mac's cook window,
    /// which is a window of its own and carries no section to switch.
    @Environment(SousNavigation.self) private var navigation: SousNavigation?
    /// Restoring from the trash leaves this page behind — the recipe is
    /// back in the collection, and the reader came from the trash list.
    /// A no-op where the view is not presented, like the Mac's detail column.
    @Environment(\.dismiss) private var dismiss
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
    @State private var isAddingVariant = false
    @State private var isJoiningVariants = false
    /// Whether the page's own title has scrolled up behind the navigation
    /// bar, which is when the bar takes the name over.
    @State private var showsToolbarTitle = false
    @State private var isPickingForShoppingList = false
    /// Whether the fork a recipe already on the list is asked about is up:
    /// set the portions there, or bring along what was left out here.
    @State private var isAskingAboutSecondAdd = false
    /// How much work this is: the cook's word, or what the structure says.
    ///
    /// `nil` where the recipe has too little structure to judge, and then
    /// the row simply has one fewer column — an unread dish is not an easy
    /// one, and the page does not claim otherwise.
    @State private var effort: RecipeEffort.Level?
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
    /// Which line's derived gram amount is open for correction — the gram
    /// bridge's counterpart to `clarifying`, kept apart so answering the one
    /// question does not fold the other away.
    @State private var correcting: String?
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
        // While the bar's own background is hidden over the hero image, the
        // soft edge keeps its buttons legible over a light photo — a
        // progressive fade instead of a hard bar edge once it returns.
        .scrollEdgeEffectStyle(.soft, for: .top)
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
        // The checkmark is read off the list, so the list has to have been
        // read — this page can be the first thing opened after a launch.
        .task { await shopping.loadIfNeeded() }
        .task(id: recipe.id) { await recomputeEffort() }
        .sheet(isPresented: $isPickingForShoppingList) {
            // Topping up shows the amounts the list is showing for the dish
            // — its dial, not this page's. The two are different questions,
            // and the sheet is answering the list's.
            ShoppingPickSheet(
                recipe: recipe,
                servings: listedEntry?.servingsCurrent ?? servings,
                joining: listedEntry
            ) { lines in
                addToShoppingList(lines: lines)
            }
        }
        // What a second tap on the trolley means, asked rather than guessed.
        // Both readings are real: a cook who wants more of the dish wants the
        // portion dial, and a cook who unticked the paprika last time wants
        // it now. Silently adding the recipe again answers neither — it put
        // the dish on the list twice, with two dials splitting one meal.
        .confirmationDialog(
            "Schon auf der Einkaufsliste",
            isPresented: $isAskingAboutSecondAdd,
            titleVisibility: .visible
        ) {
            Button("Portionen einstellen") { navigation?.showShoppingList(for: recipe.id) }
            Button("Zutaten ergänzen") { isPickingForShoppingList = true }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(
                """
                „\(recipe.title)“ steht schon auf der Liste. Wie viel davon \
                gebraucht wird, stellst du dort ein — oder du ergänzt hier, \
                was beim Hinzufügen abgewählt war.
                """
            )
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
            IngredientClarificationSheet(open: openIngredients) {
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
        .sheet(isPresented: $isJoiningVariants) {
            VariantJoinPicker(target: .recipe(recipe)) { group in
                // Onto the comparison, because the two recipes have just
                // been put side by side and that is the thing to look at.
                selection.target = .group(group, mode: .comparison)
            }
        }
        .sheet(isPresented: $isAddingVariant) {
            AddVariantSheet(recipe: recipe) { variant in
                // Straight into the new one: it is a copy of what is on
                // screen, and the reason to make it was to change it. Said
                // through the selection rather than by presenting it here,
                // because on the phone this page is itself the pushed one —
                // the list swaps what it pushed, and a recipe shown in a
                // sheet could not reach the editor.
                selection.target = .recipe(variant)
                selection.plannedEntryID = nil
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

    /// The dish this recipe is one version of, when it is one of several.
    ///
    /// Read from the library rather than from `recipe.variantGroupID`: a
    /// group whose only other member is in the trash is not a group at the
    /// moment, and a link to a comparison of one would lead nowhere worth
    /// going.
    private var variantGroup: VariantGroup? {
        recipe.variantGroupID.flatMap { library.variantGroups[$0] }
    }

    /// Without this the comparison is reachable only from the list, and a
    /// cook who arrived here from the meal plan has no way to see that there
    /// are four other versions of what they are reading.
    @ViewBuilder
    private var variantGroupLink: some View {
        if let group = variantGroup {
            Button {
                // The same route the list takes: on the Mac the column
                // changes, on the phone what the list pushed changes. Not a
                // sheet, because the group page is a place to work from —
                // everything on it leads to a recipe.
                //
                // As an overview, not as the table: someone reading a recipe
                // who follows this link is asking which other versions there
                // are, not which of them to cook tonight.
                selection.target = .group(group, mode: .overview)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.on.square")
                        .imageScale(.small)
                    Text("Variante von \(group.title)")
                    let count = library.variantMemberCounts[group.id] ?? 0
                    if count > 1 {
                        Text("· \(count) Varianten")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private func titleBlock(barEdge: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            variantGroupLink
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
            if !timeItems.isEmpty || effort != nil || nutrition?.coverage.isComplete == true {
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
                    // Last, and in the same shape as the times: it belongs
                    // with them, because the two together are what a cook
                    // weighs on a weekday evening — how long it takes and
                    // how much of that is standing at the counter.
                    if let effort {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(effort.title).font(.footnote.weight(.medium))
                            Text("Aufwand")
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

    /// Works out the effort, with the linked recipes fetched first.
    ///
    /// The list cannot afford this — a row per link would be a query per row
    /// — but this page can, and this is where it matters: a curry that
    /// bakes its own naan is a different evening from one that does not, and
    /// with no resolver the naan counts as the single line it looks like.
    private func recomputeEffort() async {
        var linked: [UUID: Recipe] = [:]
        for id in recipe.linkedRecipeIDs {
            if let found = await library.recipe(id: id) { linked[id] = found }
        }
        effort = recipe.effortOverride ?? recipe.effort { linked[$0] }?.level
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
                Task {
                    await library.restore(recipe)
                    dismiss()
                }
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
            if !openIngredients.isEmpty {
                basisReviewBanner(openIngredients.count, isWide: isWide)
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
                count == 1 ? "1 Zutat fehlt im Katalog" : "\(count) Zutaten fehlen im Katalog",
                systemImage: "text.book.closed"
            )
            .font(.subheadline.weight(.medium))
            Spacer()
            Button("Anlegen") {
                isReviewingIngredients = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.sousSurface, in: .rect(cornerRadius: 12))
        .fixedSize(horizontal: isWide, vertical: false)
    }

    /// The ingredients whose numbers rest on a guess or on nothing — what
    /// the collected "Nährwerte zuordnen" view walks through, each with the
    /// preparation state its answer has to be filed under.
    ///
    /// Names the catalog does not know are left out while the banner above
    /// is still asking about them: they were being counted in both numbers
    /// at once, which read as two rival questions about the same word rather
    /// than as the two steps it actually is. They come back the moment that
    /// banner is settled — see `openIngredientsWithKnownName`.
    private var openIngredients: [NutritionCoverage.OpenIngredient] {
        guard let coverage = nutrition?.coverage else { return [] }
        return needsIngredientReview ? coverage.openIngredientsWithKnownName : coverage.openIngredients
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
                count == 1
                    ? "1 Zutat ohne bestätigte Nährwerte"
                    : "\(count) Zutaten ohne bestätigte Nährwerte",
                systemImage: "questionmark.text.page"
            )
            .font(.subheadline.weight(.medium))
            Spacer()
            Button("Zuordnen") { isClarifyingAll = true }
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
        .buttonStyle(.glassProminent)
        .disabled(recipe.steps.isEmpty)
    }

    private var planButton: some View {
        Button {
            isPlanning = true
        } label: {
            Label("Einplanen", systemImage: "calendar.badge.plus")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .help("Einplanen")
    }

    private var shoppingButton: some View {
        Button {
            // A dish the list is already carrying is not a second errand.
            // Asking is the whole of the fix: the two things this tap can
            // mean live in two different places, and only the cook knows
            // which one they came for.
            if isOnShoppingList, navigation != nil {
                isAskingAboutSecondAdd = true
            } else {
                isPickingForShoppingList = true
            }
        } label: {
            Label(
                isOnShoppingList ? "Auf der Einkaufsliste" : "Auf die Einkaufsliste",
                // `cart.badge.checkmark` is not an SF Symbol, so the
                // already-on-the-list button drew nothing at all. The filled
                // cart is the pair to the badged one: same glyph, stated
                // rather than offered.
                systemImage: isOnShoppingList ? "cart.fill" : "cart.badge.plus"
            )
            // Icons only: three labelled buttons do not fit a phone
            // without wrapping mid-word.
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .disabled(recipe.ingredients.isEmpty)
        .help(isOnShoppingList ? "Auf der Einkaufsliste" : "Auf die Einkaufsliste")
    }

    /// The entry this recipe is being carried by on the list, if it still
    /// has anything outstanding there.
    ///
    /// Read off the list rather than remembered from the tap that put it
    /// there. The remembered version was wrong in both directions: it
    /// survived taking the recipe back off the list, and it was absent on a
    /// recipe that had been on the list since yesterday.
    ///
    /// And read off what is *open*, not off the plan entry: the entry
    /// outlives the shopping on purpose, so "already on the list" used to
    /// stay true for a dish whose last line had been ticked off weeks ago.
    /// Everything bought is the errand finished, and then the trolley goes
    /// back to offering the list rather than asking about it.
    private var listedEntry: ShoppingPlanEntry? {
        shopping.openPlanEntry(forRecipe: recipe.id)
    }

    /// Whether this recipe is on the shopping list right now.
    private var isOnShoppingList: Bool { listedEntry != nil }

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
        // The same glass the buttons beside it wear, so the action row
        // reads as one family instead of two.
        .glassEffect(in: .capsule)
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
                            state: gap.state,
                            source: gap.sourceRecipeTitle,
                            detail: gapDetail(for: gap),
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
                                state: line.state,
                                source: line.sourceRecipeTitle,
                                detail: basisDetail(for: line, basis: basis),
                                isOpen: line.isProvisional
                            )
                        }
                        gramBridgeRow(for: line)
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

    /// Why a line contributed nothing — and, where the answer is "the row it
    /// was mapped to is gone", which row that was.
    ///
    /// Read live off the vocabulary rather than out of the cached coverage:
    /// the remembered name is what the *mapping* carries, so it corrects
    /// itself the moment the mapping is repaired, and a coverage cached
    /// before the update cannot serve a stale one.
    private func gapDetail(for gap: NutritionCoverage.Gap) -> String {
        guard gap.reason == .orphanedBasis,
              let was = nutritionLibrary.orphanedCatalogNames(forName: gap.ingredientName).first
        else { return gap.reason.label }
        return "\(gap.reason.label) — beruhte auf: \(was)"
    }

    /// What a counting line rests on, and — where the two differ — the state
    /// it was counted in.
    ///
    /// "Kartoffeln, gegart" computed from the raw row is not wrong enough to
    /// throw the line away, but it is not silent either: the row's own name
    /// carries its state ("Kartoffel geschält, roh"), and naming the line's
    /// alongside it is what lets a cook see the two are not the same.
    private func basisDetail(
        for line: NutritionCoverage.Contribution, basis: String
    ) -> String {
        let lead = line.isProvisional ? "vorgeschlagen" : "beruht auf"
        guard !line.matchesState, let state = line.state.shoppingAnnotation else {
            return "\(lead): \(basis)"
        }
        return "\(state) — \(lead): \(basis)"
    }

    /// "2 EL ≈ 28 g (Annahme)" — the gram bridge, said out loud for the line
    /// it was crossed on, and tappable because the concept asks that every
    /// assumed number be correctable where it is shown.
    ///
    /// Only for amounts that had to be *converted*. A line that says 300 g
    /// contributes 300 g; repeating that under every second row would bury
    /// the handful of numbers that really are guesses.
    @ViewBuilder
    private func gramBridgeRow(for line: NutritionCoverage.Contribution) -> some View {
        if line.isAssumedGrams, let grams = line.grams, let quantity = line.quantity {
            let written = formatter.string(for: quantity)
            let label = "\(written) ≈ \(mass(grams)) (Annahme)"
            let key = measureKey(for: line, unit: quantity.unit)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation { correcting = correcting == key ? nil : key }
                } label: {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .underline(pattern: .dot)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if correcting == key {
                    IngredientMeasurePicker(
                        name: line.ingredientName, unit: quantity.unit
                    ) {
                        await recomputeNutrition()
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }

    /// One line's gram question, told apart from every other line's: the same
    /// ingredient can appear twice in one recipe with two units.
    private func measureKey(
        for line: NutritionCoverage.Contribution, unit: IngredientUnit
    ) -> String {
        "\(line.ingredientName)|\(unit.symbol)"
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
        name: String, state: IngredientState, source: String?, detail: String, isOpen: Bool
    ) -> some View {
        let title = source.map { "aus \($0): \(name)" } ?? name
        // Keyed by name *and* state: one word can appear twice in a recipe,
        // raw once and cooked once, and those are two separate questions with
        // two separate answers.
        let key = NutritionCoverage.OpenIngredient(name: name, state: state).id
        VStack(alignment: .leading, spacing: 0) {
            if isOpen {
                Button {
                    withAnimation { clarifying = clarifying == key ? nil : key }
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
                if clarifying == key {
                    IngredientBasisPicker(name: name, state: state) {
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
                        Task {
                            await library.restore(recipe)
                            dismiss()
                        }
                    }
                }
                // Editing stays: a recipe in the trash is an ordinary recipe
                // that happens to be marked, and fixing a typo while reading
                // it costs nothing. Saving keeps the tombstone.
                Button("Bearbeiten", systemImage: "pencil") { library.editing = recipe }
                if !recipe.isDeleted {
                    Button("Variante anlegen", systemImage: "square.on.square") {
                        isAddingVariant = true
                    }
                    if variantGroup != nil {
                        // `square.on.square.slash` does not exist; the rectangle family
                        // is the one that has a struck-through variant.
                        Button("Aus der Gruppe lösen", systemImage: "rectangle.on.rectangle.slash") {
                            Task { await library.removeFromVariantGroup(recipe) }
                        }
                    } else {
                        Button(
                            "Mit einem Rezept zusammenfassen",
                            systemImage: "rectangle.stack.badge.plus"
                        ) {
                            isJoiningVariants = true
                        }
                    }
                }
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
                    Divider()
                    // The same soft delete the list offers — into the trash,
                    // not gone — and the page leaves with the recipe: what
                    // it shows is no longer part of the collection.
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        Task {
                            await library.delete(recipe)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    /// Puts the picked ingredients on the list at the serving count on
    /// screen, so what is bought matches what was just read.
    ///
    /// Unless the dish is already there, in which case the lines join it:
    /// one heading and one portion dial per meal, however often the cook
    /// comes back to the recipe for the thing they left out.
    private func addToShoppingList(lines: Set<UUID>) {
        Task {
            if let entry = listedEntry {
                await shopping.add(recipe, lines: lines, joining: entry)
            } else {
                await shopping.add(recipe, servings: servings, lines: lines)
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
