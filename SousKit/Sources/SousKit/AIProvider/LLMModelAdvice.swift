import Foundation

/// Which of a provider's models to offer, and which to suggest.
///
/// A model list says nothing about price or what a model is for, so the
/// advice is the community's judgement, kept in `Community/ki/` with what the
/// bench found (`AIModelBench`) and carried in the data set. A suggestion only
/// counts if the provider's own list still has it.
public enum LLMModelAdvice {
    /// The catalog's models for a provider, best first; none for one the
    /// cook entered.
    static func advised(for provider: LLMProvider) -> [AIProviderCatalog.Entry.API.Model] {
        provider.catalogEntry?.api?.models ?? []
    }

    /// The provider with the settings the catalog advises for its model (low
    /// effort, thinking off, where the bench found that as good and faster);
    /// as it is for a model without advice or one the cook already tuned.
    public static func tuned(_ provider: LLMProvider) -> LLMProvider {
        guard provider.kind == .anthropic, provider.effort == nil, provider.disablesThinking == nil,
            let advice = advised(for: provider).first(where: { $0.id == provider.model })
        else { return provider }
        var tuned = provider
        tuned.effort = advice.effort
        tuned.disablesThinking = advice.thinking == false ? true : nil
        return tuned
    }

    /// The suggested models the provider offers, in the order of the advice.
    public static func suggestions(in models: [LLMModel], for provider: LLMProvider) -> [LLMModel] {
        advised(for: provider).compactMap { advice in models.first { $0.id == advice.id } }
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
