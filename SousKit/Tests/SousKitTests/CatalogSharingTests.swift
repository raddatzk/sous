import Foundation
import Testing
@testable import SousKit

/// What a household offers the curator, and when the nudge asks
/// (INGREDIENTS-DATA §3 D, phase 10).
@Suite("Catalog sharing")
struct CatalogSharingTests {
    private static func word(_ name: String, id: String) -> CatalogIngredient {
        var ingredient = CatalogIngredient(name: name, category: .legumes)
        ingredient.catalogID = id
        return ingredient
    }

    private static let catalog = IngredientCatalog(ingredients: [
        word("Tofu", id: "tofu"),
        word("Kokosmilch", id: "kokosmilch"),
    ])

    private static func info(kcal: Double, protein: Double = 0) -> NutritionInfo {
        var info = NutritionInfo.zero
        info.kcal = kcal
        info.proteinG = protein
        return info
    }

    private static let nutrition = NutritionCatalog(entries: [
        CatalogNutrition(
            name: "Tofu", perHundredGrams: ["unspecified": info(kcal: 120, protein: 12)],
            unitWeightsGrams: ["Pck.": 200]
        ),
        CatalogNutrition(name: "Kokosmilch", perHundredGrams: ["unspecified": info(kcal: 180)]),
    ])

    private static func offers(_ answers: [LocalAnswer], usage: CatalogUsage = .empty) -> [CatalogSharing.Offer] {
        CatalogSharing.offers(LocalAnswerSet(answers), catalog: catalog, nutrition: nutrition, usage: usage)
    }

    // MARK: - What is offered

    @Test("Each kind of answer lands in its group, in the sheet's order")
    func groups() {
        let offers = Self.offers([
            LocalAnswer(name: "Greenforce Sojahack", kind: .product, targetID: "tofu", brand: "Greenforce"),
            LocalAnswer(name: "dünne Kokosmilch", kind: .countsAs, targetID: "kokosmilch"),
            LocalAnswer(name: "Pandanblatt", kind: .word),
            LocalAnswer(catalogID: "tofu", name: "Tofu", weights: ["Pck.": LocalAnswer.Weight(grams: 175)]),
        ])
        #expect(offers.map(\.item.kind) == [.word, .countsAs, .values, .product])
        #expect(offers.map { CatalogSharing.Group($0.item.kind) } == [.new, .countsAs, .values, .product])

        let countsAs = offers[1].item
        #expect(countsAs.target == CatalogSubmission.Item.Target(id: "kokosmilch", name: "Kokosmilch"))
        #expect(countsAs.summary == "„dünne Kokosmilch“ zählt wie Kokosmilch")

        let product = offers[3].item
        #expect(product.brand == "Greenforce")
        #expect(product.target?.name == "Tofu")
        #expect(product.detail == "Produkt, Marke Greenforce, rechnet wie Tofu")
    }

    @Test("A product choice is the household's purchase and never offered")
    func productChoiceStaysHome() {
        let offers = Self.offers([
            LocalAnswer(name: "vegane Butter", kind: .product, targetID: "name:ja vegane butter"),
            LocalAnswer(catalogID: "tofu", name: "Tofu", kind: .product, targetID: "name:greenforce sojahack"),
        ])
        #expect(offers.isEmpty)
    }

    @Test("A fallback on a name the catalog knows is silent, and not offered")
    func silencedFallback() {
        #expect(Self.offers([LocalAnswer(name: "Kokosmilch", kind: .countsAs, targetID: "tofu")]).isEmpty)
        #expect(Self.offers([LocalAnswer(name: "Tofu", kind: .word)]).isEmpty)
    }

    @Test("For a catalog word only what differs from the catalog is offered")
    func onlyDifferences() {
        let same = LocalAnswer(
            catalogID: "tofu", name: "Tofu",
            values: Self.info(kcal: 120.2, protein: 12), valuesSource: "BLS",
            weights: ["Pck.": LocalAnswer.Weight(grams: 200)]
        )
        #expect(Self.offers([same]).isEmpty)

        var differing = same
        differing.weights["Pck."] = LocalAnswer.Weight(grams: 175)
        differing.weights["Stk."] = LocalAnswer.Weight(grams: 50)
        let item = Self.offers([differing]).first?.item
        #expect(item?.kind == .values)
        #expect(item?.catalogID == "tofu")
        #expect(item?.values == nil)
        #expect(item?.source == nil)
        #expect(item?.weights?.keys.sorted() == ["Pck.", "Stk."])
    }

