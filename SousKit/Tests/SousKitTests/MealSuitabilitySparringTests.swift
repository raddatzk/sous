import Foundation
import FoundationModels
import Testing
@testable import SousKit

/// Not a regression test — a measuring bench for the meal-suitability
/// prompt. It runs the live on-device model over a labeled set of German
/// dishes and prints a scorecard: which role the model picked, which slots
/// that maps to, and where it disagrees with the label. The planner only
/// reads dinner-eligibility today, so that column is the one that counts.
///
/// Opt in explicitly, since a live model call has no place in a routine
/// test run:
///
///     SOUS_SPARRING=1 swift test --filter MealSuitabilitySparring
@Suite(
    "Meal suitability sparring",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_SPARRING"] == "1")
)
struct MealSuitabilitySparringTests {
    /// A dish as the bench sees it: what the collection would hand the
    /// classifier, and what a cook would say about it. `dinner` is the
    /// verdict the planner acts on; `role` is the expected reasoning,
    /// reported but not scored, since two roles can map to the same slots.
    private struct Case {
        let title: String
        let categories: [String]
        let ingredients: String
        let dinner: Bool
        let expectedRole: DishRole
    }

    // The two real misses from the first simulator run sit at the top.
    private let cases: [Case] = [
        Case(title: "Brownie Rezept - schnell & einfach", categories: [],
             ingredients: "200 g Zartbitterschokolade\n200 g Butter\n200 g Zucker\n3 Eier\n100 g Mehl",
             dinner: false, expectedRole: .sweetTreat),
        Case(title: "Basilikum Pesto", categories: [],
             ingredients: "2 Bund Basilikum\n50 g Pinienkerne\n50 g Parmesan\n100 ml Olivenöl\n1 Knoblauchzehe",
             dinner: false, expectedRole: .component),
        Case(title: "Knoblauchsuppe", categories: ["Suppen"],
             ingredients: "8 Knoblauchzehen\n1 l Gemüsebrühe\n200 ml Sahne\n2 Scheiben Brot",
             dinner: true, expectedRole: .savoryMain),
        Case(title: "Kaiserschmarrn", categories: [],
             ingredients: "4 Eier\n250 ml Milch\n150 g Mehl\n2 EL Zucker\n50 g Rosinen",
             dinner: true, expectedRole: .sweetMain),
        Case(title: "Milchreis mit Zimt", categories: [],
             ingredients: "250 g Milchreis\n1 l Milch\n3 EL Zucker\n1 TL Zimt",
             dinner: true, expectedRole: .sweetMain),
        Case(title: "Porridge mit Beeren", categories: ["Frühstück"],
             ingredients: "80 g Haferflocken\n300 ml Milch\n1 Handvoll Beeren\n1 EL Honig",
             dinner: false, expectedRole: .breakfastDish),
        Case(title: "Overnight Oats", categories: [],
             ingredients: "50 g Haferflocken\n150 ml Milch\n1 EL Chiasamen\n1 Apfel",
             dinner: false, expectedRole: .breakfastDish),
        Case(title: "Chili con Carne", categories: ["Hauptgerichte"],
             ingredients: "500 g Hackfleisch\n2 Dosen Kidneybohnen\n1 Dose Mais\n2 Zwiebeln\n400 g Tomaten",
             dinner: true, expectedRole: .savoryMain),
        Case(title: "Lasagne", categories: [],
             ingredients: "500 g Hackfleisch\n12 Lasagneplatten\n400 g Tomaten\n50 g Parmesan\n500 ml Béchamelsoße",
             dinner: true, expectedRole: .savoryMain),
        Case(title: "Flammkuchen", categories: [],
             ingredients: "250 g Mehl\n200 g Schmand\n100 g Speck\n2 Zwiebeln",
             dinner: true, expectedRole: .savoryMain),
        Case(title: "Käsekuchen", categories: ["Kuchen"],
             ingredients: "500 g Quark\n200 g Mehl\n150 g Zucker\n3 Eier\n100 g Butter",
             dinner: false, expectedRole: .sweetTreat),
        Case(title: "Hefezopf", categories: ["Backen"],
             ingredients: "500 g Mehl\n1 Würfel Hefe\n250 ml Milch\n80 g Zucker\n1 Ei",
             dinner: false, expectedRole: .sweetTreat),
        Case(title: "Guacamole", categories: [],
             ingredients: "2 Avocados\n1 Limette\n1 Tomate\n1 Zwiebel\nKoriander",
             dinner: false, expectedRole: .component),
        Case(title: "Salatdressing mit Honig und Senf", categories: [],
             ingredients: "3 EL Olivenöl\n1 EL Essig\n1 TL Honig\n1 TL Senf",
             dinner: false, expectedRole: .component),
        Case(title: "Pizzateig", categories: ["Grundrezepte"],
             ingredients: "500 g Mehl\n1 Würfel Hefe\n300 ml Wasser\n2 EL Olivenöl\n1 TL Salz",
             dinner: false, expectedRole: .component),
        Case(title: "Semmelknödel", categories: ["Beilagen"],
             ingredients: "6 Brötchen\n250 ml Milch\n2 Eier\n1 Zwiebel\nPetersilie",
             dinner: false, expectedRole: .component),
        Case(title: "Grüner Smoothie", categories: [],
             ingredients: "1 Banane\n100 g Spinat\n1 Apfel\n200 ml Wasser",
             dinner: false, expectedRole: .drink),
        Case(title: "Caesar Salad mit Hähnchen", categories: ["Salate"],
             ingredients: "2 Hähnchenbrüste\n1 Römersalat\n50 g Parmesan\nCroûtons\nCaesar-Dressing",
             dinner: true, expectedRole: .savoryMain),
        Case(title: "Rührei", categories: [],
             ingredients: "4 Eier\n2 EL Butter\nSchnittlauch\nSalz",
             dinner: false, expectedRole: .breakfastDish),
        Case(title: "Apfelmus", categories: [],
             ingredients: "1 kg Äpfel\n2 EL Zucker\n1 Zimtstange",
             dinner: false, expectedRole: .component),
        Case(title: "Brötchen mit gegrilltem Gemüse", categories: [],
             ingredients: "4 Brötchen\n1 Zucchini\n1 Aubergine\n1 Paprika\n100 g Frischkäse",
             dinner: true, expectedRole: .savoryMain),
        Case(title: "Kürbissuppe mit Ingwer", categories: ["Suppen"],
             ingredients: "1 Hokkaido\n1 Stück Ingwer\n1 l Gemüsebrühe\n200 ml Kokosmilch",
             dinner: true, expectedRole: .savoryMain),
    ]

