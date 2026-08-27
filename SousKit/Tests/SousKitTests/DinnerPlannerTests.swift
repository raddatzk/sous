import Foundation
import Testing
@testable import SousKit

@Suite("Dinner planner")
struct DinnerPlannerTests {
    // MARK: - Fixtures

    /// A nutritionally unremarkable dinner: reference density in everything,
    /// so it neither helps nor hurts any single term.
    private func balanced(kcal: Double = 600) -> NutritionInfo {
        var info = NutritionInfo.zero
        info.kcal = kcal
        for nutrient in NutrientReference.lowerBounds + NutrientReference.upperBounds {
            set(nutrient, on: &info, to: nutrient.densityPer100kcal * kcal / 100)
        }
        return info
    }

    /// Writes one nutrient's amount back through its label — the reference
    /// table only exposes a getter, and the fixtures want to dial single
    /// nutrients up and down.
    private func set(_ nutrient: NutrientReference, on info: inout NutritionInfo, to value: Double) {
        switch nutrient.label {
        case "Eiweiß": info.proteinG = value
        case "Ballaststoffe": info.fiberG = value
        case "Vitamin A": info.vitaminAMcg = value
        case "Vitamin C": info.vitaminCMg = value
        case "Vitamin E": info.vitaminEMg = value
        case "Calcium": info.calciumMg = value
        case "Eisen": info.ironMg = value
        case "Magnesium": info.magnesiumMg = value
        case "Kalium": info.potassiumMg = value
        case "Gesättigte Fettsäuren": info.saturatedFatG = value
        case "Zucker": info.sugarG = value
        case "Natrium": info.sodiumMg = value
        default: Issue.record("Unknown nutrient label \(nutrient.label)")
        }
    }

    private func reference(_ label: String) -> NutrientReference {
        (NutrientReference.lowerBounds + NutrientReference.upperBounds)
            .first { $0.label == label }!
    }

    private func candidate(
        _ title: String,
        source: PlannerCandidate.Source = .collection,
        isWantToCook: Bool = false,
        dishKey: UUID? = nil,
        perPortion: NutritionInfo?,
        id: UUID = UUID()
    ) -> PlannerCandidate {
        PlannerCandidate(
            recipeID: id,
            dishKey: dishKey ?? id,
            source: source,
            isWantToCook: isWantToCook,
            perPortion: perPortion,
            title: title
        )
    }

    private func days(_ count: Int) -> [Date] {
        let start = Date(timeIntervalSince1970: 1_755_734_400).startOfDay
        return (0..<count).compactMap {
            Calendar.current.date(byAdding: .day, value: $0, to: start)
        }
    }

    // MARK: - Cost

    @Test("Missing protein costs, surplus protein does not")
    func lowerBoundIsAsymmetric() {
        var short = balanced()
        short.proteinG = 0
        var surplus = balanced()
        surplus.proteinG *= 3

        #expect(PlanCost.nutrientCost(of: short) > PlanCost.nutrientCost(of: balanced()))
        #expect(PlanCost.nutrientCost(of: surplus) == PlanCost.nutrientCost(of: balanced()))
    }

    @Test("Excess sodium costs, scarce sodium does not")
    func upperBoundIsAsymmetric() {
        var salty = balanced()
        salty.sodiumMg *= 3
        var bland = balanced()
        bland.sodiumMg = 0

        #expect(PlanCost.nutrientCost(of: salty) > PlanCost.nutrientCost(of: balanced()))
        #expect(PlanCost.nutrientCost(of: bland) == PlanCost.nutrientCost(of: balanced()))
    }

    @Test("An empty mix is maximally short of everything, and never NaN")
    func zeroCalorieGuard() {
        #expect(PlanCost.nutrientCost(of: .zero) == Double(NutrientReference.lowerBounds.count))
        #expect(!PlanCost.nutrientCost(of: .zero).isNaN)

        var zeroKcal = NutritionInfo.zero
        zeroKcal.proteinG = 20
        #expect(!PlanCost.nutrientCost(of: zeroKcal).isNaN)
    }

    // MARK: - Variety

    @Test("Two variants of one dish take one seat at most")
    func variantsShareASeat() {
        let dish = UUID()
        let request = PlanRequest(
            seats: .days(days(3)),
            candidates: [
                candidate("Chili", dishKey: dish, perPortion: balanced()),
                candidate("Chili vegan", dishKey: dish, perPortion: balanced()),
                candidate("Eintopf", perPortion: balanced()),
            ]
        )

        let proposal = DinnerPlanner.plan(request)

        #expect(proposal.placements.count == 2)
        #expect(Set(proposal.placements.map(\.candidate.dishKey)).count == 2)
    }