    @Test("An answer is offered until shared, and again once it changed")
    func pending() {
        let written = Date(timeIntervalSince1970: 1_000)
        var answer = LocalAnswer(name: "Pandanblatt", kind: .word, updatedAt: written)
        #expect(CatalogSharing.isPending(answer))
        answer.sharedAt = written.addingTimeInterval(10)
        #expect(!CatalogSharing.isPending(answer))
        #expect(Self.offers([answer]).isEmpty)
        answer.updatedAt = written.addingTimeInterval(20)
        #expect(CatalogSharing.isPending(answer))
    }

    // MARK: - Context

    @Test("The usage counts recipes per name and keeps one line as written")
    func usage() {
        let household = LocalAnswerSet([LocalAnswer(name: "dünne Kokosmilch", kind: .countsAs, targetID: "kokosmilch")])
            .applied(to: Self.catalog).catalog
        let usage = CatalogUsage(ingredientTexts: [
            "200 ml dünne Kokosmilch\n200 g Tofu",
            "100 ml dünne Kokosmilch\n100 ml dünne Kokosmilch",
            "1 Pck. Tofu",
        ], catalog: household)
        #expect(usage.use(forName: "Dünne Kokosmilch") == CatalogUsage.Use(recipes: 2, line: "200 ml dünne Kokosmilch"))
        #expect(usage.use(forKey: "id:tofu")?.recipes == 2)

        let offers = CatalogSharing.offers(
            LocalAnswerSet([LocalAnswer(name: "dünne Kokosmilch", kind: .countsAs, targetID: "kokosmilch")]),
            catalog: Self.catalog, nutrition: Self.nutrition, usage: usage
        )
        #expect(offers.first?.item.recipes == 2)
        #expect(offers.first?.item.line == "200 ml dünne Kokosmilch")
        #expect(offers.first?.item.context == "in 2 Rezepten · „200 ml dünne Kokosmilch“")
    }

    @Test("An unknown name nobody answered is an offer of its own")
    func unknownName() {
        let usage = CatalogUsage(ingredientTexts: ["2 Pandanblätter"], catalog: Self.catalog)
        let offer = CatalogSharing.unknown("Pandanblätter", usage: usage)
        #expect(offer.answer == nil)
        #expect(offer.item.kind == .unknown)
        #expect(offer.item.recipes == 1)
        #expect(offer.item.line == "2 Pandanblätter")
    }

    // MARK: - The submission

    @Test("Free text is capped, and a submission holds at most 50 items")
    func caps() {
        let long = String(repeating: "x", count: 300)
        let item = CatalogSubmission.Item(kind: .unknown, name: long, source: long, line: long)
        #expect(item.name.count == 80)
        #expect(item.source?.count == 200)
        #expect(item.line?.count == 200)
        let submission = CatalogSubmission(items: Array(repeating: item, count: 60), app: "1.0 (1)", dataVersion: 1)
        #expect(submission.items.count == 50)
    }

