import Foundation

/// A name the catalog does not know, as text for the curator — "melden" on an
/// unknown line. Copied, not sent: sharing comes with phase 10 (INGREDIENTS-
/// DATA §3 D). The same shape as ``RecipeOptimization/report(_:)``.
public enum CatalogReport {
    public static func unknown(_ name: String, recipeTitle: String? = nil) -> String {
        var text = "Sous – Vorschläge für den Zutatenkatalog\n"
        if let recipeTitle, !recipeTitle.isEmpty { text += "Rezept: \(recipeTitle)\n" }
        text += "- „\(name)“: unbekannt\n"
        return text
    }
}
