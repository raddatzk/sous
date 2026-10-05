import Foundation

extension Recipe {
    /// Whether this version of the recipe is in the shape Sous reads best:
    /// every ingredient line in the fixed form (amount, unit, the ingredient
    /// as bought), and the steps' references to those lines current for this
    /// very text — so the shopping list adds up and cook mode scales the
    /// amounts in the steps.
    ///
    /// Derived, never stored: an edit that breaks the form, or a text the
    /// references were not read for, ends it by itself. A recipe without
    /// steps needs no references; one without ingredients is not optimized.
    public var isOptimizedForSous: Bool {
        let lines = ingredients
        guard !lines.isEmpty, lines.allSatisfy({ !$0.isOutsideForm }) else { return false }
        return steps.isEmpty || stepReferences?.isCurrent(for: self) == true
    }
}
