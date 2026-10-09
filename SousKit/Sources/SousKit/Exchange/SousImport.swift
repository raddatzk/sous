import Foundation

/// Reads Sous's own export files, the ones ``SousExport`` writes.
///
/// The bytes are Mela's format, so everything Mela keeps is read by
/// ``MelaImport``. What Sous adds beside it lives under keys of its own —
/// the variant group, the meals a recipe suits, the text it was imported as,
/// and what each step takes from the list — and only a file Sous wrote
/// carries them. Reading them here, for Sous's extensions only, keeps a Mela
/// import exactly what Mela wrote.
public enum SousImport: RecipeImportFormat {
    public static let fileExtensions = ["sousrecipe", "sousrecipes"]

    public static func read(_ data: Data, named name: String) throws -> RecipeImportBatch {
        try MelaImport.read(data, named: name, extending: { imported, object in
            let group = variantGroup(from: object)
            imported.variantGroup = group
            imported.recipe.variantGroupID = group?.id
            imported.recipe.suitableSlots = suitableSlots(from: object)
            imported.recipe.original = original(from: object)
            imported.recipe.stepReferences = stepReferences(from: object)
        })
    }

    /// The group this file says its recipe belongs to.
    ///
    /// A group without a readable id is no group: inventing one here would
    /// put every recipe of a broken import into a group of its own.
    private static func variantGroup(from object: [String: Any]) -> VariantGroup? {
        guard let raw = object["sousVariantGroup"] as? [String: Any],
              let id = RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(raw["id"])).flatMap(UUID.init(uuidString:))
        else { return nil }
        let title = RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(raw["title"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return VariantGroup(id: id, title: title)
    }

    /// The meals the file says its recipe suits; without the key the recipe
    /// stays undecided.
    private static func suitableSlots(from object: [String: Any]) -> Set<MealSlot>? {
        guard let raw = object["sousSuitableSlots"] as? [Any] else { return nil }
        let slots = raw.compactMap { RecipeFieldParsing.string($0).flatMap(MealSlot.init(rawValue:)) }
        return slots.isEmpty ? nil : Set(slots)
    }

    /// The text the recipe was imported as before Sous optimized it. Without
    /// it the library keeps what this file says as the original.
    private static func original(from object: [String: Any]) -> RecipeOriginal? {
        guard let raw = object["sousOriginal"] as? [String: Any] else { return nil }
        return RecipeOriginal(
            ingredientsText: MelaImport.lines(raw["ingredients"]),
            instructionsText: MelaImport.lines(raw["instructions"]),
            notes: RecipeFieldParsing.nonEmpty(RecipeFieldParsing.string(raw["notes"]))
        )
    }

    /// What each step takes from the list, read the way the library reads
    /// its own column, so anything unreadable is simply no references.
    private static func stepReferences(from object: [String: Any]) -> StepReferences? {
        guard let raw = object["sousStepReferences"],
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return StepReferences.decode(String(decoding: data, as: UTF8.self))
    }
}
