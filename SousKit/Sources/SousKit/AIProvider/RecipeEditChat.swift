import Foundation
import Observation

/// A conversation with a chat model about rewriting one recipe: the cook's
/// request goes out with the recipe and the catalog, the answer streams in,
/// the cook can ask again, and the last recipe the model showed is kept as
/// the proposal.
///
/// The model shows the recipe readable and ends every such answer with the
/// JSON block ``RecipeReplacementPrompt`` asks for; the block is what
/// becomes the proposal, read by the same strict reader as a pasted one.
/// Nothing here writes to the library.
@MainActor @Observable
public final class RecipeEditChat {
    public struct Turn: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case cook, model, note }

        public let id = UUID()
        public let kind: Kind
        /// What the transcript shows; for the cook's first turn the request,
        /// not the whole prompt with the catalog.
        public let text: String
    }

    public private(set) var turns: [Turn] = []
    /// The answer so far, while it streams.
    public private(set) var partial: String?
    public private(set) var isAnswering = false
    /// The recipe of the latest answer that showed one and could be read.
    public private(set) var proposal: RecipeReplacement?
    public private(set) var failure: String?
    /// What went wrong, for a sheet that offers something other than the
    /// message (another key, say).
    public private(set) var failureError: (any Error)?

    /// What the model has been sent and has said, as the API wants it.
    private var messages: [LLMMessage] = []
    private var answers = 0
    private var task: Task<Void, Never>?
    private var client: LLMClient

    static let askForTheBlock = """
        Bitte hänge den aktuellen Stand des Rezepts als JSON-Codeblock in der beschriebenen Form an.
        """

    public init(client: LLMClient) {
        self.client = client
    }

    /// The first question: the whole `prompt` is sent, `shown` is what the
    /// transcript says the cook asked.
    public func start(prompt: String, shown: String) {
        ask(LLMMessage(.user, prompt), shown: Turn(kind: .cook, text: shown))
    }

    /// The same, with the part of the prompt that is the same every time sent
    /// ahead so that the provider can keep it.
    public func start(cachedPrefix: String, then rest: String, shown: String) {
        ask(LLMMessage(.user, rest, cachedPrefix: cachedPrefix), shown: Turn(kind: .cook, text: shown))
    }

    /// A follow-up.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ask(LLMMessage(.user, trimmed), shown: Turn(kind: .cook, text: trimmed))
    }

    /// Asks the last question again through `other`, after the first
    /// client was refused or ran out of limit. What the cook asked is not
    /// asked twice; the failed answer is simply tried again.
    public func retry(using other: LLMClient) {
        guard !isAnswering, failureError != nil, messages.last?.role == .user else { return }
        client = other
        failure = nil
        failureError = nil
        isAnswering = true
        task = Task { await self.answer(retryingWithoutBlock: answers == 0) }
    }

    /// Stops the answer in progress and keeps what has arrived.
    public func cancel() {
        task?.cancel()
    }

    private func ask(_ message: LLMMessage, shown: Turn) {
        guard !isAnswering else { return }
        turns.append(shown)
        messages.append(message)
        failure = nil
        failureError = nil
        isAnswering = true
        task = Task { await self.answer(retryingWithoutBlock: answers == 0) }
    }

    private func answer(retryingWithoutBlock: Bool) async {
        defer {
            isAnswering = false
            partial = nil
        }
        var text = ""
        partial = ""
        do {
            for try await piece in client.stream(messages) {
                text += piece
                partial = text
            }
        } catch {
            // What arrived stays in the transcript; the cook sees why it stopped.
            if !text.isEmpty { record(text) }
            if !(error is CancellationError) && !Task.isCancelled {
                failure = error.localizedDescription
                failureError = error
            }
            return
        }
        if Task.isCancelled {
            if !text.isEmpty { record(text) }
            return
        }
        record(text)
        answers += 1

        switch RecipeReplacementPrompt.read(text) {
        case .success(let recipe):
            proposal = recipe
        case .failure(.noAnswer):
            // A later answer may rightly be only talk, and the proposal stands.
            // The first has to show a recipe: ask once for the block.
            guard retryingWithoutBlock else { return }
            turns.append(Turn(kind: .note, text: "Sous bittet um den Rezeptstand als JSON-Block."))
            messages.append(LLMMessage(.user, Self.askForTheBlock))
            await answer(retryingWithoutBlock: false)
        case .failure(let reason):
            proposal = nil
            failure = reason.localizedDescription
        }
    }

    private func record(_ text: String) {
        messages.append(LLMMessage(.assistant, text))
        turns.append(Turn(kind: .model, text: text))
    }

    /// An answer as the transcript shows it: the talk, without the JSON block
    /// that carries the recipe to Sous. `showsRecipe` says there was one.
    public static func visible(_ text: String) -> (text: String, showsRecipe: Bool) {
        guard let fence = text.range(of: "```json", options: .backwards) else { return (text, false) }
        return (String(text[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), true)
    }
}
