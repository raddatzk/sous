import Foundation
import Observation

/// A place on the list as the aisle view walks it.
public enum ShoppingSection: Hashable, Sendable {
    /// Raw-text lines the app could not interpret — at the very top, so
    /// they surface before the store, not in it.
    case unassigned
    /// Everything bought at one particular shop, ahead of the aisle walk —
    /// the cook said where these live, so they are not hunted through the
    /// default store's aisles.
    case store(String)
    case aisle(IngredientCategory)
    /// Pantry staples, collapsed at the end: checked against the shelf,
    /// not hunted through the store.
    case pantry

    public var title: String {
        switch self {
        case .unassigned: "Nicht zugeordnet"
        case .store(let name): name
        case .aisle(let category): category.title
        case .pantry: "Vorräte"
        }
    }
}

/// One place on the shopping list: an ingredient, together with the
/// varieties of it that are also wanted.
///
/// The concept's grouped entry (§6), and the answer to the brief's "Tomaten
/// and Cocktailtomaten — one line": one place to walk to, with the
/// distinction intact underneath. Taken literally, a single summed line would
/// send the cook home with the wrong tomatoes.
public struct ShoppingGroup: Identifiable, Hashable, Sendable {
    /// The parent ingredient's key, or the item's own where it has no parent.
    public var id: String
    /// What the place is called — the parent's name.
    public var name: String
    /// Its rows, each still its own checkable item.
    public var items: [ShoppingItem]
    /// Whether anything is actually being held apart. `false` is the ordinary
    /// single row, which must keep looking exactly as it always did.
    public var isGrouped: Bool

    public init(id: String, name: String, items: [ShoppingItem], isGrouped: Bool) {
        self.id = id
        self.name = name
        self.items = items
        self.isGrouped = isGrouped
    }

    /// Everything wanted across the group, bundled unit by unit — the total
    /// the header line shows. Only equal units are added up, as everywhere.
    public var quantities: [Quantity] {
        items.reduce(into: [Quantity]()) { $0 = $0.adding($1.quantities) }
    }

    /// The same annotation an item carries, summed across the varieties that
    /// share this place on the list — see ``ShoppingItem/statedQuantities``.
    /// The heading has to say it too: it is the line that shows the total, so
    /// it is the line where "300 g of that was weighed cooked" belongs.
    public var statedQuantities: [(state: IngredientState, quantities: [Quantity])] {
        IngredientState.displayOrder.compactMap { state in
            let quantities = items
                .flatMap { $0.statedQuantities.filter { $0.state == state }.flatMap(\.quantities) }
                .reduce(into: [Quantity]()) { $0 = $0.adding($1) }
            return quantities.isEmpty ? nil : (state, quantities)
        }
    }

    public var isChecked: Bool { items.allSatisfy(\.isChecked) }
}

/// One section of the by-recipe view: a plan entry with its portion dial,
/// a frozen origin without one, or the hand-typed rest.
public struct ShoppingRecipeGroup: Identifiable, Sendable {
    public var id: String
    /// Set for recipes added since the list became a document — the portion
    /// stepper only exists where this is present.
    public var planEntry: ShoppingPlanEntry?
    public var title: String
    /// Each row carries only this group's share of its item, so an
    /// ingredient two dishes need appears under both with its own amount.
    public var items: [ShoppingItem]

    /// The section read as what asks for what: the dish's own lines first,
    /// then one block per subrecipe a link resolved into it.
    ///
    /// A subrecipe is not a section of its own — it has no plan entry and no
    /// dial, because the amount of naan is something the curry's line says
    /// and the curry's dial scales. What it does have is a name worth saying
    /// once, above its lines, rather than repeating "aus Naan" under every
    /// one of them.
    ///
    /// An ingredient both the dish and its subrecipe want appears in both
    /// blocks with its own share. That is the point of this reading: the
    /// aisle view is where the two become one errand.
    public var blocks: [ShoppingRecipeBlock] {
        let subrecipes = subrecipeTitles
        // Nothing was pulled in — the common case, and the rows are handed
        // on exactly as they came, manual top-ups and all.
        guard !subrecipes.isEmpty else {
            return [ShoppingRecipeBlock(id: "\(id):own", subrecipe: nil, items: items)]
        }

        var result: [ShoppingRecipeBlock] = []
        let own = items.compactMap { item -> ShoppingItem? in
            // A row with no demands at all belongs to no recipe and is not
            // split by one.
            guard !item.demands.isEmpty else { return item }
            return item.keeping { isOwn($0) }
        }
        if !own.isEmpty {
            result.append(ShoppingRecipeBlock(id: "\(id):own", subrecipe: nil, items: own))
        }
        for title in subrecipes {
            let rows = items.compactMap { item in
                item.keeping { $0.originTitle == title }
            }
            result.append(ShoppingRecipeBlock(id: "\(id):sub:\(title)", subrecipe: title, items: rows))
        }
        return result
    }

