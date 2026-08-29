import Foundation
import Testing
@testable import SousKit

/// Prints what ``RecipeEffort`` makes of a real library, so the weights and
/// the thresholds can be set against recipes somebody actually cooks rather
/// than against reasoning.
///
/// Not a test: it asserts almost nothing and exists for its output. The
/// thresholds are the one part of the measure that cannot be derived — the
/// ratios between the signals say what was meant, but where "einfach" stops
/// is a judgement about one cook's library.
///
///     SOUS_EFFORT_LIBRARY=~/Desktop/Rezepte.melarecipes \
///         swift test --filter EffortCalibration
@Suite(
    "EffortCalibration",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_EFFORT_LIBRARY"] != nil)
)
struct RecipeEffortCalibrationTests {
    @Test("What the library looks like through the measure")
    func distribution() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SOUS_EFFORT_LIBRARY"])
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let batch = try MelaImport.read(try Data(contentsOf: url), named: url.lastPathComponent)

        let recipes = batch.recipes.map(\.recipe)
        let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scored = recipes.compactMap { recipe -> (Recipe, RecipeEffort)? in
            recipe.effort { byID[$0] }.map { (recipe, $0) }
        }

        print("\n=== \(url.lastPathComponent) ===")
        print("recipes: \(recipes.count), problems: \(batch.problems.count)")
        print("scored: \(scored.count), too thin to judge: \(recipes.count - scored.count)")

        let scores = scored.map(\.1.score).sorted()
        guard !scores.isEmpty else { return }

        func percentile(_ fraction: Double) -> Double {
            scores[min(scores.count - 1, max(0, Int((Double(scores.count - 1) * fraction).rounded())))]
        }
        print(String(
            format: "\nmin %.1f  p10 %.1f  p25 %.1f  median %.1f  p75 %.1f  p90 %.1f  max %.1f",
            scores.first ?? 0, percentile(0.10), percentile(0.25), percentile(0.5),
            percentile(0.75), percentile(0.90), scores.last ?? 0
        ))

        print("\n--- histogram (width 4) ---")
        let bucketWidth = 4.0
        let buckets = Dictionary(grouping: scores) { Int($0 / bucketWidth) }
        for bucket in buckets.keys.sorted() {
            let count = buckets[bucket]?.count ?? 0
            let low = Double(bucket) * bucketWidth
            print(String(format: "%5.0f–%-5.0f %3d %@",
                         low, low + bucketWidth, count, String(repeating: "█", count: count)))
        }

        print("\n--- with the thresholds as they stand ---")
        for level in RecipeEffort.Level.allCases {
            let count = scored.filter { $0.1.level == level }.count
            let share = Double(count) * 100 / Double(scored.count)
            print(String(format: "%-10s %3d  %4.1f%%", (level.rawValue as NSString).utf8String!, count, share))
        }

        print("\n--- a walk through each rung, every fifth recipe ---")
        for level in RecipeEffort.Level.allCases {
            let inRung = scored.filter { $0.1.level == level }.sorted { $0.1.score < $1.1.score }
            print("\n  \(level.rawValue) — \(inRung.count)")
            for (index, pair) in inRung.enumerated() where index % 5 == 0 {
                print(String(format: "   %5.1f  %@", pair.1.score, pair.0.title.prefix(60).description))
            }
        }

        print("\n--- where a third and two thirds would fall ---")
        print(String(format: "p33 %.1f   p66 %.1f", percentile(1.0 / 3), percentile(2.0 / 3)))

        func describe(_ pair: (Recipe, RecipeEffort)) -> String {
            let parts = pair.1.contributions
                .map { "\($0.signal.rawValue) \($0.count)" }
                .joined(separator: ", ")
            return String(format: "%6.1f  %-52s %@",
                          pair.1.score,
                          (String(pair.0.title.prefix(52)) as NSString).utf8String!,
                          parts)
        }

        print("\n--- the ten heaviest ---")
        for pair in scored.sorted(by: { $0.1.score > $1.1.score }).prefix(10) {
            print(describe(pair))
        }
        print("\n--- the ten lightest ---")
        for pair in scored.sorted(by: { $0.1.score < $1.1.score }).prefix(10) {
            print(describe(pair))
        }

        print("\n--- what carries the weight, across the library ---")
        var byfSignal: [RecipeEffort.Signal: (count: Int, points: Double)] = [:]
        for (_, effort) in scored {
            for contribution in effort.contributions {
                byfSignal[contribution.signal, default: (0, 0)].count += contribution.count
                byfSignal[contribution.signal, default: (0, 0)].points += contribution.points
            }
        }
        let total = byfSignal.values.reduce(0) { $0 + $1.points }
        for signal in byfSignal.keys.sorted(by: { byfSignal[$0]!.points > byfSignal[$1]!.points }) {
            let entry = byfSignal[signal]!
            print(String(format: "%-14s %6d occurrences  %8.1f points  %4.1f%% of all weight",
                         (signal.rawValue as NSString).utf8String!,
                         entry.count, entry.points, entry.points * 100 / total))
        }

        // The only thing worth asserting: the measure ran on a real library
        // without falling over, and it did not read the whole thing as one
        // rung — which would make the rungs useless whatever the words are.
        #expect(Set(scored.map(\.1.level)).count > 1)
    }
}
