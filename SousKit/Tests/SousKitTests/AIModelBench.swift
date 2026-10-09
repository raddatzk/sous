import Foundation
import Testing
@testable import SousKit

/// A throwaway bench that asks real chat models to do Sous's tasks and
/// scores the answers with the same strict readers the app uses.
///
/// It spends money, so it never runs with the normal suite. Start it with
/// `SOUS_AI_BENCH=list` (model lists only, free) or `SOUS_AI_BENCH=run`
/// (needs `SOUS_AI_BENCH_MODELS`, a file with one `provider: model` per line).
/// Keys come from `~/.sous-bench-keys`; they are never printed or written.
/// Results go to the directory in `SOUS_AI_BENCH_OUT`.
@Suite("AI model bench", .serialized)
struct AIModelBench {
    private static let mode = ProcessInfo.processInfo.environment["SOUS_AI_BENCH"]

    /// provider name → key variable
    private static let keyNames = [
        "Anthropic": "ANTHROPIC_API_KEY", "OpenAI": "OPENAI_API_KEY",
        "Grok": "GROK_API_KEY", "Gemini": "GEMINI_API_KEY",
    ]

    private static func keys() -> [String: String] {
        let path = NSString(string: "~/.sous-bench-keys").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var found: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            }
            if parts.count == 2, !parts[1].isEmpty { found[parts[0]] = parts[1] }
        }
        return found
    }

    private static func client(_ providerName: String, model: String = "", tuned: Bool = false) -> LLMClient? {
        guard let base = LLMProvider.presets.first(where: { $0.name == providerName }),
            let variable = keyNames[providerName], let key = keys()[variable]
        else { return nil }
        var provider = base
        provider.model = model
        let environment = ProcessInfo.processInfo.environment
        if base.kind == .anthropic {
            provider.effort = environment["SOUS_AI_BENCH_EFFORT"]
            provider.disablesThinking = environment["SOUS_AI_BENCH_THINKING"] == "off" ? true : nil
        }
        if tuned { provider = LLMModelAdvice.tuned(provider) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        return LLMClient(provider: provider, apiKey: key, session: URLSession(configuration: configuration))
    }

    private static var outDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOUS_AI_BENCH_OUT"] ?? NSTemporaryDirectory())
    }

    @Test("Lists what each provider offers", .enabled(if: mode == "list"))
    func list() async throws {
        var report = ""
        for name in ["Anthropic", "OpenAI", "Grok", "Gemini"] {
            report += "## \(name)\n"
            guard let client = Self.client(name) else { report += "no key\n\n"; continue }
            do {
                let models = try await client.models()
                report += models.map { "\($0.id)\t\($0.name == $0.id ? "" : $0.name)" }.joined(separator: "\n") + "\n\n"
            } catch {
                report += "failed: \(error)\n\n"
            }
        }
        try report.write(to: Self.outDirectory.appending(path: "models.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor
    @Test("Talks to a real model about a recipe, with a follow-up", .enabled(if: mode == "chat"))
    func chat() async throws {
        let model = ProcessInfo.processInfo.environment["SOUS_AI_BENCH_CHAT_MODEL"] ?? "claude-haiku-5-5"
        let client = try #require(Self.client("Anthropic", model: model, tuned: true))
        let chat = RecipeEditChat(client: client)
        let recipe = Self.optimizeRecipes[1]
        let template = try #require(PromptTemplate.builtIn.first { $0.title == "Vegan machen" })
        chat.start(prompt: RecipeReplacementPrompt.prompt(task: template.text, for: recipe, showsRecipe: false), shown: template.title)
        var sawPartial = false
        while chat.isAnswering {
            if let partial = chat.partial, !partial.isEmpty { sawPartial = true }
            try await Task.sleep(for: .milliseconds(50))
        }
        var report = "streamed: \(sawPartial)\nfailure: \(chat.failure ?? "-")\nproposal after first: \(chat.proposal?.title ?? "-")\n"
        chat.send("Nimm bitte Margarine statt Öl.")
        while chat.isAnswering { try await Task.sleep(for: .milliseconds(50)) }
        report += "failure: \(chat.failure ?? "-")\nproposal after follow-up: \(chat.proposal?.title ?? "-")\n"
        report += "turns: \(chat.turns.map { "\($0.kind)" }.joined(separator: ","))\n"
        for turn in chat.turns where turn.kind == .model {
            let shown = RecipeEditChat.visible(turn.text)
            report += "model said (\(shown.text.count) characters, recipe block: \(shown.showsRecipe)): \(shown.text.prefix(300))\n"
        }
        report += "ingredients: \(chat.proposal?.ingredientsText.replacingOccurrences(of: "\n", with: " | ") ?? "-")\n"
        if let proposal = chat.proposal {
            let edited = proposal.applied(to: recipe, fields: .standard)
            report += "in form before tidying: \(edited.isOptimizedForSous)\n"
            let start = Date()
            if let result = try await RecipeTidier.tidy(edited, backend: client) {
                switch result {
                case .success(let tidied):
                    report += "tidied in \(Int(Date().timeIntervalSince(start))) s, in form now: \(tidied.isOptimizedForSous)\n"
                    report += "tidied ingredients: \(tidied.ingredientsText.replacingOccurrences(of: "\n", with: " | "))\n"
                case .failure(let failure):
                    report += "tidying failed: \(failure)\n"
                }
            } else {
                report += "nothing to tidy\n"
            }
        }
        try report.write(to: Self.outDirectory.appending(path: "chat.txt"), atomically: true, encoding: .utf8)
    }

    @Test("Asks twice with the same start and reports what the provider kept", .enabled(if: mode == "cache"))
    func cache() async throws {
        let models = [("Anthropic", "claude-haiku-5-5"), ("Grok", "grok-4.20-0309-non-reasoning"),
                      ("OpenAI", "gpt-5.4-mini"), ("Gemini", "gemini-3.5-flash-lite")]
        var report = "provider\tmodel\trequest\tinput\tcache read\tcache written\toutput\tseconds\n"
        for (name, model) in models {
            guard let client = Self.client(name, model: model, tuned: true) else { continue }
            for (index, recipe) in [Self.optimizeRecipes[0], Self.optimizeRecipes[2], Self.optimizeRecipes[3]].enumerated() {
                let parts = RecipeOptimizationPrompt.parts(for: recipe)
                let start = Date()
                do {
                    let reply = try await client.complete([LLMMessage(.user, parts.rest, cachedPrefix: parts.prefix)])
                    report += "\(name)\t\(model)\t\(index + 1)\t\(reply.inputTokens ?? -1)\t\(reply.cachedInputTokens ?? 0)\t\(reply.cacheWriteTokens ?? 0)\t\(reply.outputTokens ?? -1)\t\(Int(Date().timeIntervalSince(start)))\n"
                } catch {
                    report += "\(name)\t\(model)\t\(index + 1)\terror: \(error)\n"
                }
            }
        }
        try report.write(to: Self.outDirectory.appending(path: "cache.tsv"), atomically: true, encoding: .utf8)
    }

    // MARK: Cases

    struct Case {
        let recipe: Recipe
        let forbidden: [String]
    }

    static let optimizeRecipes: [Recipe] = [
        Recipe(
            title: "Spaghetti Bolognese", servings: 4,
            ingredientsText: """
                500g Rinderhackfleisch
                2 Zwiebeln, fein gehackt
                1 Knoblauchzehe (oder 2)
                1 Dose gehackte Tomaten (400 g)
                2 EL Tomatenmark
                Salz & Pfeffer nach Belieben
                400 g Spaghetti
                Olivenöl zum Anbraten
                """,
            instructionsText: "Zwiebeln und Knoblauch anbraten.\nHack dazugeben und krümelig braten.\nTomaten und Tomatenmark zugeben, 30 Minuten köcheln.\nSpaghetti kochen und mit der Soße servieren."
        ),
        Recipe(
            title: "Pfannkuchen", servings: 4,
            ingredientsText: """
                250g Mehl (Type 405)
                1/2 l Milch
                3 Eier (M)
                1 Prise Salz
                2 EL Zucker
                etwas Butter zum Ausbacken
                """,
            instructionsText: "Mehl, Milch, Eier, Salz und Zucker verrühren.\nTeig 15 Minuten quellen lassen.\nIn Butter goldbraun ausbacken."
        ),
        Recipe(
            title: "Kürbissuppe", servings: 4,
            ingredientsText: """
                1 Hokkaido-Kürbis (ca. 800 g)
                1 Zwiebel
                1 Stück Ingwer, ca. daumengroß, gerieben
                1 EL Currypulver
                800 ml Gemüsebrühe
                200 ml Kokosmilch
                Saft einer halben Limette
                Kürbiskernöl, nach Geschmack
                """,
            instructionsText: "Kürbis würfeln, Zwiebel würfeln.\nAlles in Öl anschwitzen, Curry und Ingwer zugeben.\nMit Brühe aufgießen, 20 Minuten kochen.\nPürieren, Kokosmilch einrühren, mit Limette abschmecken."
        ),
        Recipe(
            title: "Tomatensalat", servings: 2,
            ingredientsText: """
                500 g Tomaten, in Scheiben
                1 rote Zwiebel
                3 EL Essig
                4 EL Öl
                1 TL Zucker
                frische Petersilie, gehackt
                Salz, Pfeffer
                """,
            instructionsText: "Tomaten und Zwiebel schneiden.\nAus Essig, Öl, Zucker, Salz und Pfeffer ein Dressing rühren.\nAlles mischen und 10 Minuten ziehen lassen."
        ),
        Recipe(
            title: "Linsencurry", servings: 3,
            ingredientsText: """
                250 g rote Linsen
                1 Dose Kokosmilch
                1 Zwiebel, gewürfelt
                2 Karotten
                2 TL Currypaste
                Koriander (optional)
                500 ml Wasser
                """,
            instructionsText: "Zwiebel und Karotten anbraten.\nCurrypaste zugeben, Linsen, Wasser und Kokosmilch dazu.\n20 Minuten köcheln."
        ),
    ]

    static let editCases: [(task: String, recipe: Recipe, forbidden: [String])] = [
        ("Vegan machen", optimizeRecipes[0], ["hackfleisch", "rind", "fleisch", "käse", "butter", "milch", "ei "]),
        ("Vegan machen", optimizeRecipes[1], ["milch", "eier", "ei ", "butter"]),
        ("Glutenfrei machen", optimizeRecipes[0], ["spaghetti", "weizen", "nudeln", "pasta"]),
        ("Glutenfrei machen", optimizeRecipes[1], ["type 405", "weizen"]),
    ]

    struct Row {
        var task: String
        var recipe: String
        var passed: Bool
        var note: String
        var seconds: Double
        var input: Int?
        var output: Int?
    }

    @Test("Runs the models in SOUS_AI_BENCH_MODELS through the tasks", .enabled(if: mode == "run"))
    func run() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SOUS_AI_BENCH_MODELS"])
        let entries = try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && !parts[0].hasPrefix("#") ? (parts[0], parts[1]) : nil
            }

        // One task per provider, so the providers run side by side while each
        // provider's requests stay in a row (and within its rate limits).
        let byProvider = Dictionary(grouping: entries, by: \.0)
        let lines = LineCollector()
        await withTaskGroup(of: Void.self) { group in
            for (providerName, models) in byProvider {
                group.addTask {
                    for (_, model) in models {
                        guard let client = Self.client(providerName, model: model, tuned: ProcessInfo.processInfo.environment["SOUS_AI_BENCH_TUNED"] == "1") else {
                            await lines.add("\(providerName)\t\(model)\t-\t-\tno key\n")
                            continue
                        }
                        for row in await Self.rows(client) {
                            await lines.add([
                                providerName, model, row.task, row.recipe, row.passed ? "yes" : "no",
                                String(format: "%.1f", row.seconds), row.input.map(String.init) ?? "",
                                row.output.map(String.init) ?? "", row.note,
                            ].joined(separator: "\t") + "\n")
                        }
                        // Written after every model, so an aborted run keeps what it has.
                        try? await lines.text.write(
                            to: Self.outDirectory.appending(path: "results.tsv"), atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }

    private actor LineCollector {
        private(set) var text = "provider\tmodel\ttask\trecipe\tpassed\tseconds\tinput\toutput\tnote\n"
        func add(_ line: String) { text += line }
    }

    private static let only = ProcessInfo.processInfo.environment["SOUS_AI_BENCH_TASKS"]

    private static func rows(_ client: LLMClient) async -> [Row] {
        var rows: [Row] = []

        for recipe in optimizeRecipes where only == nil || only == "optimize" {
            let parts = RecipeOptimizationPrompt.parts(
                for: recipe, catalog: .current, excerpt: ProcessInfo.processInfo.environment["SOUS_AI_BENCH_EXCERPT"] == "1")
            rows.append(await measure("optimize", recipe.title, client, parts.prefix + parts.rest, retry: nil) {
                scoreOptimize($0, recipe)
            })
        }

        for item in editCases where only == nil || only == "edit" {
            let template = PromptTemplate.builtIn.first { $0.title == item.task }!
            let prompt = RecipeReplacementPrompt.prompt(task: template.text, for: item.recipe)
            rows.append(await measure(
                "edit: \(item.task)", item.recipe.title, client, prompt,
                retry: "Bitte hänge den aktuellen Stand des Rezepts als JSON-Codeblock in der beschriebenen Form an."
            ) { scoreEdit($0, item) })
        }
        return rows
    }

    static func scoreOptimize(_ text: String, _ recipe: Recipe) -> (Bool, String) {
        switch RecipeOptimizationPrompt.read(text, for: recipe, catalog: .current, nutritionCatalog: .current) {
        case .failure(let failure):
            return (false, "unreadable: \(failure)")
        case .success(let result):
            let refused = result.lines.filter(\.isRefused).count
            let changed = result.lines.filter(\.isChanged).count
            let known = result.lines.filter(\.resolves).count
            return (refused == 0, "\(changed) changed, \(refused) refused of \(result.lines.count); \(known) known to the catalog, \(result.classifications.count) classified")
        }
    }

    static func scoreEdit(_ text: String, _ item: (task: String, recipe: Recipe, forbidden: [String])) -> (Bool, String) {
        switch RecipeReplacementPrompt.read(text) {
        case .failure(let failure):
            return (false, "unreadable: \(failure)")
        case .success(let result):
            // A line that calls itself gluten-free ("glutenfreie Spaghetti") is the answer, not the fault;
            // buckwheat is no wheat.
            let lines = result.ingredientsText.lowercased()
                .replacingOccurrences(of: "buchweizen", with: "buchkorn")
                .replacingOccurrences(of: "hafermilch", with: "haferdrink")
                .replacingOccurrences(of: "sojamilch", with: "sojadrink")
                .replacingOccurrences(of: "mandelmilch", with: "mandeldrink")
                .replacingOccurrences(of: "reismilch", with: "reisdrink")
                .replacingOccurrences(of: "kokosmilch", with: "kokosdrink")
                .split(whereSeparator: \.isNewline)
                // Group headings ("# Für die Nudeln") are not ingredients.
                .filter { !$0.hasPrefix("#") && !$0.contains("glutenfrei") && !$0.contains("gluten-frei") }
                .map { $0 + "\n" }
            let hits = item.forbidden.filter { word in lines.contains { $0.contains(word) } }
            let steps = result.instructionsText.split(whereSeparator: \.isNewline).count
            let sameServings = result.servings == nil || result.servings == item.recipe.servings
            let ok = hits.isEmpty && steps >= 2 && sameServings
            return (ok, hits.isEmpty ? "ok" : "still has: \(hits.joined(separator: ", "))")
        }
    }

    @Test("Scores saved answers again, without asking anyone", .enabled(if: mode == "rescore"))
    func rescore() throws {
        let directories = try #require(ProcessInfo.processInfo.environment["SOUS_AI_BENCH_ANSWERS"])
            .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        var report = "provider\tmodel\ttask\trecipe\tpassed\tseconds\tinput\toutput\tnote\n"
        for directory in directories {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let parts = file.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
                guard parts.count == 3, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let title = parts[2].replacingOccurrences(of: "_", with: " ")
                let scored: (Bool, String)?
                if parts[1] == "optimize" {
                    scored = Self.optimizeRecipes.first { $0.title == title }.map { Self.scoreOptimize(text, $0) }
                } else {
                    let task = parts[1].replacingOccurrences(of: "edit:_", with: "").replacingOccurrences(of: "_", with: " ")
                    scored = Self.editCases.first { $0.task == task && $0.recipe.title == title }.map { Self.scoreEdit(text, $0) }
                }
                guard let (passed, note) = scored else { continue }
                report += "-\t\(parts[0])\t\(parts[1].replacingOccurrences(of: "_", with: " "))\t\(title)\t\(passed ? "yes" : "no")\t0\t0\t0\t\(note)\n"
            }
        }
        try report.write(to: Self.outDirectory.appending(path: "rescored.tsv"), atomically: true, encoding: .utf8)
    }

    private static func save(_ text: String, task: String, recipe: String, model: String) {
        let directory = outDirectory.appending(path: "answers")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(model)--\(task)--\(recipe)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        try? text.write(to: directory.appending(path: name + ".txt"), atomically: true, encoding: .utf8)
    }

    private static func measure(
        _ task: String, _ recipe: String, _ client: LLMClient, _ prompt: String, retry: String?,
        score: (String) -> (Bool, String)
    ) async -> Row {
        let start = Date()
        do {
            var reply = try await client.complete([LLMMessage(.user, prompt)])
            save(reply.text, task: task, recipe: recipe, model: client.provider.model)
            var (passed, note) = score(reply.text)
            if reply.wasCutOff { note += " (cut off at the token limit)" }
            // A model that answered in prose and forgot the JSON block gets asked once for it.
            if !passed, let retry, note.contains("noAnswer") {
                let again = try await client.complete([
                    LLMMessage(.user, prompt), LLMMessage(.assistant, reply.text), LLMMessage(.user, retry),
                ])
                save(again.text, task: task + "-retry", recipe: recipe, model: client.provider.model)
                (passed, note) = score(again.text)
                note = "after retry: " + note
                reply = LLMReply(
                    text: again.text,
                    inputTokens: (reply.inputTokens ?? 0) + (again.inputTokens ?? 0),
                    outputTokens: (reply.outputTokens ?? 0) + (again.outputTokens ?? 0))
            }
            return Row(
                task: task, recipe: recipe, passed: passed, note: note,
                seconds: Date().timeIntervalSince(start), input: reply.inputTokens, output: reply.outputTokens)
        } catch {
            return Row(
                task: task, recipe: recipe, passed: false, note: "error: \(error)",
                seconds: Date().timeIntervalSince(start), input: nil, output: nil)
        }
    }
}