    @Test("Scorecard over the labeled dishes")
    func scorecard() async throws {
        var dinnerHits = 0
        var roleHits = 0
        var lines: [String] = []

        for testCase in cases {
            let recipe = Recipe(
                title: testCase.title,
                ingredientsText: testCase.ingredients,
                categories: testCase.categories
            )
            let role = try await MealSuitabilityClassifier.role(for: recipe)
            let dinner = role.slots.contains(.dinner)
            let dinnerRight = dinner == testCase.dinner
            let roleRight = role == testCase.expectedRole
            if dinnerRight { dinnerHits += 1 }
            if roleRight { roleHits += 1 }
            lines.append(String(
                format: "%@ %-38@ %-14@ (erwartet %-14@) Abend: %@",
                dinnerRight ? "✓" : "✗",
                testCase.title as NSString,
                role.rawValue as NSString,
                testCase.expectedRole.rawValue as NSString,
                dinner ? "ja" : "nein"
            ))
        }

        print("""

        ── Meal suitability sparring ─────────────────────────────
        \(lines.joined(separator: "\n"))
        ──────────────────────────────────────────────────────────
        Abend-Urteil: \(dinnerHits)/\(cases.count) richtig
        Rolle:        \(roleHits)/\(cases.count) wie erwartet

        """)

        // The bench measures; it only fails when the prompt is genuinely
        // broken, so a flaky borderline dish cannot redden a suite run.
        #expect(Double(dinnerHits) >= Double(cases.count) * 0.8)
    }
}
