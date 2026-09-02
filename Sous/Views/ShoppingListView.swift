import SousKit
import SwiftUI

/// The shopping list, readable two ways: as one line per ingredient for the
/// shop, or split by dish — where each recipe keeps its portion dial.
struct ShoppingListView: View {
    @Environment(ShoppingLibrary.self) private var shopping
    /// Only to look a recipe up by id when its heading is tapped — the list
    /// itself is built from the snapshot, not from the library.
    @Environment(RecipeLibrary.self) private var library
    #if os(macOS)
    @Environment(RecipeSelection.self) private var selection
    #endif
    /// Read for the recipe a detail page asked this list to stand at.
    @Environment(SousNavigation.self) private var navigation

    @State private var grouping: Grouping = .aisle
    @State private var newItem = ""
    /// The pantry is a check-through list, not errands — it starts folded.
    @State private var pantryExpanded = false
    /// "I am standing in this shop" — the aisle view narrowed to one
    /// store's errands. `nil` is the whole list.
    @State private var storeFilter: String?
    #if os(iOS)
    /// The dish whose heading was tapped, pushed over the list. The Mac has
    /// no such state: it hands the recipe to the window's detail column.
    @State private var openedRecipe: Recipe?
    #endif
    /// The recipe the bin was pressed on, waiting to be confirmed.
    ///
    /// The dial's last press is a single tap on a key that was a minus a
    /// moment earlier, and four quick presses down from four land on it — so
    /// that one asks. The context menu's entry does not: a long press and a
    /// pick from a red menu item is already the deliberate way round.
    @State private var removalCandidate: ShoppingPlanEntry?

    private let formatter = QuantityFormatter(locale: .sous)

    private enum Grouping: String, CaseIterable {
        case aisle
        case recipe

        var title: String {
            switch self {
            case .aisle: "Nach Abteilung"
            case .recipe: "Nach Rezept"
            }
        }
    }

    var body: some View {
        // The Mac has one split view for the whole window, so this is only
        // its first column; the phone brings its own stack.
        #if os(macOS)
        list
        #else
        NavigationStack {
            list
                .navigationDestination(item: $openedRecipe) { recipe in
                    RecipeDetailView(recipe: recipe)
                }
        }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        ScrollViewReader { proxy in
            listBody(proxy)
        }
    }

    /// Takes the list to the recipe a detail page sent it to.
    ///
    /// Switching the grouping is part of it: asked for one dish, the aisle
    /// view is the wrong shape of answer — its lines are scattered down the
    /// whole list, and the portion dial that the cook came for only exists
    /// under a recipe heading.
    private func standAt(_ recipeID: UUID?, proxy: ScrollViewProxy) {
        guard let recipeID,
              let group = shopping.byRecipe.first(where: { $0.planEntry?.recipeID == recipeID })
        else { return }
        #if os(iOS)
        // Tapped from a recipe the list itself had pushed: without this the
        // list would be "shown" underneath the page that asked for it.
        openedRecipe = nil
        #endif
        grouping = .recipe
        Task {
            // A turn later. The section does not exist until the picker has
            // switched and the list has been rebuilt around it, and a proxy
            // asked for an id it cannot see does nothing — silently.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation { proxy.scrollTo(group.id, anchor: .top) }
            navigation.shoppingRecipeID = nil
        }
    }

