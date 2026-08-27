import CryptoKit
import Foundation
import FoundationModels

/// What role a dish plays at the table — the one judgment the model is
/// asked for. A closed set of roles rather than three independent booleans:
/// "is this a component or a meal" is a single categorical question the
/// small model answers far more reliably than three separate yes/nos, and
/// which meals a role covers is then a fact this code states, not something
/// the model decides anew per recipe.
@Generable
enum DishRole: String, Equatable, Sendable {
    /// A savory dish eaten as the meal itself: Eintopf, Auflauf, Curry,
    /// pasta, a soup, a meal-sized salad.
    case savoryMain
    /// A sweet dish that is nonetheless the meal: Kaiserschmarrn,
    /// Milchreis, Pfannkuchen, Germknödel.
    case sweetMain
    /// Eaten in the morning: Porridge, Müsli, Overnight Oats, Rührei.
    case breakfastDish
    /// Cake, cookies, dessert — eaten beside or after a meal, never as one.
    case sweetTreat
    /// A part of a dish, not a dish: sauce, dip, spread, dough, stock,
    /// side, spice mix, preserve.
    case component
    case drink
}

extension DishRole {
    /// Which meals the role covers. Stated here once, in code — the model
    /// names the role, this table names the meals.
    var slots: Set<MealSlot> {
        switch self {
        case .savoryMain, .sweetMain: [.lunch, .dinner]
        case .breakfastDish: [.breakfast]
        case .sweetTreat, .component, .drink: []
        }
    }
}

@Generable
struct MealSuitabilityJudgment: Equatable, Sendable {
    @Guide(description: "Welche Rolle dieses Gericht bei Tisch spielt — eine vollwertige Mahlzeit, oder etwas, das nur neben oder in einer Mahlzeit vorkommt")
    var role: DishRole
}

public enum MealSuitabilityError: Error, LocalizedError {
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Auf diesem Gerät nicht verfügbar."
        }
    }
}

/// Guesses which meals a recipe suits, for recipes whose
/// ``Recipe/suitableSlots`` nobody has set. The same division of labour as
/// ``AmountAIExtractor``: this is genuinely a question about language and
/// the world — nothing in "Porridge mit Beeren" says breakfast except
/// knowing what porridge is — so it goes to the model, once per recipe,
/// and the answer is cached in ``RecipeEnrichmentStore`` until the words
/// it was derived from change. The guess never touches the recipe itself;
/// an explicit choice in the editor always outranks it.
public enum MealSuitabilityClassifier {
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static func classify(_ recipe: Recipe) async throws -> Set<MealSlot> {
        try await role(for: recipe).slots
    }

    /// The model's single judgment, exposed for the sparring bench.
    static func role(for recipe: Recipe) async throws -> DishRole {
        guard isAvailable else { throw MealSuitabilityError.modelUnavailable }

        let instructions = """
        Du ordnest ein Rezept aus einer deutschen Rezeptsammlung genau \
        einer Rolle zu. Entscheidend ist, ob das Gericht selbst die \
        Mahlzeit ist oder nur neben oder in einer Mahlzeit vorkommt:

        - savoryMain: ein herzhaftes Gericht, das als Mittag- oder \
        Abendessen auf den Tisch kommt — Eintopf, Suppe, Auflauf, Curry, \
        Pasta, Pfannengericht, belegtes Brot als Mahlzeit, großer Salat.
        - sweetMain: eine süße Hauptspeise, die trotzdem die Mahlzeit ist — \
        Kaiserschmarrn, Milchreis, Pfannkuchen, Germknödel.
        - breakfastDish: wird morgens gegessen — Porridge, Müsli, \
        Overnight Oats, Rührei, Frühstücksbrei.
        - sweetTreat: Kuchen, Torte, Brownies, Kekse, Dessert, Eis — wird \
        zum Kaffee oder nach dem Essen gegessen, ist aber selbst keine \
        Mahlzeit.
        - component: ein Bestandteil, kein Gericht — Soße, Pesto, Dip, \
        Aufstrich, Dressing, Teig, Fond, Gewürzmischung, Marmelade, \
        Beilage wie Knödel oder Rotkohl.
        - drink: Getränk, Smoothie, Sirup.

        Die Probe: Würde jemand sagen "heute gibt es X zum Abendessen" und \
        nichts weiter dazu? Bei Brownies, Pesto oder einem Dressing nein — \
        die begleiten etwas. Bei einem Eintopf oder Kaiserschmarrn ja. \
        Ein süßes Rezept ist nur dann sweetMain, wenn es sättigend als \
        ganze Mahlzeit gegessen wird; Gebäck und Desserts sind sweetTreat. \
        Du beurteilst das Gericht als Ganzes, nicht einzelne Zutaten.
        """
        let ingredientNames = recipe.ingredients
            .map(\.name)
            .prefix(25)
            .joined(separator: ", ")
        let categories = recipe.categories.joined(separator: ", ")
        let prompt = """
        Rezept: \(recipe.title)
        \(categories.isEmpty ? "" : "Kategorien: \(categories)\n")\
        \(ingredientNames.isEmpty ? "" : "Zutaten: \(ingredientNames)\n")\

        Welche Rolle spielt dieses Gericht bei Tisch?
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: MealSuitabilityJudgment.self,
            options: GenerationOptions(temperature: 0)
        )
        return response.content.role
    }

    /// What the guess was derived from, hashed — title, categories and
    /// ingredient names, not the instructions: renaming "Brei" to
    /// "Bratreis" changes what the dish is, rewriting step three does not.
    /// The version covers the prompt too — v2 when the boolean question
    /// became the role question, so every old guess re-runs.
    static func inputHash(for recipe: Recipe) -> String {
        let names = recipe.ingredients.map(\.name).joined(separator: "|")
        let input = "v2|\(recipe.title)|\(recipe.categories.joined(separator: "|"))|\(names)"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
