import Foundation
import FoundationModels
import Testing
@testable import SousKit

/// Not a regression test — a measuring bench for the question "what if a
/// language model, not the resolver, decided what each step takes?". It
/// walks a library dump, and for every recipe writes what the resolver
/// shows today (inline amounts and chips per step) next to what the
/// on-device model answers when handed the ingredient list and the steps.
/// It also writes the model-neutral prompt per recipe, so a cloud model can
/// be run over the same input by a script outside the package.
///
///     SOUS_SPARRING=1 SOUS_LLM_LIBRARY=/path/library.json SOUS_LLM_OUT=/path/out \
///         swift test --filter StepChipsLLMSparring
///
/// `SOUS_LLM_ONDEVICE=0` skips the on-device model; `SOUS_LLM_LIMIT=n` stops
/// after n recipes. With `ANTHROPIC_API_KEY` set, the same prompt also goes
/// to Claude over the Messages API (`SOUS_LLM_CLAUDE_MODEL`, default
/// `claude-opus-5`; `SOUS_LLM_CLAUDE_EFFORT` optional).
@Suite(
    "Step chips LLM sparring",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_SPARRING"] == "1")
)
struct StepChipsLLMSparringTests {
    struct LibraryRecipe: Decodable {
        let title: String
        let servings: Int?
        let ingredientsText: String?
        let instructionsText: String?
    }

    struct Use: Codable {
        /// 1-based index into the ingredient lines as numbered in the prompt.
        let line: Int
        /// What the step takes at the recipe's own serving count, as a cook
        /// would read it ("150 g", "1/2 TL") — `nil` where no amount applies.
        let amount: String?
        let inline: Bool?
    }

    struct StepResult: Codable {
        let step: Int
        let uses: [Use]
    }

    struct RecipeResult: Codable {
        let title: String
        let servings: Int
        let lines: [String]
        let steps: [String]
        let prompt: String
        let resolver: [StepResult]
        var onDevice: [StepResult]?
        var onDeviceError: String?
        var onDeviceSeconds: Double?
        var claude: [StepResult]?
        var claudeError: String?
        var claudeSeconds: Double?
        var claudeUsage: [String: Int]?
    }

    @Generable
    struct ModelUse {
        @Guide(description: "Nummer der Zutatenzeile (Z-Nummer ohne Z)")
        var zeile: Int
        @Guide(description: "Menge, die dieser Schritt von der Zeile verwendet, z. B. \"150 g\" oder \"1/2 TL\"; leer, wenn die Zeile keine Menge hat oder der Schritt nur mit bereits Verarbeitetem weiterarbeitet")
        var menge: String
    }

    @Generable
    struct ModelStep {
        @Guide(description: "Nummer des Schritts (S-Nummer ohne S)")
        var schritt: Int
        @Guide(description: "Zutaten, die in diesem Schritt neu von der Zutatenliste genommen werden")
        var zutaten: [ModelUse]
    }

    @Generable
    struct ModelAnswer {
        var schritte: [ModelStep]
    }

    static let instructions = """
    Du liest ein deutsches Rezept und ordnest jedem Zubereitungsschritt die \
    Zutaten zu, die in diesem Schritt von der Zutatenliste genommen werden, \
    mit der Menge, die der Schritt davon braucht.

    Regeln:
    - Jede Zutatenzeile wird über alle Schritte hinweg höchstens so oft \
    verteilt, wie sie Menge hat. Wird eine Zutat auf mehrere Schritte \
    aufgeteilt, müssen die Teilmengen zusammen die Zeilenmenge ergeben.
    - Nennt der Schritt eine Zutat, die ein früherer Schritt schon vollständig \
    verarbeitet hat ("die Zwiebeln glasig dünsten" nach "Zwiebeln würfeln"), \
    wird sie nicht erneut genommen.
    - Steht eine Menge im Schritt, gilt sie. "Die Hälfte", "den Rest", \
    "restliche" rechnest du in eine Menge um.
    - Zeilen ohne Menge (Salz, Pfeffer) nimmst du mit leerer Menge auf, wenn \
    der Schritt sie verwendet — auch wenn sie nur gemeint sind ("abschmecken").
    - Nur Zeilen aus der Liste, keine erfundenen Zutaten. Schritte ohne Zutaten \
    bekommen eine leere Liste.
    """

    static func prompt(title: String, servings: Int, lines: [RecipeIngredient], steps: [RecipeStep]) -> String {
        let formatter = QuantityFormatter()
        var text = "Rezept: \(title) (für \(servings) Portionen)\n\nZutaten:\n"
        var lastGroup: String?
        for (index, line) in lines.enumerated() {
            if let group = line.group, group != lastGroup { text += "[\(group)]\n" }
            lastGroup = line.group
            text += "Z\(index + 1): \(formatter.string(for: line))\n"
        }
        text += "\nZubereitung:\n"
        lastGroup = nil
        for (index, step) in steps.enumerated() {
            if let group = step.group, group != lastGroup { text += "[\(group)]\n" }
            lastGroup = step.group
            text += "S\(index + 1): \(step.text)\n"
        }
        return text
    }

