import Foundation

/// Brings a recipe a model rewrote into the form Sous reads best.
///
/// An edit asks the model for the lines in the fixed form already, and good
/// models deliver it. Where every line is in form and the steps' references
/// are current, nothing more is asked. Where not, the optimizer runs over
/// the *edited* recipe: against it, amounts and ingredients are fixed and only
/// the tidying is allowed, which is the strictness the optimizer has. Run
/// against the original it would refuse every change the cook asked for.
public enum RecipeTidier {
    /// What tidying makes of `recipe`: `nil` where it is in form already,
    /// else the recipe with the lines the optimizer's checks let through —
    /// the ones it would offer ticked.
    public static func tidy(
        _ recipe: Recipe,
        catalog: IngredientCatalog = .current,
        nutritionCatalog: NutritionCatalog = .current,
        backend: some RecipeOptimizationBackend
    ) async throws -> Result<Recipe, RecipeOptimizationPrompt.Failure>? {
        if recipe.isOptimizedForSous { return nil }
        let result = try await RecipeOptimizer.optimize(
            recipe, catalog: catalog, nutritionCatalog: nutritionCatalog, excerpt: true, backend: backend
        )
        return result.map { $0.applied($0.defaultSelection).recipe }
    }
}

extension RecipeOptimizationPrompt.Failure {
    /// The failure for a cook whose answer came from a provider: the
    /// descriptions say "in the clipboard", which is only true of a pasted one.
    public var providerDescription: String {
        switch self {
        case .noAnswer: "Das Modell hat keine lesbare Optimierung geliefert."
        default: localizedDescription
        }
    }
}
