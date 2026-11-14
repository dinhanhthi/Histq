// The cloud AI providers Histq can call (ported from Dblore's `AIProviderKind`, cut down to text-only streaming chat
// over an API key: no OAuth, no local models, no Apple Intelligence). The spec's "codex" is `.openAI`: OpenAI and
// Codex models through an OpenAI API key. Gemini is reached through its OpenAI-compatible endpoint, so every
// provider but Anthropic speaks the chat-completions wire.
import Foundation

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openAI, anthropic, gemini, xAI, custom

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .xAI: "xAI (Grok)"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    public var wire: AIWire {
        self == .anthropic ? .anthropicMessages : .chatCompletions
    }

    /// The base URL a built-in provider always uses; empty for `.custom`, whose URL the user enters. A built-in
    /// provider never takes a user URL, so its key can only ever reach its own host.
    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .xAI: "https://api.x.ai/v1"
        case .custom: ""
        }
    }

    /// A custom endpoint is often a local server that takes no key; every built-in provider needs one.
    public var requiresAPIKey: Bool { self != .custom }

    /// The editable default model of the provider (see `AIDefaultModels`); empty for `.custom`.
    public var defaultModel: String { AIDefaultModels.table[self] ?? "" }
}

/// The providers' flagship model ids at the time of writing, in one place so they are easy to update. They are only
/// defaults: the user can type any model id in Settings, and ids change as providers ship new models.
public enum AIDefaultModels {
    public static let table: [AIProvider: String] = [
        .openAI: "gpt-5.1",
        .anthropic: "claude-sonnet-5-5",
        .gemini: "gemini-2.5-pro",
        .xAI: "grok-4",
    ]
}