    @Test("The text form carries the same items as a block a machine reads")
    func textForm() throws {
        let submission = CatalogSubmission(items: [
            CatalogSubmission.Item(
                kind: .countsAs, name: "dünne Kokosmilch",
                target: .init(id: "kokosmilch", name: "Kokosmilch"), recipes: 2, line: "200 ml dünne Kokosmilch"
            ),
        ], app: "1.0 (7)", dataVersion: 2026100200)
        let text = submission.text
        #expect(text.contains("- „dünne Kokosmilch“ zählt wie Kokosmilch · in 2 Rezepten"))
        let block = try #require(text.components(separatedBy: "```json sous-submission\n").last?
            .components(separatedBy: "\n```").first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(block.utf8)) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["dataVersion"] as? Int == 2026100200)
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.first?["kind"] as? String == "countsAs")
        #expect((items.first?["target"] as? [String: String])?["id"] == "kokosmilch")
        #expect(items.first?["values"] == nil)

        let url = try #require(submission.issueFormURL)
        #expect(url.absoluteString.hasPrefix("https://github.com/raddatzk/sous/issues/new?template=katalog.yml"))
    }

    @Test("Items decode from the wire format, weights with their state")
    func wireRoundTrip() throws {
        let item = CatalogSubmission.Item(
            kind: .values, name: "Kichererbsen", catalogID: "kichererbsen",
            values: Self.info(kcal: 120), source: "Dose, Marke X",
            weights: ["Dose": LocalAnswer.Weight(grams: 240, state: .cooked)]
        )
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(CatalogSubmission.Item.self, from: data) == item)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["weights"] as? [String: [String: Any]])?["Dose"]?["state"] as? String == "cooked")
        #expect((object["values"] as? [String: Any])?["kcal"] as? Double == 120)
    }

    // MARK: - Nudge and cap

    @Test("The nudge asks at five pending answers, then not for 30 days")
    func nudge() throws {
        let defaults = try #require(UserDefaults(suiteName: "CatalogSharingTests.nudge.\(UUID())"))
        let nudge = CatalogNudge(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!nudge.shows(pending: 4, now: now))
        #expect(nudge.shows(pending: 5, now: now))
        nudge.restart(at: now)
        #expect(!nudge.shows(pending: 9, now: now.addingTimeInterval(29 * 24 * 3600)))
        #expect(nudge.shows(pending: 9, now: now.addingTimeInterval(30 * 24 * 3600)))
        nudge.neverAsk = true
        #expect(!nudge.shows(pending: 9, now: now.addingTimeInterval(60 * 24 * 3600)))
    }

    @Test("At most three submissions a day leave one device")
    func dailyCap() throws {
        let defaults = try #require(UserDefaults(suiteName: "CatalogSharingTests.cap.\(UUID())"))
        let log = CatalogSubmissionLog(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000_000)
        for minute in 0..<3 {
            #expect(log.canSend(now: now.addingTimeInterval(Double(minute) * 60)))
            log.record(at: now.addingTimeInterval(Double(minute) * 60))
        }
        #expect(!log.canSend(now: now.addingTimeInterval(3600)))
        #expect(log.canSend(now: now.addingTimeInterval(24 * 3600 + 1)))
    }

    // MARK: - Stores and library

    @Test("Marking shared leaves the answer's time alone, so a later save counts as a change")
    func markSharedKeepsUpdatedAt() async throws {
        let store = CoreDataLocalAnswerStore(container: try SousPersistentContainer.make(inMemory: true))
        let saved = try #require(try await store.save(LocalAnswer(name: "Pandanblatt", kind: .word)))
        let sharedAt = saved.updatedAt.addingTimeInterval(1)
        try await store.markShared(keys: [saved.key], at: sharedAt)

        var read = try #require(try await store.answers().first)
        #expect(read.sharedAt == sharedAt)
        #expect(read.updatedAt == saved.updatedAt)
        #expect(!CatalogSharing.isPending(read))

        // An edit keeps sharedAt and moves updatedAt past it.
        read.weights["Stk."] = LocalAnswer.Weight(grams: 1)
        try await Task.sleep(for: .milliseconds(1_100))
        let edited = try #require(try await store.save(read))
        #expect(edited.sharedAt == sharedAt)
        #expect(CatalogSharing.isPending(edited))
    }

    @Test("The library offers pending answers and stops after marking them shared")
    @MainActor
    func library() async throws {
        let library = IngredientCatalogLibrary(localAnswers: InMemoryLocalAnswerStore())
        await library.reload()
        #expect(await library.saveLocalAnswer(LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tofu")))
        let offers = library.shareOffers()
        #expect(offers.map(\.item.name) == ["Rauchtofu"])
        #expect(library.pendingShareCount == 1)

        await library.markShared(offers + [CatalogSharing.unknown("Pandanblatt")])
        #expect(library.pendingShareCount == 0)
        #expect(library.localAnswer(for: "Rauchtofu")?.sharedAt != nil)
    }
}
