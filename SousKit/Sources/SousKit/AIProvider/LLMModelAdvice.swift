import Foundation

/// Which of a provider's models to offer, and which to suggest.
///
/// A model list says nothing about price or what a model is for, so this is
/// a judgement kept in code: a list of ids measured with the bench
/// (`AIModelBench`) and an app update can change it. A suggestion only
/// counts if the provider's own list still has it.
public enum LLMModelAdvice {
    /// Suggested models by provider name, best first.
    static let suggested: [String: [String]] = [
        "Anthropic": ["claude-haiku-5-5", "claude-haiku-4-5-20251001", "claude-sonnet-5-5"],
        "OpenAI": ["gpt-5.4-mini", "gpt-5.6-luna"],
        "Grok": ["grok-4.20-0309-non-reasoning"],
        "Gemini": ["gemini-3.5-flash-lite", "gemini-3.5-flash"],
    ]

    /// What a model should be asked with, measured with the bench. Haiku 5.5
    /// thinks at length by default (about 6,000 output tokens and 25 s per
    /// request); at low effort without thinking it did the same tasks in 5 s
    /// and about 1,100 tokens, and passed all of them.
    private static let tuning: [String: (effort: String, disablesThinking: Bool)] = [
        "claude-haiku-5-5": ("low", true),
    ]

    /// The provider with the settings advised for its model; as it is for a
    /// model without advice or one the cook already tuned.
    public static func tuned(_ provider: LLMProvider) -> LLMProvider {
        guard provider.kind == .anthropic, provider.effort == nil, provider.disablesThinking == nil,
            let advice = tuning[provider.model]
        else { return provider }
        var tuned = provider
        tuned.effort = advice.effort
        tuned.disablesThinking = advice.disablesThinking
        return tuned
    }

    /// The suggested models the provider offers, in the order of the advice.
    public static func suggestions(in models: [LLMModel], for provider: LLMProvider) -> [LLMModel] {
        (suggested[provider.name] ?? []).compactMap { id in models.first { $0.id == id } }
    }

    /// Words of models that do not write text, in the lists that mix them in.
    private static let notForChat = [
        "embed", "whisper", "tts", "transcribe", "dall-e", "image", "imagine", "moderation",
        "realtime", "audio", "live", "sora", "veo", "lyria", "video", "babbage", "davinci",
        "aqa", "nano-banana", "robotics", "computer-use", "antigravity", "deep-research",
        "translate", "search-api", "search-preview",
    ]

    /// Whether a model plausibly answers in text. Only the obvious is left
    /// out; a name this does not know stays in.
    public static func looksLikeChat(_ model: LLMModel) -> Bool {
        let id = model.id.lowercased()
        return !notForChat.contains { id.contains($0) }
    }

    /// The list as the picker shows it: without the models that cannot chat.
    public static func chatModels(_ models: [LLMModel]) -> [LLMModel] {
        models.filter(looksLikeChat)
    }
}