    /// What the resolver shows per step today: every line with an amount
    /// bound inline, then every chip.
    static func resolverOutput(for recipe: Recipe, lines: [RecipeIngredient], steps: [RecipeStep]) -> [StepResult] {
        let formatter = QuantityFormatter()
        let resolution = StepAmountResolver.resolve(recipe, toServings: recipe.servings)
        let indexByID = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.id, $0 + 1) })
        return steps.enumerated().map { stepIndex, step in
            var uses: [Use] = []
            let boundMarks = resolution.marks(for: step).filter { $0.kind == .bound }
            for (index, line) in lines.enumerated() where resolution.mentionsAmount(of: line, in: step) {
                let mark = boundMarks.first { $0.ingredientName == line.name }
                uses.append(Use(line: index + 1, amount: mark.map { String(step.text[$0.range]) }, inline: true))
            }
            for chip in recipe.ingredients(mentionedIn: step, resolution: resolution) {
                guard let index = indexByID[chip.id] else { continue }
                uses.append(Use(line: index, amount: chip.quantity.map { formatter.string(for: $0, size: chip.size) }, inline: false))
            }
            return StepResult(step: stepIndex + 1, uses: uses)
        }
    }

    /// The JSON shape Claude must answer in — the same fields as the
    /// on-device `ModelAnswer`, so both read through one path.
    nonisolated(unsafe) static let claudeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "schritte": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "schritt": ["type": "integer"],
                        "zutaten": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "zeile": ["type": "integer"],
                                    "menge": ["type": "string"],
                                ],
                                "required": ["zeile", "menge"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["schritt", "zutaten"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["schritte"],
        "additionalProperties": false,
    ]

    struct ClaudeReply {
        let steps: [StepResult]
        let usage: [String: Int]
    }

    static func askClaude(prompt: String, apiKey: String, model: String, effort: String?) async throws -> ClaudeReply {
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": claudeSchema]]
        if let effort { outputConfig["effort"] = effort }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": instructions,
            "fallbacks": "default",
            "output_config": outputConfig,
            "messages": [["role": "user", "content": prompt]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (status == 429 || status >= 500), attempt < 4 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt * attempt) * 5))
                continue
            }
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeBenchError.http(status, String(decoding: data, as: UTF8.self))
            }
            let stopReason = json["stop_reason"] as? String
            guard stopReason != "refusal", stopReason != "max_tokens" else {
                throw ClaudeBenchError.stopped(stopReason ?? "")
            }
            let blocks = json["content"] as? [[String: Any]] ?? []
            guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
                throw ClaudeBenchError.stopped("no text block")
            }
            struct Answer: Decodable {
                struct Step: Decodable { let schritt: Int; let zutaten: [Item] }
                struct Item: Decodable { let zeile: Int; let menge: String }
                let schritte: [Step]
            }
            let answer = try JSONDecoder().decode(Answer.self, from: Data(text.utf8))
            let usage = (json["usage"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int }
            return ClaudeReply(
                steps: answer.schritte.map { step in
                    StepResult(step: step.schritt, uses: step.zutaten.map {
                        Use(line: $0.zeile, amount: $0.menge.isEmpty ? nil : $0.menge, inline: nil)
                    })
                },
                usage: usage
            )
        }
    }

    enum ClaudeBenchError: Error {
        case http(Int, String)
        case stopped(String)
    }

    /// Writes the app's paste prompt per recipe to `SOUS_LLM_PASTE_OUT`, and
    /// where `<n>.answer.txt` sits beside it, a side-by-side of resolver and
    /// pasted answer with what `StepChipsPrompt.read` warns about.
    @Test("Paste prompts and pasted answers")
    func paste() throws {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env["SOUS_LLM_LIBRARY"], let outPath = env["SOUS_LLM_PASTE_OUT"] else { return }
        let picks = env["SOUS_LLM_PICK"]?.split(separator: ",").compactMap { Int($0) }
        let library = try JSONDecoder().decode([LibraryRecipe].self, from: Data(contentsOf: URL(fileURLWithPath: libraryPath)))
        try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
        let formatter = QuantityFormatter()
        let out = URL(fileURLWithPath: outPath)

        var report = ""
        for (index, entry) in library.enumerated() where picks?.contains(index) ?? true {
            let recipe = Recipe(title: entry.title, servings: entry.servings ?? 2, ingredientsText: entry.ingredientsText ?? "", instructionsText: entry.instructionsText ?? "")
            let lines = recipe.ingredients
            let steps = recipe.steps
            guard !lines.isEmpty, !steps.isEmpty else { continue }
            try StepChipsPrompt.prompt(for: recipe).write(to: out.appendingPathComponent("\(index).prompt.txt"), atomically: true, encoding: .utf8)

            let answerURL = out.appendingPathComponent("\(index).answer.txt")
            guard let pasted = try? String(contentsOf: answerURL, encoding: .utf8) else { continue }
            report += "\n=== [\(index)] \(recipe.title) (\(recipe.servings) Portionen)\n"
            for (lineIndex, line) in lines.enumerated() {
                report += "  Z\(lineIndex + 1): \(formatter.string(for: line))\n"
            }
            let reading: StepChipsPrompt.Reading
            switch StepChipsPrompt.read(pasted, for: recipe) {
            case .success(let value): reading = value
            case .failure(let failure):
                report += "  ABGELEHNT: \(failure.localizedDescription)\n"
                continue
            }
            let resolver = Self.resolverOutput(for: recipe, lines: lines, steps: steps)
            func describe(_ uses: [(line: Int, amount: String?)]) -> String {
                uses.map { "Z\($0.line)\($0.amount.map { " \($0)" } ?? "")" }.joined(separator: ", ")
            }
            for (stepIndex, step) in steps.enumerated() {
                let old = describe(resolver[stepIndex].uses.map { ($0.line, $0.amount) })
                let new = describe(reading.chips.usesByStep[stepIndex].map { ($0.line, $0.amount) })
                report += "\n  S\(stepIndex + 1): \(step.text)\n    Resolver: \(old)\n    LLM:      \(new)\(old == new ? "" : "   ≠")\n"
            }
            report += "\n  Warnungen: \(reading.warnings.isEmpty ? "keine" : reading.warnings.map { "\($0)" }.joined(separator: "; "))\n"
        }
        try report.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    @Test("Resolver vs. on-device model over a library dump")
    func bench() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env["SOUS_LLM_LIBRARY"], let outPath = env["SOUS_LLM_OUT"] else { return }
        var useModel = env["SOUS_LLM_ONDEVICE"] != "0"
        let limit = env["SOUS_LLM_LIMIT"].flatMap(Int.init) ?? .max
        let library = try JSONDecoder().decode([LibraryRecipe].self, from: Data(contentsOf: URL(fileURLWithPath: libraryPath)))
        try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)

        if useModel, case .unavailable(let reason) = SystemLanguageModel.default.availability {
            print("On-device model unavailable, skipped: \(reason)")
            useModel = false
        }

        var results: [RecipeResult] = []
        for entry in library.prefix(limit) {
            let recipe = Recipe(
                title: entry.title,
                servings: entry.servings ?? 2,
                ingredientsText: entry.ingredientsText ?? "",
                instructionsText: entry.instructionsText ?? ""
            )
            let lines = recipe.ingredients
            let steps = recipe.steps
            guard !lines.isEmpty, !steps.isEmpty else { continue }
            let formatter = QuantityFormatter()
            let prompt = Self.prompt(title: recipe.title, servings: recipe.servings, lines: lines, steps: steps)
            var result = RecipeResult(
                title: recipe.title,
                servings: recipe.servings,
                lines: lines.map { formatter.string(for: $0) },
                steps: steps.map(\.text),
                prompt: prompt,
                resolver: Self.resolverOutput(for: recipe, lines: lines, steps: steps)
            )

            if useModel {
                let start = Date()
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(
                        to: prompt,
                        generating: ModelAnswer.self,
                        options: GenerationOptions(temperature: 0)
                    )
                    result.onDevice = response.content.schritte.map { step in
                        StepResult(step: step.schritt, uses: step.zutaten.map {
                            Use(line: $0.zeile, amount: $0.menge.isEmpty ? nil : $0.menge, inline: nil)
                        })
                    }
                } catch {
                    result.onDeviceError = String(describing: error)
                }
                result.onDeviceSeconds = Date().timeIntervalSince(start)
                print("[\(results.count + 1)] \(recipe.title): \(result.onDeviceError == nil ? "ok" : "error") \(String(format: "%.1f", result.onDeviceSeconds ?? 0)) s")
            }
            results.append(result)
        }

        if let apiKey = env["ANTHROPIC_API_KEY"], !apiKey.isEmpty {
            let model = env["SOUS_LLM_CLAUDE_MODEL"] ?? "claude-opus-5"
            let effort = env["SOUS_LLM_CLAUDE_EFFORT"]
            let prompts = results.map(\.prompt)
            let replies = await withTaskGroup(of: (Int, Result<ClaudeReply, Error>, Double).self) { group in
                var collected: [(Int, Result<ClaudeReply, Error>, Double)] = []
                var next = 0
                func add() {
                    let index = next
                    next += 1
                    group.addTask {
                        let start = Date()
                        do {
                            let reply = try await Self.askClaude(prompt: prompts[index], apiKey: apiKey, model: model, effort: effort)
                            return (index, .success(reply), Date().timeIntervalSince(start))
                        } catch {
                            return (index, .failure(error), Date().timeIntervalSince(start))
                        }
                    }
                }
                for _ in 0..<min(6, prompts.count) { add() }
                while let reply = await group.next() {
                    collected.append(reply)
                    print("[claude \(collected.count)/\(prompts.count)] \(results[reply.0].title)")
                    if next < prompts.count { add() }
                }
                return collected
            }
            for (index, reply, seconds) in replies {
                results[index].claudeSeconds = seconds
                switch reply {
                case .success(let value):
                    results[index].claude = value.steps
                    results[index].claudeUsage = value.usage
                case .failure(let error):
                    results[index].claudeError = String(describing: error)
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: URL(fileURLWithPath: outPath).appendingPathComponent("bench.json"))
    }
}
