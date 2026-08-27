import AppIntents
import CoreSpotlight
import SousKit

// The vision's rule, kept: every capability here is a thin wrapper over a
// function the app already has — `ShoppingLibrary.addItem`, the meal plan's
// day read, `CookSession.start`. Siri, Shortcuts and Spotlight are a second
// surface, never a second implementation.

// MARK: - The recipe, as the system sees it

/// A recipe as Siri, Shortcuts and Spotlight can hold it: the id to fetch
/// by, and enough words to be recognized and displayed. Indexed, so the
/// collection turns up in the system search without the app open.
struct RecipeEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Rezept")
    static let defaultQuery = RecipeEntityQuery()

    let id: UUID
    let title: String
    let categories: [String]

    init(recipe: Recipe) {
        id = recipe.id
        title = recipe.title
        categories = recipe.categories
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: categories.isEmpty ? nil : "\(categories.joined(separator: ", "))"
        )
    }
}

struct RecipeEntityQuery: EntityStringQuery {
    @Dependency private var recipeStore: CoreDataRecipeStore

    func entities(for identifiers: [UUID]) async throws -> [RecipeEntity] {
        var found: [RecipeEntity] = []
        for id in identifiers {
            guard let recipe = try await recipeStore.recipe(id: id), !recipe.isDeleted else { continue }
            found.append(RecipeEntity(recipe: recipe))
        }
        return found
    }

    /// "Koche Chili" — the same search field the list's search runs on,
    /// so whatever a person can find by typing, Siri can find by name.
    func entities(matching string: String) async throws -> [RecipeEntity] {
        try await recipeStore.recipes(matching: RecipeQuery(searchText: string))
            .map(RecipeEntity.init)
    }

    /// What Siri offers before anything is typed: the recipes the cook
    /// already said they feel like eating.
    func suggestedEntities() async throws -> [RecipeEntity] {
        try await recipeStore.recipes(matching: RecipeQuery(onlyWantToCook: true))
            .prefix(8)
            .map(RecipeEntity.init)
    }
}

// MARK: - Intents

/// "Setz Butter auf die Einkaufsliste" — the one most worth saying out
/// loud, because it is said with both hands in the dough.
struct AddToShoppingListIntent: AppIntent {
    static let title: LocalizedStringResource = "Auf die Einkaufsliste setzen"
    static let description = IntentDescription("Setzt etwas auf die Einkaufsliste — mit Menge, wenn du eine sagst.")

    @Parameter(title: "Was", requestValueDialog: "Was soll auf die Einkaufsliste?")
    var item: String

    @Dependency private var shopping: ShoppingLibrary

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            throw $item.needsValueError("Was soll auf die Einkaufsliste?")
        }
        // The same entry the list's own field takes: amounts in the words
        // are parsed, and the same wording merges into one row.
        await shopping.addItem(line)
        return .result(dialog: "\(line) steht auf der Einkaufsliste.")
    }
}

/// "Was gibt es heute?" — the plan's answer, spoken.
struct TodaysPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Was gibt es heute?"
    static let description = IntentDescription("Sagt dir, was für heute geplant ist.")

    @Dependency private var plan: MealPlanLibrary

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await plan.reload()
        let meals = plan.meals(for: Date())
        let parts = meals.compactMap { meal -> String? in
            let titles = meal.items.compactMap { $0.recipe?.title }
            guard !titles.isEmpty else { return nil }
            return "\(meal.slot.title): \(titles.joined(separator: ", "))"
        }
        guard !parts.isEmpty else {
            return .result(dialog: "Für heute ist nichts geplant.")
        }
        return .result(dialog: "\(parts.joined(separator: ". "))")
    }
}

/// "Koche die Ajvar-Suppe" — puts the recipe on the hob and opens cook
/// mode on it, exactly like the page's own button.
struct StartCookingIntent: AppIntent {
    static let title: LocalizedStringResource = "Rezept kochen"
    static let description = IntentDescription("Öffnet den Kochmodus mit einem Rezept.")
    static let openAppWhenRun = true

    @Parameter(title: "Rezept")
    var recipe: RecipeEntity

    @Dependency private var recipeStore: CoreDataRecipeStore
    @Dependency private var session: CookSession

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let full = try await recipeStore.recipe(id: recipe.id),
              !full.isDeleted, !full.steps.isEmpty
        else {
            throw SousIntentError.nothingToCook
        }
        session.start(full, servings: full.servings)
        return .result()
    }
}

/// Opens a recipe's page — what tapping a Spotlight hit means.
struct OpenRecipeIntent: AppIntent, OpenIntent {
    static let title: LocalizedStringResource = "Rezept öffnen"

    @Parameter(title: "Rezept")
    var target: RecipeEntity

    @Dependency private var recipeStore: CoreDataRecipeStore
    @Dependency private var navigation: SousNavigation
    @Dependency private var selection: RecipeSelection

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let full = try await recipeStore.recipe(id: target.id), !full.isDeleted else {
            throw SousIntentError.recipeGone
        }
        navigation.section = .recipes
        selection.target = .recipe(full)
        return .result()
    }
}

/// The Control-Center-sized action: straight to the list, one hand on the
/// trolley.
struct OpenShoppingListIntent: AppIntent {
    static let title: LocalizedStringResource = "Einkaufsliste öffnen"
    static let openAppWhenRun = true

    @Dependency private var navigation: SousNavigation

    @MainActor
    func perform() async throws -> some IntentResult {
        navigation.section = .shopping
        return .result()
    }
}

enum SousIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToCook
    case recipeGone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToCook: "Das Rezept hat keine Zubereitungsschritte."
        case .recipeGone: "Das Rezept gibt es nicht mehr."
        }
    }
}

// MARK: - The phrases

/// What Siri, Spotlight and the Shortcuts app offer without any setup.
struct SousAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // No parameter in the phrase: a free-text parameter may not ride in
        // an App Shortcut phrase (entities and enums only), so Siri asks
        // "Was soll auf die Einkaufsliste?" as its own turn instead.
        AppShortcut(
            intent: AddToShoppingListIntent(),
            phrases: [
                "Setz etwas in \(.applicationName) auf die Einkaufsliste",
                "Schreib etwas auf die \(.applicationName) Einkaufsliste",
            ],
            shortTitle: "Auf die Einkaufsliste",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: TodaysPlanIntent(),
            phrases: [
                "Was gibt es heute in \(.applicationName)",
                "Was koche ich heute in \(.applicationName)",
            ],
            shortTitle: "Was gibt es heute?",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: StartCookingIntent(),
            phrases: [
                "Koche \(\.$recipe) mit \(.applicationName)",
                "Starte \(\.$recipe) in \(.applicationName)",
            ],
            shortTitle: "Rezept kochen",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: OpenShoppingListIntent(),
            phrases: [
                "Öffne die Einkaufsliste in \(.applicationName)",
                "Zeig mir die \(.applicationName) Einkaufsliste",
            ],
            shortTitle: "Einkaufsliste öffnen",
            systemImageName: "cart"
        )
    }
}