    @Test("A dish the span already holds is never proposed")
    func excludedDishNeverSeats() {
        let dish = UUID()
        let request = PlanRequest(
            seats: .days(days(2)),
            excludedDishKeys: [dish],
            candidates: [candidate("Chili", dishKey: dish, perPortion: balanced())]
        )

        #expect(DinnerPlanner.plan(request).placements.isEmpty)
    }

    // MARK: - Pool

    @Test("A poor pool meal is seated ahead of an ideal collection recipe")
    func poolSeatsFirst() {
        var junk = NutritionInfo.zero
        junk.kcal = 700
        junk.saturatedFatG = 40
        junk.sugarG = 60
        let poolEntry = UUID()
        let request = PlanRequest(
            seats: .days(days(1)),
            candidates: [
                candidate("Traumgericht", perPortion: balanced()),
                candidate("Pommes", source: .pool(entryID: poolEntry, servings: 2), perPortion: junk),
            ]
        )

        let proposal = DinnerPlanner.plan(request)

        #expect(proposal.placements.map(\.candidate.title) == ["Pommes"])
    }

    @Test("A pool meal without nutrition still seats")
    func poolSeatsWithoutNutrition() {
        let request = PlanRequest(
            seats: .days(days(1)),
            candidates: [
                candidate("Omas Rezept", source: .pool(entryID: UUID(), servings: nil), perPortion: nil)
            ]
        )

        #expect(DinnerPlanner.plan(request).placements.count == 1)
    }

    @Test("A pool meal colliding with the span is skipped, not seated")
    func collidingPoolEntrySkipped() {
        let dish = UUID()
        let request = PlanRequest(
            seats: .days(days(1)),
            excludedDishKeys: [dish],
            candidates: [
                candidate("Chili", source: .pool(entryID: UUID(), servings: nil), dishKey: dish, perPortion: balanced()),
                candidate("Eintopf", perPortion: balanced()),
            ]
        )

        #expect(DinnerPlanner.plan(request).placements.map(\.candidate.title) == ["Eintopf"])
    }

    // MARK: - Want to cook

    @Test("The mark wins between near-equals and loses to a sodium bomb")
    func bonusIsATiebreakNotAQueue() {
        var salty = balanced()
        salty.sodiumMg *= 6

        let nearEqual = PlanRequest(
            seats: .days(days(1)),
            candidates: [
                candidate("Alltag", perPortion: balanced()),
                candidate("Wunsch", source: .wantToCook, isWantToCook: true, perPortion: balanced()),
            ]
        )
        #expect(DinnerPlanner.plan(nearEqual).placements.map(\.candidate.title) == ["Wunsch"])

        let bomb = PlanRequest(
            seats: .days(days(1)),
            candidates: [
                candidate("Alltag", perPortion: balanced()),
                candidate("Salzwunsch", source: .wantToCook, isWantToCook: true, perPortion: salty),
            ]
        )
        #expect(DinnerPlanner.plan(bomb).placements.map(\.candidate.title) == ["Alltag"])
    }

    // MARK: - Swap pass

    @Test("The swap pass improves on what greedy alone selected")
    func swapImprovesGreedy() {
        // The all-rounder is the best single dish, so greedy grabs it first
        // — but the two specialists complete each other perfectly, and only
        // a look back can trade the all-rounder away for the second one.
        let kcal = 600.0
        var allRounder = NutritionInfo.zero
        allRounder.kcal = kcal
        var firstHalf = NutritionInfo.zero
        firstHalf.kcal = kcal
        var secondHalf = NutritionInfo.zero
        secondHalf.kcal = kcal
        for (index, nutrient) in NutrientReference.lowerBounds.enumerated() {
            set(nutrient, on: &allRounder, to: nutrient.densityPer100kcal * kcal / 100 * 0.6)
            if index < 5 {
                set(nutrient, on: &firstHalf, to: nutrient.densityPer100kcal * kcal / 100 * 2)
            }
            if index >= 4 {
                set(nutrient, on: &secondHalf, to: nutrient.densityPer100kcal * kcal / 100 * 2)
            }
        }

        let request = PlanRequest(
            seats: .days(days(2)),
            candidates: [
                candidate("Allrounder", perPortion: allRounder),
                candidate("Erste Hälfte", perPortion: firstHalf),
                candidate("Zweite Hälfte", perPortion: secondHalf),
            ]
        )

        let greedy = DinnerPlanner.greedySelection(request)
        let improved = DinnerPlanner.improvedSelection(request)

        func cost(_ selection: [PlannerCandidate]) -> Double {
            let mix = selection.reduce(NutritionInfo.zero) { $0 + ($1.perPortion ?? .zero) }
            return PlanCost.totalCost(of: mix, wantToCookCount: selection.filter(\.isWantToCook).count)
        }
        #expect(cost(improved) < cost(greedy))
    }