    /// The subrecipes this section's rows read as coming from, each named
    /// once, in the order they first appear.
    private var subrecipeTitles: [String] {
        var seen = Set<String>()
        return items.flatMap(\.demands).compactMap { demand in
            guard !isOwn(demand), seen.insert(demand.originTitle).inserted else { return nil }
            return demand.originTitle
        }
    }

    /// Whether a demand reads as the dish's own. An origin nobody wrote is
    /// the dish's, not a nameless subrecipe's.
    private func isOwn(_ demand: ShoppingDemand) -> Bool {
        demand.originTitle.isEmpty || demand.originTitle == title
    }
}

/// A stretch of one dish's rows that reads as coming from one place.
public struct ShoppingRecipeBlock: Identifiable, Sendable {
    public var id: String
    /// The subrecipe the lines came from, or `nil` for the dish's own.
    public var subrecipe: String?
    public var items: [ShoppingItem]
}

extension ShoppingItem {
    /// The row narrowed to the demands that pass — `nil` where none do.
    ///
    /// Hand-typed amounts stay out of a narrowed row: they belong to no
    /// recipe line, so any split by origin would have to invent a place for
    /// them, and the by-recipe view already gives them one of their own.
    fileprivate func keeping(_ isIncluded: (ShoppingDemand) -> Bool) -> ShoppingItem? {
        let share = demands.filter(isIncluded)
        guard !share.isEmpty else { return nil }
        var row = self
        row.demands = share
        row.manualQuantities = []
        return row
    }
}

/// The view-facing shopping list.
///
/// The list is a document; nothing changes it but adding, ticking, turning
/// a plan entry's portion dial, and sweeping. Recipes and whole weeks are
/// put on it deliberately.
@MainActor
@Observable
public final class ShoppingLibrary {
    private let store: any ShoppingListStore
    private let recipeStore: any RecipeStore
    /// Kept so that ingredients the cook added resolve like the bundled ones
    /// — and because the pantry flag lives on their vocabulary entry now.
    private let catalogLibrary: IngredientCatalogLibrary?

    /// Every line still on the list, swept rows already left out.
    public private(set) var items: [ShoppingItem] = []
    public private(set) var planEntries: [ShoppingPlanEntry] = []
    /// Whether the list has ever been read. An empty list and a list not yet
    /// read look the same from outside, and they are not the same answer.
    public private(set) var hasLoaded = false
    public var errorMessage: String?
    /// Set after something was added, so the interface can say what happened.
    public var lastAddition: String?

    public init(
        store: any ShoppingListStore,
        recipeStore: any RecipeStore,
        catalogLibrary: IngredientCatalogLibrary? = nil
    ) {
        self.store = store
        self.recipeStore = recipeStore
        self.catalogLibrary = catalogLibrary
    }

    /// Which ingredients are shelf staples — read straight off the
    /// vocabulary, so the flag and everything else about an ingredient say
    /// the same thing at the same moment.
    public var pantryKeys: Set<String> { catalogLibrary?.pantryKeys ?? [] }

    private var catalog: IngredientCatalog {
        catalogLibrary?.catalog ?? .bundled
    }

