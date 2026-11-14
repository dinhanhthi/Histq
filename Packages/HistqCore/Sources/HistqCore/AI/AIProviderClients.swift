// The streaming chat requests of the two wires (ported from Dblore's `OpenAICompatibleClient` and `AnthropicClient`,
// text only). OpenAI, Gemini (through its OpenAI-compatible endpoint), xAI and custom servers speak
// chat-completions; Anthropic speaks Messages. The key goes in a header only, never in the URL or the body.
import Foundation

enum AIProviderRequests {
    /// Required by the Messages API (docs.anthropic.com, verified in Dblore 2026-09).
    static let anthropicVersion = "2023-06-01"

    static func make(_ request: AIChatRequest, provider: AIProvider, baseURL: URL, apiKey: String) -> URLRequest {
        switch provider.wire {
        case .chatCompletions: chatCompletions(request, provider: provider, baseURL: baseURL, apiKey: apiKey)
        case .anthropicMessages: anthropicMessages(request, baseURL: baseURL, apiKey: apiKey)
        }
    }

    /// `POST <base>/chat/completions` with `Authorization: Bearer <key>` (no header when a custom server takes no
    /// key).
    static func chatCompletions(
        _ request: AIChatRequest, provider: AIProvider, baseURL: URL, apiKey: String
    ) -> URLRequest {
        var urlRequest = streamingPOST(AIEndpoint.chatURL(base: baseURL, wire: .chatCompletions))
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = ["model": request.model, "messages": messages, "stream": true]
        // The hosted providers get no cap: api.openai.com rejects `max_tokens` on o-series and GPT-5+ models, and
        // its replacement, like Gemini's and xAI's output caps, also counts hidden reasoning tokens, so a small cap
        // could be spent on reasoning and return no answer (the model's own limit applies instead). A custom server
        // still gets `max_tokens`, since some local servers default to a very short answer without it.
        if provider == .custom { body["max_tokens"] = request.maxTokens }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// `POST <base>/messages` with `x-api-key` and `anthropic-version`; `max_tokens` is required there.
    static func anthropicMessages(_ request: AIChatRequest, baseURL: URL, apiKey: String) -> URLRequest {
        var urlRequest = streamingPOST(AIEndpoint.chatURL(base: baseURL, wire: .anthropicMessages))
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "max_tokens": request.maxTokens,
            "stream": true,
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func streamingPOST(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
}
