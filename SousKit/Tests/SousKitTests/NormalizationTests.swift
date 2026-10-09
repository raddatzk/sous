import Foundation
import Testing
@testable import SousKit

/// `IngredientCatalog.normalize` against the vectors the data compiler is
/// tested against too (`Fixtures/normalize-cases.json`). The compiler refuses two
/// catalog spellings that normalize alike; if the app folded differently, a
/// spelling the compiler let through could be unreachable here, or two the
/// compiler kept apart could collide.
@Suite("Normalization")
struct NormalizationTests {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            var input: String
            var key: String
        }
        var cases: [Case]
        var distinct: [[String]]
    }

    /// Read from the repository rather than bundled, so the compiler's tests
    /// (`Scripts/data/test_compile.py`) read the very same file.
    private static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SousKitTests
            .appendingPathComponent("Fixtures/normalize-cases.json")
        do {
            return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Fixtures/normalize-cases.json is unreadable: \(error)")
        }
    }()

    @Test("Folds exactly as the compiler does")
    func sharedCases() {
        #expect(Self.vectors.cases.count > 10)
        for vector in Self.vectors.cases {
            #expect(
                IngredientCatalog.normalize(vector.input) == vector.key,
                "\(vector.input.debugDescription) normalized to \(IngredientCatalog.normalize(vector.input).debugDescription)"
            )
        }
    }

    @Test("Keeps apart what is not a spelling of the same thing")
    func sharedDistinctPairs() {
        for pair in Self.vectors.distinct {
            #expect(IngredientCatalog.normalize(pair[0]) != IngredientCatalog.normalize(pair[1]), "\(pair)")
        }
    }

    @Test("The stored key stays what it always was")
    func storageKeyIsFrozen() {
        // Rows written before the folding, and rows an older app writes, are
        // looked up by this string. It must not learn anything new.
        #expect(IngredientCatalog.storageKey("  Weißwein ") == "weißwein")
        #expect(IngredientCatalog.storageKey("Hokkaido-Kürbis") == "hokkaido-kürbis")
        #expect(IngredientCatalog.normalize(IngredientCatalog.storageKey("Weißwein"))
                == IngredientCatalog.normalize("Weißwein"))
    }

    @Test("A folded spelling finds the catalog word")
    func foldedSpellingsResolve() {
        let catalog = IngredientCatalog.bundled
        #expect(catalog.canonicalName(for: "Weisswein") == "Weißwein")
        #expect(catalog.canonicalName(for: "Hokkaido-Kürbis") == "Hokkaido")
        #expect(catalog.canonicalName(for: "Hokkaidokürbis") == "Hokkaido")
        #expect(catalog.canonicalName(for: "Süsskartoffel") == "Süßkartoffel")
        #expect(catalog.canonicalName(for: "Soja-Hack") == "Sojahack")
    }
}