    public func reload() async {
        do {
            await catalogLibrary?.ensureLoaded()
            let snapshot = try await store.snapshot()
            items = snapshot.items.filter { !$0.isCleared }
            planEntries = snapshot.planEntries
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the list once, for a screen that asks a question about it
    /// without being the screen that shows it.
    ///
    /// The recipe page needs to know whether the recipe it is showing is
    /// already on the list, and until the list has been opened at least once
    /// `planEntries` is empty for want of a read rather than for want of
    /// errands. A failed read leaves the flag down, so the next screen to
    /// ask tries again.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// Puts a recipe's ingredients on the list, at the servings it is being
    /// cooked for. Linked recipes contribute what they are made of.
    ///
    /// `lines` narrows it to some of the recipe's ingredient lines, named by
    /// `RecipeIngredient.id`; `nil` — the default — is the whole recipe. The
    /// picked lines become the capture, and that is the whole of it: the
    /// portion dial on the list scales the demands it finds and never reads
    /// the recipe again, so what was left out stays left out however far the
    /// dial is turned afterwards.
    public func add(_ recipe: Recipe, servings: Int? = nil, lines: Set<UUID>? = nil) async {
        let servings = servings ?? recipe.servings
        do {
            var known: [UUID: Recipe] = [recipe.id: recipe]
            try await resolveLinks(of: recipe, into: &known)
            let capture = ShoppingListBuilder.build(
                from: recipe,
                servings: servings,
                selecting: lines,
                catalog: catalog
            ) { known[$0] }
            try await commit(capture, describing: recipe.title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds picked lines to a dish the list already carries, instead of
    /// putting the recipe on a second time.
    ///
    /// The way back from "ich habe beim Hinzufügen was abgewählt". A second
    /// add would give the dish a second heading and a second portion dial,
    /// and the cook would then be turning one of two halves of the same
    /// meal — so the lines join the entry that is already there.
    ///
    /// Captured at *that* entry's portion count rather than at whatever the
    /// recipe page happens to be showing: everything under one dial has to
    /// be captured at the same count, or the lines that arrived late would
    /// grow at a different rate than the rest of the dish.
    public func add(_ recipe: Recipe, lines: Set<UUID>, joining planEntry: ShoppingPlanEntry) async {
        guard !lines.isEmpty else { return }
        do {
            var known: [UUID: Recipe] = [recipe.id: recipe]
            try await resolveLinks(of: recipe, into: &known)
            let capture = ShoppingListBuilder.build(
                from: recipe,
                servings: planEntry.servingsCaptured,
                selecting: lines,
                catalog: catalog
            ) { known[$0] }
            // The builder always makes an entry — it has no notion of a list
            // that already exists. Dropping it and re-pointing its demands is
            // what turns the capture into an addition to the dish on the
            // list: one heading, one dial, more under it than before.
            let joined = ShoppingCapture(
                planEntries: [],
                demands: capture.demands.map { captured in
                    var captured = captured
                    captured.demand.planEntryID = planEntry.id
                    return captured
                }
            )
            try await commit(joined, describing: recipe.title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts everything planned for a set of days on the list.
    public func add(planned: [(recipe: Recipe, servings: Int)], describing description: String) async {
        await add(planned, describing: description)
    }

    private func add(_ planned: [(Recipe, Int)], describing description: String) async {
        do {
            var known: [UUID: Recipe] = [:]
            for entry in planned {
                known[entry.0.id] = entry.0
                try await resolveLinks(of: entry.0, into: &known)
            }

            let capture = ShoppingListBuilder.build(
                from: planned.map { (recipe: $0.0, servings: $0.1) },
                catalog: catalog
            ) { known[$0] }

            try await commit(capture, describing: description)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes a capture and lets the list catch up.
    private func commit(_ capture: ShoppingCapture, describing description: String) async throws {
        try await store.add(capture)
        await reload()
        lastAddition = description
    }

    /// Follows links a level at a time so the builder can resolve them.
    private func resolveLinks(of recipe: Recipe, into known: inout [UUID: Recipe], depth: Int = 0) async throws {
        guard depth < 3 else { return }
        for id in recipe.linkedRecipeIDs where known[id] == nil {
            guard let linked = try await recipeStore.recipe(id: id) else { continue }
            known[id] = linked
            try await resolveLinks(of: linked, into: &known, depth: depth + 1)
        }
    }

    /// Adds a line typed by hand, parsed like an ingredient so "2 kg
    /// Kartoffeln" arrives with its amount.
    public func addItem(_ line: String) async {
        let ingredient = IngredientParser.parseLine(line)
        let name = ShoppingItem.displayName(for: ingredient.name)
        guard !name.isEmpty else { return }

        let known = catalog.ingredient(for: name)
        do {
            try await store.addManual(
                key: ShoppingItem.key(for: ingredient.name, catalog: catalog),
                name: known?.name ?? name,
                category: known?.category,
                quantities: ingredient.quantity.map { [$0] } ?? []
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggle(_ item: ShoppingItem) async {
        do {
            try await store.setChecked(!item.isChecked, itemID: item.itemID)
            // Checking freezes amounts and un-checking hands them back to
            // the stepper, so the whole list is re-read rather than patched.
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func remove(_ item: ShoppingItem) async {
        do {
            try await store.remove(itemID: item.itemID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Turns a plan entry's portion dial. Everything open adjusts in place;
    /// everything checked keeps its size, with differences appended and
    /// lapses annotated.
    public func setServings(_ servings: Int, for planEntry: ShoppingPlanEntry) async {
        do {
            try await store.setServings(servings, planEntryID: planEntry.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Takes a recipe off the list. Open demand disappears; on checked
    /// items it is annotated as lapsed rather than deleted.
    public func remove(planEntry: ShoppingPlanEntry) async {
        do {
            try await store.removePlanEntry(planEntry.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Whether `recipeID` still has anything unbought on the list.
    ///
    /// Not simply "is there a plan entry for it". The entry outlives the
    /// shopping on purpose — it is what lets the same recipe added a second
    /// time have its new demands marked as arriving late — and it is never
    /// deleted except by taking the recipe off the list by hand. Read off the
    /// entry alone, "already on the list" stayed true for a recipe whose last
    /// line had been ticked off weeks ago, and stayed true after "Abgehaktes
    /// entfernen" for one the list no longer showed anywhere at all.
    ///
    /// Ticked-off counts as done rather than as present: everything bought is
    /// the errand finished, and the button that offers the list should go
    /// back to offering it.
    public func hasOpenDemand(forRecipe recipeID: UUID) -> Bool {
        !openEntryIDs(ofRecipe: recipeID).isEmpty
    }

    /// The entry a recipe is being carried by right now, or `nil` where the
    /// list has nothing outstanding for it.
    ///
    /// What a second add joins instead of putting the dish on again. The
    /// newest one where a recipe somehow got on twice — that is the entry
    /// the cook was last looking at, and the one the list shows last.
    public func openPlanEntry(forRecipe recipeID: UUID) -> ShoppingPlanEntry? {
        let open = openEntryIDs(ofRecipe: recipeID)
        return planEntries
            .filter { open.contains($0.id) }
            .max { $0.addedAt < $1.addedAt }
    }

    /// Which lines of the recipe behind `planEntry` the list already carries,
    /// named the way a picker names them: by ``RecipeIngredient/id``.
    ///
    /// Bought counts as carried. The line is on the list either way, and a
    /// picker that offered it again as though it were missing would be
    /// describing a list the cook is not looking at.
    public func listedLines(of planEntry: ShoppingPlanEntry) -> Set<UUID> {
        var lines: Set<UUID> = []
        for item in items {
            for demand in item.demands where demand.planEntryID == planEntry.id {
                if let lineID = demand.lineID { lines.insert(lineID) }
            }
        }
        return lines
    }

    /// The recipe's entries the list still shows something unbought under.
    private func openEntryIDs(ofRecipe recipeID: UUID) -> Set<UUID> {
        let entries = Set(planEntries.filter { $0.recipeID == recipeID }.map(\.id))
        guard !entries.isEmpty else { return [] }
        // `items` already leaves out what "Abgehaktes entfernen" cleared, so
        // the only question left is which of what remains is open.
        var open: Set<UUID> = []
        for item in items where !item.isChecked {
            for demand in item.demands {
                if let id = demand.planEntryID, entries.contains(id) { open.insert(id) }
            }
        }
        return open
    }

    public func clearChecked() async {
        do {
            try await store.clearChecked()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pantry

    public func isPantry(_ item: ShoppingItem) -> Bool {
        pantryKeys.contains(item.key) || groupIngredient(of: item).map {
            pantryKeys.contains($0.key)
        } == true
    }

    /// Loads the vocabulary without touching the list — for screens that
    /// only ask about the flag.
    public func ensurePantryLoaded() async {
        await catalogLibrary?.ensureLoaded()
    }

    /// The cook's call that an ingredient is a shelf staple — set from the
    /// ingredient form or straight on the list item.
    public func setPantry(_ flagged: Bool, name: String) async {
        await catalogLibrary?.setPantry(flagged, name: name)
    }

    // MARK: - Stores

    /// Where `item` is bought, when the cook said — its own entry first,
    /// then the ingredient it is a variety of, the same reach `isPantry`
    /// has: a store named on "Tofu" covers the Räuchertofu on the list.
    public func preferredStore(of item: ShoppingItem) -> String? {
        let stores = catalogLibrary?.preferredStores ?? [:]
        if let store = stores[item.key] { return store }
        return groupIngredient(of: item).flatMap { stores[$0.key] }
    }

    /// What to know at the shelf for `item`, same lookup as its store.
    public func shoppingNote(of item: ShoppingItem) -> String? {
        guard let vocabulary = catalogLibrary?.vocabulary else { return nil }
        if let note = vocabulary[item.key]?.shoppingNote { return note }
        return groupIngredient(of: item).flatMap { vocabulary[$0.key]?.shoppingNote }
    }

    // MARK: - Varieties

    /// The ingredient an item bundles under: itself, or the one it is a
    /// variety of.
    private func groupIngredient(of item: ShoppingItem) -> CatalogIngredient? {
        catalog.groupIngredient(for: item.name)
    }

    /// The items of one stretch of the list as the *places* they occupy.
    ///
    /// Varieties share a place with the ingredient they are varieties of —
    /// the concept's grouped entry: one line to find in the shop, and the
    /// distinction still readable underneath it. Anything without varieties
    /// in play comes back as a group of one, which renders exactly as a plain
    /// row always did.
    public func grouped(_ items: [ShoppingItem]) -> [ShoppingGroup] {
        var order: [String] = []
        var byGroup: [String: [ShoppingItem]] = [:]
        var names: [String: String] = [:]
        for item in items {
            let parent = groupIngredient(of: item)
            let key = parent?.key ?? item.key
            if byGroup[key] == nil {
                order.append(key)
                names[key] = parent?.name ?? item.name
            }
            byGroup[key, default: []].append(item)
        }
        return order.map { key in
            let members = byGroup[key] ?? []
            return ShoppingGroup(
                id: key,
                name: names[key] ?? key,
                items: members,
                // A single item under its own name is not a group, however
                // the display renders it: nothing is being held apart.
                isGrouped: members.count > 1 || members.first.map { $0.key != key } == true
            )
        }
    }

    // MARK: - Readings

    public var openItems: [ShoppingItem] { items.filter { !$0.isChecked } }
    public var checkedItems: [ShoppingItem] { items.filter(\.isChecked) }

    /// Whether any line came from a recipe — what makes the by-recipe view
    /// worth offering.
    public var hasRecipeDemands: Bool {
        !planEntries.isEmpty || items.contains { !$0.demands.isEmpty }
    }

    /// The list grouped for the walk through the store: raw-text lines
    /// first, so they surface before the shop; then one section per named
    /// store, since those errands happen somewhere else entirely; then the
    /// aisles in walking order; pantry staples collected at the end.
    public var bySection: [(section: ShoppingSection, items: [ShoppingItem])] {
        var unassigned: [ShoppingItem] = []
        var pantry: [ShoppingItem] = []
        var stores: [String: [ShoppingItem]] = [:]
        var aisles: [IngredientCategory: [ShoppingItem]] = [:]

        for item in items {
            if pantryKeys.contains(item.key) {
                pantry.append(item)
            } else if let store = preferredStore(of: item) {
                stores[store, default: []].append(item)
            } else if let category = item.category {
                aisles[category, default: []].append(item)
            } else {
                unassigned.append(item)
            }
        }

        var sections: [(section: ShoppingSection, items: [ShoppingItem])] = []
        if !unassigned.isEmpty {
            sections.append((.unassigned, unassigned))
        }
        sections.append(contentsOf: stores
            .map { name, items in
                // Inside one shop the aisle walk applies just the same.
                (section: ShoppingSection.store(name), items: items.sorted {
                    ($0.category?.aisleOrder ?? -1, $0.name) < ($1.category?.aisleOrder ?? -1, $1.name)
                })
            }
            .sorted { $0.section.title.localizedCompare($1.section.title) == .orderedAscending })
        sections.append(contentsOf: aisles
            .map { (section: ShoppingSection.aisle($0.key), items: $0.value) }
            .sorted { $0.section.aisleOrder < $1.section.aisleOrder })
        if !pantry.isEmpty {
            sections.append((.pantry, pantry))
        }
        return sections
    }

    /// The heading for items that belong to no recipe.
    public static let ungroupedTitle = "Sonstiges"

    /// The list grouped by the dish that wants it: plan entries first, each
    /// with its portion dial; then frozen origins the migration carried
    /// over; then what was typed by hand.
    public var byRecipe: [ShoppingRecipeGroup] {
        var groups: [ShoppingRecipeGroup] = []

        for planEntry in planEntries {
            let rows = share(of: planEntry.id)
            guard !rows.isEmpty else { continue }
            groups.append(ShoppingRecipeGroup(
                id: planEntry.id.uuidString,
                planEntry: planEntry,
                title: planEntry.title,
                items: rows
            ))
        }

        // Demands without a plan entry — migrated rows and lapsed remains —
        // still read as coming from their recipe, just without a dial.
        var frozenOrder: [String] = []
        var frozen: [String: [ShoppingItem]] = [:]
        for item in items {
            let orphans = item.demands.filter { $0.planEntryID == nil }
            for title in orderedTitles(of: orphans) {
                if frozen[title] == nil {
                    frozenOrder.append(title)
                }
                var row = item
                row.demands = orphans.filter { $0.originTitle == title }
                row.manualQuantities = []
                frozen[title, default: []].append(row)
            }
        }
        for title in frozenOrder {
            groups.append(ShoppingRecipeGroup(
                id: "frozen:\(title)",
                planEntry: nil,
                title: title,
                items: frozen[title] ?? []
            ))
        }

        let manual = items.compactMap { item -> ShoppingItem? in
            guard !item.manualQuantities.isEmpty || item.demands.isEmpty else { return nil }
            // Belongs to no dish, so it is grouped by that fact rather than
            // by where it came from. A line that came from a recipe *and*
            // was topped up by hand appears in both places.
            var row = item
            row.demands = []
            return row
        }
        if !manual.isEmpty {
            groups.append(ShoppingRecipeGroup(
                id: "manual",
                planEntry: nil,
                title: Self.ungroupedTitle,
                items: manual
            ))
        }
        return groups
    }

    /// Each item's share of one plan entry, one row per item in list order.
    private func share(of planEntryID: UUID) -> [ShoppingItem] {
        items.compactMap { item in
            let share = item.demands.filter { $0.planEntryID == planEntryID }
            guard !share.isEmpty else { return nil }
            var row = item
            row.demands = share
            row.manualQuantities = []
            return row
        }
    }

    private func orderedTitles(of demands: [ShoppingDemand]) -> [String] {
        var seen = Set<String>()
        return demands.compactMap { demand in
            guard seen.insert(demand.originTitle).inserted else { return nil }
            return demand.originTitle
        }
    }
}

extension ShoppingSection {
    /// Walking order of the aisle view; the special sections bracket it.
    fileprivate var aisleOrder: Int {
        switch self {
        case .unassigned: -1
        // Store sections sit with the unassigned lines ahead of the walk;
        // among themselves they sort by name, which `bySection` does
        // explicitly — this order never has to separate two of them.
        case .store: -1
        case .aisle(let category): category.aisleOrder
        case .pantry: .max
        }
    }
}
