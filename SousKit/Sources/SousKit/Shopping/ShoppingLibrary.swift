import Foundation
import Observation

/// A place on the list as the aisle view walks it.
public enum ShoppingSection: Hashable, Sendable {
    /// Raw-text lines the app could not interpret — at the very top, so
    /// they surface before the store, not in it.
    case unassigned
    case aisle(IngredientCategory)
    /// Pantry staples, collapsed at the end: checked against the shelf,
    /// not hunted through the store.
    case pantry

    public var title: String {
        switch self {
        case .unassigned: "Nicht zugeordnet"
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts a recipe's ingredients on the list, at the servings it is being
    /// cooked for. Linked recipes contribute what they are made of.
    public func add(_ recipe: Recipe, servings: Int? = nil) async {
        await add([(recipe, servings ?? recipe.servings)], describing: recipe.title)
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

            try await store.add(capture)
            await reload()
            lastAddition = description
        } catch {
            errorMessage = error.localizedDescription
        }
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
    /// first, so they surface before the shop; then the aisles in walking
    /// order; pantry staples collected at the end.
    public var bySection: [(section: ShoppingSection, items: [ShoppingItem])] {
        var unassigned: [ShoppingItem] = []
        var pantry: [ShoppingItem] = []
        var aisles: [IngredientCategory: [ShoppingItem]] = [:]

        for item in items {
            if pantryKeys.contains(item.key) {
                pantry.append(item)
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
        case .aisle(let category): category.aisleOrder
        case .pantry: .max
        }
    }
}