    @ViewBuilder
    private func listBody(_ proxy: ScrollViewProxy) -> some View {
        List {
            addRow

            if !shopping.items.isEmpty, shopping.hasRecipeDemands {
                Picker("Ansicht", selection: $grouping) {
                    ForEach(Grouping.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            switch grouping {
            case .aisle: byAisle
            case .recipe: byRecipe
            }
        }
        .sousReadableList()
        // Both, because the ask can arrive either way: from another tab,
        // where this view appears fresh, or from a recipe pushed on top of
        // this very list, where it is already on screen.
        .onAppear { standAt(navigation.shoppingRecipeID, proxy: proxy) }
        .onChange(of: navigation.shoppingRecipeID) { _, id in standAt(id, proxy: proxy) }
        .navigationTitle("Einkaufsliste")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if grouping == .aisle, !storeNames.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Besorgung", selection: $storeFilter) {
                            Text("Alle Besorgungen").tag(String?.none)
                            ForEach(storeNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                    } label: {
                        Label(
                            "Besorgung",
                            systemImage: activeStoreFilter == nil ? "storefront" : "storefront.fill"
                        )
                    }
                    .help("Nach Besorgung filtern")
                }
            }
            if !shopping.checkedItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Erledigte entfernen", systemImage: "trash") {
                        Task { await shopping.clearChecked() }
                    }
                    .labelStyle(.iconOnly)
                    .help("Erledigte entfernen")
                }
            }
        }
        .overlay { emptyState }
        .sousConfirmation(
            "Rezept von der Liste nehmen?",
            isPresented: Binding(presence: $removalCandidate),
            message: removalCandidate.map {
                """
                „\($0.title)“ verschwindet mit allem, was dafür noch offen \
                ist. Abgehaktes bleibt stehen und wird als entfallen vermerkt.
                """
            }
        ) {
            if let entry = removalCandidate {
                Button("Von der Liste nehmen", role: .destructive) {
                    Task { await shopping.remove(planEntry: entry) }
                }
            }
        }
        .task { await shopping.reload() }
        .refreshable { await shopping.reload() }
    }

    /// Grouped for the walk through the store: unassigned lines first so
    /// they surface before the shop, then the aisles, then the folded
    /// pantry. What is already in the basket drops to the bottom.
    @ViewBuilder
    private var byAisle: some View {
        ForEach(openSections, id: \.section) { group in
            Section {
                place(group.items)
            } header: {
                sectionHeader(group.section.title)
            }
        }

        if !checkedErrands.isEmpty {
            Section {
                place(checkedErrands)
            } header: {
                sectionHeader("Erledigt")
            }
        }

        // Standing in one shop, the shelf at home is not on the walk.
        if activeStoreFilter == nil {
            pantrySection
        }
    }

    /// A stretch of the list, one row per thing to buy.
    ///
    /// Varieties used to share a place here: "Tomate 700 g" as a heading that
    /// could not be ticked, with the cocktail tomatoes readable as sub-lines
    /// under it. That was concept §6's grouped entry, and it is given up on
    /// purpose — see the catalog target, decision E.
    ///
    /// What it was for, one place to walk to, the aisle sort already
    /// delivers: two kinds of tomato land next to each other in Gemüse
    /// whether or not a heading says they belong together. What it cost was
    /// a total across things that are not one purchase — mushrooms are the
    /// case that shows it, since "Pilz 350 g" is a sum of Champignons and
    /// Pfifferlinge and you can buy neither of those by that name.
    private func place(_ items: [ShoppingItem], showingSource: Bool = true) -> some View {
        ForEach(items) { item in
            row(item, showingSource: showingSource)
        }
    }

    /// "300 g gegart gewogen" — what an amount says about itself beyond the
    /// number.
    ///
    /// The list bundles across states on purpose: a shop sells one potato,
    /// and 500 g raw plus 300 g cooked is one errand. What it must not do is
    /// swallow the difference, because how much raw yields 300 g cooked is
    /// something nobody here knows — so the fact is handed over and left
    /// there (no yield factor, concept §11).
    private func stateAnnotation(
        _ stated: [(state: IngredientState, quantities: [Quantity])]
    ) -> String? {
        let parts = stated.compactMap { entry -> String? in
            guard let annotation = entry.state.shoppingAnnotation else { return nil }
            let amounts = entry.quantities.map { formatter.string(for: $0) }.joined(separator: " + ")
            return amounts.isEmpty ? nil : "\(amounts) \(annotation)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The open items of every section but the pantry, which keeps its own
    /// checked rows and comes last. With a store filter set, only that
    /// shop's errands remain.
    private var openSections: [(section: ShoppingSection, items: [ShoppingItem])] {
        shopping.bySection.compactMap { group in
            guard group.section != .pantry else { return nil }
            if let store = activeStoreFilter, group.section != .store(store) { return nil }
            let open = group.items.filter { !$0.isChecked }
            return open.isEmpty ? nil : (group.section, open)
        }
    }

    /// The stores the current list mentions, for the filter menu.
    private var storeNames: [String] {
        shopping.bySection.compactMap { group in
            if case .store(let name) = group.section { return name }
            return nil
        }
    }

    /// The filter, unless the store it named has meanwhile left the list —
    /// clearing the last Lidl item must not leave an empty view behind.
    private var activeStoreFilter: String? {
        storeFilter.flatMap { storeNames.contains($0) ? $0 : nil }
    }

    private var checkedErrands: [ShoppingItem] {
        shopping.checkedItems.filter { item in
            guard !shopping.isPantry(item) else { return false }
            guard let store = activeStoreFilter else { return true }
            return shopping.preferredStore(of: item) == store
        }
    }

    /// Pantry staples as a check-through list: open and checked stay in
    /// place here rather than wandering to "Erledigt".
    @ViewBuilder
    private var pantrySection: some View {
        let pantry = shopping.bySection.first { $0.section == .pantry }?.items ?? []
        if !pantry.isEmpty {
            Section {
                if pantryExpanded {
                    place(pantry)
                }
            } header: {
                Button {
                    withAnimation { pantryExpanded.toggle() }
                } label: {
                    HStack {
                        sectionHeader("Vorräte")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(pantryExpanded ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var byRecipe: some View {
        ForEach(shopping.byRecipe) { group in
            Section {
                ForEach(group.blocks) { block in
                    if let subrecipe = block.subrecipe {
                        subrecipeHeadline(subrecipe)
                    }
                    ForEach(block.items) { item in
                        row(item, showingSource: false, indented: block.subrecipe != nil)
                    }
                }
            } header: {
                recipeHeader(for: group)
            }
            // Named so the list can be sent to one dish — see `standAt`.
            .id(group.id)
        }
    }

    /// The heading a resolved subrecipe gets inside its parent's section.
    ///
    /// It is a heading and not a section, because the naan is not a second
    /// dish on the list: its amount comes from the curry's line and its dial
    /// is the curry's. What it needed was a name said once — "aus Naan" under
    /// each of four lines told the same thing four times and still left them
    /// looking like the curry's own.
    ///
    /// Not checkable: what goes in the basket is flour and yeast, one at a
    /// time, and a heading that could be ticked would claim otherwise.
    private func subrecipeHeadline(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
            Text(title)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Aus \(title)")
        .accessibilityAddTraits(.isHeader)
    }

    /// A recipe's heading — with its portion dial, where the entry knows
    /// the scale it was captured at.
    @ViewBuilder
    private func recipeHeader(for group: ShoppingRecipeGroup) -> some View {
        if let planEntry = group.planEntry {
            HStack {
                recipeTitle(group)
                Spacer()
                servingsDial(for: planEntry)
            }
            .contextMenu {
                Button("Rezept von der Liste nehmen", systemImage: "trash", role: .destructive) {
                    Task { await shopping.remove(planEntry: planEntry) }
                }
            }
        } else {
            recipeTitle(group)
        }
    }

    /// The heading, as the way back to the dish underneath it.
    ///
    /// Read by recipe, the list is a set of decisions already taken, and the
    /// question it raises at the shelf — how much of this did it actually
    /// want, and what for — is answered on the recipe page rather than here.
    /// A chevron, because a section heading is not somewhere a tap is
    /// expected to lead anywhere.
    ///
    /// Only where the entry still names a recipe: migrated rows and the
    /// lapsed remains of a removed dish keep the title they were written
    /// with and have nothing to open.
    @ViewBuilder
    private func recipeTitle(_ group: ShoppingRecipeGroup) -> some View {
        if let recipeID = group.planEntry?.recipeID {
            Button {
                Task { await open(recipeID) }
            } label: {
                HStack(spacing: 4) {
                    sectionHeader(group.title)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            sectionHeader(group.title)
        }
    }

    /// Opens the dish this stretch of the list came from — beside the list on
    /// the Mac, pushed over it on the phone.
    ///
    /// Looked up rather than carried along: the list holds the snapshot taken
    /// when the recipe was put on it, and the page has to show the recipe as
    /// it stands now. No plan entry rides along either — the shopping dial is
    /// this list's own scale and has nothing to say about the meal plan's.
    /// A recipe deleted since simply does not open.
    private func open(_ recipeID: UUID) async {
        guard let recipe = await library.recipe(id: recipeID) else { return }
        #if os(macOS)
        selection.recipe = recipe
        selection.plannedEntryID = nil
        #else
        openedRecipe = recipe
        #endif
    }

    /// The portion dial, built by hand rather than taken from `Stepper`.
    ///
    /// At one portion the minus has nothing left to take away — the store
    /// floors the value there, so the press was simply swallowed. What it
    /// means at that point is "then not this recipe either", and the glyph
    /// says so before it is pressed rather than after. `Stepper` has no say
    /// over its two glyphs, which is why it is gone.
    private func servingsDial(for planEntry: ShoppingPlanEntry) -> some View {
        let removes = planEntry.servingsCurrent <= 1
        return HStack(spacing: 8) {
            Text(Servings.text(planEntry.servingsCurrent))
                .font(.caption)
                .monospacedDigit()
                .textCase(nil)
            HStack(spacing: 0) {
                Button {
                    guard !removes else {
                        removalCandidate = planEntry
                        return
                    }
                    Task {
                        await shopping.setServings(
                            planEntry.servingsCurrent - 1, for: planEntry
                        )
                    }
                } label: {
                    dialGlyph(removes ? "trash" : "minus")
                }
                .foregroundStyle(removes ? AnyShapeStyle(Color.sousDanger) : AnyShapeStyle(.tint))
                .accessibilityLabel(
                    removes ? "Rezept von der Liste nehmen" : "Eine Portion weniger"
                )

                Divider().frame(height: 16)

                Button {
                    Task {
                        await shopping.setServings(planEntry.servingsCurrent + 1, for: planEntry)
                    }
                } label: {
                    dialGlyph("plus")
                }
                .accessibilityLabel("Eine Portion mehr")
            }
            .foregroundStyle(.tint)
            .buttonStyle(.plain)
            .background(.quaternary, in: .capsule)
        }
        // The moment the minus turns into a bin is the moment the next press
        // stops being reversible, so the hand is told about it too.
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: removes)
    }

    /// One key of the dial, at a size a thumb can hit in a shop.
    private func dialGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 36, height: 28)
            .contentShape(.rect)
    }

    @ViewBuilder
    private var addRow: some View {
        HStack {
            Image(systemName: "plus.circle")
                .foregroundStyle(.tint)
            TextField("Etwas hinzufügen, z. B. „2 kg Kartoffeln“", text: $newItem)
                .onSubmit(add)
            if !newItem.isEmpty {
                Button("Hinzufügen", systemImage: "return", action: add)
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private func row(
        _ item: ShoppingItem,
        showingSource: Bool,
        // Set under a subrecipe's heading, where the row keeps the
        // ingredient's own name and only moves in under it.
        indented: Bool = false
    ) -> some View {
        // A button rather than a tap gesture: the pointer changes over it,
        // the keyboard reaches it, and the Mac gets the click it expects.
        Button {
            Task { await shopping.toggle(item) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    label(for: item)
                        .strikethrough(item.isChecked)
                    if let annotation = annotation(for: item) {
                        Text(annotation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // What the cook wrote down for the shelf — "die feste
                    // Sorte" — travels with the item wherever it renders.
                    if let shelfNote = shopping.shoppingNote(of: item) {
                        Text(shelfNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if showingSource, let origin = originText(for: item) {
                        Text(origin)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .opacity(item.isChecked ? 0.5 : 1)
            .padding(.leading, indented ? 16 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Ticking is done one-handed in a shop with the eyes on the shelf —
        // the tap should be felt, not checked. And VoiceOver has to hear the
        // difference between bought and still open.
        .sensoryFeedback(.impact(flexibility: .soft), trigger: item.isChecked)
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
        .swipeActions { actions(for: item) }
        // The same actions again, because a swipe needs a trackpad to exist
        // at all and gives no sign that it is there.
        .contextMenu { actions(for: item) }
    }

    @ViewBuilder
    private func actions(for item: ShoppingItem) -> some View {
        if !item.key.isEmpty {
            if shopping.isPantry(item) {
                Button("Kein Vorrat mehr", systemImage: "cabinet") {
                    Task { await shopping.setPantry(false, name: item.name) }
                }
            } else {
                Button("Als Vorrat merken", systemImage: "cabinet") {
                    Task { await shopping.setPantry(true, name: item.name) }
                }
            }
        }
        Button("Entfernen", systemImage: "trash", role: .destructive) {
            Task { await shopping.remove(item) }
        }
    }

    /// What the line says about itself beyond its amount: which part of it a
    /// recipe weighed in a named state, what arrived late, and what lapsed.
    private func annotation(for item: ShoppingItem) -> String? {
        var parts: [String] = []
        if let states = stateAnnotation(item.statedQuantities) {
            parts.append(states)
        }
        if item.isLateAddition {
            parts.append("Nachträglich")
        }
        let lapsed = item.lapsedQuantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        if !lapsed.isEmpty {
            parts.append("− \(lapsed) entfallen")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Two names at most — a staple wanted by five dishes would otherwise
    /// bury the line it belongs to.
    private func originText(for item: ShoppingItem) -> String? {
        let titles = item.originTitles
        guard !titles.isEmpty else { return nil }
        guard titles.count > 2 else { return titles.joined(separator: " · ") }
        return "\(titles[0]) · \(titles[1]) +\(titles.count - 2)"
    }

    /// The amounts lead, in the accent, because that is what is read while
    /// standing in the shop.
    private func label(for item: ShoppingItem) -> Text {
        let amounts = item.quantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        // The catalog's name, not the word a recipe happened to write. A row
        // used to say the written word when it sat under a grouped heading,
        // to show what made it different from its siblings; with no heading
        // above it there is nothing to be different from, and the name the
        // ingredient is known by is the one to look for on a shelf.
        let name = item.name
        guard !amounts.isEmpty else { return Text(name) }
        let amount = Text(amounts).foregroundStyle(.tint).fontWeight(.medium)
        return Text("\(amount) \(name)")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).sousGroupHeader()
    }

    @ViewBuilder
    private var emptyState: some View {
        if shopping.items.isEmpty {
            ContentUnavailableView {
                Label("Nichts einzukaufen", systemImage: "cart")
            } description: {
                Text("Setze ein Rezept oder eine geplante Woche auf die Liste, oder tippe oben etwas ein.")
            }
        }
    }

    private func add() {
        let line = newItem
        newItem = ""
        Task { await shopping.addItem(line) }
    }
}