    // MARK: - Determinism

    @Test("A shuffled candidate list proposes the same dinners")
    func deterministicUnderShuffle() {
        let candidates = (0..<12).map { index -> PlannerCandidate in
            var info = balanced()
            info.proteinG *= Double(index % 4) * 0.4
            info.sodiumMg *= Double(index % 3) * 0.7
            return candidate(
                "Gericht \(index)",
                source: index % 5 == 0 ? .wantToCook : .collection,
                isWantToCook: index % 5 == 0,
                perPortion: info,
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            )
        }

        let straight = DinnerPlanner.plan(PlanRequest(seats: .days(days(5)), candidates: candidates))
        let shuffled = DinnerPlanner.plan(PlanRequest(seats: .days(days(5)), candidates: candidates.reversed()))

        #expect(straight.placements.map(\.id) == shuffled.placements.map(\.id))
        #expect(straight.placements.map(\.day) == shuffled.placements.map(\.day))
    }

    // MARK: - Replacement

    @Test("A replacement holds every other seat and respects what was turned down")
    func replacementCyclesForward() {
        let a = candidate("A", perPortion: balanced())
        let b = candidate("B", perPortion: balanced())
        let c = candidate("C", perPortion: balanced())
        let d = candidate("D", perPortion: balanced())
        let request = PlanRequest(seats: .days(days(2)), candidates: [a, b, c, d])

        let proposal = DinnerPlanner.plan(request)
        #expect(proposal.placements.map(\.candidate.title) == ["A", "B"])
        let swapped = proposal.placements[1]

        let first = DinnerPlanner.replacement(for: swapped, in: proposal, request: request)
        #expect(first?.title == "C")

        let second = DinnerPlanner.replacement(
            for: swapped, in: proposal, request: request,
            excluding: [first!.recipeID]
        )
        #expect(second?.title == "D")

        let third = DinnerPlanner.replacement(
            for: swapped, in: proposal, request: request,
            excluding: [first!.recipeID, second!.recipeID]
        )
        #expect(third == nil)
    }

    // MARK: - Pool mode

    @Test("Pool seats fall onto the earliest days, the rest behind them")
    func dayAssignmentOrder() {
        let request = PlanRequest(
            seats: .days(days(2)),
            candidates: [
                candidate("Neu", perPortion: balanced()),
                candidate("Vorgemerkt", source: .pool(entryID: UUID(), servings: nil), perPortion: balanced()),
            ]
        )

        let proposal = DinnerPlanner.plan(request)

        #expect(proposal.placements.first?.candidate.title == "Vorgemerkt")
        #expect(proposal.placements.map(\.day) == proposal.placements.map(\.day).sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) })
    }

    @Test("A pool-mode run leaves every placement undated")
    func poolModeIsUndated() {
        let request = PlanRequest(
            seats: .pool(count: 2),
            candidates: [
                candidate("Eins", perPortion: balanced()),
                candidate("Zwei", perPortion: balanced()),
                candidate("Drei", perPortion: balanced()),
            ]
        )

        let proposal = DinnerPlanner.plan(request)

        #expect(proposal.placements.count == 2)
        #expect(proposal.placements.allSatisfy { $0.day == nil })
    }

    // MARK: - Suitability plumbing

    @Test("An empty set of suitable slots normalizes to nil at the door")
    func emptySlotsNormalize() {
        let recipe = Recipe(title: "Test", suitableSlots: [])
        #expect(recipe.suitableSlots == nil)

        let explicit = Recipe(title: "Test", suitableSlots: [.breakfast])
        #expect(explicit.suitableSlots == [.breakfast])
    }
}
